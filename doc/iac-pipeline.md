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
2. **Create environment directory:** `mkdir -p config/environments/<env>`
3. **Configure credentials:** Copy `config/.env.sample` → `config/environments/<env>/.env`, fill in provider credentials, OCI auth, DNS tokens
4. **Configure infrastructure:** Create/edit `config/environments/<env>/config.yaml` — select provider, deployment template, cluster name/VIP, DNS, app settings
5. **Deploy:**
   ```bash
   make plan ENV=<env>      # Review execution plan
   make apply ENV=<env>     # Provision infrastructure
   ```
6. **Outputs:**
   - `artifacts/<env>/kubernetes/kubeconfig` — cluster access
   - `artifacts/<env>/talos-config/talosconfig` — Talos API access (on-prem only)
   - Flux running and reconciling platform services with adopter values applied

### Multiple environments from a single clone

```bash
# Deploy Control Center
make plan-apply ENV=cc

# Deploy App Environment
make plan-apply ENV=env-prod
```

Each environment has its own config, secrets, Terraform state, and artifacts — fully independent.

## 4. Configuration System

All configuration lives under `config/`. Two ownership levels:

### Adopter-owned (edited per environment)

| File | Purpose |
|------|---------|
| `config/environments/<env>/config.yaml` | Infrastructure config: provider, template, cluster, DNS, app settings |
| `config/environments/<env>/.env` | Secrets and credentials (git-ignored) |

### Platform-team-owned (bundled, not normally edited)

| Path | Purpose |
|------|---------|
| `config/definitions/workload-classes.yaml` | Talos/K8s versions, node role definitions (control-plane, worker, mixed-plane) |
| `config/patches/talos/` | Talos machine config patches — static `.yaml` (cilium-install, openebs, allow-scheduling-on-cp) and templates `.yaml.tpl` (vip) |
| `config/providers/{proxmox,aws,gcp,digitalocean,openstack}/` | Provider-specific deployment templates, VM/instance defaults |
| `gitops/` | FluxCD Kustomize manifests — platform services, vendor-specific gap-fillers, CC/env apps |

The adopter touches `config/environments/<env>/config.yaml` + `.env`. Everything else ships with the bundle.

### Environment isolation

The `ENV=` variable (default: `cc`) selects the active environment. Terraform state and artifacts are stored per-environment under `artifacts/<env>/`. The Makefile passes `-backend-config` to `terraform init` to route state to the correct location.

## 5. Module Pipeline

### 5.1 config-loader

Loads all YAML configs from `config/` and normalizes them into a single structured output.

**Inputs:**
- `config/environments/<env>/config.yaml` — adopter config
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
- `paths` — shared patch folder location

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
- `artifacts/<env>/talos-config/controlplane.yaml` — base control-plane config
- `artifacts/<env>/talos-config/worker.yaml` — base worker config
- `artifacts/<env>/talos-config/{instance-name}.yaml` — per-instance configs
- `artifacts/<env>/talos-config/talosconfig` — talosctl client config
- `artifacts/<env>/talos-secrets/secrets.yaml` — cluster secrets backup

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

Artifacts: `artifacts/<env>/kubernetes/kubeconfig`

#### 5.2.2 Managed: aws

Provisions an EKS cluster with VPC, IAM, node groups, and managed service instances.

**Infrastructure:**
- VPC with dynamic AZ discovery (up to 3 AZs), subnets, Internet Gateway, route tables
- IAM roles for cluster (`AmazonEKSClusterPolicy`) and nodes (`AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`)
- EKS cluster with version extracted from `kubernetes_version` (major.minor)
- Node groups from deployment template (instance types, scaling config)
- EKS add-on: `aws-ebs-csi-driver` for persistent volumes

**Managed services (CC role):**
- `aws_s3_bucket` — object storage (replaces MinIO)
- `aws_ecr_repository` — OCI registry (replaces Harbor)

