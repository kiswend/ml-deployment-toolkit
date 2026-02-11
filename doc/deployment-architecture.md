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
| Certificates | cert-manager + Let's Encrypt | TLS automation, ACME DNS-01 issuers (DigitalOcean DNS validation) |
| Ingress | Gateway API | Kubernetes-native ingress (replaces deprecated Ingress resource) |
| Secrets | External Secrets Operator (ESO) | Vault/external secret store integration |
| Partner Edge | Envoy | External mTLS with dynamic partner onboarding (xDS/SDS) |

**On-prem only services (Talos/Proxmox):**

| Component | Tool | Purpose | Cloud equivalent |
|-----------|------|---------|-----------------|
| CNI + Gateway | Cilium HelmRelease (`gatewayAPI.enabled`) | Networking, policies, mTLS, Gateway API controller + GatewayClass | Cilium (managed by cloud provider, GatewayClass pre-created) |
| Load balancing | Cilium LB-IPAM | L2 announcement + IP pool allocation | Cloud load balancers |
| Storage | OpenEBS (hostpath) | Local persistent volumes | Cloud CSI (EBS, DO Block Storage) |
| Object storage | MinIO | S3-compatible storage for state/backups | Managed S3/Spaces |

On managed Kubernetes (EKS, DOKS), Cilium is provided as a managed CNI (default on DOKS, optional on EKS) with Gateway API support. Storage, load balancing, and object storage are cloud-native — no Flux manifests needed for those.

### DNS Configuration Strategy

The platform must support multiple DNS providers (e.g., AWS Route53, Cloudflare, DigitalOcean) with different authentication requirements. To maintain a clean separation between Infrastructure as Code (IaC) and GitOps:

1.  **Configuration Source:** DNS provider settings and credentials are defined in the IaC configuration (`config.yaml`).
2.  **IaC Responsibility:** Terraform reads this configuration and generates a provider-specific `values.yaml` blob. This blob contains the exact nested structure required by the `external-dns` Helm chart for that specific provider.
3.  **Secret Injection:** Terraform injects this blob into a Kubernetes Secret (e.g., `cluster-config`) in the GitOps controller's namespace.
4.  **GitOps Consumption:** The FluxCD `HelmRelease` for `external-dns` references this secret using `valuesFrom`. This allows the GitOps manifest to remain generic while the specific configuration is supplied dynamically by the infrastructure layer.

**Distribution:** Publish validated OCI artifact to registry (GHCR, Harbor, ECR)

### GitOps Artifact Structure

A single OCI artifact contains seven Kustomize roots. Flux deploys a subset based on the cluster's provider and role:

```
gitops/
  platform/        # Always deployed — shared services (cert-manager, external-dns, ESO, metrics-server)
  platform-config/ # Always deployed — shared config (ClusterIssuers, DNS-01 secret, Gateway with wildcard TLS)
  onprem/          # Conditionally deployed — on-prem only (Cilium HelmRelease with gatewayAPI.enabled, LB-IPAM, OpenEBS)
  cc/              # Control Center operators (vault-operator) + namespace definitions (vault, harbor, minio)
  cc-config/       # Control Center services (Vault CR, Harbor + proxy cache setup, MinIO — each in own namespace)
  cc-routes/       # Control Center HTTPRoutes (vault, harbor, minio — deployed after cc-config services are healthy)
  env/             # App Environment services (Mojaloop app)
```

Note: GatewayClass is not in the artifact. It is auto-created by Cilium — either by the on-prem HelmRelease (`gatewayAPI.enabled: true`) or by the cloud-managed Cilium installation.

**Deployment matrix:**

| Cluster | Provider | Kustomizations | Dependency chain |
|---------|----------|---------------|-----------------|
| CC | Proxmox | platform → platform-config → onprem → cc → cc-config → cc-routes | cc-routes waits for cc-config health checks (services running) |
| CC | DOKS/EKS | platform → platform-config → cc → cc-config → cc-routes | cc-routes waits for cc-config health checks (services running) |
| Env | Proxmox | platform → platform-config → onprem → env | env waits for onprem |
| Env | DOKS/EKS | platform → platform-config → env | env waits for platform |

Version coherence is guaranteed — all seven directories ship in one artifact. A single OCI tag (e.g. `v1.0.0` or `latest`) covers the entire stack.

### Cilium: Two-Phase Deployment (On-prem)

Cilium is the CNI for on-prem clusters. It presents a bootstrap challenge: Cilium must be running before any pods can schedule (including Flux), but Cilium is distributed only as a Helm chart, and Talos cannot run Helm during provisioning.

**Phase 1 — Talos extraManifests (bootstrap):**
A pre-rendered Cilium manifest is hosted on private storage and referenced in the Talos machine config patch (`patch-cilium-install.yaml`). Talos downloads and applies it as a static manifest during node bootstrap, ensuring CNI is available before the kubelet starts scheduling pods.

**Phase 2 — Flux HelmRelease (steady-state):**
Once the cluster is running and Flux is reconciling, a Cilium HelmRelease in `gitops/onprem/` takes over management. Flux adopts the existing Cilium installation, enabling version upgrades, configuration changes, and Helm values management through GitOps.

