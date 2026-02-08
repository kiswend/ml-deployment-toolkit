# Config Loader Module
# Loads and processes YAML configuration files

locals {
  # Load main deployer configuration
  config = yamldecode(file(var.config_path))

  # Load definition files
  deployment_templates = yamldecode(file(var.deployment_templates_path))
  instance_types       = yamldecode(file(var.instance_types_path))
  storage_types        = yamldecode(file(var.storage_types_path))
  workload_classes     = yamldecode(file(var.workload_classes_path))

  # Load provider-specific mappings
  provider_instance_mapping = var.provider_instance_mapping_path != "" ? yamldecode(file(var.provider_instance_mapping_path)) : {}
  provider_storage_mapping  = var.provider_storage_mapping_path != "" ? yamldecode(file(var.provider_storage_mapping_path)) : {}

  # Extract provider name and placement map
  provider_name = local.config.infra.provider
  placement_map = try(local.config.infra[local.provider_name].placement, {})

  # Select the deployment template by name
  deployment_template_name = local.config.template
  deployment_template = [
    for size in local.deployment_templates.sizes : size
    if size.name == local.deployment_template_name
  ][0]

  # Process instances with simplified placement resolution
  # placement_group from template → provider value via infra.<provider>.placement map
  instances = [
    for instance in local.deployment_template.instances : {
      name           = instance.name
      placement      = instance.placement
      instance_type  = instance.instance_type
      workload_class = instance.workload_class
      storage        = instance.storage
      tags           = try(instance.tags, [])

      resolved_placement = {
        placement_group = lookup(local.placement_map, instance.placement.placement_group, instance.placement.placement_group)
      }
    }
  ]

  # Separate by workload class
  control_plane_instances = [
    for instance in local.instances :
    instance if instance.workload_class == "control-plane"
  ]

  worker_instances = [
    for instance in local.instances :
    instance if startswith(instance.workload_class, "worker")
  ]
}