**Managed services (Env role):**
- `aws_rds_cluster` — Aurora MySQL (replaces Percona XtraDB)
- `aws_msk_cluster` — Managed Streaming for Kafka (replaces Strimzi)
- `aws_docdb_cluster` — DocumentDB (replaces Percona MongoDB)
- `aws_elasticache_replication_group` — Redis (replaces in-cluster Redis)

**Kubeconfig:** Uses `aws eks get-token` exec auth plugin (auto-refreshing tokens).

Outputs: `kubeconfig_path`, `s3_bucket`, `ecr_url`, `rds_endpoint`, `msk_endpoint`, `docdb_endpoint`, `elasticache_endpoint`

#### 5.2.3 Managed: gcp

Provisions a GKE cluster with VPC, node pools, Dataplane V2 (Cilium), and managed service instances.

**Infrastructure:**
- VPC with subnet (`google_compute_network`, `google_compute_subnetwork`), VPC-native networking
- GKE cluster with `datapath_provider = "ADVANCED_DATAPATH"` (Cilium), `gateway_api_config { channel = "CHANNEL_STANDARD" }`, Workload Identity enabled
- Node pools from deployment template (machine types, node counts)
- `remove_default_node_pool = true` — explicit pool management

**Managed services (CC role):**
- `google_storage_bucket` + HMAC keys — object storage with S3-compat API (replaces MinIO)
- `google_artifact_registry_repository` — OCI registry (replaces Harbor)

**Managed services (Env role):**
- `google_sql_database_instance` — Cloud SQL for MySQL (replaces Percona XtraDB)
- `google_managed_kafka_cluster` — Managed Kafka (replaces Strimzi)
- `mongodbatlas_cluster` — MongoDB Atlas on GCP (replaces Percona MongoDB)
- `google_redis_instance` — Memorystore for Redis (replaces in-cluster Redis)

**Kubeconfig:** Uses `gcloud` exec auth or token-based authentication.

Outputs: `kubeconfig_path`, `gcs_bucket`, `gar_url`, `cloudsql_endpoint`, `kafka_endpoint`, `atlas_endpoint`, `redis_endpoint`

#### 5.2.4 Managed: digitalocean

Provisions a DOKS cluster with VPC and node pools. Simpler than AWS/GCP — fewer managed services, Cilium is the default managed CNI.

Outputs: `kubeconfig_path`, cluster provisioned

#### 5.2.5 On-prem: openstack (target design)

Provisions Talos Linux VMs on OpenStack, structurally identical to the Proxmox composite module.

**Pipeline:** `talos-gen-config → openstack-vm → talos-bootstrap`

**Infrastructure:**
- Neutron network + subnet + router + floating IPs
- Security groups (ports 6443, 50000 for Talos API)
- `openstack_compute_instance_v2` VMs with Talos raw disk images (uploaded to Glance)
- Talos machine configs applied via cloud-init

**Terraform provider:** `terraform-provider-openstack/openstack ~> 3.0` + `siderolabs/talos ~> 0.9`

OpenStack sits between on-prem and cloud: K8s is self-managed (Talos), but infrastructure services (Cinder for storage, Swift for S3, Octavia for LB, Designate for DNS) are managed by the OpenStack platform.

Outputs: `kubeconfig_path`, cluster provisioned

### 5.3 flux-bootstrap

Installs FluxCD into the cluster. Provider-agnostic — works identically for on-prem and managed. Always runs.

**Components installed:**
- source-controller
- kustomize-controller
- helm-controller
- notification-controller

**Inputs:** kubeconfig (from provider module), Flux version, namespace

**Outputs:** `flux_installed`, `flux_namespace`, `bootstrap_complete`

### 5.4 flux-config

Generates and applies adopter personalization to Flux. Only runs when `oci.repo.active: true`. Skipped when `oci.repo.active: false` (empty cluster for testing).

