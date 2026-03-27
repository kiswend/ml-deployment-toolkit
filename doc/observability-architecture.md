# Observability Architecture

## Overview

Hub-and-spoke model: centralized backend on the Control Center (CC) cluster, lightweight collection agents on App Environment (env) clusters.

## Stack Components

| Signal | CC Backend | Env Agent | License | CNCF |
|--------|-----------|-----------|---------|------|
| **Metrics** | Thanos (Receive + Query + Store Gateway + Compactor) | Grafana Alloy (Deployment, single instance) | Apache 2.0 | Incubating |
| **Logs** | Loki (SingleBinary) | Grafana Alloy (Deployment, single instance) | AGPL 3.0 | — |
| **Traces** | Tempo (SingleBinary) | (Phase 3 — not yet active) | AGPL 3.0 | — |
| **Dashboards** | Grafana | — | AGPL 3.0 | — |

All backends store data in MinIO S3 buckets on the CC cluster. Credentials are managed via ExternalSecrets from Vault.

## Why Thanos for Metrics

### Decision Rationale

We evaluated multiple Prometheus-compatible metrics backends:

| Option | License | S3 Model | Pods | Memory | Status |
|--------|---------|----------|------|--------|--------|
| **Mimir** | AGPL 3.0 | Primary | 7+ | ~3Gi | Rejected — AGPL license, heavy resource footprint |
| **Thanos** | Apache 2.0 | Primary | 4 | ~1.3Gi | **Selected** |
| **VictoriaMetrics** | Apache 2.0 | Backup only | 1 | ~512Mi | Rejected — no native S3 primary storage |
| **Cortex** | Apache 2.0 | Primary | 1-6 | ~1-2Gi | Rejected — maintenance mode since Mimir fork |
| **Prometheus** | Apache 2.0 | Backup only | 1 | ~512Mi | Rejected — no native S3 primary storage |

**Key factors:**

1. **License**: Mojaloop is open-source infrastructure deployed by adopters. AGPL (Mimir) could create licensing friction for adopters providing hosted services. Thanos is Apache 2.0 — fully permissive.

2. **S3 as primary storage**: Metrics data is written directly to S3 (MinIO), not just local disk. Historical data is queryable live from S3 via the Store Gateway. This provides durability beyond the pod's PV lifecycle.

3. **Resource efficiency**: 4 pods at ~1.3Gi total vs Mimir's 7+ pods at ~3Gi. Each Thanos component has a clear, single responsibility.

4. **CNCF status**: Thanos is CNCF Incubating — governed by the CNCF, not a single company.

5. **Push-based architecture**: Thanos Receive accepts standard Prometheus `remote_write` — identical to what Alloy already uses. No architecture change needed.

### Why Not the Others

- **Mimir**: Best Helm chart and features, but AGPL 3.0 license is problematic for an open-source project. Also resource-heavy for small deployments.
- **VictoriaMetrics**: Lightest and most performant, but S3 is only for backups (not primary storage). Backups are proprietary format ("dead backups" — must restore to query).
- **Cortex**: Same codebase as Mimir (pre-fork), Apache 2.0, but Grafana moved development to Mimir. Effectively maintenance-mode.
- **Prometheus standalone**: No native S3 long-term storage. Would need Thanos anyway for S3.

## Deployment Model

### Thanos (kube-thanos Jsonnet)

Thanos has no official Helm chart. The official distribution is **kube-thanos** — a Jsonnet library maintained by the Thanos team. We render Jsonnet to YAML manifests and commit them to the gitops directory.

```
rendering/thanos/                         # Jsonnet source
  jsonnetfile.json                        # kube-thanos dependency
  thanos.jsonnet                          # Component configuration
    ↓ make render-thanos
gitops/cc-observability/thanos/           # Rendered YAML (committed)
  thanos-receive-statefulSet.yaml
  thanos-query-deployment.yaml
  thanos-store-statefulSet.yaml
  thanos-compact-statefulSet.yaml
  externalsecret.yaml                     # S3 credentials from Vault
  kustomization.yaml
    ↓ FluxCD Kustomization (raw manifests, no HelmRelease)
Kubernetes (observability namespace)
```

**Upgrading Thanos:**
1. Update kube-thanos version in `rendering/thanos/jsonnetfile.json`
2. Run `make render-thanos`
3. Review diff, commit, `make push-gitops`

### Data Flow

