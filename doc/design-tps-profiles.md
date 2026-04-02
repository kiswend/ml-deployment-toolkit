# Design: TPS-Based Sizing Profiles

## Problem Statement

Today, deploying Mojaloop requires the deployer to understand infrastructure topology (e.g. `h2c1w3`, `h2c1w3k3d3`) and application scaling is hardcoded in the gitops manifests. There is no connection between the chosen infrastructure size and the application-level scaling (Kafka partitions, handler replicas, MySQL tuning). The deployer must be an expert in both infrastructure and Mojaloop internals.

**Goal:** Reduce the deployer's decision to two inputs -- the infrastructure provider and the desired transaction throughput (TPS). The Mojaloop platform team prepares tested profiles per provider that bundle infrastructure topology, application scaling, and data layer tuning into one coherent package per TPS target.

## Decision Factors

### 1. Four Dimensions Scale Together

A transfer in Mojaloop flows through: API adapter -> Kafka -> central-ledger handlers -> MySQL -> Kafka -> notification handler. Scaling any one layer without the others creates a bottleneck. The four scaling dimensions are:

- **Infrastructure provider**: The outermost dimension. Determines what infrastructure looks like (VMs vs managed node groups), whether data services are self-hosted or managed (PXC vs RDS, Strimzi vs MSK), what tuning knobs are available, and who maintains the profiles. The provider shapes the other three dimensions -- the same TPS target looks fundamentally different on Proxmox vs AWS vs DigitalOcean. This is why profiles are organized per-provider.
- **Infrastructure topology**: Node count (horizontal), node size (vertical), node specialization (dedicated Kafka/DB nodes via taints/tolerations). Provider-specific: Proxmox defines VMs with cores/memory/storage; AWS defines node groups with instance types; DigitalOcean defines node pools with droplet sizes.
- **Application horizontal scaling**: Pod replica counts for Mojaloop handlers, API services, auth components. Provider-influenced: the same TPS target may need more replicas on smaller VMs (Proxmox) than on beefier instances (AWS).
- **Data layer tuning**: Kafka partition counts per topic (determines max consumer parallelism), MySQL InnoDB buffer pool size, max connections, flush/durability settings, storage sizing. Provider-dependent: self-hosted (Proxmox/DigitalOcean) has full tuning control; managed services (AWS RDS/MSK) have different or fewer knobs.

These four dimensions must be co-designed for a given TPS target. They are not independently tunable without expert knowledge.

### 2. Evidence from Performance Testing (`legacy/ml-perf`)

The Mojaloop performance whitepaper workspace contains tested configurations for 500, 1000, and 2000 TPS on AWS. Key findings:

**Replica counts scale aggressively with TPS:**

| Service | 500 TPS | 1000 TPS | 2000 TPS |
|---------|---------|----------|----------|
| account-lookup-service | 16 | 20 | 24 |
| quoting-service | 12 | 12 | 16 |
| quoting-service-handler | 12 | 12 | 16 |
| ml-api-adapter-service | 12 | 12 | 16 |
| ml-api-adapter-handler-notification | 18 | 18 | 32 |
| centralledger-service | 8 | 8 | 8 |
| cl-handler-transfer-prepare | 12 | 12 | 16 |
| cl-handler-transfer-position-batch | 8 | 8 | 8 |
| cl-handler-transfer-fulfil | 12 | 12 | 16 |
| als-msisdn-oracle | 8 | 8 | 8 |

**Kafka partitions must match handler replicas** (idle consumers if replicas > partitions):

| Topic | 500 TPS | 1000 TPS | 2000 TPS |
|-------|---------|----------|----------|
| topic-transfer-prepare | 12 | 12 | 16 |
| topic-transfer-fulfil | 12 | 12 | 16 |
| topic-quotes-post | 12 | 12 | 16 |
| topic-quotes-put | 12 | 12 | 16 |
| topic-transfer-position-batch | 8 | 8 | 8 |
| topic-notification-event | 12 | 18 | 32 |