This module bridges the gap between infrastructure provisioning and platform service configuration — it creates the Kubernetes resources that tell Flux what to deploy and how to customize it for this specific adopter.

#### oci.repo.active

| Value | Behavior | Use case |
|-------|----------|----------|
| `true` | flux-config creates OCIRepository + Kustomizations + ConfigMap + Secret | Normal operation (CC and App Env) |
| `false` | Flux controllers installed, no sources configured — cluster is empty | Testing, manual experimentation |

#### OCI source chain

The adopter sets `oci.repo.url` to the OCI registry Flux should pull from. This differs by deployment type:

**Control Center (self-hosted: Proxmox, OpenStack):**
- `oci.repo.url` = Platform Team's public OCI registry (e.g. `oci://ghcr.io/mojaloop/ml-gitops`)
- Credentials optional (public repo)
- Flux pulls the platform bundle → deploys platform services, and the vendor kustomization deploys Harbor + MinIO
- Once Harbor is running, it mirrors/caches the Platform Team's OCI content
- `oci.proxy.active: false` — CC IS the proxy
- App Environments pull from CC Harbor for air-gapped operation

**Control Center (managed: AWS, GCP):**
- `oci.repo.url` = Platform Team's public OCI registry (e.g. `oci://ghcr.io/mojaloop/ml-gitops`) or managed registry (e.g. `oci://123456789.dkr.ecr.us-east-1.amazonaws.com/ml-gitops`)
- Credentials optional (public repo) or managed IAM (ECR/GAR)
- Flux pulls the platform bundle → deploys platform services. No Harbor or MinIO — Terraform has already created the managed OCI registry and S3/GCS bucket
- `oci.proxy.active: false` — no in-cluster image proxy
- App Environments pull from the same managed OCI registry or directly from the Platform Team's public registry

**App Environment (self-hosted CC):**
- `oci.repo.url` = CC Harbor (e.g. `oci://harbor.cc.example.com/mojaloop/ml-gitops`)
- Credentials required (Harbor auth)
- Flux pulls from CC Harbor → deploys platform services
- `oci.proxy.active: true` — Talos registry mirrors route container pulls through Harbor
- App Env can operate fully air-gapped when both repo and proxy point through Harbor

**App Environment (managed CC):**
- `oci.repo.url` = Managed OCI registry (e.g. ECR, GAR) or Platform Team's public registry (GHCR)
- Credentials required (managed IAM or GHCR PAT)
- Flux pulls from the configured registry → deploys platform services
- `oci.proxy.active: false` — no in-cluster image proxy; container images pulled directly from public registries

#### Kustomization paths

A single OCIRepository serves multiple Flux Kustomizations, each pointing to a different `path` within the artifact:

```
OCIRepository (ml-gitops)
    │
    ├── Kustomization: platform        path: ./platform        (always)
    │       ↓
    ├── Kustomization: platform-config path: ./platform-config (always — Gateway with wildcard TLS)
    │       ↓
    ├── Kustomization: <vendor>        path: ./<vendor>        (exactly one: onprem|aws|gcp|openstack)
    │       ↓
    │   ┌───────────────────────────────────────────────────┐
    │   │  CC path:                    Env path:            │
    │   │  cc → cc-config → cc-routes  env [→ env-data]     │
    │   │                              → env-auth → env-app │
    │   └───────────────────────────────────────────────────┘
```

Dependency chain ensures ordering:
- `platform` deploys first (cert-manager, external-dns, ESO, metrics-server)
- `platform-config` waits for platform (needs cert-manager running), deploys Gateway with `${gateway_class_name}` and wildcard TLS
- `<vendor>` waits for platform-config — deploys provider-specific gap-fillers:
  - `onprem/`: Cilium HelmRelease, LB-IPAM, OpenEBS, MinIO, Harbor, ClusterIssuers + DNS secret
  - `aws/`: Cilium BYOCNI HelmRelease, ClusterIssuers (Route53) + DNS secret
  - `gcp/`: ClusterIssuers (Cloud DNS) + DNS secret (Cilium is GKE-managed)
  - `openstack/`: Cilium HelmRelease, Harbor, ClusterIssuers (Designate/RFC-2136) + DNS secret