```
App Environment (ml-test)                 Control Center (ml-cc)
┌──────────────────────────┐              ┌─────────────────────────────┐
│ Alloy (Deployment x1)   │              │ observability namespace      │
│ ├─ Pod discovery:        │  HTTPS       │                             │
│ │  ├─ Mojaloop apps (20) │──remote────→│ Thanos Receive (:19291)     │
│ │  └─ Finance Portal     │  write       │   ↓ writes TSDB blocks      │
│ ├─ Endpoint discovery:   │              │ MinIO S3 (thanos bucket)    │
│ │  ├─ Kafka JMX (3)     │              │   ↑ reads blocks             │
│ │  ├─ Kafka Exporter (1) │              │ Thanos Store Gateway        │
│ │  ├─ MySQL exporter (3) │              │   ↑                         │
│ │  ├─ MongoDB exporter(3)│              │ Thanos Query (:9090) ←─ Grafana
│ │  ├─ Redis exporter (1) │              │ Thanos Compactor (background)│
│ │  └─ kube-state-metrics │              │                             │
│ ├─ Node discovery:       │              │ Loki ← logs                 │
│ │  ├─ kubelet (5)        │              │ Tempo ← traces (Phase 3)    │
│ │  ├─ cAdvisor (5)       │              │ Grafana ← dashboards        │
│ │  └─ node-exporter (5)  │              └─────────────────────────────┘
│ └─ Log collection:       │
│    └─ All pod logs ──────│──push──────→ Loki
└──────────────────────────┘
```

## Metrics Collection

### Scraping Architecture

Alloy uses **two discovery mechanisms** to avoid duplication while covering all targets:

| Discovery | Targets | Labels | Use case |
|-----------|---------|--------|----------|
| **Pod discovery** | Pods with `prometheus.io/scrape=true` annotation | `pod`, `service`, `namespace` | Mojaloop app services, Finance Portal |
| **Endpoint discovery** | Individual pod endpoints behind services with `prometheus.io/scrape=true` | `pod`, `service`, `namespace`, unique `instance` per pod | Data layer exporters (Kafka, MySQL, MongoDB, Redis), kube-state-metrics |

Pod discovery scrapes each pod directly. Endpoint discovery resolves headless services to individual pod IPs, giving per-instance granularity for clustered data services.

**Single instance**: Alloy runs as a single-replica Deployment (not DaemonSet). All scrape targets and log collection are handled by one pod. Log collection uses `loki.source.kubernetes` (Kubernetes API-based, not filesystem-based), so it works from any node without requiring a per-node DaemonSet.

### Infrastructure Metrics

| Source | Method | Port | Metrics |
|--------|--------|------|---------|
| **kubelet** | Node discovery, HTTPS + bearer token | 10250 | Kubelet internals |
| **cAdvisor** | Node discovery, HTTPS + bearer token | 10250 `/metrics/cadvisor` | Container CPU, memory, network, disk |
| **node-exporter** | Node discovery, DaemonSet | 9100 | Host CPU, RAM, disk, network |
| **kube-state-metrics** | Endpoint discovery | 8080 | K8s object state (pods, deployments, PVCs, nodes) |

### Data Layer Metrics

| Service | Exporter | Method | Port | Key metrics |
|---------|----------|--------|------|-------------|
| **Kafka (brokers)** | JMX Prometheus Exporter (Strimzi built-in) | Endpoint discovery via `mojaloop-kafka-metrics` service | 9404 | Request rate, connections, under-replicated partitions, ISR, leader count |
| **Kafka (consumers)** | Kafka Exporter (`spec.kafkaExporter` in Kafka CR) | Endpoint discovery via `mojaloop-kafka-exporter-metrics` service | 9404 | Consumer group lag, topic offsets, partition count |
| **MySQL (PXC)** | mysqld-exporter v0.16 sidecar | Endpoint discovery via `mojaloop-db-metrics` service | 9104 | Connections, queries/sec, InnoDB, replication, wsrep status |
| **MongoDB (PSMDB)** | mongodb_exporter v0.43 sidecar | Endpoint discovery via `bulk-mongodb-metrics` service | 9216 | Connections, operations/sec, replication lag, oplog window |
| **Redis** | redis-exporter v1.44 (operator-managed) | Endpoint discovery via `ttk-redis-metrics` service | 9121 | Connected clients, memory, commands/sec |

All data layer exporters provide **per-pod instance labels** for drill-down (e.g., `pod="mojaloop-db-pxc-0"`, `instance="10.244.0.181:9104"`).

### Mojaloop App Metrics

Mojaloop Node.js services natively expose Prometheus metrics on their HTTP port via `/metrics`. Controlled by `metrics.enabled: true` in Helm values.

