# OS Image Downloads for Proxmox
# Downloads Talos OS images based on workload class configuration

locals {
  # Get unique Proxmox nodes from instances
  unique_nodes = toset([
    for instance in local.instances_with_specs :
    instance.resolved_placement.placement_group
  ])

  # Build a map of instance to their image configuration from workload class
  instance_images = {
    for inst in local.instances_with_specs :
    inst.name => try(var.workload_classes[inst.workload_class].image, local.provider_config.talos.image)
  }

  # Get unique images needed (deduplicate by file_name)
  unique_images = distinct([
    for inst_name, img in local.instance_images :
    {
      url           = img.url
      content_type  = img.content_type
      datastore     = img.datastore
      file_name     = try(img.file_name, basename(img.url))
      decompression = try(img.decompression, null)
      key           = try(img.file_name, md5(img.url))
    }
  ])

  # Create a flat map of node+image combinations that need to be downloaded
  node_image_downloads = flatten([
    for node in local.unique_nodes : [
      for img in local.unique_images : {
        node          = node
        image_key     = img.key
        url           = img.url
        content_type  = img.content_type
        datastore     = img.datastore
        file_name     = img.file_name
        decompression = img.decompression
        download_key  = "${node}-${img.key}"
      }
    ]
  ])

  # Convert to map for for_each
  node_image_downloads_map = {
    for item in local.node_image_downloads :
    item.download_key => item
  }
}

# Download OS images to each unique node
resource "proxmox_virtual_environment_download_file" "os_image" {
  for_each = local.node_image_downloads_map

  content_type = each.value.content_type
  datastore_id = each.value.datastore
  node_name    = each.value.node

  url                     = each.value.url
  file_name               = each.value.file_name
  decompression_algorithm = each.value.decompression
  overwrite               = false

  lifecycle {
    ignore_changes = [
      url,
      checksum,
      checksum_algorithm
    ]
  }
}

# Map instance name → downloaded image ID for VM creation
locals {
  instance_image_ids = {
    for inst in local.instances_with_specs :
    inst.name => proxmox_virtual_environment_download_file.os_image[
      "${local.nodes_map[inst.name]}-${try(var.workload_classes[inst.workload_class].image.file_name, md5(try(var.workload_classes[inst.workload_class].image.url, local.provider_config.talos.image.url)))}"
    ].id
  }
}