- `cc` waits for vendor — deploys operators (vault-operator), creates namespaces
- `cc-config` waits for cc — deploys Vault CR, SecretStore; health checks confirm services running
- `cc-routes` waits for cc-config — deploys HTTPRoutes (backends guaranteed to exist)
- `env` waits for vendor — deploys data/auth/app operators
- `env-data` waits for env — deploys in-cluster data CRs (self-hosted profile only: Proxmox, OpenStack)
- `env-auth` waits for env-data (if present) or env (if managed) — deploys Keycloak, Ory stack
- `env-app` waits for env-auth — deploys Mojaloop core, MCM, Finance Portal

Every provider gets a vendor kustomization — the concept is no longer "on-prem only". The vendor layer normalizes provider differences so all layers above it (cc, env, app) are generic.

#### Inputs

| Source | Values |
|--------|--------|
| `config/environments/<env>/config.yaml` | domain, alert_email, lb_ipam range, DNS provider, cluster name/role, infra provider, gateway_class_name, `oci.repo.url`/`version` |
| `config/environments/<env>/.env` | OCI credentials (if authenticated), DNS tokens, provider credentials needed at runtime |
| Terraform outputs (all) | cluster VIP, gateway_class_name |
| Terraform outputs (managed CC) | s3_bucket, s3_endpoint, s3_region, oci_registry_url |
| Terraform outputs (managed env) | mysql_central_ledger_host, mysql_account_lookup_host, kafka_host, mongodb_host, redis_host (+ ports) |

#### Kubernetes resources created

1. **`OCIRepository`** — points Flux source-controller at `oci.repo.url`. Attaches `secretRef` (type `kubernetes.io/dockerconfigjson`) if OCI repo credentials are configured.
2. **`Kustomization` (platform)** — always deployed, shared services
3. **`Kustomization` (platform-config)** — always deployed, Gateway with wildcard TLS
4. **`Kustomization` (vendor)** — exactly one per provider (`onprem`, `aws`, `gcp`, `openstack`), deploys provider-specific gap-fillers including ClusterIssuers
5. **`Kustomization` (role-specific)** — cc or env, depends on vendor kustomization
6. **`Kustomization` (env-data)** — only on self-hosted profile (Proxmox, OpenStack) for in-cluster data layer
7. **`Kustomization` (env-auth, env-app)** — always for env clusters
8. **`ConfigMap` (`cluster-config`)** — adopter values for Flux variable substitution:
   - `cluster_name`, `cluster_vip`, `domain`, `dns_provider`, `alert_email`, `lb_ipam_range`, `gateway_class_name`
   - For env clusters: `mysql_central_ledger_host`, `kafka_host`, `mongodb_host`, `redis_host` (+ ports)
   - For CC clusters (managed): `s3_bucket`, `s3_endpoint`, `s3_region`
9. **`Secret` (`cluster-secrets`)** — sensitive adopter values:
   - `digitalocean_token`, `oci_repo_username`, `oci_repo_password`, `oci_proxy_username`, `oci_proxy_password`
   - DNS provider credentials (provider-specific)
   - For CC clusters (self-hosted only): `minio_root_user`, `minio_root_password`, `harbor_admin_password`
   - For env clusters: database passwords, OIDC secrets

#### How Flux consumes these

Platform Team HelmReleases and Kustomizations are authored generically in the OCI bundle. They reference adopter values via:
- `postBuild.substituteFrom` — Kustomizations substitute `${domain}`, `${cluster_vip}`, etc. from the ConfigMap/Secret
- `valuesFrom` — HelmReleases pull values from the same ConfigMap/Secret

The adopter never forks the platform bundle. All personalization flows through these locally-generated config resources.

## 6. Data Flow

