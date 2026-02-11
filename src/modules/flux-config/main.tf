# Flux Config Module
# Creates Kubernetes resources for Flux OCI-based GitOps
# Deploys: 1 OCIRepository + 3-9 Kustomizations (platform → platform-config → [onprem] → role-specific → [env-data] → [env-auth] → [env-app] | [cc-config] → [cc-routes])

locals {
  has_oci_credentials = var.oci_repo_username != "" && var.oci_repo_password != ""
  is_onprem           = var.infra_provider == "proxmox"
  is_env              = var.cluster_role == "env"

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

  # Data layer endpoints — on-prem uses in-cluster service names, cloud uses managed service endpoints
  mysql_central_ledger_host = local.is_onprem ? "central-ledger-db-haproxy" : var.mysql_central_ledger_host
  mysql_account_lookup_host = local.is_onprem ? "account-lookup-db-haproxy" : var.mysql_account_lookup_host
  mysql_port                = local.is_onprem ? "3306" : var.mysql_port
  kafka_host                = local.is_onprem ? "mojaloop-kafka-kafka-bootstrap" : var.kafka_host
  kafka_port                = local.is_onprem ? "9092" : var.kafka_port
  mongodb_host              = local.is_onprem ? "bulk-mongodb-rs0" : var.mongodb_host
  mongodb_port              = local.is_onprem ? "27017" : var.mongodb_port
  redis_host                = local.is_onprem ? "ttk-redis" : var.redis_host
  redis_port                = local.is_onprem ? "6379" : var.redis_port
  auth_db_host              = local.is_onprem ? "auth-db-haproxy" : var.auth_db_host
}

# ConfigMap with cluster configuration for postBuild substitution
resource "kubernetes_config_map_v1" "cluster_config" {
  metadata {
    name      = "cluster-config"
    namespace = var.flux_namespace
  }

  data = merge(
    {
      cluster_name  = var.cluster_name
      cluster_vip   = var.cluster_vip
      domain        = var.domain
      dns_provider  = var.dns_provider
      alert_email   = var.alert_email
      lb_ipam_range = var.lb_ipam_range
      lb_ipam_start = split("-", var.lb_ipam_range)[0]
      lb_ipam_stop  = split("-", var.lb_ipam_range)[1]
    },
    local.is_env ? {
      mysql_central_ledger_host = local.mysql_central_ledger_host
      mysql_account_lookup_host = local.mysql_account_lookup_host
      mysql_port                = local.mysql_port
      kafka_host                = local.kafka_host
      kafka_port                = local.kafka_port
      mongodb_host              = local.mongodb_host
      mongodb_port              = local.mongodb_port
      redis_host                = local.redis_host
      redis_port                = local.redis_port
      auth_db_host              = local.auth_db_host
    } : {}
  )
}

# Secret with sensitive credentials for postBuild substitution
resource "kubernetes_secret_v1" "cluster_secrets" {
  metadata {
    name      = "cluster-secrets"
    namespace = var.flux_namespace
  }

  data = merge(
    {
      digitalocean_token    = var.digitalocean_token
      oci_repo_username     = var.oci_repo_username
      oci_repo_password     = var.oci_repo_password
      oci_proxy_username    = var.oci_proxy_username
      oci_proxy_password    = var.oci_proxy_password
      minio_root_user       = var.minio_root_user
      minio_root_password   = var.minio_root_password
      harbor_admin_password = var.harbor_admin_password
    },
    local.is_env ? {
      mysql_root_password           = var.mysql_root_password
      mysql_central_ledger_password = var.mysql_central_ledger_password
      mysql_account_lookup_password = var.mysql_account_lookup_password
      mysql_oracle_msisdn_password  = var.mysql_oracle_msisdn_password
      mongodb_root_password         = var.mongodb_root_password
      mongodb_app_password          = var.mongodb_app_password
      keycloak_db_password          = var.keycloak_db_password
      kratos_db_password            = var.kratos_db_password
      keto_db_password              = var.keto_db_password
      mcm_db_password               = var.mcm_db_password
      keycloak_admin_password       = var.keycloak_admin_password
      hubop_oidc_secret             = var.hubop_oidc_secret
      mcm_oidc_client_secret        = var.mcm_oidc_client_secret
      role_assign_svc_secret        = var.role_assign_svc_secret
    } : {}
  )

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
      timeout  = "20m"
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

# Kustomization: env-data (on-prem data layer — operators deploy CRs for MySQL, Kafka, MongoDB, Redis)
resource "kubectl_manifest" "kustomization_env_data" {
  count = local.is_onprem && local.is_env ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "env-data"
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      timeout  = "20m"
      path     = "./env-data"
      prune    = true
      dependsOn = [
        { name = "env" }
      ]
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      healthChecks = [
        {
          apiVersion = "pxc.percona.com/v1"
          kind       = "PerconaXtraDBCluster"
          name       = "central-ledger-db"
          namespace  = "mojaloop"
        },
        {
          apiVersion = "kafka.strimzi.io/v1beta2"
          kind       = "Kafka"
          name       = "mojaloop-kafka"
          namespace  = "mojaloop"
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

# Kustomization: env-auth (auth layer — Vault, Keycloak, Ory stack, HTTPRoutes)
resource "kubectl_manifest" "kustomization_env_auth" {
  count = local.is_env ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "env-auth"
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      timeout  = "20m"
      path     = "./env-auth"
      prune    = true
      dependsOn = local.is_onprem ? [
        { name = "env-data" }
        ] : [
        { name = "env" }
      ]
      sourceRef = {
        kind = "OCIRepository"
        name = "ml-gitops"
      }
      healthChecks = [
        {
          apiVersion = "vault.banzaicloud.com/v1alpha1"
          kind       = "Vault"
          name       = "vault"
          namespace  = "vault"
        },
        {
          apiVersion = "apps/v1"
          kind       = "Deployment"
          name       = "keycloak-operator"
          namespace  = "keycloak"
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
    kubectl_manifest.kustomization_role,
    kubectl_manifest.kustomization_env_data
  ]
}

# Kustomization: env-app (Mojaloop core + MCM + Finance Portal — always deployed for env clusters)
resource "kubectl_manifest" "kustomization_env_app" {
  count = local.is_env ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "env-app"
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      timeout  = "30m"
      path     = "./env-app"
      prune    = true
      dependsOn = local.is_onprem ? [
        { name = "env-auth" }
        ] : [
        { name = "env-auth" }
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
    kubectl_manifest.kustomization_role,
    kubectl_manifest.kustomization_env_data,
    kubectl_manifest.kustomization_env_auth
  ]
}
