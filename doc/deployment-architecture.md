# Deployment Architecture

## Overview

This document describes the deployment architecture for Mojaloop infrastructure using OCI-based distribution (no Git in clusters).

## Deployment Flow

```
┌─────────────────────┐     ┌─────────────────────┐     ┌─────────────────────┐     ┌─────────────────────┐
│  1. App Dev Team    │────▶│ 2. Platform Team    │────▶│ 3. Control Center   │────▶│ 4. App Environment  │
│    (Creators)       │     │   (Orchestrators)   │     │  (Management Plane) │     │    (Workloads)      │
└─────────────────────┘     └─────────────────────┘     └─────────────────────┘     └─────────────────────┘
```

### Stage 1: App Development Team

**Artifacts produced:**
- OCI-compliant container images
- Helm charts with generic Kubernetes manifests (clean YAML for portability)

**Distribution:** Publish to public OCI registry (ghcr.io/mojaloop/)

### Stage 2: Platform Team

**Bundle creation:** Two deliverables:
- **IaC bundle** — Terraform modules for infrastructure provisioning (this repo, applied directly)
- **GitOps artifact** — OCI artifact containing Flux Kustomization manifests for platform services

**Platform Services (shared — all providers):**

| Component | Tool | Purpose |
|-----------|------|---------|
| Metrics | metrics-server | Kubelet metrics aggregation |
| DNS | external-dns | Bridge K8s services to provider DNS (Route53, Cloudflare, DigitalOcean, PowerDNS) |
| Certificates | cert-manager + Let's Encrypt | TLS automation, ACME issuers |
| Ingress | Gateway API | Kubernetes-native ingress (replaces deprecated Ingress resource) |
| Secrets | External Secrets Operator (ESO) | Vault/external secret store integration |
| Partner Edge | Envoy | External mTLS with dynamic partner onboarding (xDS/SDS) |

**On-prem only services (Talos/Proxmox):**

| Component | Tool | Purpose | Cloud equivalent |
|-----------|------|---------|-----------------|
| CNI | Cilium | Networking, network policies, internal mTLS | Managed CNI |
| Load balancing | Cilium LB-IPAM | L2 announcement + IP pool allocation | Cloud load balancers |
| Storage | OpenEBS (hostpath) | Local persistent volumes | Cloud CSI (EBS, DO Block Storage) |
| Object storage | MinIO | S3-compatible storage for state/backups | Managed S3/Spaces |

On managed Kubernetes (EKS, DOKS), these capabilities are provided natively by the cloud provider — no Flux manifests needed.

### DNS Configuration Strategy

The platform must support multiple DNS providers (e.g., AWS Route53, Cloudflare, DigitalOcean) with different authentication requirements. To maintain a clean separation between Infrastructure as Code (IaC) and GitOps:

1.  **Configuration Source:** DNS provider settings and credentials are defined in the IaC configuration (`config.yaml`).
2.  **IaC Responsibility:** Terraform reads this configuration and generates a provider-specific `values.yaml` blob. This blob contains the exact nested structure required by the `external-dns` Helm chart for that specific provider.
3.  **Secret Injection:** Terraform injects this blob into a Kubernetes Secret (e.g., `cluster-config`) in the GitOps controller's namespace.
4.  **GitOps Consumption:** The FluxCD `HelmRelease` for `external-dns` references this secret using `valuesFrom`. This allows the GitOps manifest to remain generic while the specific configuration is supplied dynamically by the infrastructure layer.

**Distribution:** Publish validated OCI artifact to registry (GHCR, Harbor, ECR)

### GitOps Artifact Structure

A single OCI artifact contains four Kustomize roots. Flux deploys a subset based on the cluster's provider and role:

```
gitops/
  platform/     # Always deployed — provider-agnostic services
  onprem/       # Conditionally deployed — on-prem only (Talos/Proxmox)
  cc/           # Control Center services
  env/          # App Environment services
```

**Deployment matrix:**

| Cluster | Provider | Kustomizations | Dependency chain |
|---------|----------|---------------|-----------------|
| CC | Proxmox | platform → onprem → cc | cc waits for onprem (needs storage, LB-IPAM) |
| CC | DOKS/EKS | platform → cc | cc waits for platform |
| Env | Proxmox | platform → onprem → env | env waits for onprem |
| Env | DOKS/EKS | platform → env | env waits for platform |

Version coherence is guaranteed — all four directories ship in one artifact. A single OCI tag (e.g. `v1.0.0` or `latest`) covers the entire stack.

### Cilium: Two-Phase Deployment (On-prem)

Cilium is the CNI for on-prem clusters. It presents a bootstrap challenge: Cilium must be running before any pods can schedule (including Flux), but Cilium is distributed only as a Helm chart, and Talos cannot run Helm during provisioning.

**Phase 1 — Talos extraManifests (bootstrap):**
A pre-rendered Cilium manifest is hosted on private storage and referenced in the Talos machine config patch (`patch-cilium-install.yaml`). Talos downloads and applies it as a static manifest during node bootstrap, ensuring CNI is available before the kubelet starts scheduling pods.

**Phase 2 — Flux HelmRelease (steady-state):**
Once the cluster is running and Flux is reconciling, a Cilium HelmRelease in `gitops/onprem/` takes over management. Flux adopts the existing Cilium installation, enabling version upgrades, configuration changes, and Helm values management through GitOps.

