# Flux Config Module
# Creates Kubernetes resources for Flux OCI-based GitOps
# Deploys: 1 OCIRepository + 3-6 Kustomizations (platform → platform-config → [onprem] → role-specific → [cc-config] → [cc-routes])

locals {
  has_oci_credentials = var.oci_repo_username != "" && var.oci_repo_password != ""
  is_onprem           = var.infra_provider == "proxmox"

  # Extract registry host from artifact URL (e.g. "oci://ghcr.io/kiswend/ml-iac3" → "ghcr.io")
  oci_registry = local.has_oci_credentials ? split("/", replace(var.artifact_url, "oci://", ""))[0] : ""

  # Docker config JSON for Flux source-controller authentication
  dockerconfigjson = local.has_oci_credentials ? jsonencode({
    auths = {
      (local.oci_registry) = {
        username = var.oci_repo_username
        password = var.oci_repo_password
        auth     = base64encode("${var.oci_repo_username}:${var.oci_repo_password}")
      }
    }
  }) : ""
}

# ConfigMap with cluster configuration for postBuild substitution
resource "kubernetes_config_map_v1" "cluster_config" {
  metadata {
    name      = "cluster-config"
    namespace = var.flux_namespace
  }

  data = {
    cluster_name  = var.cluster_name
    cluster_vip   = var.cluster_vip
    domain        = var.domain
    dns_provider  = var.dns_provider
    alert_email   = var.alert_email
    lb_ipam_range = var.lb_ipam_range
    lb_ipam_start = split("-", var.lb_ipam_range)[0]
    lb_ipam_stop  = split("-", var.lb_ipam_range)[1]
  }
}

# Secret with sensitive credentials for postBuild substitution
resource "kubernetes_secret_v1" "cluster_secrets" {
  metadata {
    name      = "cluster-secrets"
    namespace = var.flux_namespace
  }

  data = {
    digitalocean_token    = var.digitalocean_token
    oci_repo_username     = var.oci_repo_username
    oci_repo_password     = var.oci_repo_password
    oci_proxy_username    = var.oci_proxy_username
    oci_proxy_password    = var.oci_proxy_password
    minio_root_user       = var.minio_root_user
    minio_root_password   = var.minio_root_password
    harbor_admin_password = var.harbor_admin_password
  }

  type = "Opaque"
}

# OCI registry credentials secret (for Flux source-controller to pull from private registry)
resource "kubernetes_secret_v1" "oci_credentials" {
  count = local.has_oci_credentials ? 1 : 0

  metadata {
    name      = "oci-credentials"
    namespace = var.flux_namespace
  }

  data = {
    ".dockerconfigjson" = local.dockerconfigjson
  }

  type = "kubernetes.io/dockerconfigjson"
}

# OCIRepository source — single artifact containing all gitops paths
resource "kubectl_manifest" "oci_repository" {
  yaml_body = yamlencode({
    apiVersion = "source.toolkit.fluxcd.io/v1beta2"
    kind       = "OCIRepository"
    metadata = {
      name      = "ml-gitops"
      namespace = var.flux_namespace
    }
    spec = merge(
      {
        interval = "10m"
        url      = var.artifact_url
        ref = {
          tag = var.artifact_version
        }
      },
      local.has_oci_credentials ? {
        secretRef = {
          name = kubernetes_secret_v1.oci_credentials[0].metadata[0].name
        }
      } : {}
    )
  })

  depends_on = [kubernetes_secret_v1.oci_credentials]
}

# Kustomization: platform (shared — always deployed first)
resource "kubectl_manifest" "kustomization_platform" {
  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "platform"
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      path     = "./platform"
      prune    = true
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      healthChecks = [
        {
          apiVersion = "apps/v1"
          kind       = "Deployment"
          name       = "external-secrets-external-secrets-webhook"
          namespace  = "external-secrets"
        },
        {
          apiVersion = "apps/v1"
          kind       = "Deployment"
          name       = "cert-manager-cert-manager-webhook"
          namespace  = "cert-manager"
        }
      ]
      postBuild = {
        substituteFrom = [
          {
            kind = "ConfigMap"
            name = kubernetes_config_map_v1.cluster_config.metadata[0].name
          },
          {
            kind = "Secret"
            name = kubernetes_secret_v1.cluster_secrets.metadata[0].name
          }
        ]
      }
    }
  })

  depends_on = [
    kubectl_manifest.oci_repository,
    kubernetes_config_map_v1.cluster_config,
    kubernetes_secret_v1.cluster_secrets
  ]
}

