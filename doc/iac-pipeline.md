# IaC Pipeline

## 1. Overview

This document describes the infrastructure-as-code pipeline for ml-iac3 — the step-by-step technical flow an adopter follows to go from configuration to a running Kubernetes cluster with FluxCD bootstrapped and personalized.

**Scope:** IaC pipeline only (provisioning through Flux bootstrap). Does not cover application deployment, Control Center services (Harbor, Vault, MinIO), or the 4-stage organizational flow described in `deployment-architecture.md`.

**End-to-end goal:** The adopter gets a working Kubernetes cluster with Flux bootstrapped, pointed at the Platform Team's OCI registry, and configured with the adopter's local values (domain, credentials, network ranges). The adopter never forks the platform bundle — all personalization is via locally-generated Kubernetes resources.

## 2. Provider Model

Infrastructure providers fall into two categories. Both paths converge at the same output: a kubeconfig + Flux running with adopter config applied.

### On-prem providers (e.g. Proxmox)

Terraform provisions VMs, Talos OS bootstraps Kubernetes on those VMs. The adopter has full control over node configuration — machine patches, VIP, storage layout.

**Pipeline:**
```
config-loader → talos-gen-config → VM provisioning → talos-bootstrap → flux-bootstrap → flux-config
```

### Managed providers (e.g. AWS EKS, GCP GKE, DO DOKS)

Terraform provisions a managed Kubernetes service directly. No Talos, no VM management — the provider handles the control plane and node pools.

**Pipeline:**
```
config-loader → managed-k8s provisioning → flux-bootstrap → flux-config
```

## 3. Adopter Workflow

1. **Pull the IaC bundle** (OCI artifact or Git clone during development)
2. **Configure credentials:** Copy `config/.env.sample` → `config/.env`, fill in provider credentials, OCI auth, DNS tokens
3. **Configure infrastructure:** Edit `config/config.yaml` — select provider, deployment template, cluster name/VIP, DNS, app settings
4. **Deploy:**
   ```bash
   make init        # Initialize Terraform providers
   make plan        # Review execution plan
   make apply       # Provision infrastructure
   ```
5. **Outputs:**
   - `artifacts/kubernetes/kubeconfig` — cluster access
   - `artifacts/talos-config/talosconfig` — Talos API access (on-prem only)
   - Flux running and reconciling platform services with adopter values applied

## 4. Configuration System

All configuration lives under `config/`. Two ownership levels:

### Adopter-owned (edited per deployment)

| File | Purpose |
|------|---------|
| `config/config.yaml` | Main infrastructure config: provider, template, cluster, DNS, app settings |
| `config/.env` | Secrets and credentials (git-ignored) |

### Platform-team-owned (bundled, not normally edited)

| Path | Purpose |
|------|---------|
| `config/definitions/deployment-templates.yaml` | Cluster topologies (tiny, small, small3m3w) |
| `config/definitions/instance-types.yaml` | Abstract instance type catalog (co-4vcpu-8gb, gp-2vcpu-8gb, etc.) |
| `config/definitions/storage-types.yaml` | Abstract storage class catalog (local-fast, standard, bulk) |
| `config/definitions/workload-classes.yaml` | Node role definitions + patch/image references |
| `config/patches/talos/` | Talos machine config patches — static `.yaml` (cilium-install, openebs) and templates `.yaml.tpl` (vip) rendered by provider modules |
| `config/providers/{proxmox,aws,...}/` | Provider-specific mappings: abstract types → provider specs |

The adopter touches `config.yaml` + `.env`. Everything else ships with the bundle and defines how abstract resources map to concrete infrastructure.

## 5. Module Pipeline

### 5.1 config-loader

Loads all YAML configs from `config/` and normalizes them into a single structured output.