The `onprem/` kustomization also deploys Cilium configuration CRDs (L2AnnouncementPolicy, CiliumLoadBalancerIPPool) that configure LB-IPAM — the on-prem equivalent of cloud load balancers.

On managed Kubernetes, the cloud provider supplies the CNI natively — neither phase applies.

### Stage 3: Adopter Control Center

**Bootstrap process:**
1. Pull OCI bundle via CLI
2. Configure `config/.env` with provider credentials
3. Configure `config/config.yaml` with infrastructure settings
4. Run `terraform apply`

**Control Center hosts:**

| Service | Purpose | Provider |
|---------|---------|----------|
| Harbor | Local OCI registry — source of truth and cache | All |
| Vault | Secrets management, internal CA, partner keys | All |
| MinIO | Infrastructure state and backup storage | On-prem only |
| FluxCD | GitOps reconciliation (OCI-based, not Git) | All |
| tf-controller | Terraform automation for downstream environments | All |

On cloud, MinIO is replaced by managed object storage (S3, DigitalOcean Spaces).

### Stage 4: Adopter App Environment

**Creation flow:**
1. Push environment config to CC Harbor
2. CC FluxCD detects change
3. tf-controller provisions the App Environment
4. App Environment pulls artifacts from CC Harbor

**Customization:** Provider differences are handled by conditional Kustomization paths:
- On-prem: `onprem/` kustomization deploys Cilium LB-IPAM, OpenEBS storage, MinIO
- Cloud: managed CNI, cloud LB, cloud CSI, managed S3 — no additional manifests needed

**Partner connectivity:**
- Internal traffic: Cilium with network policies
- External partners: Envoy gateway with dynamic mTLS (see below)

**Sovereignty:** All images and configs served from CC Harbor - App Env operates even if public internet is unreachable.

---

## Partner Edge: Cilium + Envoy

Cilium handles internal service mesh but does not support mTLS to external partners. We use Envoy for the partner edge.

**Architecture:**
```
┌──────────────────────────────────────────────────────────────┐
│                      App Environment                          │
│                                                               │
│  ┌─────────────┐      ┌─────────────┐      ┌──────────────┐  │
│  │  Mojaloop   │◀────▶│   Cilium    │◀────▶│    Envoy     │◀─┼──▶ Partner DFSPs
│  │  Services   │      │  (internal) │      │ (partner edge)│  │
│  └─────────────┘      └─────────────┘      └──────────────┘  │
│                                                   ▲           │
│                                                   │           │
│                                            ┌──────┴──────┐   │
│                                            │ xDS Control │   │
│                                            │   Plane     │   │
│                                            └─────────────┘   │
└──────────────────────────────────────────────────────────────┘
```

**Why Envoy for partner edge:**
- Partners are onboarded dynamically
- Each partner has their own CA and TLS requirements
- Cannot restart gateway to add a partner

**Envoy xDS discovery services:**
- **LDS** (Listener): Dynamic ports/listeners
- **RDS** (Route): Dynamic routing tables
- **CDS** (Cluster): Dynamic backend services
- **SDS** (Secret): Hot-swap certificates and partner CAs without connection drops

**Implementation options:**
1. Standalone Envoy with custom xDS control plane
2. Envoy Gateway (Kubernetes-native)
3. CiliumEnvoyConfig (Cilium-managed Envoy sidecar)

---

## Security Model

### Vault Chain of Trust

```
┌─────────────────────────────────────┐
│         Control Center              │
│  ┌─────────────────────────────┐   │
│  │       Root Vault            │   │
│  │  - Provider credentials     │   │
│  │  - Unseal keys for leafs    │   │
│  │  - Internal root CA         │   │
│  └──────────────┬──────────────┘   │
└─────────────────┼───────────────────┘
                  │ transit auto-unseal
      ┌───────────┼───────────┐
      ▼           ▼           ▼
┌──────────┐ ┌──────────┐ ┌──────────┐
│ Dev Vault│ │Test Vault│ │Prod Vault│
│ - DB creds│ │ - DB creds│ │ - DB creds│
│ - Partner │ │ - Partner │ │ - Partner │
│   certs   │ │   certs   │ │   certs   │
└──────────┘ └──────────┘ └──────────┘
```

- Root Vault (CC) holds provider credentials and unseal keys
- Leaf Vaults (App Envs) hold runtime secrets only
- Compromising Dev does not compromise Root or Prod

### Recovery Kit

Bootstrap produces `recovery-kit/` containing:
- Vault root token and unseal keys
- Harbor admin password
- Kubeconfig for CC cluster
- Talosconfig for node access

**Store offline** (physical safe, air-gapped storage). Required for disaster recovery.

---

## Disaster Recovery

### Backup Strategy

| Component | Location | Criticality |
|-----------|----------|-------------|
| Recovery Kit | Offline physical safe | Critical |
| CC Terraform state | Offline or CC MinIO | High |
| App Env state | CC MinIO | High |
| Vault data | CC MinIO + external replica | High |

### Recovery: Total Loss of Control Center

1. Retrieve recovery kit and terraform state from offline storage
2. Provision new infrastructure
3. Run `terraform apply` with saved state
4. Restore MinIO buckets from external backup
5. Unseal Vault with recovery kit keys
6. FluxCD reconciles and reconnects to existing App Environments
