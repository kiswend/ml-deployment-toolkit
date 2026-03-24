# Observability Architecture

## Overview

Hub-and-spoke model: centralized backend on the Control Center (CC) cluster, lightweight collection agents on App Environment (env) clusters.

## Stack Components

| Signal | CC Backend | Env Agent | License | CNCF |
|--------|-----------|-----------|---------|------|
| **Metrics** | Thanos (Receive + Query + Store Gateway + Compactor) | Grafana Alloy (DaemonSet with clustering) | Apache 2.0 | Incubating |
| **Logs** | Loki (SingleBinary) | Grafana Alloy (DaemonSet) | AGPL 3.0 | — |
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
┌─────────────────────┐                   ┌─────────────────────────────┐
│ Alloy (DaemonSet)   │                   │ observability namespace      │
│ ├─ kubelet/cAdvisor  │   HTTPS           │                             │
│ ├─ node-exporter    │──remote_write────→│ Thanos Receive (:19291)     │
│ ├─ kube-state-metrics│                   │   ↓ writes TSDB blocks      │
│ └─ service scraping │                   │ MinIO S3 (thanos bucket)    │
└─────────────────────┘                   │   ↑ reads blocks             │
                                          │ Thanos Store Gateway        │
                                          │   ↑                         │
                                          │ Thanos Query (:9090) ←─ Grafana
                                          │ Thanos Compactor (background)│
                                          └─────────────────────────────┘
```

### Env Agents (Alloy)

Alloy runs as a DaemonSet with **clustering enabled** — pods shard scrape targets via gossip protocol to avoid duplicate metrics.

Scrape targets:
- **kubelet** `/metrics` — kubelet own metrics (HTTPS, bearer token auth)
- **cAdvisor** `/metrics/cadvisor` — container CPU/memory/network/disk
- **node-exporter** port 9100 — host-level metrics (requires `privileged` PSA on namespace)
- **kube-state-metrics** — Kubernetes object metrics (pods, deployments, nodes, PVCs)
- **Services** with `prometheus.io/scrape=true` annotation

### S3 Storage Layout

| Bucket | Used by | Content |
|--------|---------|---------|
| `thanos` | Thanos Receive + Store Gateway + Compactor | TSDB metric blocks |
| `loki` | Loki | Log chunks and indexes |
| `tempo` | Tempo | Trace data |

All buckets in MinIO (`minio.minio:9000`), credentials from Vault via ExternalSecrets.

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

## Retention

All signals: **7 days (168h)**
- Thanos: compactor `--retention.resolution-raw=168h`, downsampling disabled
- Loki: `limits_config.retention_period: 168h`
- Tempo: `retention: 168h`
