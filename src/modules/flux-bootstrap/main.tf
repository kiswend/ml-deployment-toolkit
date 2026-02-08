# Flux Bootstrap Module
# Installs FluxCD controllers via Helm chart (OCI-native, no Git dependency)

resource "helm_release" "flux" {
  name             = "flux2"
  namespace        = var.flux_namespace
  create_namespace = true
  repository       = "oci://ghcr.io/fluxcd-community/charts"
  chart            = "flux2"
  version          = var.flux_version

  # Install core controllers
  set {
    name  = "sourceController.create"
    value = "true"
  }

  set {
    name  = "kustomizeController.create"
    value = "true"
  }

  set {
    name  = "helmController.create"
    value = "true"
  }

  set {
    name  = "notificationController.create"
    value = "true"
  }

  # Disable optional controllers
  set {
    name  = "imageReflectorController.create"
    value = "false"
  }

  set {
    name  = "imageAutomationController.create"
    value = "false"
  }

  # Watch all namespaces
  set {
    name  = "watchAllNamespaces"
    value = "true"
  }

  wait = true
}
