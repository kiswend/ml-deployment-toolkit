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

# DigitalOcean Provider - reads token from DIGITALOCEAN_TOKEN env var (native, like Proxmox and AWS)
provider "digitalocean" {}

# AWS Provider - reads region from config, credentials from env (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
provider "aws" {
  region                      = try(local.config_raw.infra.aws.region, "us-east-1")
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

# Kubeconfig path — static convention, no module output dependency.
# fileexists() returns true for existing clusters, false for fresh deploys.
# When false, providers get null and defer until apply (proxmox module creates the file first).
locals {
  static_kubeconfig = "../artifacts/${var.env_name}/kubernetes/kubeconfig"
  kubeconfig        = fileexists(local.static_kubeconfig) ? local.static_kubeconfig : null
}

# Kubernetes Provider - configured with kubeconfig from cluster bootstrap
provider "kubernetes" {
  config_path = local.kubeconfig
}

# Helm Provider - for Flux installation
provider "helm" {
  kubernetes {
    config_path = local.kubeconfig
  }
}

# Kubectl Provider - for Flux CRDs (handles missing API server at plan time)
provider "kubectl" {
  config_path = local.kubeconfig
}
