# Main Terraform configuration
# Orchestrates infrastructure deployment using YAML configuration files

locals {
  # Read base config to determine provider and flux mode
  config_raw    = yamldecode(file("../config/config.yaml"))
  provider_name = local.config_raw.infra.provider
  flux_mode     = local.config_raw.cluster.flux.mode

  # Config-loader outputs
  config = module.config.config

  # Kubeconfig path from provider module (for K8s/Helm/Kubectl providers)
  kubeconfig_path = local.provider_name == "proxmox" && length(module.proxmox) > 0 ? module.proxmox[0].kubeconfig_path : null
}

# Load configuration from YAML files
module "config" {
  source = "./modules/config-loader"

  config_path             = "../config/config.yaml"
  deployment_templates_path = "../config/definitions/deployment-templates.yaml"
  instance_types_path     = "../config/definitions/instance-types.yaml"
  storage_types_path      = "../config/definitions/storage-types.yaml"
  workload_classes_path   = "../config/definitions/workload-classes.yaml"

  # Provider-specific mappings
  provider_instance_mapping_path = local.provider_name == "proxmox" ? "../config/providers/proxmox/instance-types.yaml" : ""
  provider_storage_mapping_path  = local.provider_name == "proxmox" ? "../config/providers/proxmox/storage-types.yaml" : ""
}

# Proxmox Cluster
module "proxmox" {
  count  = local.provider_name == "proxmox" ? 1 : 0
  source = "./modules/proxmox"

  instances         = module.config.instances
  provider_mappings = module.config.provider_mappings
  cluster           = module.config.cluster
  workload_classes  = module.config.workload_classes

  patches_path         = module.config.paths.patches
  artifacts_path       = module.config.paths.artifacts
  provider_config_path = "../config/providers/proxmox/config.yaml"
}

# FluxCD Bootstrap - install controllers (always, for all flux.mode values)
module "flux_bootstrap" {
  count  = local.provider_name != "" ? 1 : 0
  source = "./modules/flux-bootstrap"

  flux_version = local.config_raw.cluster.flux.version

  depends_on = [
    module.proxmox
  ]
}

# FluxCD Config - OCI source + Kustomization (only when flux.mode == "oci")
module "flux_config" {
  count  = local.flux_mode == "oci" ? 1 : 0
  source = "./modules/flux-config"

  cluster_name       = local.config.cluster.name
  cluster_vip        = local.config.cluster.vip
  domain             = local.config.dns.domain
  dns_provider       = local.config.dns.provider
  alert_email        = local.config.app.alert_email
  lb_ipam_range      = local.config.app.lb_ipam.range
  artifact_repo_url  = local.config.cluster.artifact_repo.url

  digitalocean_token = var.digitalocean_token
  oci_username       = var.oci_username
  oci_password       = var.oci_password

  depends_on = [
    module.flux_bootstrap
  ]
}
