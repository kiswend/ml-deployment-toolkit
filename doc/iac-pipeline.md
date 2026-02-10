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
| `config/definitions/workload-classes.yaml` | Talos/K8s versions, node role definitions (control-plane, worker, mixed-plane) |
| `config/patches/talos/` | Talos machine config patches — static `.yaml` (cilium-install, openebs, allow-scheduling-on-cp) and templates `.yaml.tpl` (vip) |
| `config/providers/{proxmox,aws,digitalocean}/` | Provider-specific deployment templates, VM/instance defaults |
| `gitops/` | FluxCD Kustomize manifests — platform services, on-prem gap fillers, CC/env apps |

The adopter touches `config.yaml` + `.env`. Everything else ships with the bundle.

## 5. Module Pipeline

### 5.1 config-loader

Loads all YAML configs from `config/` and normalizes them into a single structured output.

**Inputs:**
- `config/config.yaml` — adopter config
- `config/definitions/workload-classes.yaml` — Talos/K8s versions, node role definitions
- `config/providers/{provider}/deployment-templates.yaml` — provider-specific cluster topologies
- `config/providers/{provider}/config.yaml` — provider defaults (VM specs, image settings)

**Processing:**
1. Selects deployment template by name from the active provider's templates (e.g. "h1m1" → 1 mixed-plane node)
2. For on-prem: resolves placement groups → physical nodes, constructs Talos image URL from version + schematic, attaches workload class patches
3. For managed K8s: passes through node pool/group definitions as-is
4. Separates instances by role (control-plane/mixed-plane vs worker)

**Outputs:**
- `instances` — normalized list with resolved placement and workload class (on-prem only)
- `control_plane_instances` / `worker_instances` — filtered lists (on-prem only)
- `deployment_template` — raw template data for managed K8s (node_pools, node_groups)
- `workload_classes` — class definitions with talos_type and patch lists
- `talos_version` / `kubernetes_version` — from workload-classes.yaml (single source of truth)
- `talos_image` — constructed URL and file name
- `label_taint_patches` — dynamically generated patches for node labels/taints
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
1. **Workload class patches** — defined in `workload-classes.yaml` per class (e.g. `patch-cilium-install.yaml` for all classes, `patch-openebs.yaml` for workers and mixed-plane, `patch-allow-scheduling-on-cp.yaml` for mixed-plane)
2. **Provider patches** — rendered from templates with provider-specific values (e.g. VIP patch with `vip_address` and `interface`)
3. **Label/taint patches** — dynamically generated for workload classes with `node_labels` or `node_taints`

Outputs: `instance_configs` map (instance name → machine config YAML), `client_configuration` (for talosctl)

Artifacts:
- `artifacts/talos-config/controlplane.yaml` — base control-plane config
- `artifacts/talos-config/worker.yaml` — base worker config
- `artifacts/talos-config/{instance-name}.yaml` — per-instance configs
- `artifacts/talos-config/talosconfig` — talosctl client config
- `artifacts/talos-secrets/secrets.yaml` — cluster secrets backup

**proxmox-vm (infrastructure):**

Provisions VMs on Proxmox using specs from deployment templates.

- Reads cores, memory, storage directly from deployment template (no abstract type indirection)
- Constructs Talos image URL from version + schematic (single source of truth in workload-classes.yaml)
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

### 5.4 flux-config

Generates and applies adopter personalization to Flux. Only runs when `flux.mode: oci`. Skipped when `flux.mode: none` (empty cluster for testing).

This module bridges the gap between infrastructure provisioning and platform service configuration — it creates the Kubernetes resources that tell Flux what to deploy and how to customize it for this specific adopter.

#### flux.mode

| Mode | Behavior | Use case |
|------|----------|----------|
| `oci` | flux-config creates OCIRepository + Kustomizations + ConfigMap + Secret | Normal operation (CC and App Env) |
| `none` | Flux controllers installed, no sources configured — cluster is empty | Testing, manual experimentation |

#### OCI source chain

The adopter sets `cluster.flux.artifact.url` to the OCI registry Flux should pull from. This differs by deployment type:

**Control Center:**
- `artifact.url` = Platform Team's public OCI registry (e.g. `oci://ghcr.io/mojaloop/ml-gitops`)
- Credentials optional (public repo)
- Flux pulls the platform bundle → deploys platform services including Harbor
- Once Harbor is running, it mirrors/caches the Platform Team's OCI content

**App Environment:**
- `artifact.url` = CC Harbor (e.g. `oci://harbor.cc.example.com/mojaloop/ml-gitops`)
- Credentials required (Harbor auth)
- Flux pulls from Harbor → deploys platform services
- App Env never touches the public internet — full sovereignty

#### Kustomization paths

A single OCIRepository serves multiple Flux Kustomizations, each pointing to a different `path` within the artifact:

```
OCIRepository (ml-gitops)
    │
    ├── Kustomization: platform        path: ./platform        (always)
    │       ↓
    ├── Kustomization: platform-config path: ./platform-config (always — ClusterIssuers, DNS-01 secret)
    │       ↓
    ├── Kustomization: onprem          path: ./onprem          (if provider == proxmox)
    │       ↓
    ├── Kustomization: cc              path: ./cc              (if cluster.role == cc — operators)
    │       ↓
    ├── Kustomization: cc-config       path: ./cc-config       (if cluster.role == cc — services)
    │       ↓
    ├── Kustomization: cc-routes       path: ./cc-routes       (if cluster.role == cc — HTTPRoutes, after services healthy)
    │
    └── Kustomization: env             path: ./env             (if cluster.role == env)
```

