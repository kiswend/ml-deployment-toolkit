# Main Terraform configuration
# Orchestrates infrastructure deployment using YAML configuration files

locals {
  # Read base config to determine provider and OCI repo active state
  config_raw    = yamldecode(file("../config/config.yaml"))
  provider_name = local.config_raw.infra.provider
  oci_active    = try(local.config_raw.oci.repo.active, false)

  # Config-loader outputs
  config = module.config.config

  # Kubeconfig path from provider module (for K8s/Helm/Kubectl providers)
  kubeconfig_path = (
    local.provider_name == "proxmox" && length(module.proxmox) > 0
    ? module.proxmox[0].kubeconfig_path
    : local.provider_name == "digitalocean" && length(module.digitalocean) > 0
    ? module.digitalocean[0].kubeconfig_path
    : local.provider_name == "aws" && length(module.aws) > 0
    ? module.aws[0].kubeconfig_path
    : null
  )
}

# Load configuration from YAML files
module "config" {
  source = "./modules/config-loader"

  config_path           = "../config/config.yaml"
  workload_classes_path = "../config/definitions/workload-classes.yaml"
}

# Proxmox Cluster
module "proxmox" {
  count  = local.provider_name == "proxmox" ? 1 : 0
  source = "./modules/proxmox"

  instances           = module.config.instances
  cluster             = module.config.cluster
  workload_classes    = module.config.workload_classes
  talos_version       = module.config.talos_version
  kubernetes_version  = module.config.kubernetes_version
  talos_image         = module.config.talos_image
  label_taint_patches = module.config.label_taint_patches

  patches_path         = module.config.paths.patches
  artifacts_path       = module.config.paths.artifacts
  provider_config_path = "../config/providers/proxmox/config.yaml"

  oci_proxy_active   = try(local.config_raw.oci.proxy.active, false)
  oci_proxy_url      = try(local.config_raw.oci.proxy.url, "")
  oci_proxy_username = var.oci_proxy_username
  oci_proxy_password = var.oci_proxy_password
}

# DigitalOcean Cluster (DOKS Managed Kubernetes)
module "digitalocean" {
  count  = local.provider_name == "digitalocean" ? 1 : 0
  source = "./modules/digitalocean"

  cluster            = module.config.cluster
  kubernetes_version = module.config.kubernetes_version
  node_pools         = try(module.config.deployment_template.node_pools, [])

  artifacts_path       = module.config.paths.artifacts
  provider_config_path = "../config/providers/digitalocean/config.yaml"

  region             = try(local.config_raw.infra.digitalocean.region, "nyc1")
  digitalocean_token = var.digitalocean_token
}

# AWS Cluster (EKS Managed Kubernetes)
module "aws" {
  count  = local.provider_name == "aws" ? 1 : 0
  source = "./modules/aws"

  cluster            = module.config.cluster
  kubernetes_version = module.config.kubernetes_version
  node_groups        = try(module.config.deployment_template.node_groups, [])

  artifacts_path       = module.config.paths.artifacts
  provider_config_path = "../config/providers/aws/config.yaml"

  region = try(local.config_raw.infra.aws.region, "us-east-1")
}

# FluxCD Bootstrap - install controllers (always)
module "flux_bootstrap" {
  count  = local.provider_name != "" ? 1 : 0
  source = "./modules/flux-bootstrap"

  flux_version = local.config_raw.cluster.flux.version

  depends_on = [
    module.proxmox,
    module.digitalocean,
    module.aws
  ]
}

# FluxCD Config - OCI source + Kustomization (only when oci.repo.active is true)
module "flux_config" {
  count  = local.oci_active ? 1 : 0
  source = "./modules/flux-config"

  cluster_name     = local.config.cluster.name
  cluster_role     = local.config.cluster.role
  cluster_vip      = try(local.config.cluster.vip, "")
  domain           = local.config.dns.domain
  dns_provider     = local.config.dns.provider
  alert_email      = local.config.app.alert_email
  lb_ipam_range    = local.config.app.lb_ipam.range
  artifact_url     = local.config_raw.oci.repo.url
  artifact_version = try(local.config_raw.oci.repo.version, "latest")

  infra_provider = local.provider_name

  digitalocean_token = var.digitalocean_token
  oci_repo_username  = var.oci_repo_username
  oci_repo_password  = var.oci_repo_password
  oci_proxy_username = var.oci_proxy_username
  oci_proxy_password = var.oci_proxy_password

  minio_root_user      = var.minio_root_user
  minio_root_password  = var.minio_root_password
  harbor_admin_password = var.harbor_admin_password

  depends_on = [
    module.flux_bootstrap
  ]
}
