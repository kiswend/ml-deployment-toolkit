# Provider Configurations
# Configure providers at root level (not in modules)

# Proxmox Provider - reads credentials from environment variables:
# PROXMOX_VE_ENDPOINT, PROXMOX_VE_API_TOKEN, PROXMOX_VE_SSH_USERNAME, PROXMOX_VE_SSH_PASSWORD
provider "proxmox" {
  insecure = true

  ssh {
    agent = false
  }
}

# Kubernetes Provider - configured with kubeconfig from cluster bootstrap
provider "kubernetes" {
  config_path = local.kubeconfig_path
}

# Helm Provider - for Flux installation
provider "helm" {
  kubernetes {
    config_path = local.kubeconfig_path
  }
}

# Kubectl Provider - for Flux CRDs (handles missing API server at plan time)
provider "kubectl" {
  config_path = local.kubeconfig_path
}