Dependency chain ensures ordering:
- `platform` deploys first (cert-manager, external-dns, ESO, metrics-server)
- `platform-config` waits for platform (needs cert-manager running), deploys ClusterIssuers (DNS-01), DNS token Secret, Gateway (wildcard TLS)
- `onprem` waits for platform-config, deploys Cilium HelmRelease (with `gatewayAPI.enabled` → auto-creates GatewayClass), LB-IPAM, OpenEBS
- `cc` waits for onprem (if present) or platform-config (if cloud) — deploys operators (vault-operator), creates namespaces (vault, harbor, minio)
- `cc-config` waits for cc — deploys Vault CR (vault ns), MinIO HelmRelease (minio ns), Harbor HelmRelease (harbor ns); health checks confirm services running
- `cc-routes` waits for cc-config — deploys HTTPRoutes for vault, harbor, minio (backends guaranteed to exist)
- `env` waits for onprem (if present) or platform-config (if cloud) — deploys Mojaloop app

On managed K8s (DOKS/EKS), `onprem` is skipped entirely — cloud-native CNI, load balancers, storage, and S3 are used instead.

#### Inputs

| Source | Values |
|--------|--------|
| `config.yaml` | domain, alert_email, lb_ipam range, DNS provider, cluster name/role, infra provider, `artifact.url`/`version` |
| `.env` | OCI credentials (if authenticated), DNS tokens, provider credentials needed at runtime |
| Terraform outputs | cluster VIP |

#### Kubernetes resources created

1. **`OCIRepository`** — points Flux source-controller at `artifact.url`. Attaches `secretRef` (type `kubernetes.io/dockerconfigjson`) if OCI credentials are configured.
2. **`Kustomization` (platform)** — always deployed, shared services
3. **`Kustomization` (onprem)** — conditionally deployed when `infra.provider == "proxmox"`, on-prem gap fillers
4. **`Kustomization` (cc or env)** — role-specific services, depends on upstream kustomizations
5. **`ConfigMap` (`cluster-config`)** — adopter values for Flux variable substitution:
   - `cluster_name`, `cluster_vip`, `domain`, `dns_provider`, `alert_email`, `lb_ipam_range`
6. **`Secret` (`cluster-secrets`)** — sensitive adopter values:
   - `digitalocean_token`, `oci_username`, `oci_password`

#### How Flux consumes these

Platform Team HelmReleases and Kustomizations are authored generically in the OCI bundle. They reference adopter values via:
- `postBuild.substituteFrom` — Kustomizations substitute `${domain}`, `${cluster_vip}`, etc. from the ConfigMap/Secret
- `valuesFrom` — HelmReleases pull values from the same ConfigMap/Secret

The adopter never forks the platform bundle. All personalization flows through these locally-generated config resources.

## 6. Data Flow

### Instance lifecycle (on-prem)

Trace a single instance from definition to running node:

```
providers/proxmox/                     config.yaml
  deployment-templates.yaml              infra.proxmox.placement:
    instance: "m-0"                        placement-group-1: "node0"
    cores: 4, memory: 7168               template: "h1m1"
    workload_class: mixed-plane
    placement_group: placement-group-1
          │                                     │
          ▼                                     ▼
     config-loader ─────────────────────────────┘
          │
          │  resolved instance:
          │    name: m-0
          │    cores: 4, memory: 7168
          │    class: mixed-plane (talos_type: controlplane)
          │    target_node: node0
          │    patches: cilium + openebs + allow-scheduling-on-cp + vip
          │
          ▼
     proxmox module
          │  image URL: factory.talos.dev/image/{schematic}/{version}/nocloud-amd64.raw.gz
          │  storage_pool: local-lvm
          │
          ▼
     running VM on node0
     with Talos + Kubernetes
```

### Flux config flow

```
config.yaml              .env                    TF outputs
  artifact.url=          OCI_USERNAME=xxx        cluster_vip
    oci://ghcr.io/...    OCI_PASSWORD=xxx          = 192.168.88.10
  cluster.role=cc        DIGITALOCEAN_TOKEN=xxx
  infra.provider=proxmox
  domain, dns, app...
          │                  │                        │
          └──────────────────┼────────────────────────┘
                             │
                             ▼
                   flux-config module (flux.mode: oci)
                             │
        ┌────────────────────┼──────────────────────────┐
        │                    │                          │
        ▼                    ▼                          ▼
  ConfigMap              Secret                   OCIRepository
  cluster-config         cluster-secrets          (ml-gitops)
    domain=...             do_token=xxx              │
    lb_ipam=...            oci_password=xxx          │
    cluster_vip=...        ...                       │
        │                    │              ┌────────┼────────┐
        └────────┬───────────┘              │        │        │
                 │                          ▼        ▼        ▼
                 │                    Kustomization paths:
                 │                    platform  onprem*  cc|env
                 │                    (* if provider=proxmox)
                 │                          │        │        │
                 └──────────────────────────┼────────┼────────┘
                                            │
                                            ▼
                                 Flux postBuild.substituteFrom
                                 Flux valuesFrom (HelmRelease)
                                            │
                                            ▼
                                 HelmReleases rendered with adopter values
                                   external-dns → ${dns_provider} + ${digitalocean_token}
                                   cert-manager → ${domain}
                                   cilium       → ${lb_ipam_range} (on-prem only)
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
