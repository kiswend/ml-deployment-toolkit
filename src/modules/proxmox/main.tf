# Proxmox Cluster Composite Module
# Orchestrates: talos-gen-config -> proxmox-vm -> talos-bootstrap

locals {
  vip_address = var.cluster.vip

  # Read provider config for patch references
  provider_config = yamldecode(file(var.provider_config_path))

  # All instances are Talos (no standalone support)
  talos_instances = var.instances

  # Get unique workload classes used
  used_workload_classes = toset([
    for inst in local.talos_instances :
    inst.workload_class
  ])

  # Load workload-specific patches from config/patches/talos/
  workload_class_patches = {
    for wc in local.used_workload_classes :
    wc => try([
      for patch_name in var.workload_classes[wc].talos_patches :
      file("${var.patches_path}/${patch_name}")
    ], [])
  }

  # Render provider-specific VIP patch
  provider_patches_config = try(local.provider_config.talos-patches, {})

  # Build provider patches by class, also apply control-plane patches to mixed-plane
  provider_patches_by_class = merge(
    {
      for patch_key, patch_file in local.provider_patches_config :
      replace(patch_key, "config-patch-", "") => [
        templatefile("${dirname(var.provider_config_path)}/${patch_file}", {
          interface   = "eth0"
          vip_address = local.vip_address
        })
      ]
    },
    # Also apply control-plane provider patches to mixed-plane
    contains(local.used_workload_classes, "mixed-plane") ? {
      "mixed-plane" = [
        for patch_key, patch_file in local.provider_patches_config :
        templatefile("${dirname(var.provider_config_path)}/${patch_file}", {
          interface   = "eth0"
          vip_address = local.vip_address
        })
        if patch_key == "config-patch-control-plane"
      ]
    } : {}
  )
}

# Generate Talos configurations
module "talos_config" {
  source = "../talos-gen-config"

  cluster_name       = var.cluster.name
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version
  lb_ip              = local.vip_address

  talos_endpoints = [local.vip_address]

  artifacts_folder = var.artifacts_path

  # Generate per-instance configs with workload + provider + label/taint patches
  generate_per_instance = true
  instances = [
    for inst in local.talos_instances : {
      name           = inst.name
      workload_class = inst.workload_class
      talos_type     = var.workload_classes[inst.workload_class].talos_type
      workload_patches = concat(
        lookup(local.workload_class_patches, inst.workload_class, []),
        lookup(local.provider_patches_by_class, inst.workload_class, []),
        try([var.label_taint_patches[inst.workload_class]], [])
      )
    }
  ]
}

# Create VMs using proxmox-vm module
module "infrastructure" {
  source = "../proxmox-vm"

  instances             = var.instances
  provider_config_path  = var.provider_config_path
  talos_image           = var.talos_image
  provider_image_config = local.provider_config.talos.image

  talos_configs = module.talos_config.instance_configs

  depends_on = [module.talos_config]
}

# Bootstrap Talos Kubernetes cluster
module "bootstrap" {
  source = "../talos-bootstrap"

  control_plane_endpoints    = module.infrastructure.control_plane_ips
  worker_endpoints           = module.infrastructure.worker_ips
  talos_client_configuration = module.talos_config.client_configuration

  cluster_name     = var.cluster.name
  artifacts_folder = var.artifacts_path

  depends_on = [module.infrastructure]
}