# Kustomization: platform-config (CRD instances that depend on platform HelmReleases — e.g. ClusterIssuers)
resource "kubectl_manifest" "kustomization_platform_config" {
  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "platform-config"
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      path     = "./platform-config"
      prune    = true
      dependsOn = [
        { name = "platform" }
      ]
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      postBuild = {
        substituteFrom = [
          {
            kind = "ConfigMap"
            name = kubernetes_config_map_v1.cluster_config.metadata[0].name
          },
          {
            kind = "Secret"
            name = kubernetes_secret_v1.cluster_secrets.metadata[0].name
          }
        ]
      }
    }
  })

  depends_on = [
    kubectl_manifest.kustomization_platform
  ]
}

# Kustomization: onprem (on-prem gap fillers — only when provider is proxmox)
resource "kubectl_manifest" "kustomization_onprem" {
  count = local.is_onprem ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "onprem"
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      path     = "./onprem"
      prune    = true
      dependsOn = [
        { name = "platform-config" }
      ]
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      postBuild = {
        substituteFrom = [
          {
            kind = "ConfigMap"
            name = kubernetes_config_map_v1.cluster_config.metadata[0].name
          },
          {
            kind = "Secret"
            name = kubernetes_secret_v1.cluster_secrets.metadata[0].name
          }
        ]
      }
    }
  })

  depends_on = [
    kubectl_manifest.kustomization_platform_config
  ]
}

# Kustomization: role-specific (cc or env — deployed after onprem if on-prem, otherwise after platform)
resource "kubectl_manifest" "kustomization_role" {
  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = var.cluster_role
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      path     = "./${var.cluster_role}"
      prune    = true
      dependsOn = local.is_onprem ? [
        { name = "onprem" }
        ] : [
        { name = "platform-config" }
      ]
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      postBuild = {
        substituteFrom = [
          {
            kind = "ConfigMap"
            name = kubernetes_config_map_v1.cluster_config.metadata[0].name
          },
          {
            kind = "Secret"
            name = kubernetes_secret_v1.cluster_secrets.metadata[0].name
          }
        ]
      }
    }
  })

  depends_on = [
    kubectl_manifest.kustomization_platform_config,
    kubectl_manifest.kustomization_onprem
  ]
}

# Kustomization: cc-config (Vault CR, ESO SecretStore, MinIO, Harbor — depends on cc installing vault-operator CRDs)
resource "kubectl_manifest" "kustomization_cc_config" {
  count = var.cluster_role == "cc" ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "cc-config"
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      path     = "./cc-config"
      prune    = true
      dependsOn = [
        { name = "cc" }
      ]
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      healthChecks = [
        {
          apiVersion = "helm.toolkit.fluxcd.io/v2"
          kind       = "HelmRelease"
          name       = "minio"
          namespace  = var.flux_namespace
        },
        {
          apiVersion = "helm.toolkit.fluxcd.io/v2"
          kind       = "HelmRelease"
          name       = "harbor"
          namespace  = var.flux_namespace
        }
      ]
      postBuild = {
        substituteFrom = [
          {
            kind = "ConfigMap"
            name = kubernetes_config_map_v1.cluster_config.metadata[0].name
          },
          {
            kind = "Secret"
            name = kubernetes_secret_v1.cluster_secrets.metadata[0].name
          }
        ]
      }
    }
  })

  depends_on = [
    kubectl_manifest.kustomization_role
  ]
}

# Kustomization: cc-routes (HTTPRoutes for CC services — depends on cc-config so backend services exist)
resource "kubectl_manifest" "kustomization_cc_routes" {
  count = var.cluster_role == "cc" ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "cc-routes"
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      path     = "./cc-routes"
      prune    = true
      dependsOn = [
        { name = "cc-config" }
      ]
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      postBuild = {
        substituteFrom = [
          {
            kind = "ConfigMap"
            name = kubernetes_config_map_v1.cluster_config.metadata[0].name
          },
          {
            kind = "Secret"
            name = kubernetes_secret_v1.cluster_secrets.metadata[0].name
          }
        ]
      }
    }
  })

  depends_on = [
    kubectl_manifest.kustomization_cc_config
  ]
}