**Inputs:**
- `config/config.yaml` — adopter config
- `config/definitions/deployment-templates.yaml` — topologies
- `config/definitions/instance-types.yaml` — abstract instance catalog
- `config/definitions/storage-types.yaml` — abstract storage catalog
- `config/definitions/workload-classes.yaml` — node role definitions
- `config/providers/{provider}/instance-types.yaml` — provider-specific instance mappings
- `config/providers/{provider}/storage-types.yaml` — provider-specific storage mappings

**Processing:**
1. Selects deployment template by name (e.g. "tiny" → 1 master + 1 worker)
2. Resolves abstract placement → provider-specific values via `infra.{provider}.placement` in config.yaml (e.g. `placement-group-1` → Proxmox node `node0`, or → AWS AZ `us-east-1a`)
3. Attaches workload class metadata (image URLs, patch lists) to each instance
4. Separates instances by role (control plane vs worker)

**Outputs:**
- `instances` — normalized list with resolved placement, instance types, storage
- `control_plane_instances` / `worker_instances` — filtered lists
- `provider_mappings` — raw provider-specific type mappings
- `workload_classes` — full definitions (images, patches, cloud-init templates)
- `kubernetes_version` / `talos_version`
- `paths` — artifact and patch folder locations

### 5.2 Provider modules

#### 5.2.1 On-prem: proxmox (composite module)

Orchestrates Talos cluster creation. Sub-module flow:

**talos-gen-config:**

Generates Talos machine secrets (shared across cluster) and per-instance machine configs with layered patches.

Patches in `config/patches/talos/` come in two forms:
- **Static patches** (`.yaml`) — applied as-is (e.g. `patch-cilium-install.yaml`, `patch-openebs.yaml`)
- **Template patches** (`.yaml.tpl`) — rendered by the provider module with Terraform `templatefile()` before being passed to talos-gen-config (e.g. `patch-vip.yaml.tpl` rendered with `vip_address` and `interface`)

Patch layering per instance:
1. **Base patches** — applied to all Talos nodes (e.g. `patch-cilium-install.yaml`)
2. **Provider patches** — rendered from templates with provider-specific values (e.g. VIP address, network interface)
3. **Workload class patches** — role-specific (e.g. `patch-openebs.yaml` for workers, referenced in `workload-classes.yaml`)

Outputs: `instance_configs` map (instance name → machine config YAML), `client_configuration` (for talosctl)

Artifacts:
- `artifacts/talos-config/controlplane.yaml` — base control-plane config
- `artifacts/talos-config/worker.yaml` — base worker config
- `artifacts/talos-config/{instance-name}.yaml` — per-instance configs
- `artifacts/talos-config/talosconfig` — talosctl client config
- `artifacts/talos-secrets/secrets.yaml` — cluster secrets backup

**proxmox-vm (infrastructure):**

Maps abstract types to Proxmox-specific resources and provisions VMs.

- Maps abstract instance types → Proxmox specs (e.g. `co-4vcpu-8gb` → `{cores: 4, memory: 7000, sockets: 1, cpu_type: "host"}`)
- Maps abstract storage classes → Proxmox pools (e.g. `local-standard` → `{storage_pool: "local-lvm", cache: "writeback", discard: true}`)
- Deduplicates OS image downloads across Proxmox nodes (unique by URL hash)
- Uploads Talos machine configs as cloud-init snippets
- Creates VMs with virtio network, SCSI storage, cloud-init on ide2

Outputs: `vm_ips` (instance name → IP), `control_plane_ips`, `worker_ips`

**talos-bootstrap:**

Bootstraps etcd on the first control-plane node, generates kubeconfig, waits for cluster health.

- Bootstraps first CP node (initializes etcd + K8s control plane)
- Generates kubeconfig after successful bootstrap
- Health check validates all CP + worker nodes (Talos API + etcd + K8s API)
- Timeout: 30 minutes (allows for CNI deployment, image pulls)

Outputs: `kubeconfig_path`, `bootstrap_complete`

Artifacts: `artifacts/kubernetes/kubeconfig`

#### 5.2.2 Managed: aws/gcp/digitalocean (target design)