| Metric prefix | Services |
|--------------|----------|
| `moja_ml_*` | ml-api-adapter-service, ml-api-adapter-handler-notification |
| `moja_*` | All other services: centralledger handlers, quoting-service, account-lookup-service, etc. |

Note: Legacy docs reference service-specific prefixes (`moja_cl_*`, `moja_qs_*`, `moja_als_*`, `moja_cs_*`) — these no longer exist. Current Mojaloop versions use a flat `moja_` prefix. Only `moja_ml_*` retains a service-specific prefix. See `doc/grafana-dashboards.md` for the full metric mapping.

Scraped via Alloy **pod discovery** — each pod with `prometheus.io/scrape=true` is scraped individually.

### JMX Exporter Configuration

Kafka JMX metrics are configured via a ConfigMap (`kafka-metrics`) with JMX exporter rules. The ConfigMap is referenced in the Kafka CR's `spec.kafka.metricsConfig`. Key metric categories:
- Broker topic metrics (bytes in/out, messages/sec)
- Replica manager (under-replicated partitions, ISR)
- Controller (active controller, offline partitions)
- Log size per topic/partition
- Consumer lag per topic

## S3 Storage Layout

| Bucket | Used by | Content |
|--------|---------|---------|
| `thanos` | Thanos Receive + Store Gateway + Compactor | TSDB metric blocks |
| `loki` | Loki | Log chunks and indexes |
| `tempo` | Tempo | Trace data |

All buckets in MinIO (`minio.minio:9000`), credentials from Vault via ExternalSecrets.

Thanos Receive writes TSDB blocks to S3 every ~2 hours (Prometheus TSDB block cycle). Until a block is completed, data is in Receive's local WAL. Thanos Query merges real-time data (from Receive) with historical data (from Store Gateway/S3) transparently.

## Configuration

### CC Cluster (observability backend)
No per-environment config needed — S3 endpoint and bucket names are hardcoded in manifests (same MinIO on every CC).

### Env Cluster (collection agents)
```yaml
# config/environments/<env>/config.yaml
observability:
  loki_url: "https://loki.int.<cc-domain>/loki/api/v1/push"
  mimir_url: "https://thanos.int.<cc-domain>/api/v1/receive"  # still named mimir_url for compatibility
```

These are injected into Alloy via Flux postBuild substitution from the `cluster-config` ConfigMap.

### HTTPRoute (path-based routing)

A single HTTPRoute on `thanos.int.${domain}` handles both write and read traffic:
- `/api/v1/receive` → Thanos Receive (:19291) — Alloy remote_write
- Everything else → Thanos Query (:9090) — Grafana queries

## Retention

All signals: **7 days (168h)**
- Thanos: compactor `--retention.resolution-raw=168h`, downsampling disabled
- Loki: `limits_config.retention_period: 168h`
- Tempo: `retention: 168h`

## Rendering Framework

Components that need pre-rendering (Jsonnet → YAML) live in `rendering/` at the repo root. Rendered output is committed to `gitops/` and deployed by FluxCD.

```bash
make render          # render all components
make render-thanos   # render Thanos manifests only
```

The `rendering/*/vendor/` directories (Jsonnet dependencies) are git-ignored — downloaded by `jb install` during rendering.

## Known Constraints

- **CC node memory**: The single-node CC cluster (7GB RAM) is tight with the full observability stack. Thanos Receive is the largest consumer during write bursts and WAL replay. Consider increasing VM RAM for production CC deployments.
- **Thanos block shipping**: TSDB blocks are shipped to S3 every ~2 hours. Data loss window on Receive pod crash is up to 2 hours of metrics (mitigated by WAL replay on restart).
- **No CC self-monitoring**: The CC cluster does not scrape its own metrics (Thanos, Loki, Tempo, Grafana, Vault, Harbor, MinIO). Future work.
- **No alerting**: No alert rules configured. Future work via Thanos Ruler or external alerting.
- **16 Grafana dashboards** provisioned via ConfigMap sidecar across 3 folders:
  - **Infrastructure** (8): Kubernetes Cluster, Node Overview, Pod Resources, CoreDNS, Cilium Network, Kube API Server, Kubelet, Persistent Volumes, Namespace Resources
  - **Data Layer** (4): MySQL Overview, PXC/Galera Cluster, Kafka Overview, Redis Overview
  - **Mojaloop** (4): Transfer Pipeline, Account Lookup Service, Quoting Service, Node.js Runtime
  - See `doc/grafana-dashboards.md` for details.