The `onprem/` kustomization also deploys Cilium configuration CRDs (L2AnnouncementPolicy, CiliumLoadBalancerIPPool) that configure LB-IPAM — the on-prem equivalent of cloud load balancers. The Cilium HelmRelease includes `gatewayAPI.enabled: true`, which auto-creates the GatewayClass (`cilium`).

On managed Kubernetes, the cloud provider supplies Cilium as a managed CNI (default on DOKS, optional on EKS) — neither bootstrap phase applies. The GatewayClass is pre-created by the cloud provider (DOKS, GKE) or auto-created by a self-installed Cilium (EKS BYOCNI).

### Cilium and GatewayClass: Provider Model

Cilium is the CNI on all providers. The GatewayClass is never deployed by the gitops artifact — it is always a byproduct of the Cilium installation:

| Provider | Cilium installation | GatewayClass | Gateway API CRDs |
|----------|--------------------|--------------|--------------------|
| Proxmox | Self-managed: Talos extraManifests (bootstrap) → Flux HelmRelease (steady-state) | Auto-created by Cilium Helm (`gatewayAPI.enabled`) | Installed via Talos extraManifests |
| DigitalOcean DOKS | Managed (default CNI) | Pre-created by DigitalOcean (VPC-native + K8s 1.33+) | Pre-installed |
| AWS EKS | Self-installed (BYOCNI or CNI chaining) — future `eks/` kustomization | Auto-created by Cilium Helm (`gatewayAPI.enabled`) | Installed before Cilium |
| GCP GKE | Managed (Dataplane V2 = Cilium) | Auto-created by GKE | Pre-installed |

The shared Gateway in `platform-config/` references `gatewayClassName: cilium` which exists on all providers regardless of who created it.

### Stage 3: Adopter Control Center

**Bootstrap process:**
1. Pull OCI bundle via CLI
2. Configure `config/environments/<env>/.env` with provider credentials
3. Configure `config/environments/<env>/config.yaml` with infrastructure settings
4. Run `make plan-apply ENV=<env>`

**Control Center hosts:**

| Service | Purpose | Provider |
|---------|---------|----------|
| Harbor | Local OCI registry — source of truth + pull-through cache for docker.io, ghcr.io, quay.io, registry.k8s.io | All |
| Vault | Secrets management, internal CA, partner keys | All |
| MinIO | Infrastructure state and backup storage | On-prem only |
| FluxCD | GitOps reconciliation (OCI-based, not Git) | All |

On cloud, MinIO is replaced by managed object storage (S3, DigitalOcean Spaces).

**CC Service Ingress (Gateway API):**

CC services are exposed via a shared Gateway in `platform-system` namespace with a wildcard TLS listener (`*.${domain}`). The Gateway receives a LoadBalancer IP from LB-IPAM (on-prem) or cloud LB. Each service has its own HTTPRoute in its dedicated namespace:

| Hostname | HTTPRoute namespace | Backend | Port |
|----------|-------------------|---------|------|
| `vault.${domain}` | vault | vault | 8200 |
| `harbor.${domain}` | harbor | harbor | 80 |
| `minio.${domain}` | minio | minio-console | 9001 |

HTTPRoutes reference the Gateway cross-namespace via `parentRefs.namespace: platform-system`. Backend services are in the same namespace as the HTTPRoute — no ReferenceGrant needed.

A single wildcard TLS certificate (`*.${domain}`) is auto-provisioned by cert-manager using DNS-01 challenges (DigitalOcean DNS TXT validation). DNS-01 is required for on-prem because Let's Encrypt cannot reach private IPs for HTTP-01 challenges. external-dns watches `gateway-httproute` sources and creates DNS A records pointing each hostname to the Gateway's LB IP.

**Namespace isolation:** Vault, Harbor, and MinIO each run in their own namespace (`vault`, `harbor`, `minio`) for least-privilege security. The vault-operator remains in `cc-system`. This prevents a compromised Harbor pod from accessing Vault's ServiceAccount tokens and Secrets.

**Harbor proxy cache:** A setup Job (in `cc-config/harbor/`) configures Harbor as a pull-through cache for upstream OCI registries. App Environments pull all container images through Harbor instead of hitting public registries directly:

| Upstream registry | Harbor proxy project | Pull path |
|-------------------|---------------------|-----------|
| docker.io | `docker-hub` | `harbor.${domain}/docker-hub/<image>` |
| ghcr.io | `ghcr` | `harbor.${domain}/ghcr/<image>` |
| quay.io | `quay` | `harbor.${domain}/quay/<image>` |
| registry.k8s.io | `k8s` | `harbor.${domain}/k8s/<image>` |

This enables air-gapped operation — once an image is cached, the App Environment no longer needs public internet access.

### Stage 4: Adopter App Environment

**Creation flow:**
1. Configure `config/environments/<env>/config.yaml` with infrastructure settings
2. Configure `config/environments/<env>/.env` with provider credentials
3. Run `make plan-apply ENV=<env>` to provision the App Environment
4. FluxCD reconciles and pulls artifacts from CC Harbor

Each environment is provisioned independently from the operator's workstation using the same Terraform codebase and Makefile. There is no in-cluster automation (tf-controller) — all environments are managed via `make plan-apply ENV=<env>`.

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
