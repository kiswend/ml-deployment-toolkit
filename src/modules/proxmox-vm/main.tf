# Proxmox Infrastructure Module
# Handles Talos VM provisioning on Proxmox Virtual Environment

locals {
  # Read Proxmox provider configuration from YAML
  provider_config = yamldecode(file(var.provider_config_path))

  # Process instances with provider-specific mappings
  instances_with_specs = [
    for instance in var.instances : merge(instance, {
      vm_specs = lookup(var.provider_mappings.instance_types, instance.instance_type, {
        cores   = 2
        memory  = 4096
        sockets = 1
      })

      storage_config = flatten([
        for storage_item in instance.storage : [
          for storage_key, storage_value in storage_item : {
            size      = storage_value.size
            interface = storage_value.interface
            type = lookup(var.provider_mappings.storage_types, storage_value.class, {
              type         = "scsi"
              storage_pool = local.provider_config.storage.default_pool
              cache        = "writeback"
              discard      = true
            })
          }
        ]
      ])
    })
  ]

  # Extract node information (placement_group → Proxmox node name)
  nodes_map = {
    for instance in local.instances_with_specs :
    instance.name => instance.resolved_placement.placement_group
  }

  # Map instances by name for easy lookup
  instances_by_name = {
    for inst in local.instances_with_specs :
    inst.name => inst
  }
}

# Create VMs on Proxmox Virtual Environment
resource "proxmox_virtual_environment_vm" "instance" {
  for_each = { for inst in local.instances_with_specs : inst.name => inst }

  name      = each.value.name
  node_name = local.nodes_map[each.value.name]
  vm_id     = local.provider_config.vm_id.start + index(keys({ for inst in local.instances_with_specs : inst.name => inst }), each.key)

  cpu {
    type    = try(each.value.vm_specs.cpu_type, local.provider_config.vm_defaults.cpu_type)
    cores   = each.value.vm_specs.cores
    sockets = try(each.value.vm_specs.sockets, 1)
  }

  memory {
    dedicated = each.value.vm_specs.memory
  }

  scsi_hardware = local.provider_config.vm_defaults.scsihw

  boot_order = [local.provider_config.vm_defaults.boot_order]

  agent {
    enabled = local.provider_config.vm_defaults.qemu_agent
  }

  # Data disks - first disk (index 0) is the boot disk from downloaded OS image
  dynamic "disk" {
    for_each = each.value.storage_config
    content {
      datastore_id = disk.value.type.storage_pool
      file_id      = disk.key == 0 ? local.instance_image_ids[each.value.name] : null
      interface    = disk.value.interface
      size         = disk.value.size
      discard      = local.provider_config.vm_defaults.disk.discard ? "on" : "ignore"
      file_format  = local.provider_config.vm_defaults.disk.format
    }
  }

  # Cloud-init disk
  disk {
    datastore_id = each.value.storage_config[0].type.storage_pool
    interface    = "ide2"
    file_format  = "raw"
  }

  # Network device
  network_device {
    bridge   = local.provider_config.vm_defaults.network.bridge
    model    = local.provider_config.vm_defaults.network.model
    firewall = local.provider_config.vm_defaults.network.firewall
  }

  operating_system {
    type = "l26"
  }

  # Cloud-init configuration for Talos VMs
  initialization {
    user_data_file_id = local.talos_config_file_ids[each.key]
    meta_data_file_id = local.talos_meta_file_ids[each.key]
  }

  tags = each.value.tags

  on_boot         = true
  stop_on_destroy = true
  timeout_stop_vm = 60

  lifecycle {
    ignore_changes = [
      disk,
    ]
  }

  depends_on = [
    proxmox_virtual_environment_file.talos_config,
    proxmox_virtual_environment_file.talos_meta
  ]
}
