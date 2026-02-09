# Config Loader Module
# Loads and processes YAML configuration files

locals {
  # Load main deployer configuration
  config = yamldecode(file(var.config_path))

  # Load workload classes (single source of truth for versions)
  workload_classes = yamldecode(file(var.workload_classes_path))

  # Single source of truth for Talos/Kubernetes versions
  talos_version      = local.workload_classes.talos_version
  kubernetes_version = local.workload_classes.kubernetes_version

  # Construct image URL from workload-classes (no more hardcoded versions in YAML)
  talos_image_schematic = local.workload_classes.talos_image.schematic
  talos_image_platform  = local.workload_classes.talos_image.platform
  talos_image_arch      = local.workload_classes.talos_image.arch
  talos_image_url       = "https://factory.talos.dev/image/${local.talos_image_schematic}/${local.talos_version}/${local.talos_image_platform}-${local.talos_image_arch}.raw.gz"
  talos_image_file_name = "talos-${local.talos_version}-${local.talos_image_arch}.img"

  # Extract provider name and placement map
  provider_name = local.config.infra.provider
  placement_map = try(local.config.infra[local.provider_name].placement, {})

  # Load provider-specific deployment template
  deployment_templates = yamldecode(file("../config/providers/${local.provider_name}/deployment-templates.yaml"))
  deployment_template  = local.deployment_templates[local.config.template]

  # Process instances with simplified placement resolution
  # placement_group from template -> provider value via infra.<provider>.placement map
  instances = [
    for instance in local.deployment_template.instances : {
      name            = instance.name
      placement_group = instance.placement_group
      cores           = instance.cores
      memory          = instance.memory
      sockets         = try(instance.sockets, 1)
      workload_class  = instance.workload_class
      storage         = instance.storage
      tags            = try(instance.tags, [])

      resolved_placement = {
        placement_group = lookup(local.placement_map, instance.placement_group, instance.placement_group)
      }
    }
  ]

  # Separate by workload class (mixed-plane counts as control-plane for bootstrap/VIP)
  control_plane_instances = [
    for instance in local.instances :
    instance if contains(["control-plane", "mixed-plane"], instance.workload_class)
  ]

  worker_instances = [
    for instance in local.instances :
    instance if startswith(instance.workload_class, "worker")
  ]

  # Dynamic label/taint patches per workload class
  label_taint_patches = {
    for class_name, class_def in local.workload_classes.classes :
    class_name => yamlencode({
      machine = merge(
        length(try(class_def.node_labels, {})) > 0 ? { nodeLabels = class_def.node_labels } : {},
        length(try(class_def.node_taints, [])) > 0 ? {
          nodeTaints = {
            for taint in class_def.node_taints :
            "${taint.key}=${taint.value}" => taint.effect
          }
        } : {}
      )
    })
    if length(try(class_def.node_labels, {})) > 0 || length(try(class_def.node_taints, [])) > 0
  }
}