Provisions a managed Kubernetes cluster (EKS/GKE/DOKS) directly.

- Configures node pools from deployment template (instance types, counts)
- No Talos, no VM-level configuration, no machine patches
- Provider handles control-plane HA, etcd, node lifecycle

Outputs: `kubeconfig_path`, cluster provisioned

### 5.3 flux-bootstrap

Installs FluxCD into the cluster. Provider-agnostic — works identically for on-prem and managed. Runs for all `flux.mode` values (including `none`).

**Components installed:**
- source-controller
- kustomize-controller
- helm-controller
- notification-controller

**Inputs:** kubeconfig (from provider module), Flux version, namespace

**Outputs:** `flux_installed`, `flux_namespace`, `bootstrap_complete`

### 5.4 flux-config (target design)

Generates and applies adopter personalization to Flux. Only runs when `flux.mode: oci`. Skipped when `flux.mode: none` (empty cluster for testing).

This module bridges the gap between infrastructure provisioning and platform service configuration — it creates the Kubernetes resources that tell Flux what to deploy and how to customize it for this specific adopter.

#### flux.mode

| Mode | Behavior | Use case |
|------|----------|----------|
| `oci` | flux-config creates OCIRepository + Kustomization + ConfigMap + Secret | Normal operation (CC and App Env) |
| `none` | Flux controllers installed, no sources configured — cluster is empty | Testing, manual experimentation |

#### OCI source chain

The adopter sets `cluster.artifact_repo.url` to the OCI registry Flux should pull from. This differs by deployment type:

**Control Center:**
- `artifact_repo.url` = Platform Team's public OCI registry (e.g. `ghcr.io/mojaloop/platform`)
- Credentials optional (public repo)
- Flux pulls the platform bundle → deploys platform services including Harbor
- Once Harbor is running, it mirrors/caches the Platform Team's OCI content

**App Environment:**
- `artifact_repo.url` = CC Harbor (e.g. `harbor.cc.example.com/mojaloop/platform`)
- Credentials required (Harbor auth)
- Flux pulls from Harbor → deploys platform services
- App Env never touches the public internet — full sovereignty

The flux-config module doesn't distinguish between CC and App Env. It reads `artifact_repo.url` and creates the OCIRepository. If credentials are configured, it creates a pull secret and attaches `secretRef`. If not, it creates an unauthenticated source.

#### Inputs

| Source | Values |
|--------|--------|
| `config.yaml` | domain, alert_email, lb_ipam range, DNS provider, cluster name, `artifact_repo.url` |
| `.env` | OCI credentials (if authenticated), DNS tokens, provider credentials needed at runtime |
| Terraform outputs | cluster VIP |

#### Kubernetes resources created

1. **`OCIRepository`** — points Flux source-controller at `artifact_repo.url`. Attaches `secretRef` if OCI credentials are configured.
2. **`Kustomization`** — references the OCIRepository, triggers reconciliation of the platform bundle
3. **`ConfigMap` (`cluster-config`)** — adopter values for Flux variable substitution:
   - `domain`, `alert_email`, `lb_ipam_range`, `dns_provider`, `cluster_name`, `cluster_vip`
4. **`Secret` (`cluster-secrets`)** — sensitive adopter values:
   - DNS tokens, provider credentials needed at runtime, OCI credentials (if authenticated)
5. **Provider-specific `Kustomize` patches** — last-mile customization (e.g. AWS NLB annotations vs on-prem IPAM config)

#### How Flux consumes these

Platform Team HelmReleases and Kustomizations are authored generically in the OCI bundle. They reference adopter values via:
- `valuesFrom` — HelmReleases pull values from the `cluster-config` ConfigMap and `cluster-secrets` Secret
- `postBuild.substituteFrom` — Kustomizations substitute `${DOMAIN}`, `${CLUSTER_VIP}`, etc. from the same ConfigMap/Secret

The adopter never forks the platform bundle. All personalization flows through these locally-generated config resources.

