# Talos Configuration Generator Module
# Generates Talos machine configurations using the native Talos provider

locals {
  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  cluster_endpoint   = var.cluster_endpoint != "" ? "https://${var.cluster_endpoint}:6443" : "https://${var.lb_ip}:6443"
  talos_version      = var.talos_version

  # Read base patch file content if it exists
  cilium_patch = fileexists("${var.patch_folder}/patch-cilium-install.yaml") ? file("${var.patch_folder}/patch-cilium-install.yaml") : ""

  # Combine all patches
  base_patches = local.cilium_patch != "" ? [local.cilium_patch] : []
  all_patches  = concat(local.base_patches, var.additional_patches)
}

# Generate Talos machine secrets
resource "talos_machine_secrets" "this" {
  talos_version = local.talos_version
}

# Generate control plane configuration (base)
data "talos_machine_configuration" "controlplane" {
  cluster_name       = local.cluster_name
  machine_type       = "controlplane"
  cluster_endpoint   = local.cluster_endpoint
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = local.talos_version
  kubernetes_version = local.kubernetes_version

  config_patches = local.all_patches

  examples = false
  docs     = false
}

# Generate worker configuration (base)
data "talos_machine_configuration" "worker" {
  cluster_name       = local.cluster_name
  machine_type       = "worker"
  cluster_endpoint   = local.cluster_endpoint
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = local.talos_version
  kubernetes_version = local.kubernetes_version

  config_patches = local.all_patches

  examples = false
  docs     = false
}

# Generate per-instance configurations if requested
data "talos_machine_configuration" "instance" {
  for_each = var.generate_per_instance ? {
    for inst in var.instances : inst.name => inst
  } : {}

  cluster_name       = local.cluster_name
  machine_type       = each.value.workload_class == "control-plane" ? "controlplane" : "worker"
  cluster_endpoint   = local.cluster_endpoint
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = local.talos_version
  kubernetes_version = local.kubernetes_version

  # Layer patches: generic + provider + workload-specific
  config_patches = concat(
    local.all_patches,
    each.value.workload_patches
  )

  examples = false
  docs     = false
}

# Generate client configuration (talosconfig)
data "talos_client_configuration" "this" {
  cluster_name         = local.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = length(var.talos_endpoints) > 0 ? var.talos_endpoints : [split(":", trimprefix(local.cluster_endpoint, "https://"))[0]]
}

# Write control plane configuration to file
resource "local_file" "controlplane_config" {
  filename = "${var.artifacts_folder}/talos-config/controlplane.yaml"
  content  = data.talos_machine_configuration.controlplane.machine_configuration
}

# Write worker configuration to file
resource "local_file" "worker_config" {
  filename = "${var.artifacts_folder}/talos-config/worker.yaml"
  content  = data.talos_machine_configuration.worker.machine_configuration
}

# Write per-instance configurations to files
resource "local_file" "instance_config" {
  for_each = data.talos_machine_configuration.instance

  filename = "${var.artifacts_folder}/talos-config/${each.key}.yaml"
  content  = each.value.machine_configuration
}

# Write talosconfig to file
resource "local_file" "talosconfig" {
  filename = "${var.artifacts_folder}/talos-config/talosconfig"
  content  = data.talos_client_configuration.this.talos_config
}

# Write machine secrets to file (for reference/backup)
resource "local_sensitive_file" "machine_secrets" {
  filename = "${var.artifacts_folder}/talos-secrets/secrets.yaml"
  content  = yamlencode(talos_machine_secrets.this.machine_secrets)
}