**MySQL was tuned vertically, not scaled horizontally:**
- `innodb_buffer_pool_size: 40G` (vs current 512M)
- `innodb_flush_log_at_trx_commit: 2` (trades durability for speed)
- `sync_binlog: 0`, `log_bin: 0`
- `max_connections: 5000` (reduced to 2000 at 2000 TPS)
- Node: m7i.4xlarge (16 vCPU, 64GB) -> m7i.8xlarge (32 vCPU, 128GB) at 2000 TPS
- PXC replica count stayed at 1 in perf testing (3 in production for HA via raft -- not for write scaling)

**Infrastructure scaled vertically at 2000 TPS:**
- Switch worker nodes: m7i.4xlarge (16c/64G) -> m7i.8xlarge (32c/128G)
- This confirms that horizontal-only scaling has a ceiling

### 3. Horizontal-Only Assessment

- **2-50 TPS**: Horizontal scaling of handlers is sufficient. Small nodes work.
- **200 TPS**: Horizontal + MySQL config tuning (buffer pool, connections). Moderate node sizes.
- **1000 TPS**: Requires both horizontal scaling AND vertical infrastructure (bigger nodes) + aggressive MySQL tuning. Cannot achieve with horizontal-only.

**Decision:** Profiles govern all four dimensions. The provider is selected by the deployer (it's a business/operational choice); the profile then governs infrastructure topology, app scaling, and data tuning for that provider. Data layer replicas stay fixed at 3 (raft HA) -- what changes is configuration tuning. Infrastructure topology defines both node count AND node size.

### 4. Provider Shapes Everything Else

Since the provider is the outermost dimension (see section 1), the other three dimensions look different on each provider:

| Dimension | Proxmox | AWS | DigitalOcean |
|-----------|---------|-----|--------------|
| Infra topology | VM cores/memory/storage, placement groups | Instance types, node groups, auto-scaling | Droplet sizes, node pools |
| App replicas | May need more on smaller VMs | Fewer on beefier instances | Varies by droplet size |
| Data tuning | Self-hosted PXC, Strimzi, PSMDB | Could be managed RDS/MSK/DocumentDB | Self-hosted (no managed data services) |
| Maintained by | On-prem infra team | Cloud infra team | Cloud infra team |

The existing codebase already separates Terraform modules and config per provider (`config/providers/{provider}/`, `src/modules/{provider}/`). TPS profiles follow the same pattern -- profiles live under each provider directory because the same TPS target produces fundamentally different configurations per provider.

### 5. Cluster Role Separation

The system has three cluster roles, each with different scaling concerns:

| | **env** (Mojaloop switch) | **cc** (control center) | **base** (DFSP simulator) |
|---|---|---|---|
| Sizing driver | Transaction throughput (TPS) | Number of environments served | Number of DFSPs simulated |
| Deploys | Mojaloop app, data layer, auth stack, observability agent | Vault, Harbor, MinIO, observability stack (Loki/Mimir/Tempo) | Platform services only (Cilium, DNS, cert-manager, Gateway) — no role-specific kustomizations |
| Scales | Mojaloop handlers, Kafka partitions, MySQL tuning | Harbor storage, observability ingestion, MinIO | Minimal — mostly infra topology |
| Irrelevant | Thanos, Harbor, MinIO | Kafka, Mojaloop app, MongoDB, auth stack | Everything app/data/cc |

Current environments: `ml-cc` (role: cc), `ml-test` (role: env, template: h2c1w3), `ml-dfsp` (role: base, template: h1m1-dfsp), `dc-cc` (role: cc).

**Decision:** Profiles are split by cluster role. `env` profiles are TPS-driven. `cc` profiles are operations-scale-driven (small/medium/large). `base` profiles are lightweight — primarily infra topology with minimal or no app/data tuning.

## What Was Decided

### Profile Directory Structure

```
config/providers/
  proxmox/
    config.yaml                          # existing, unchanged
    profiles/
      env/                               # TPS-driven (Mojaloop switch)
        tps-1.yaml                       # Minimal switch (derived from current ml-test/h2c1w3)
        tps-500.yaml                     # Derived from ml-perf 500 TPS benchmarks
        tps-2000.yaml                    # Derived from ml-perf 2000 TPS benchmarks
      cc/                                # operations-scale-driven (control center)
        small.yaml                       # 1-2 environments
      base/                              # DFSP simulator / lightweight clusters
        small.yaml                       # Single mixed-plane node
  aws/
    config.yaml
    profiles/
      env/
        tps-1.yaml
        tps-500.yaml
        tps-2000.yaml
      cc/
        small.yaml
      base/
        small.yaml
  digitalocean/
    config.yaml
    profiles/
      env/ ...
      cc/ ...
      base/ ...
```

Additional env TPS tiers (tps-10, tps-50, tps-200) and CC sizes (medium, large) will be added as they are validated through load testing. The initial set covers the current running clusters plus the two benchmarked performance tiers.

**`deployment-templates.yaml` is retired.** Infrastructure topology is inlined inside each profile. One file = everything for that tier on that provider.

### Deployer's Environment Config

Before (requires knowing template names and gets no app scaling):

```yaml
infra:
  provider: proxmox
template: "h2c1w3"        # deployer must know what this means
cluster:
  role: env
```

After (single meaningful choice):

```yaml
# ml-test — Mojaloop switch (env)
infra:
  provider: proxmox
profile: tps-1             # resolved as: config/providers/proxmox/profiles/env/tps-1.yaml
cluster:
  role: env                # determines profile subdirectory (env/ vs cc/ vs base/)
```

```yaml
# ml-cc — Control Center
infra:
  provider: proxmox
profile: small             # resolved as: config/providers/proxmox/profiles/cc/small.yaml
cluster:
  role: cc
```

```yaml
# ml-dfsp — DFSP simulator (base)
infra:
  provider: proxmox
profile: small             # resolved as: config/providers/proxmox/profiles/base/small.yaml
cluster:
  role: base
```

### Profile File Format

#### Environment Profile (TPS-driven)

This is the `tps-1` profile — derived directly from the current `ml-test` cluster (template `h2c1w3`) with the current hardcoded gitops values. It represents the smallest functional Mojaloop switch deployment.

```yaml
# config/providers/proxmox/profiles/env/tps-1.yaml

# --- Infrastructure topology (was h2c1w3 in deployment-templates.yaml) ---
infra:
  instances:
    - name: c-0
      placement_group: placement-group-2
      cores: 6
      memory: 5120
      workload_class: control-plane
      storage:
        - storage_pool: local-lvm
          size: 32
          interface: scsi0
      tags: [ml, ml-master]

    - name: w-0
      placement_group: placement-group-2
      cores: 8
      memory: 10240
      workload_class: worker-general
      storage:
        - storage_pool: local-lvm
          size: 64
          interface: scsi0
        - storage_pool: local-lvm
          size: 64
          interface: scsi1
      tags: [ml, ml-worker]

    - name: w-1
      placement_group: placement-group-2
      cores: 8
      memory: 10240
      workload_class: worker-general
      storage:
        - storage_pool: local-lvm
          size: 64
          interface: scsi0
        - storage_pool: local-lvm
          size: 64
          interface: scsi1
      tags: [ml, ml-worker]

    - name: w-2
      placement_group: placement-group-1
      cores: 8
      memory: 10240
      workload_class: worker-general
      storage:
        - storage_pool: local-lvm
          size: 64
          interface: scsi0
        - storage_pool: local-lvm
          size: 64
          interface: scsi1
      tags: [ml, ml-worker]

# --- Application horizontal scaling (pod replicas) ---
# All set to 1 — matches current hardcoded defaults in gitops manifests
app:
  # Account Lookup Service
  als_service_replicas: 1
  als_admin_replicas: 1
  als_oracle_replicas: 1
  # Quoting Service
  qs_service_replicas: 1
  qs_handler_replicas: 1
  # Central Ledger
  cl_service_replicas: 1
  cl_handler_prepare_replicas: 1
  cl_handler_position_batch_replicas: 1
  cl_handler_fulfil_replicas: 1
  cl_handler_get_replicas: 1
  cl_handler_timeout_replicas: 1
  cl_handler_admin_replicas: 1
  # Central Settlement
  cs_service_replicas: 1
  cs_handler_deferred_replicas: 1
  cs_handler_rules_replicas: 1
  # Transaction Requests
  tx_requests_replicas: 1
  # ML API Adapter
  ml_adapter_service_replicas: 1
  ml_adapter_handler_notification_replicas: 1
  # External API
  extapi_envoy_replicas: 2
  # MCM
  mcm_replicas: 1
  # Auth
  keycloak_instances: 1
  kratos_replicas: 1
  keto_replicas: 1
  oathkeeper_replicas: 1

# --- Data layer tuning (replicas stay 3 for raft HA) ---
# Values match current hardcoded settings in gitops/env-data/
data:
  # Kafka — current defaults from Strimzi CR
  kafka_partition_prepare: 6
  kafka_partition_fulfil: 6
  kafka_partition_quotes_post: 6
  kafka_partition_quotes_put: 6
  kafka_partition_position_batch: 6
  kafka_partition_notification: 6
  kafka_partition_default: 6
  kafka_storage: "8Gi"
  # MySQL — current PXC CR values
  mysql_innodb_buffer_pool_size: "512M"
  mysql_max_connections: 2000
  mysql_innodb_flush_log_at_trx_commit: 1    # 1 = durable (production)
  mysql_storage: "8Gi"
  # MongoDB
  mongodb_storage: "3Gi"
```

#### CC Profile (operations-scale-driven)

```yaml
# config/providers/proxmox/profiles/cc/small.yaml

# --- Infrastructure topology ---
infra:
  instances:
    - name: m-0
      placement_group: placement-group-1
      cores: 8
      memory: 9216
      workload_class: mixed-plane
      storage:
        - storage_pool: local-lvm
          size: 64
          interface: scsi0
        - storage_pool: local-lvm
          size: 64
          interface: scsi1
      tags: [ml, ml-mixed]

# --- CC services scaling ---
cc:
  vault_replicas: 1
  harbor_registry_storage: "20Gi"
  harbor_db_storage: "2Gi"
  minio_storage: "20Gi"
  # Observability (sized for ingestion from N environments)
  loki_storage: "10Gi"
  mimir_storage: "10Gi"
  tempo_storage: "10Gi"
```

### Pipeline Flow

```
config/environments/<env>/config.yaml
  - reads: profile = "tps-1", role = "env", provider = "proxmox"
    |
    v
config-loader module
  - resolves: config/providers/proxmox/profiles/env/tps-1.yaml
  - extracts: infra.instances -> provisions infrastructure (same as today)
  - extracts: app.* + data.* -> passes to flux-config module
    |
    v
flux-config module
  - flattens app.* + data.* into cluster-config ConfigMap
    |
    v
Flux postBuild substitution
  - gitops/env-app/*.yaml uses ${cl_handler_prepare_replicas}, ${ml_adapter_service_replicas}
  - gitops/env-data/*.yaml uses ${kafka_partition_prepare}, ${mysql_innodb_buffer_pool_size}
  - gitops/env-auth/*.yaml uses ${keycloak_instances}, ${kratos_replicas}
```

For CC clusters, the flow is identical but resolves `profiles/cc/small.yaml` and populates `cc.*` vars instead of `app.*` + `data.*`. For base clusters, the profile only contains the `infra` section — no app/data/cc vars are injected.

### TPS Tier Reference Grid

The initial implementation includes three profiles based on real data: `tps-1` from the current running `ml-test` cluster, and `tps-500`/`tps-2000` from the `legacy/ml-perf` benchmarks. Future tiers (tps-10, tps-50, tps-200) will be added as they are validated through load testing.

| Parameter | **tps-1** (current ml-test) | **tps-500** (ml-perf) | **tps-2000** (ml-perf) |
|-----------|---------------------------|----------------------|----------------------|
| **Proxmox** | 1c+3w (6-8c/5-10G) | TBD (large VMs, 16c/64G) | TBD (very large, 32c/128G) |
| **AWS** | 3x m5.xlarge | 3x m7i.4xlarge + dedicated | 3x m7i.8xlarge + dedicated |
| MySQL buffer pool | 512M | 40G | 40G |
| MySQL flush_at_trx | 1 (durable) | 2 (fast) | 2 (fast) |
| MySQL max_connections | 2000 | 5000 | 2000 |
| Kafka partitions (hot topics) | 6 | 12 | 16 |
| Kafka partitions (notification) | 6 | 12 | 32 |
| ALS service | 1 | 16 | 24 |
| CL service | 1 | 8 | 8 |
| CL handler prepare | 1 | 12 | 16 |
| CL handler fulfil | 1 | 12 | 16 |
| CL handler position-batch | 1 | 8 | 8 |
| QS service + handler | 1 | 12 | 16 |
| ML API adapter | 1 | 12 | 16 |
| Notification handler | 1 | 18 | 32 |
| ALS oracle | 1 | 8 | 8 |
| ExtAPI Envoy | 2 | 2 | 4 |
| Keycloak | 1 | 1 | 2 |

**Note:** The ml-perf benchmarks used `innodb_flush_log_at_trx_commit=2` and `sync_binlog=0` for all tests. The `tps-500` and `tps-2000` profiles carry those same settings since they are directly derived from tested configurations. For intermediate TPS tiers to be added later, the durability/performance tradeoff should be a conscious decision validated via load testing.

### Full Inventory of Scalable Components

#### Data Layer (`gitops/env-data/`) -- Tuning, NOT replica scaling

| Component | Tuning Knobs | Current Value |
|-----------|-------------|---------------|
| **MySQL PXC** | `innodb_buffer_pool_size`, `max_connections`, `innodb_flush_log_at_trx_commit`, storage | 512M, 2000, implied 1, 8Gi |
| **Kafka** | per-topic partition counts, `replication.factor`, `min.insync.replicas`, storage | 6 default, 3, 2, 8Gi |
| **MongoDB** | storage | 3Gi |
| **Redis** | storage | 1Gi |

Replica counts are fixed at 3 (raft HA for PXC, Kafka, MongoDB) and 1 (Redis).

#### App Layer (`gitops/env-app/`) -- Replica scaling

| Component | Current Replicas |
|-----------|-----------------|
| centralledger-service | 1 (default) |
| cl-handler-transfer-prepare | 1 |
| cl-handler-transfer-position | 1 |
| cl-handler-transfer-position-batch | 1 |
| cl-handler-transfer-fulfil | 1 |
| cl-handler-transfer-get | 1 |
| cl-handler-timeout | 1 |
| cl-handler-admin-transfer | 1 |
| quoting-service | 1 |
| quoting-service-handler | 1 |
| centralsettlement-service | 1 |
| centralsettlement-handler-deferredsettlement | 1 |
| centralsettlement-handler-rules | 1 |
| account-lookup-service | 1 |
| account-lookup-service-admin | 1 |
| als-msisdn-oracle | 1 |
| transaction-requests-service | 1 |
| ml-api-adapter-service | 1 |
| ml-api-adapter-handler-notification | 1 |
| ExtAPI Envoy | 2 |
| MCM | 1 |
| Finance Portal (7 sub-services) | 1 each (not TPS-sensitive) |

#### Auth Layer (`gitops/env-auth/`) -- Replica scaling

| Component | Current Value |
|-----------|--------------|
| Keycloak instances | 1 |
| Kratos replicas | 1 (default) |
| Keto replicas | 1 (default) |
| Oathkeeper replicas | 1 (default) |
| Vault replicas | 3 (raft HA, fixed) |

#### CC Layer (`gitops/cc-config/`) -- Storage scaling

| Component | Current Value |
|-----------|--------------|
| Vault replicas | 1 (standalone) |
| Harbor registry storage | 20Gi |
| Harbor DB storage | 2Gi |
| MinIO storage | 20Gi |
| Loki/Mimir/Tempo storage | TBD (observability stack) |

#### Not TPS-Sensitive (excluded from profiles)

Platform services (Cilium, cert-manager, external-dns, ESO, metrics-server, VPA, Goldilocks), observability agents (Alloy, kube-state-metrics, node-exporter), OpenEBS. These scale with cluster size, not application throughput.

## Impact on Current Codebase

### Files That Change

#### 1. Config Layer

| File | Change |
|------|--------|
| `config/providers/proxmox/deployment-templates.yaml` | **Deleted** -- content moves into profiles |
| `config/providers/aws/deployment-templates.yaml` | **Deleted** -- content moves into profiles |
| `config/providers/digitalocean/deployment-templates.yaml` | **Deleted** -- content moves into profiles |
| `config/providers/{provider}/profiles/env/*.yaml` | **New** -- 5 TPS profile files per provider |
| `config/providers/{provider}/profiles/cc/*.yaml` | **New** -- 3 CC profile files per provider |
| `config/environments/*/config.yaml` | `template: "h2c1w3"` -> `profile: "tps-50"` |
| `config/.env.sample` | No change (secrets are orthogonal to profiles) |
| `config/definitions/workload-classes.yaml` | No change (workload classes are referenced by profiles) |

#### 2. Terraform Modules

| File | Change |
|------|--------|
| `src/modules/config-loader/main.tf` | **Modified** -- reads profile file instead of `deployment-templates.yaml`; extracts `app.*` and `data.*` sections alongside `infra.instances` |
| `src/modules/config-loader/variables.tf` | No change (profile path derived from provider + role + profile name) |
| `src/modules/config-loader/outputs.tf` | **Modified** -- adds `profile_app` and `profile_data` outputs |
| `src/main.tf` | **Modified** -- passes `profile_app` and `profile_data` to `flux_config` module |
| `src/modules/flux-config/variables.tf` | **Modified** -- adds `profile_vars` map variable |
| `src/modules/flux-config/main.tf` | **Modified** -- merges `profile_vars` into `cluster-config` ConfigMap |

#### 3. GitOps Manifests

| File | Change |
|------|--------|
| `gitops/env-app/mojaloop/helmrelease.yaml` | **Modified** -- adds `replicaCount` overrides using `${variable}` substitutions |
| `gitops/env-app/routes/extapi-envoy-deployment.yaml` | **Modified** -- `replicas: ${extapi_envoy_replicas}` |
| `gitops/env-data/kafka/kafka.yaml` | **Modified** -- per-topic partition counts via substitution |
| `gitops/env-data/mysql/mojaloop-db.yaml` | **Modified** -- `innodb_buffer_pool_size`, `max_connections` via substitution |
| `gitops/env-data/mongodb/bulk-mongodb.yaml` | **Modified** -- storage via substitution |
| `gitops/env-data/redis/redis.yaml` | **Modified** -- storage via substitution |
| `gitops/env-auth/keycloak/keycloak.yaml` | **Modified** -- `instances: ${keycloak_instances}` |
| `gitops/env-auth/ory/helmrelease-kratos.yaml` | **Modified** -- adds replicaCount |
| `gitops/env-auth/ory/helmrelease-keto.yaml` | **Modified** -- adds replicaCount |
| `gitops/env-auth/ory/helmrelease-oathkeeper.yaml` | **Modified** -- adds replicaCount |
| `gitops/cc-config/harbor/helmrelease.yaml` | **Modified** -- storage values via substitution |
| `gitops/cc-config/minio/helmrelease.yaml` | **Modified** -- storage via substitution |
| `gitops/cc-config/vault/vault.yaml` | **Modified** -- replicas via substitution |

#### 4. Documentation

| File | Change |
|------|--------|
| `CLAUDE.md` | **Modified** -- update Repository Structure, Configuration section, Key Design Decisions |
| `doc/adopter-guide.md` | **Modified** -- deployer instructions change from "pick a template" to "pick a TPS target" |
| `doc/platform-team-guide.md` | **Modified** -- platform team now maintains profile files |
| `doc/deployment-architecture.md` | **Modified** -- add TPS profiles to architecture docs |

### Files That Do NOT Change

- `src/modules/proxmox/` -- receives instances the same way (from config-loader output)
- `src/modules/aws/` -- receives node_groups the same way
- `src/modules/digitalocean/` -- receives node_pools the same way
- `src/modules/talos-gen-config/`, `talos-bootstrap/`, `proxmox-vm/` -- no change
- `src/modules/flux-bootstrap/` -- installs Flux controllers, unrelated to profiles
- `src/versions.tf`, `src/providers.tf`, `src/variables.tf` -- no change
- `gitops/platform/`, `gitops/platform-config/`, `gitops/dns/`, `gitops/talos/` -- platform services not TPS-sensitive
- `Makefile` -- `ENV=` selector unchanged; `make plan-apply ENV=env-prod` works the same way
- `config/definitions/workload-classes.yaml` -- Talos node classes unchanged, referenced by profiles

### Scope of config-loader Changes

Current `config-loader/main.tf` (lines 35-37):

```hcl
deployment_templates = yamldecode(file("../config/providers/${local.provider_name}/deployment-templates.yaml"))
deployment_template  = local.deployment_templates[local.config.template]
```

Changes to:

```hcl
# Load profile based on role + profile name
profile = yamldecode(file("../config/providers/${local.provider_name}/profiles/${local.config.cluster.role}/${local.config.profile}.yaml"))

# Infrastructure topology is now inside the profile
deployment_template = local.profile.infra
```

The rest of config-loader (instance processing, workload class resolution, Talos patches) works unchanged because it reads from `deployment_template.instances` regardless of where that data came from.

New outputs:

```hcl
output "profile_app" {
  description = "Application scaling variables from TPS profile"
  value       = try(local.profile.app, {})
}

output "profile_data" {
  description = "Data layer tuning variables from TPS profile"
  value       = try(local.profile.data, {})
}

output "profile_cc" {
  description = "CC services scaling variables from CC profile"
  value       = try(local.profile.cc, {})
}
```

### Scope of flux-config Changes

`flux-config/main.tf` ConfigMap section adds:

```hcl
resource "kubernetes_config_map_v1" "cluster_config" {
  data = merge(
    { ... existing vars ... },
    var.profile_vars,           # <-- all profile app/data/cc vars flattened
  )
}
```

`main.tf` passes them through:

```hcl
module "flux_config" {
  ...
  profile_vars = merge(
    module.config.profile_app,
    module.config.profile_data,
    module.config.profile_cc,
  )
}
```

## Migration: Live Clusters Are Safe

The three running clusters (ml-cc, ml-test, ml-dfsp) do **not** need to be destroyed before the change. The migration is designed to be a no-op on first apply:

### Why it's safe

1. **Infrastructure: zero changes.** The `tps-1` profile's `infra.instances` section is an exact copy of the current `h2c1w3` deployment template. Config-loader feeds the same instance list to the Proxmox module. `terraform plan` will show no VM changes. Same applies to `cc/small.yaml` (copy of `h1m1`) and `base/small.yaml` (copy of `h1m1-dfsp`).

2. **ConfigMap: additive only.** The `cluster-config` ConfigMap gains new keys (all the `app.*` / `data.*` / `cc.*` profile variables). Existing keys are unchanged. Kubernetes ConfigMap updates are non-destructive — Terraform will show `~ update in-place` for the ConfigMap, nothing else.

3. **GitOps manifests: substituted values match hardcoded values.** When gitops files change from `replicas: 3` to `replicas: ${mysql_replicas}`, Flux substitution fills in `3` (from the ConfigMap). The resulting manifest is byte-identical. No pod restarts, no reconciliation changes.

4. **Two-phase deployment is safe.** The Terraform changes (config-loader + flux-config) and gitops changes (substitution variables) ship independently:
   - **Phase 1: `make plan-apply`** — Updates ConfigMap with new keys. Gitops files still have hardcoded values. The new ConfigMap keys are unused but harmless.
   - **Phase 2: `make push-gitops`** — Pushes updated manifests with `${substitution_variables}`. Flux resolves them from the ConfigMap that was populated in Phase 1. Values match what was hardcoded — no visible change to the cluster.

### What to verify

After applying each phase, verify:

```bash
# After Phase 1 (Terraform): no infra changes, only ConfigMap update
make plan ENV=ml-test     # should show: 0 to add, 1 to change (ConfigMap), 0 to destroy
make plan ENV=ml-cc       # same pattern
make plan ENV=ml-dfsp     # same pattern

# After Phase 2 (GitOps push): Flux reconciles with no drift
kubectl get kustomizations -n flux-system   # all should show Ready
flux get kustomizations                      # no suspended or failed entries
```

### Rollback

If something goes wrong:
- **Terraform rollback:** Revert config-loader changes, `make plan-apply`. ConfigMap loses the new keys. Gitops manifests with hardcoded values still work (they don't reference the missing keys).
- **GitOps rollback:** Push the previous OCI artifact version. Flux reverts to hardcoded values.

The two phases are independently reversible because each is self-consistent.

## New Repo vs. Modify In Place

### Assessment: Modify in place

**Recommended approach: modify the current repository.**

Reasons:

1. **No breaking change to the deployment workflow.** `make plan-apply ENV=env-prod` still works. The only user-facing change is `template:` -> `profile:` in `config.yaml`.

2. **Small Terraform surface area.** The changes touch config-loader (profile loading) and flux-config (ConfigMap population). Both are additive -- new outputs, one new variable. No module signatures break.

3. **GitOps manifests are additive.** Replacing hardcoded values with `${substitution_variables}` is backward-compatible -- Flux substitution fills them in. If a variable is missing from the ConfigMap, Flux will error clearly (not silently break).

4. **Deployment templates are config files, not code.** Moving them from `deployment-templates.yaml` into `profiles/` is a file reorganization, not an architectural change.

5. **No dependency changes.** No new Terraform providers, no new Flux controllers, no new Kubernetes CRDs.

6. **Git history preserved.** All context for why things are the way they are today stays in the same repo.

A new repo would only make sense if:
- The profile system required a fundamentally different Terraform state structure (it doesn't)
- The gitops manifests needed a different OCI artifact structure (they don't)
- Multiple teams needed independent release cycles for profiles vs. infrastructure (profiles ship in the same OCI artifact)

### Migration Path

**Phase 1 — Terraform (no cluster impact):**

1. Create profile files that replicate current behavior:
   - `proxmox/profiles/env/tps-1.yaml` — from `h2c1w3` + current hardcoded gitops values
   - `proxmox/profiles/cc/small.yaml` — from `h1m1` + current CC service values
   - `proxmox/profiles/base/small.yaml` — from `h1m1-dfsp` (infra only)
2. Update config-loader to read profiles instead of `deployment-templates.yaml`
3. Wire profile vars through flux-config into `cluster-config` ConfigMap
4. Update environment configs: `template:` -> `profile:`
5. Validate: `make plan ENV=ml-test` / `ENV=ml-cc` / `ENV=ml-dfsp` — expect 0 infra changes, ConfigMap update only
6. Apply: `make apply` for each environment
7. Delete `deployment-templates.yaml` files

**Phase 2 — GitOps (no cluster impact if values match):**

8. Update gitops manifests to use `${substitution_variables}` in place of hardcoded values
9. Push: `make push-gitops` — Flux reconciles, substituted values match previous hardcoded values
10. Verify: `flux get kustomizations` — all Ready, no drift

**Phase 3 — New profiles (future):**

11. Add `tps-500.yaml` and `tps-2000.yaml` derived from `legacy/ml-perf` benchmarks
12. Add AWS/DigitalOcean profiles as those providers are used
13. Validate new profiles via load testing before publishing