## 6. Data Flow

### Instance lifecycle

Trace a single instance from definition to running node:

```
deployment-templates.yaml          config.yaml
  instance: "cc-master-0"           infra.proxmox.placement:
  instance_type: co-4vcpu-8gb         placement-group-1: "node0"
  workload_class: control-plane        placement-group-2: "node2"
  placement_group: placement-group-1   placement-group-3: "node0"
          │                                     │
          ▼                                     ▼
     config-loader ─────────────────────────────┘
          │
          │  resolved instance:
          │    type: co-4vcpu-8gb
          │    class: control-plane
          │    node: node0
          │
          ▼
     provider module
          │
          │  co-4vcpu-8gb → {cores:4, mem:7000}
          │  local-standard → {pool: local-lvm}
          │  patches: cilium.yaml + vip.yaml.tpl(vip=192.168.88.12)
          │
          ▼
     running VM on node0
     with Talos + Kubernetes
```

### Flux config flow

Two deployment scenarios — same flux-config module, different `artifact_repo.url`:

```
Control Center:                        App Environment:
  artifact_repo.url =                    artifact_repo.url =
    ghcr.io/mojaloop/platform              harbor.cc.example.com/platform
  credentials: (none)                    credentials: harbor auth
          │                                       │
          └──────────────┬────────────────────────┘
                         │
config.yaml              │           .env                    TF outputs
  domain: example.com    │             DIGITALOCEAN_TOKEN=xxx  cluster_vip
  dns_provider: do       │             OCI_PASSWORD=xxx          = 192.168.88.12
  lb_ipam: ...           │                  │                        │
          │              │                  │                        │
          └──────────────┼──────────────────┼────────────────────────┘
                         │                  │
                         ▼                  ▼
                   flux-config module (flux.mode: oci)
                         │
        ┌────────────────┼────────────────────────┐
        │                │                        │
        ▼                ▼                        ▼
  ConfigMap          Secret                 OCIRepository +
  cluster-config     cluster-secrets        Kustomization
    domain=...         do_token=xxx           url=artifact_repo.url
    lb_ipam=...        oci_password=xxx       secretRef (if creds)
    cluster_vip=...    ...
        │                │
        └────────┬───────┘
                 │
                 ▼
        Flux postBuild.substituteFrom
        Flux valuesFrom (HelmRelease)
                 │
                 ▼
        Platform HelmReleases rendered with adopter values
          external-dns → digitalocean provider + token
          cert-manager → domain = example.com
          cilium       → lb_ipam = 192.168.88.100-110
```

## 7. Artifacts

What `make apply` produces:

| Artifact | Path | Provider |
|----------|------|----------|
| Kubeconfig | `artifacts/kubernetes/kubeconfig` | All |
| Talos client config | `artifacts/talos-config/talosconfig` | On-prem only |
| Per-instance Talos configs | `artifacts/talos-config/{instance}.yaml` | On-prem only |
| Base Talos configs | `artifacts/talos-config/controlplane.yaml`, `worker.yaml` | On-prem only |
| Talos secrets backup | `artifacts/talos-secrets/secrets.yaml` | On-prem only |
| Terraform state | `artifacts/terraform/terraform.tfstate` | All |
| Terraform plan | `artifacts/terraform/tfplan` | All |

## 8. Module Dependency Chain

```
On-prem (Proxmox):

  config-loader ──→ proxmox (composite)
                           │
                           ├── talos-gen-config
                           │        │
                           ├── proxmox-vm ←────────┘
                           │        │
                           └── talos-bootstrap ←───┘
                                    │
                                    ▼
                              flux-bootstrap
                                    │
                                    ▼
                              flux-config


Managed (AWS/GCP/DO):

  config-loader ──→ managed-k8s
                         │
                         ▼
                   flux-bootstrap
                         │
                         ▼
                   flux-config
```

Both paths produce: **kubeconfig + Flux running with adopter config applied**.
