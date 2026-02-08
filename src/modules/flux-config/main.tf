# Flux Config Module
# Creates Kubernetes resources for Flux OCI-based GitOps

locals {
  has_oci_credentials = var.oci_username != "" && var.oci_password != ""
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
  }
}

# Secret with sensitive credentials for postBuild substitution
resource "kubernetes_secret_v1" "cluster_secrets" {
  metadata {
    name      = "cluster-secrets"
    namespace = var.flux_namespace
  }

  data = {
    digitalocean_token = var.digitalocean_token
    oci_username       = var.oci_username
    oci_password       = var.oci_password
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
    username = var.oci_username
    password = var.oci_password
  }

  type = "Opaque"
}

# OCIRepository source pointing at the artifact registry
resource "kubectl_manifest" "oci_repository" {
  yaml_body = yamlencode({
    apiVersion = "source.toolkit.fluxcd.io/v1beta2"
    kind       = "OCIRepository"
    metadata = {
      name      = "platform"
      namespace = var.flux_namespace
    }
    spec = merge(
      {
        interval = "10m"
        url      = var.artifact_repo_url
        ref = {
          tag = "latest"
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

# Kustomization referencing the OCIRepository with postBuild substitution
resource "kubectl_manifest" "kustomization" {
  yaml_body = yamlencode({
    apiVersion = "kustomize.toolkit.fluxcd.io/v1"
    kind       = "Kustomization"
    metadata = {
      name      = "platform"
      namespace = var.flux_namespace
    }
    spec = {
      interval = "10m"
      path     = "./"
      prune    = true
      sourceRef = {
        kind = "OCIRepository"
        name = "platform"
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
    kubectl_manifest.oci_repository,
    kubernetes_config_map_v1.cluster_config,
    kubernetes_secret_v1.cluster_secrets
  ]
}