### Instance lifecycle (on-prem)

Trace a single instance from definition to running node:

```
providers/proxmox/                     config/environments/<env>/config.yaml
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
config/environments/<env>/   config/environments/<env>/   TF outputs
  config.yaml                  .env                       cluster_vip, gateway_class_name
  oci.repo.url=                OCI_REPO_USERNAME=xxx      s3_bucket, ecr_url (CC managed)
    oci://ghcr.io/...          OCI_REPO_PASSWORD=xxx      rds_endpoint, msk_endpoint (env managed)
  cluster.role=cc              DNS_TOKEN=xxx              ...
  infra.provider=aws
  domain, dns, app...
          │                      │                          │
          └──────────────────────┼──────────────────────────┘
                                 │
                                 ▼
                       flux-config module (oci.repo.active: true)
                                 │
        ┌────────────────────────┼──────────────────────────┐
        │                        │                          │
        ▼                        ▼                          ▼
  ConfigMap                  Secret                   OCIRepository
  cluster-config             cluster-secrets          (ml-gitops)
    domain=...                 dns_token=xxx              │
    gateway_class_name=...     oci_repo_password=xxx      │
    dns_provider=...           db_passwords=xxx           │
    s3_bucket=... (managed)    ...                        │
    mysql_host=... (managed)                              │
        │                        │              ┌─────────┼───────────┐
        └────────┬───────────────┘              │         │           │
                 │                              ▼         ▼           ▼
                 │                        Kustomization paths:
                 │                        platform  <vendor>  cc|env→...
                 │                        (exactly one: onprem|aws|gcp|openstack)
                 │                              │         │           │
                 └──────────────────────────────┼─────────┼───────────┘
                                                │
                                                ▼
                                     Flux postBuild.substituteFrom
                                     Flux valuesFrom (HelmRelease)
                                                │
                                                ▼
                                     HelmReleases rendered with adopter values
                                       external-dns  → ${dns_provider} + DNS credentials
                                       Gateway       → ${gateway_class_name}
                                       ClusterIssuer → provider-specific DNS-01 solver (in vendor kustomization)
                                       Mojaloop      → ${mysql_central_ledger_host}, ${kafka_host}, ...
```

## 7. Artifacts

What `make apply ENV=<env>` produces:

| Artifact | Path | Provider |
|----------|------|----------|
| Kubeconfig | `artifacts/<env>/kubernetes/kubeconfig` | All |
| Talos client config | `artifacts/<env>/talos-config/talosconfig` | On-prem only |
| Per-instance Talos configs | `artifacts/<env>/talos-config/{instance}.yaml` | On-prem only |
| Base Talos configs | `artifacts/<env>/talos-config/controlplane.yaml`, `worker.yaml` | On-prem only |
| Talos secrets backup | `artifacts/<env>/talos-secrets/secrets.yaml` | On-prem only |
| Terraform state | `artifacts/<env>/terraform/terraform.tfstate` | All |
| Terraform plan | `artifacts/<env>/terraform/tfplan` | All |

## 8. Module Dependency Chain

```
On-prem (Proxmox, OpenStack):

  config-loader ──→ provider (composite: talos-gen-config → vm-provisioning → talos-bootstrap)
                         │
                         ▼
                   flux-bootstrap
                         │
                         ▼
                   flux-config


Managed (AWS, GCP, DigitalOcean):

  config-loader ──→ provider (cluster + managed services)
                         │
                         ├── K8s cluster (EKS/GKE/DOKS)
                         ├── CC services: S3 bucket, OCI registry (if role=cc)
                         └── Env services: RDS, MSK, DocumentDB, ElastiCache (if role=env)
                         │
                         ▼
                   flux-bootstrap
                         │
                         ▼
                   flux-config (receives managed service endpoints as variables)
```

Both paths produce: **kubeconfig + Flux running with adopter config applied + managed service endpoints injected into GitOps substitution variables**.
