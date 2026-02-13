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
| Certificates | cert-manager + Let's Encrypt | TLS automation, ACME DNS-01 issuers (supports Route53, Cloud DNS, DigitalOcean, Cloudflare, RFC-2136, and more) |
| Ingress | Gateway API | Kubernetes-native ingress (replaces deprecated Ingress resource) |
| Secrets | External Secrets Operator (ESO) | Vault/external secret store integration |
| Partner Edge | Envoy | External mTLS with dynamic partner onboarding (xDS/SDS) |

**Vendor-specific services (deployed by per-provider GitOps kustomizations):**

Each provider gets a vendor kustomization that fills the gaps between what the provider manages natively and what the generic platform layer expects. This ensures consistency (Cilium CNI everywhere, DNS-01 TLS everywhere) while using cloud-native services where available.

| Function | Proxmox (`onprem/`) | AWS (`aws/`) | GCP (`gcp/`) | OpenStack (`openstack/`) |
|----------|---------------------|-------------|-------------|------------------------|
| Cilium HelmRelease | YES — full install with `gatewayAPI.enabled`, `lbIPAM.enabled`, `l2announcements` | YES — BYOCNI install with `gatewayAPI.enabled`, replaces VPC-CNI | NO — managed by GKE (Dataplane V2) | YES — identical to Proxmox |
| LB-IPAM pools | YES — `CiliumLoadBalancerIPPool` + L2 announcement | NO — AWS Cloud LB | NO — GKE Cloud LB | DEPENDS — Octavia LB or Cilium LB-IPAM |
| Storage provisioner | YES — OpenEBS hostpath | NO — EBS CSI is EKS add-on | NO — PD CSI auto-installed | NO — Cinder CSI pre-installed |
| Object storage (MinIO) | YES — standalone MinIO | NO — uses S3 bucket from IaC | NO — uses GCS bucket from IaC | DEPENDS — Swift available? If yes, skip. If no, deploy MinIO |
| OCI registry (Harbor) | YES — Harbor + proxy cache | NO — uses ECR from IaC | NO — uses Artifact Registry from IaC | YES — Harbor (no managed alternative) |

DNS configuration (ClusterIssuers, DNS credential Secrets, external-dns provider config) is an **independent dimension** from infrastructure provider — a Proxmox cluster may use Cloudflare, Route53, or any other DNS provider. DNS resources are therefore placed in separate `dns/{dns_provider}` kustomizations, not in the vendor kustomizations above. See DNS Configuration Strategy below.

Two provider profiles emerge from this mapping:

| Profile | Providers | Data layer | Storage/Registry | Cilium |
|---------|-----------|------------|------------------|--------|
| **Self-hosted** | Proxmox, OpenStack | In-cluster operators + CRs (Strimzi, Percona) | MinIO + Harbor + OpenEBS/Cinder | Self-managed (two-phase bootstrap) |
| **Managed** | AWS, GCP | Managed services (RDS, MSK, etc. — endpoints from IaC) | Managed S3/GCS + ECR/GAR + native CSI | BYOCNI (AWS) or fully managed (GCP) |

### DNS Configuration Strategy

The platform supports all DNS providers that external-dns and cert-manager support. Both tools use the same DNS provider, and the configuration is fully driven by IaC — GitOps manifests remain provider-agnostic.

#### external-dns

The external-dns Helm chart is designed with a generic architecture: `provider.name` selects the provider, `env` passes credentials, and `extraArgs` passes provider-specific flags. No provider has dedicated Helm value keys. The HelmRelease in `platform/` uses `${dns_provider}` for provider selection and provider-specific env vars via Flux `postBuild` substitution.

Supported DNS providers and their credential requirements:

| DNS Provider | `provider.name` | Credentials (env vars) | Extra args |
|-------------|-----------------|----------------------|------------|
| DigitalOcean | `digitalocean` | `DO_TOKEN` | — |
| Cloudflare | `cloudflare` | `CF_API_TOKEN` | — |
| AWS Route53 | `aws` | None (IRSA/node role) or `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` | `--aws-zone-type=public` |
| Google Cloud DNS | `google` | None (Workload Identity) or `GOOGLE_APPLICATION_CREDENTIALS` | `--google-project=${gcp_project}` |
| PowerDNS | `pdns` | — | `--pdns-server`, `--pdns-api-key` |
| OpenStack Designate | `designate` | `OS_AUTH_URL`, `OS_USERNAME`, `OS_PASSWORD`, `OS_PROJECT_NAME`, `OS_REGION_NAME` | — |
| Azure DNS | `azure` | Managed Identity or Service Principal | — |

#### cert-manager (DNS-01 ClusterIssuers)

cert-manager's ClusterIssuer is inherently provider-specific in its `dns01` solver block — different providers have structurally different YAML (not just different values). ClusterIssuers and their DNS credential Secrets are therefore placed in the **vendor-specific kustomizations** (`onprem/`, `aws/`, `gcp/`, `openstack/`), not in the shared `platform-config/`.

In-tree DNS-01 solvers supported by cert-manager:

| DNS Provider | Solver key | Auth mechanism |
|-------------|-----------|----------------|
| AWS Route53 | `route53` | Static keys, IRSA, Pod Identity, instance metadata |
| Google Cloud DNS | `cloudDNS` | Service account JSON, GKE Workload Identity |
| DigitalOcean | `digitalocean` | API token via Secret |
| Cloudflare | `cloudflare` | API token (recommended) or API key via Secret |
| RFC-2136 (BIND, PowerDNS) | `rfc2136` | TSIG shared secret |
| Azure DNS | `azureDNS` | Managed Identity, Service Principal |
| Akamai | `akamai` | Client token + secret + access token |
| ACME-DNS (universal proxy) | `acmeDNS` | ACME-DNS account JSON |

Out-of-tree providers (deployed as webhook): OpenStack Designate, OVH, Hetzner, Infoblox, NS1, and many more via the `dns01.webhook` extension point.

#### DNS kustomization paths (`dns/{provider}`)

DNS resources are structurally different per provider (not just different values), so each DNS provider gets its own kustomization path in the OCI artifact:

```
gitops/
  dns/
    digitalocean/           # ClusterIssuers (digitalocean solver), DNS Secret (DO token), external-dns values patch
    cloudflare/             # ClusterIssuers (cloudflare solver), DNS Secret (CF token), external-dns values patch
    route53/                # ClusterIssuers (route53 solver), DNS Secret (AWS keys or IRSA), external-dns values patch
    clouddns/               # ClusterIssuers (cloudDNS solver), DNS Secret (GCP SA or WI), external-dns values patch
    rfc2136/                # ClusterIssuers (rfc2136 solver), DNS Secret (TSIG key), external-dns values patch
    designate/              # ClusterIssuers (webhook solver), DNS Secret (OS_* vars), external-dns values patch
```

Each path contains 3-4 files:
1. **`letsencrypt.yaml`** — ClusterIssuers (prod + staging) with the provider-specific `dns01` solver block
2. **`dns-secret.yaml`** — K8s Secret with DNS credentials, using `${substitution}` variables from `cluster-secrets`
3. **`external-dns-values.yaml`** — HelmRelease values patch that adds the provider-specific env vars to external-dns
4. **`kustomization.yaml`** — references the above resources

The Flux `kustomization_dns` resource (created by the `flux-config` Terraform module) points to `./dns/${dns_provider}` based on the environment's `config.yaml`. This is independent of the infrastructure provider — any combination of infra and DNS providers works.

#### Credential flow

DNS providers have different credential shapes (single token, key pair, IAM role, service account JSON). Credentials are stored as flat key-value pairs in `.env` using provider-specific variable names:

```bash
# DigitalOcean DNS: 1 token
DIGITALOCEAN_TOKEN=dop_v1_xxx

# Cloudflare DNS: 1 token
CLOUDFLARE_API_TOKEN=xxx

# Route53 DNS: key pair (or IRSA — no credentials needed)
AWS_DNS_ACCESS_KEY_ID=xxx
AWS_DNS_SECRET_ACCESS_KEY=xxx

# PowerDNS (rfc2136): URL + key
POWERDNS_API_URL=https://pdns.example.com/api/v1
POWERDNS_API_KEY=xxx

# OpenStack Designate: OpenRC-style vars
OS_AUTH_URL=https://identity.cloud.example.com/v3
OS_USERNAME=dns-admin
OS_PASSWORD=xxx
OS_PROJECT_NAME=mojaloop
OS_REGION_NAME=RegionOne
```

The Makefile maps all DNS-related `.env` variables into a single Terraform map variable (`dns_credentials`). Terraform injects every key into the `cluster-secrets` K8s Secret. Each `dns/{provider}/` kustomization references only the keys it needs via `${substitution}` — empty values for unused providers are harmless.

```
.env (flat k/v)  →  Makefile (TF_VAR_dns_credentials map)  →  flux-config module
                                                                      │
                                                    ┌─────────────────┴─────────────────┐
                                                    ▼                                   ▼
                                            cluster-secrets (K8s Secret)      kustomization_dns
                                            all DNS vars as keys              path: ./dns/${dns_provider}
                                                    │                                   │
                                                    └──────────── postBuild ────────────┘
                                                                     │
                                                    ┌────────────────┼────────────────┐
                                                    ▼                ▼                ▼
                                            dns-secret.yaml   letsencrypt.yaml   external-dns-values.yaml
                                            ${do_token}        ${do_token}        ${do_token}
```

This design means adding a new DNS provider requires:
1. Create `gitops/dns/{new_provider}/` with 3-4 files — **zero Terraform changes**
2. Add the new credential variable names to the Makefile's `dns_credentials` map — **one line**
3. Set `dns.provider: new_provider` in the environment's `config.yaml`

**Distribution:** Publish validated OCI artifact to registry (GHCR, Harbor, ECR)

### GitOps Artifact Structure

A single OCI artifact contains multiple Kustomize roots. Flux deploys a subset based on the cluster's provider and role:

```
gitops/
  platform/           # Always — shared services (metrics-server, external-dns, cert-manager, ESO)
  platform-config/    # Always — shared config (Gateway with ${gateway_class_name}, wildcard TLS)

  # DNS-provider kustomizations — exactly one deployed per cluster (independent of infra provider)
  dns/
    digitalocean/     # ClusterIssuers (DO solver), DNS Secret, external-dns values patch
    cloudflare/       # ClusterIssuers (CF solver), DNS Secret, external-dns values patch
    route53/          # ClusterIssuers (Route53 solver), DNS Secret, external-dns values patch
    clouddns/         # ClusterIssuers (Cloud DNS solver), DNS Secret, external-dns values patch
    rfc2136/          # ClusterIssuers (rfc2136 solver), DNS Secret, external-dns values patch
    designate/        # ClusterIssuers (Designate webhook solver), DNS Secret, external-dns values patch

  # Vendor-specific kustomizations — exactly one deployed per cluster (infra gap-fillers)
  onprem/             # Proxmox: Cilium, LB-IPAM, OpenEBS, MinIO, Harbor
  openstack/          # OpenStack: Cilium, LB-IPAM or Octavia config, Harbor
  aws/                # AWS: Cilium (BYOCNI)
  gcp/                # GCP: (minimal — GKE manages Cilium, storage, LB)

  # Role-specific (unchanged)
  cc/                 # CC operators (vault-operator) + namespace definitions
  cc-config/          # CC services (Vault CR, SecretStore) — provider-agnostic only
  cc-routes/          # CC HTTPRoutes (vault, and conditionally harbor, minio)
  env/                # Env operators (Strimzi, Percona, Redis, Vault)
  env-data/           # Self-hosted env only: data layer CRs (MySQL, Kafka, MongoDB, Redis)
  env-auth/           # Auth layer (Keycloak, Ory stack)
  env-app/            # Mojaloop core app (MCM, Finance Portal)
```

Two independent provider dimensions determine which kustomizations are deployed:
- **Infrastructure provider** (`infra.provider`) selects the vendor kustomization — holds Cilium (if self-managed), LB config, storage/registry gap-fillers
- **DNS provider** (`dns.provider`) selects the DNS kustomization — holds ClusterIssuers, DNS credential Secret, external-dns values patch

This separation means any combination works (e.g. Proxmox + Cloudflare, AWS + DigitalOcean DNS). Adding a new DNS provider requires only a new `dns/{provider}/` directory — zero Terraform changes. Adding a new infra provider requires a new vendor kustomization + Terraform module.

GatewayClass is not in the artifact. It is auto-created by Cilium — either by the self-managed HelmRelease (`gatewayAPI.enabled: true`) or by the cloud-managed Cilium installation. On GCP, GKE provides its own GatewayClasses backed by Google Cloud Load Balancers.

**Deployment matrix:**

| Cluster | Infra | DNS | Kustomizations | Notes |
|---------|-------|-----|---------------|-------|
| CC | Proxmox | digitalocean | platform → dns/digitalocean → platform-config → onprem → cc → cc-config → cc-routes | onprem: Cilium, LB-IPAM, OpenEBS, MinIO, Harbor |
| CC | Proxmox | cloudflare | platform → dns/cloudflare → platform-config → onprem → cc → cc-config → cc-routes | Same infra, different DNS — works seamlessly |
| CC | AWS | route53 | platform → dns/route53 → platform-config → aws → cc → cc-config → cc-routes | aws: Cilium (BYOCNI); uses EBS + S3 + ECR |
| CC | GCP | clouddns | platform → dns/clouddns → platform-config → gcp → cc → cc-config → cc-routes | gcp: minimal; GKE manages Cilium + storage |
| Env | Proxmox | digitalocean | platform → dns/digitalocean → platform-config → onprem → env → env-data → env-auth → env-app | env-data: in-cluster MySQL, Kafka, MongoDB, Redis |
| Env | AWS | route53 | platform → dns/route53 → platform-config → aws → env → env-auth → env-app | No env-data — uses RDS, MSK, DocumentDB, ElastiCache |

**Dependency chain:**

```
platform → dns/{dns_provider} → platform-config → vendor (onprem|aws|gcp|openstack)
                                                       ↓
                                           ┌───────────┴───────────┐
                                           cc                      env
                                           ↓                       ↓
                                       cc-config              env-data (self-hosted only)
                                           ↓                       ↓
                                       cc-routes              env-auth
                                                                   ↓
                                                               env-app
```

The `dns/{provider}` kustomization depends on `platform` (needs cert-manager + external-dns operators to be installed). `platform-config` depends on `dns/{provider}` (the Gateway needs ClusterIssuers to exist for cert annotation).

Version coherence is guaranteed — all directories ship in one artifact. A single OCI tag (e.g. `v1.0.0` or `latest`) covers the entire stack.

### Cilium: Deployment Strategy Per Provider

Cilium is the CNI on all providers. The deployment mechanism varies but the result is consistent: Cilium running with Gateway API support. Each vendor kustomization handles Cilium appropriately for its provider.

#### Two-Phase Deployment (Talos-based: Proxmox, OpenStack)

Cilium must be running before any pods can schedule (including Flux), but Cilium is distributed only as a Helm chart, and Talos cannot run Helm during provisioning.

**Phase 1 — Talos extraManifests (bootstrap):**
A pre-rendered Cilium manifest is hosted on private storage and referenced in the Talos machine config patch (`patch-cilium-install.yaml`). Talos downloads and applies it as a static manifest during node boot, ensuring CNI is available before the kubelet starts scheduling pods.

**Phase 2 — Flux HelmRelease (steady-state):**
Once the cluster is running and Flux is reconciling, a Cilium HelmRelease in the vendor kustomization (`onprem/` or `openstack/`) takes over management. Flux adopts the existing Cilium installation, enabling version upgrades, configuration changes, and Helm values management through GitOps.

The HelmRelease includes `gatewayAPI.enabled: true`, which auto-creates the GatewayClass (`cilium`). The vendor kustomization also deploys Cilium configuration CRDs (L2AnnouncementPolicy, CiliumLoadBalancerIPPool) for LB-IPAM where applicable.

#### BYOCNI (AWS EKS)

EKS ships with VPC-CNI by default. The `aws/` vendor kustomization deploys a Cilium HelmRelease that replaces VPC-CNI with Cilium in BYOCNI mode. This gives consistent Gateway API support via `gatewayAPI.enabled: true` and creates the `cilium` GatewayClass. EBS CSI driver is installed as an EKS add-on by Terraform (IaC layer), not by GitOps.

#### Managed Cilium (GCP GKE)

GKE Dataplane V2 **is** Cilium — Google chose Cilium as the underlying technology. Enabled via `datapath_provider = "ADVANCED_DATAPATH"` in Terraform. No Cilium HelmRelease is needed in GitOps. However, GKE does **not** create a `cilium` GatewayClass — it creates its own GatewayClasses backed by Google Cloud Load Balancers (e.g. `gke-l7-regional-external-managed`). Gateway API CRDs are auto-installed via `gateway_api_config { channel = "CHANNEL_STANDARD" }`.

#### Managed Cilium (DigitalOcean DOKS)

DOKS provides Cilium as the default managed CNI. GatewayClass is pre-created by DigitalOcean. No vendor kustomization is needed for Cilium or Gateway API.

### Cilium, GatewayClass, and Gateway API: Provider Model

| Provider | Cilium installation | GatewayClass name | GatewayClass creation | Gateway API CRDs |
|----------|--------------------|--------------------|----------------------|-----------------|
| Proxmox | Self-managed: Talos extraManifests → Flux HelmRelease (`onprem/`) | `cilium` | Auto-created by Cilium Helm (`gatewayAPI.enabled`) | Installed via Talos extraManifests |
| OpenStack | Self-managed: Talos extraManifests → Flux HelmRelease (`openstack/`) | `cilium` | Auto-created by Cilium Helm (`gatewayAPI.enabled`) | Installed via Talos extraManifests |
| AWS EKS | Self-installed: Flux HelmRelease (`aws/`) replaces VPC-CNI | `cilium` | Auto-created by Cilium Helm (`gatewayAPI.enabled`) | Installed before Cilium (EKS add-on or manifest) |
| GCP GKE | Managed (Dataplane V2, `ADVANCED_DATAPATH`) | `gke-l7-regional-external-managed` | Pre-created by GKE | Auto-installed via `gateway_api_config.channel` |
| DigitalOcean DOKS | Managed (default CNI) | Provider-created | Pre-created by DigitalOcean | Pre-installed |

The shared Gateway in `platform-config/` references `gatewayClassName: ${gateway_class_name}` — a substitution variable set per environment. This is `cilium` on most providers and a GKE-specific class on GCP.

### Stage 3: Adopter Control Center

**Bootstrap process:**
1. Pull OCI bundle via CLI
2. Configure `config/environments/<env>/.env` with provider credentials
3. Configure `config/environments/<env>/config.yaml` with infrastructure settings
4. Run `make plan-apply ENV=<env>`

**Control Center hosts:**

| Service | Purpose | Self-hosted profile (Proxmox, OpenStack) | Managed profile (AWS, GCP) |
|---------|---------|----------------------------------------|---------------------------|
| Vault | Secrets management, internal CA, partner keys | `cc-config/` (all providers) | `cc-config/` (all providers) |
| Harbor | Local OCI registry + pull-through cache | Vendor kustomization (`onprem/`, `openstack/`) | Not deployed — uses ECR (AWS) or Artifact Registry (GCP) |
| MinIO | S3-compatible object storage | Vendor kustomization (`onprem/`, `openstack/` if no Swift) | Not deployed — uses S3 (AWS) or GCS (GCP) |
| FluxCD | GitOps reconciliation (OCI-based, not Git) | All providers | All providers |

On self-hosted providers, Harbor stores OCI artifacts in MinIO (S3-compatible). On managed providers (AWS, GCP), neither Harbor nor MinIO is deployed — Terraform creates the managed equivalents (S3/GCS bucket, ECR/Artifact Registry repository) and passes their endpoints as substitution variables. FluxCD pulls directly from the managed OCI registry; no in-cluster registry is needed on cloud.

**CC Service Ingress (Gateway API):**

CC services are exposed via a shared Gateway in `platform-system` namespace with a wildcard TLS listener (`*.${domain}`). The Gateway receives a LoadBalancer IP from LB-IPAM (on-prem) or cloud LB. Each service has its own HTTPRoute in its dedicated namespace:

| Hostname | HTTPRoute namespace | Backend | Port | Profile |
|----------|-------------------|---------|------|---------|
| `vault.${domain}` | vault | vault | 8200 | All providers |
| `harbor.${domain}` | harbor | harbor | 80 | Self-hosted only (Proxmox, OpenStack) |
| `minio.${domain}` | minio | minio-console | 9001 | Self-hosted only (Proxmox, OpenStack) |

HTTPRoutes reference the Gateway cross-namespace via `parentRefs.namespace: platform-system`. Backend services are in the same namespace as the HTTPRoute — no ReferenceGrant needed.

A single wildcard TLS certificate (`*.${domain}`) is auto-provisioned by cert-manager using DNS-01 challenges. DNS-01 is always used (all providers) because on-prem LB IPs are private and unreachable by Let's Encrypt for HTTP-01. The ClusterIssuer's DNS-01 solver block is provider-specific and lives in the `dns/{dns_provider}` kustomization (see DNS Configuration Strategy). external-dns watches `gateway-httproute` sources and creates DNS A records pointing each hostname to the Gateway's LB IP.

**Namespace isolation (self-hosted CC):** On self-hosted providers, Vault, Harbor, and MinIO each run in their own namespace (`vault`, `harbor`, `minio`) for least-privilege security. The vault-operator remains in `cc-system`. This prevents a compromised Harbor pod from accessing Vault's ServiceAccount tokens and Secrets. On managed providers, only the `vault` namespace is created — Harbor and MinIO are not deployed.

**Harbor proxy cache (self-hosted profile only):** On self-hosted providers (Proxmox, OpenStack), a setup Job (in the vendor kustomization's `harbor/` directory) configures Harbor as a pull-through cache for upstream OCI registries. App Environments pull all container images through Harbor instead of hitting public registries directly. On managed providers (AWS, GCP), this does not apply — there is no in-cluster Harbor; container images are pulled directly from public registries or via the cloud provider's native image caching.

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
4. FluxCD reconciles and pulls the GitOps artifact from the configured OCI source:
   - **Self-hosted CC:** pulls from CC Harbor (e.g. `oci://harbor.cc.example.com/mojaloop/ml-gitops`)
   - **Managed CC:** pulls from the managed OCI registry (e.g. ECR, Artifact Registry) or directly from the Platform Team's public registry (GHCR)

Each environment is provisioned independently from the operator's workstation using the same Terraform codebase and Makefile. There is no in-cluster automation (tf-controller) — all environments are managed via `make plan-apply ENV=<env>`.

**Customization:** Provider differences are handled by vendor-specific kustomization paths:
- Proxmox (`onprem/`): Cilium HelmRelease, LB-IPAM, OpenEBS, MinIO, Harbor, ClusterIssuers
- OpenStack (`openstack/`): Cilium HelmRelease, Harbor, ClusterIssuers; uses Cinder (storage) and Swift (S3)
- AWS (`aws/`): Cilium BYOCNI, ClusterIssuers (Route53); uses EBS, S3, ECR from Terraform
- GCP (`gcp/`): ClusterIssuers (Cloud DNS) only; GKE manages Cilium, storage, and LB natively

**Data layer (env clusters):**
- Self-hosted profile (Proxmox, OpenStack): `env-data/` kustomization deploys in-cluster MySQL (Percona), Kafka (Strimzi), MongoDB (Percona), Redis
- Managed profile (AWS, GCP): Terraform provisions RDS/Cloud SQL, MSK/Managed Kafka, DocumentDB/Atlas, ElastiCache/Memorystore and passes endpoints to GitOps via ConfigMap substitution. `env-data/` is not deployed.

**Partner connectivity:**
- Internal traffic: Cilium with network policies
- External partners: Envoy gateway with dynamic mTLS (see below)

**Sovereignty:** On self-hosted profile, all images and configs are served from CC Harbor — the App Env operates even if public internet is unreachable (fully air-gapped). On managed profile, there is no in-cluster OCI registry or object store; sovereignty depends on the adopter's cloud region, managed registry (ECR/GAR) configuration, and network policies. Air-gapped operation on cloud requires additional VPC endpoint and registry mirroring configuration outside the scope of this platform.

---

## Multi-Provider Architecture

This section provides the complete function-to-provider mapping that validates the design across all four target providers.

### IaC Layer (Terraform) — Vendor-Specific

Terraform is responsible for provisioning infrastructure and creating managed service instances. Each provider has its own Terraform module (`src/modules/{provider}/`). The outputs converge to a common interface: a kubeconfig + substitution variables for GitOps.

| Function | Proxmox | AWS | GCP | OpenStack |
|----------|---------|-----|-----|-----------|
| **TF Provider** | `bpg/proxmox ~>0.86` + `siderolabs/talos ~>0.9` | `hashicorp/aws ~>5.0` | `hashicorp/google ~>5.0` | `terraform-provider-openstack/openstack ~>3.0` + `siderolabs/talos ~>0.9` |
| **K8s provisioning** | Talos on VMs (composite: talos-gen-config → proxmox-vm → talos-bootstrap) | EKS managed (`aws_eks_cluster` + `aws_eks_node_group`) | GKE managed (`google_container_cluster` + `google_container_node_pool`, `datapath_provider = "ADVANCED_DATAPATH"`) | Talos on VMs (composite: talos-gen-config → openstack-vm → talos-bootstrap) |
| **Network** | Physical (VIP via patch-vip) | VPC + subnets + IGW (`aws_vpc`, `aws_subnet`) | VPC + subnet, VPC-native (`google_compute_network`, `google_compute_subnetwork`) | Neutron network + subnet + router + floating IPs |
| **CNI bootstrap** | Cilium via Talos `extraManifests` | EKS default VPC-CNI (replaced by Cilium via GitOps) | Dataplane V2 = Cilium (managed) | Cilium via Talos `extraManifests` |
| **Storage CSI** | N/A (GitOps deploys OpenEBS) | EKS add-on: `aws-ebs-csi-driver` | Auto-installed: `pd.csi.storage.gke.io` | Cinder CSI (cloud-provider-openstack) |
| **Object storage** | N/A (GitOps deploys MinIO) | `aws_s3_bucket` | `google_storage_bucket` + HMAC keys (S3-compat) | Swift (pre-existing) or `openstack_objectstorage_container_v1` |
| **OCI registry** | N/A (GitOps deploys Harbor) | `aws_ecr_repository` | `google_artifact_registry_repository` | N/A (GitOps deploys Harbor) |
| **DNS zone** | External (pre-existing) | Route53 (`aws_route53_zone` or pre-existing) | Cloud DNS (`google_dns_managed_zone`) | Designate (`openstack_dns_zone_v2`) or external |
| **MySQL (env)** | N/A (GitOps deploys Percona XtraDB) | `aws_rds_cluster` (Aurora MySQL) | `google_sql_database_instance` (Cloud SQL) | Trove or N/A (GitOps deploys Percona) |
| **Kafka (env)** | N/A (GitOps deploys Strimzi) | `aws_msk_cluster` | `google_managed_kafka_cluster` | N/A (GitOps deploys Strimzi) |
| **MongoDB (env)** | N/A (GitOps deploys Percona MongoDB) | `aws_docdb_cluster` (DocumentDB) | `mongodbatlas_cluster` (Atlas) or Firestore | N/A (GitOps deploys Percona MongoDB) |
| **Redis (env)** | N/A (GitOps deploys in-cluster) | `aws_elasticache_replication_group` | `google_redis_instance` (Memorystore) | N/A (GitOps deploys in-cluster) |
| **Kubeconfig** | Talos bootstrap output | `aws eks get-token` exec auth | `gcloud` exec auth or token | Talos bootstrap output |
| **Outputs → GitOps** | `cluster_vip`, `lb_ipam_range` | `s3_bucket`, `ecr_url`, `rds_endpoint`, `msk_endpoint`, `docdb_endpoint`, `elasticache_endpoint` | `gcs_bucket`, `gar_url`, `cloudsql_endpoint`, `kafka_endpoint`, `redis_endpoint` | `swift_endpoint` (if applicable) |

### GitOps Layer — Vendor-Specific Kustomizations

Each provider gets exactly one vendor kustomization deployed. It normalizes provider differences so all layers above it (cc, env, app) are generic.

| Function | Proxmox (`onprem/`) | AWS (`aws/`) | GCP (`gcp/`) | OpenStack (`openstack/`) |
|----------|---------------------|-------------|-------------|------------------------|
| **Cilium HelmRelease** | Full install: `gatewayAPI.enabled`, `lbIPAM.enabled`, `l2announcements` | BYOCNI install: `gatewayAPI.enabled`, replaces VPC-CNI | Not deployed — managed by GKE Dataplane V2 | Full install: identical to Proxmox |
| **LB-IPAM pools** | `CiliumLoadBalancerIPPool` + L2 announcement policy | Not deployed — AWS Cloud LB | Not deployed — GKE Cloud LB | Octavia LB or Cilium LB-IPAM (depends on network) |
| **Storage provisioner** | OpenEBS hostpath HelmRelease | Not deployed — EBS CSI is EKS add-on (IaC) | Not deployed — PD CSI auto-installed by GKE | Not deployed — Cinder CSI pre-installed |
| **MinIO** | Standalone MinIO HelmRelease | Not deployed — S3 bucket created by IaC | Not deployed — GCS bucket created by IaC | MinIO if no Swift; skip if Swift available |
| **Harbor** | Harbor HelmRelease + proxy cache setup Job | Not deployed — ECR created by IaC | Not deployed — Artifact Registry created by IaC | Harbor HelmRelease (no managed alternative) |
| **ClusterIssuers** | `dns/{provider}` kustomization (independent of infra) | `dns/{provider}` kustomization | `dns/{provider}` kustomization | `dns/{provider}` kustomization |
| **DNS credential Secret** | `dns/{provider}` kustomization | `dns/{provider}` kustomization | `dns/{provider}` kustomization | `dns/{provider}` kustomization |

### GitOps Layer — Generic (All Providers)

These kustomizations are provider-agnostic and consume substitution variables from the IaC-generated ConfigMap/Secret.

| Kustomization | Contents | Parameterization |
|--------------|----------|------------------|
| `platform/` | metrics-server, external-dns (base, no provider config), cert-manager, ESO | `${dns_provider}` (provider name only) |
| `dns/{provider}` | ClusterIssuers (prod + staging), DNS credential Secret, external-dns values patch | DNS credentials from `cluster-secrets` (provider-specific keys) |
| `platform-config/` | Gateway with wildcard TLS | `${gateway_class_name}`, `${domain}` |
| `cc/` | vault-operator, namespace definitions | None |
| `cc-config/` | Vault CR, ESO SecretStore | `${domain}` |
| `cc-routes/` | HTTPRoutes for vault (and conditionally harbor, minio) | `${domain}` |
| `env/` | Strimzi, Percona XtraDB, Percona MongoDB, Redis operators, Vault operator | None |
| `env-data/` | Data layer CRs (MySQL, Kafka, MongoDB, Redis clusters) | Database passwords via `cluster-secrets` |
| `env-auth/` | Keycloak, Ory stack (Kratos, Keto, Oathkeeper), Vault CR, HTTPRoutes | `${domain}`, auth DB endpoints, OIDC secrets |
| `env-app/` | Mojaloop core, MCM, Finance Portal | Data endpoints (mysql_host, kafka_host, etc.) |

### Managed vs Self-Hosted Decision Matrix

| Service | Proxmox | OpenStack | AWS | GCP |
|---------|---------|-----------|-----|-----|
| **Cilium CNI** | Self-hosted (two-phase) | Self-hosted (two-phase) | Self-installed (BYOCNI via GitOps) | Managed (Dataplane V2) |
| **GatewayClass** | `cilium` (Cilium Helm) | `cilium` (Cilium Helm) | `cilium` (Cilium Helm) | `gke-l7-regional-external-managed` (GKE) |
| **Load balancer** | Cilium LB-IPAM (L2/BGP) | Octavia (managed LBaaS) or Cilium LB-IPAM | AWS ALB/NLB (cloud) | Google Cloud Application LB |
| **Block storage** | OpenEBS hostpath | Cinder CSI (managed) | EBS CSI (EKS add-on) | Persistent Disk CSI (auto) |
| **Object storage** | MinIO (self-hosted) | Swift (managed, S3-compat) | S3 (managed) | GCS (managed, S3-compat via HMAC) |
| **OCI registry** | Harbor (self-hosted) | Harbor (self-hosted) | ECR (managed) | Artifact Registry (managed) |
| **MySQL** | Percona XtraDB (in-cluster) | Percona XtraDB (in-cluster) | RDS Aurora MySQL (managed) | Cloud SQL MySQL (managed) |
| **Kafka** | Strimzi (in-cluster) | Strimzi (in-cluster) | MSK (managed) | Managed Kafka (managed) |
| **MongoDB** | Percona MongoDB (in-cluster) | Percona MongoDB (in-cluster) | DocumentDB (managed) | MongoDB Atlas (managed) |
| **Redis** | In-cluster deployment | In-cluster deployment | ElastiCache (managed) | Memorystore (managed) |
| **DNS management** | External (Cloudflare, Route53, etc.) | Designate (managed) or external | Route53 (managed) | Cloud DNS (managed) |
| **Secrets** | Vault (self-hosted) | Vault (self-hosted) | Vault (self-hosted) | Vault (self-hosted) |

### Substitution Variables for Provider Abstraction

These variables bridge the IaC and GitOps layers. Terraform populates them into the `cluster-config` ConfigMap and `cluster-secrets` Secret; Flux Kustomizations consume them via `postBuild.substituteFrom`.

| Variable | Source | Used by | Example values |
|----------|--------|---------|----------------|
| `gateway_class_name` | IaC config | `platform-config/` Gateway | `cilium`, `gke-l7-regional-external-managed` |
| `dns_provider` | IaC config | `platform/` external-dns | `digitalocean`, `aws`, `google`, `cloudflare`, `pdns`, `designate` |
| `domain` | IaC config | Gateway, HTTPRoutes, Harbor, ClusterIssuers | `ml.example.com` |
| `s3_endpoint` | IaC output | Harbor S3 backend (self-hosted CC only) | `http://minio.minio:9000` |
| `s3_bucket` | IaC output | Harbor S3 backend (self-hosted CC only) | `harbor` |
| `s3_region` | IaC output | Harbor S3 backend (self-hosted CC only) | `us-east-1` |
| `mysql_central_ledger_host` | IaC output (managed) or fixed (on-prem) | `env-app/` Mojaloop | `central-ledger-db-haproxy` or `ml-prod.xxx.rds.amazonaws.com` |
| `kafka_host` | IaC output (managed) or fixed (on-prem) | `env-app/` Mojaloop | `mojaloop-kafka-kafka-bootstrap` or `b-1.ml-msk.xxx.kafka.us-east-1.amazonaws.com` |
| `mongodb_host` | IaC output (managed) or fixed (on-prem) | `env-app/` Mojaloop | `bulk-mongodb-rs0` or `ml-docdb.cluster-xxx.docdb.amazonaws.com` |
| `redis_host` | IaC output (managed) or fixed (on-prem) | `env-app/` Mojaloop | `ttk-redis` or `ml-redis.xxx.cache.amazonaws.com` |
| `gcp_project` | IaC config | `gcp/` ClusterIssuer, external-dns | `mojaloop-prod-123456` |

---

## Partner Edge: DFSP mTLS (App Environment Only)

App Environment clusters expose the Mojaloop FSPIOP API to external DFSPs (Digital Financial Service Providers). All DFSP communication requires mutual TLS (mTLS) — both inbound (DFSP → Hub) and outbound (Hub → DFSP callbacks) across all three Mojaloop transfer phases:

| Phase | Operation | Inbound (DFSP → Hub) | Outbound (Hub → DFSP callback) |
|-------|-----------|---------------------|-------------------------------|
| **1. Discovery** | Party lookup | `GET /parties/{Type}/{ID}` → account-lookup-service | `PUT /parties/{Type}/{ID}` ← account-lookup-service |
| **2. Agreement** | Quote negotiation | `POST /quotes` → quoting-service | `PUT /quotes/{ID}` ← quoting-service |
| **3. Transfer** | Fund movement | `POST /transfers` → ml-api-adapter | `PUT /transfers/{ID}` ← notification-handler |

mTLS applies to **all phases equally** — the infrastructure is DFSP-centric, not service-centric. A single DFSP callback URL registered in Central Ledger is used by all three handler services. This section describes the complete partner edge architecture. Control Center clusters do not need this — they have no DFSP connectivity.

### Two-Gateway Architecture

Each App Environment has two Gateways with distinct security profiles:

```
                            App Environment
  ┌──────────────────────────────────────────────────────────────────────────┐
  │                                                                          │
  │   main-gateway (operators)          partner-gateway (DFSPs)              │
  │   *.${domain} :443                  fspiop.${domain} :443                │
  │   TLS only (no client cert)         mTLS (client cert required)          │
  │   IP: A                             IP: B                                │
  │     │                                 │                                  │
  │     ├── mcm.${domain}                 └── fspiop.${domain}               │
  │     ├── keycloak.${domain}                  │                            │
  │     ├── portal.${domain}           ┌────────┼────────┐                   │
  │     ├── vault.${domain}            ▼        ▼        ▼                   │
  │     └── auth.${domain}         account-  quoting  ml-api-               │
  │           │                    lookup    service  adapter    (inbound)    │
  │           ▼                    service                                    │
  │     Oathkeeper → services        │        │        │                     │
  │                                  │  Kafka │  Kafka │  Kafka              │
  │                                  ▼        ▼        ▼                     │
  │                              account-  quoting  notification (outbound)  │
  │                              lookup    handler  handler                   │
  │                              handler     │        │                      │
  │                                  │       │        │                      │
  │                                  └───────┼────────┘                      │
  │                                          ▼                               │
  │                                  partner-egress-proxy                    │
  │                                  (CiliumEnvoyConfig)                     │
  │                                  Source IP: B ◄── same IP                │
  │                                          │                               │
  └──────────────────────────────────────────┼───────────────────────────────┘
                                             │ mTLS
                                             ▼
                                       Partner DFSPs
```

| Gateway | Audience | Hostname pattern | TLS mode | Backend |
|---------|----------|-----------------|----------|---------|
| `main-gateway` | Hub operators, admin UIs | `*.${domain}` | TLS termination (no client cert) | Oathkeeper → internal services |
| `partner-gateway` | External DFSPs | `fspiop.${domain}` | **mTLS** (client cert required, validated against scheme CA) | Path-based: account-lookup, quoting, ml-api-adapter, bulk-api-adapter, transaction-requests |

The `main-gateway` exists in `platform-config/` (deployed on all clusters). The `partner-gateway` exists in `env-edge/` (deployed only on env clusters).

### Consistent IP Requirement

DFSPs whitelist a single IP address for the Hub. The Hub must present the **same IP for both inbound and outbound** connections — DFSPs see a consistent identity. This means:

- **Inbound**: DFSP connects to `fspiop.${domain}` → resolves to IP **B** (`partner-gateway` LoadBalancer IP)
- **Outbound**: Hub sends callback to DFSP → DFSP sees source IP **B** (same IP)

This is enforced via `CiliumEgressGatewayPolicy`: egress traffic from the `partner-egress-proxy` is SNAT'd to the `partner-gateway`'s external IP. On self-hosted providers, this IP comes from LB-IPAM. On cloud providers, it comes from the cloud Load Balancer's public IP or an Elastic IP / static IP assigned to the egress path.

```yaml
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: partner-egress-snat
spec:
  selectors:
    - podSelector:
        matchLabels:
          app: partner-egress-proxy
  destinationCIDRs:
    - "0.0.0.0/0"                       # All external destinations
  egressGateway:
    nodeSelector:
      matchLabels:
        cilium.io/partner-egress: "true" # Node(s) with the partner-gateway LB IP
    egressIP: "${partner_gateway_ip}"    # Same IP as partner-gateway LoadBalancer
```

### Mojaloop PKI Model

Mojaloop mandates a **single shared scheme CA** for all participants. This simplifies the mTLS architecture:

| Property | Value |
|----------|-------|
| CA model | Single scheme-level CA (private, not public) |
| CA key | RSA 4096-bit, sha512WithRSAEncryption, 10-year validity |
| Platform certs | RSA 2048-bit minimum, sha256WithRSAEncryption, 2-year validity |
| Cert types per participant | TLS (transport), JWS (signing), JWE (encryption) — no key reuse |
| CA management | Vault PKI secrets engine, operated via MCM |

All DFSPs and the Hub receive certificates from the same CA. This means:
- **Inbound**: One CA cert validates ALL DFSP client certs (no per-DFSP CA)
- **Outbound**: Per-DFSP client certs are issued by the Hub (for cert isolation / revocation granularity), validated by DFSPs against the same scheme CA

### Security Layers

Five security layers protect Hub–DFSP communication:

| Layer | Mechanism | Scope |
|-------|-----------|-------|
| **1. mTLS** | X.509 mutual certificate authentication (TLSv1.2+) | Transport — both directions |
| **2. JWS** | JSON Web Signatures (RFC 7515) on HTTP request bodies | Message integrity — requests only (not responses) |
| **3. IP whitelisting** | Firewall rules on both Hub and DFSP sides | Network — both directions |
| **4. OAuth 2.0** | API authorization (Keycloak OIDC) | Application — inbound only |
| **5. ILP** | Interledger Protocol cryptographic transfer proof | Transfer integrity — end-to-end |

JWS provides **end-to-end integrity** — even the Hub cannot modify a message body without detection. The `FSPIOP-Signature` HTTP header carries the detached JWS. Protected headers include `FSPIOP-URI`, `FSPIOP-HTTP-Method`, `FSPIOP-Source`, and `FSPIOP-Destination`.

### Inbound Flow (DFSP → Hub)

The `partner-gateway` (Gateway API) handles inbound mTLS for **all three FSPIOP phases**. This is static infrastructure — configured via GitOps, not per-DFSP. A single mTLS listener validates all DFSP client certificates against the scheme CA, then HTTPRoutes fan out to the appropriate backend services.

```
DFSP ──mTLS──▶ partner-gateway (port 443)
                │
                │  1. Hub presents hub-server-tls cert
                │  2. Requests DFSP client certificate
                │  3. Validates client cert against scheme CA
                │  4. mTLS established
                │
                ▼
              HTTPRoute (hostname: fspiop.${domain})
                │
                │  Path-based routing:
                │
                ├── /parties/*          → account-lookup-service:80  (Discovery)
                ├── /participants/*     → account-lookup-service:80  (Discovery)
                ├── /quotes/*           → quoting-service:80         (Agreement)
                ├── /transfers/*        → ml-api-adapter-service:80  (Transfer)
                ├── /bulkQuotes/*       → quoting-service:80         (Agreement)
                ├── /bulkTransfers/*    → bulk-api-adapter-service:80 (Transfer)
                └── /transactionRequests/* → transaction-requests-service:80
```

All FSPIOP endpoints share the **same mTLS handshake** — one scheme CA, one hub server cert, one Gateway listener. Per-DFSP identity is established at the TLS layer (client cert CN/SAN), not per-service.

**Gateway API resources:**

```yaml
# partner-gateway.yaml — mTLS Gateway for DFSP traffic
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: partner-gateway
  namespace: platform-system
spec:
  gatewayClassName: ${gateway_class_name}
  tls:
    default:
      frontendValidation:
        caCertificateRefs:
          - kind: ConfigMap
            name: scheme-ca             # Validates ALL DFSP client certs
        mode: AllowValidOnly            # Reject if no valid client cert
  listeners:
    - name: fspiop-https
      hostname: "fspiop.${domain}"
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - name: hub-server-tls        # cert-manager issued from Vault PKI
```

Frontend mTLS validation uses Gateway API GEP-91 (Standard status). Cilium translates this into an Envoy `DownstreamTlsContext` with `require_client_certificate: true` and the scheme CA as `trusted_ca`. No CiliumEnvoyConfig needed for inbound.

The HTTPRoute fans out to backend services by FSPIOP path prefix:

```yaml
# fspiop-httproute.yaml — routes all FSPIOP API paths to backend services
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: fspiop-routes
  namespace: mojaloop
spec:
  parentRefs:
    - name: partner-gateway
      namespace: platform-system
  hostnames:
    - "fspiop.${domain}"
  rules:
    # Discovery phase
    - matches:
        - path: { type: PathPrefix, value: /parties }
        - path: { type: PathPrefix, value: /participants }
      backendRefs:
        - name: moja-account-lookup-service
          port: 80
    # Agreement phase
    - matches:
        - path: { type: PathPrefix, value: /quotes }
        - path: { type: PathPrefix, value: /bulkQuotes }
      backendRefs:
        - name: moja-quoting-service
          port: 80
    # Transfer phase
    - matches:
        - path: { type: PathPrefix, value: /transfers }
      backendRefs:
        - name: moja-ml-api-adapter-service
          port: 80
    - matches:
        - path: { type: PathPrefix, value: /bulkTransfers }
      backendRefs:
        - name: moja-bulk-api-adapter-service
          port: 80
    # Transaction requests
    - matches:
        - path: { type: PathPrefix, value: /transactionRequests }
      backendRefs:
        - name: moja-transaction-requests-service
          port: 80
```

The IP whitelist (`CiliumNetworkPolicy`) applies to **all backend services** listed above — not just ml-api-adapter. This matches the sw002 pattern where the `AuthorizationPolicy` targeted account-lookup-service, quoting-service, ml-api-adapter-service, and transaction-requests-service simultaneously.

### Outbound Flow (Hub → DFSP)

Outbound is architecturally harder: the Hub sends callbacks to **dynamic DFSP endpoints** (any domain, registered at runtime via MCM) and must present **per-DFSP client certificates**. A dedicated egress proxy with CiliumEnvoyConfig handles this.

**All three phases** produce outbound callbacks — each has a dedicated handler service that reads events from Kafka and sends HTTP callbacks to the DFSP's registered callback URL:

| Phase | Handler service | Callback example | Kafka topic |
|-------|----------------|------------------|-------------|
| **Discovery** | `account-lookup-service` (inline) | `PUT /parties/{Type}/{ID}` | N/A (synchronous) |
| **Agreement** | `quoting-service` (inline) | `PUT /quotes/{ID}` | N/A (synchronous) |
| **Transfer** | `ml-api-adapter-handler-notification` | `PUT /transfers/{ID}` | `topic-notification-event` |
| **Bulk Transfer** | `bulk-api-adapter-handler-notification` | `PUT /bulkTransfers/{ID}` | `topic-bulk-notification-event` |

All handler services resolve the DFSP callback URL from **Central Ledger** (a single URL per DFSP, registered during onboarding) and send plain HTTP. The egress proxy handles mTLS transparently.

```
account-lookup-service  ─┐
quoting-service          ─┤  HTTP to partner-egress-proxy.mojaloop.svc (port 80)
notification-handler     ─┤  Headers: FSPIOP-Destination: dfspA, FSPIOP-Source: hub
bulk-notification-handler─┘  Body: signed with JWS (FSPIOP-Signature header)
    │
    ▼
partner-egress-proxy Service
    │
    │  Cilium intercepts (CiliumEnvoyConfig backendServices)
    │  Envoy reads FSPIOP-Destination header → selects dfspA route
    │
    ▼
Embedded Envoy (Cilium)
    │
    │  Route: FSPIOP-Destination: dfspA → dfspA-upstream cluster
    │  Host rewrite: → callback.dfspA.com
    │  Upstream TLS: UpstreamTlsContext (MUTUAL)
    │    - client cert: cilium-secrets/dfspA-clientcert-tls (SDS)
    │    - server validation: ca_bundle from same Secret (SDS)
    │    - SNI: callback.dfspA.com
    │  Source IP: partner-gateway IP (CiliumEgressGatewayPolicy)
    │
    ▼
callback.dfspA.com:443 (mTLS established)
```

**Key design decisions:**

- **All handler services** send plain HTTP to the egress proxy. They have zero TLS awareness — mTLS is entirely infrastructure-managed. This is DFSP-centric: one DFSP onboarding enables mTLS for all three phases simultaneously.
- Routing uses the **`FSPIOP-Destination` header** (set by every Mojaloop service on every callback) to select the per-DFSP upstream cluster and cert. This header is part of the FSPIOP specification and is always present.
- The egress proxy is a **minimal pause container** — Cilium's embedded Envoy (via CiliumEnvoyConfig `backendServices`) does all the work. No standalone Envoy deployment.
- The **single callback URL** registered in Central Ledger during DFSP onboarding points to `http://partner-egress-proxy.mojaloop.svc.cluster.local` (not the real DFSP FQDN). The Envoy route rewrites the Host header and originates the real connection. All services that resolve this URL from Central Ledger automatically route through the egress proxy.

### Dynamic Resource Generation (Vault Agent Template)

DFSPs are onboarded dynamically via MCM. The Vault Agent template pattern (proven in sw002 — see `doc/sw002-reference.md`) generates all per-DFSP Kubernetes resources automatically. A Vault Agent sidecar on the MCM pod watches `secret/onboarding_pm4mls/` in Vault KV and `kubectl apply`s resources whenever the DFSP list changes.

```
MCM onboards DFSP-A
    │
    ▼
Vault PKI: issue client cert (client-cert-role)
Vault KV:  store at secret/onboarding_pm4mls/dfspA
           (host, fqdn, client_cert, client_key, ca_bundle, currency)
    │
    ▼
Vault Agent sidecar (on MCM pod, periodic re-render ~5 min)
Template: {{ range secrets "secret/onboarding_pm4mls/" }}
    │
    │  kubectl apply -f /vault/secrets/tmp/partner-edge.yaml
    │
    ├──▶ K8s Secret: dfspA-clientcert-tls (in cilium-secrets namespace)
    │      type: kubernetes.io/tls (ca.crt, tls.key, tls.crt)
    │      Created directly — no ESO/operator needed
    │
    ├──▶ CiliumEnvoyConfig: partner-egress-mtls (SINGLE resource, ALL DFSPs)
    │      Listener: port 80, routes by FSPIOP-Destination header
    │      Per-DFSP upstream clusters: STRICT_DNS → dfsp-fqdn:443
    │      Per-DFSP UpstreamTlsContext with cert via Cilium SDS
    │
    ├──▶ CiliumNetworkPolicy: dfsp-whitelist-ingress
    │      Inbound IP whitelist rebuilt from secret/whitelist_fsps + secret/whitelist_pm4mls
    │      Targets ALL FSPIOP services: account-lookup, quoting, ml-api-adapter,
    │        bulk-api-adapter, transaction-requests (all three phases protected)
    │
    └──▶ ConfigMap + Job: dfspA-onboard-dfsp
           Provisions DFSP in Central Ledger (callback URL, currency, net debit cap)
           Callback URL: http://partner-egress-proxy.mojaloop.svc.cluster.local
           (single URL — used by all handler services across all phases)
```

ESO is **not used** for per-DFSP secrets — ESO requires static `ExternalSecret` manifests, which cannot handle the dynamic DFSP list. The Vault Agent template creates K8s Secrets directly via `kubectl apply`, with the cert data already available in the template context. Cilium SDS watches these Secrets and hot-pushes them to Envoy — zero-downtime cert rotation.

### Certificate Lifecycle

| Certificate | Issued by | Stored in | Synced to K8s via | Consumed by | Rotation |
|-------------|-----------|-----------|-------------------|-------------|----------|
| Hub server cert (`hub-server-tls`) | cert-manager → Vault PKI (`server-cert-role`) | K8s Secret (cert-manager managed) | cert-manager (auto-renewal) | `partner-gateway` listener (Cilium SDS) | Automatic (`renewBefore: 720h`) |
| Hub client cert per-DFSP (`{dfsp}-clientcert-tls`) | MCM → Vault PKI (`client-cert-role`) → Vault KV | Vault KV at `secret/onboarding_pm4mls/{dfsp}` | Vault Agent template (`kubectl apply`) | `partner-egress-proxy` CiliumEnvoyConfig (Cilium SDS) | Vault Agent re-renders on KV change |
| Scheme CA (`scheme-ca`) | Generated once in Vault PKI (`pki/root/generate/internal`) | Vault KV at `secret/mcm/scheme-ca` | ESO ExternalSecret (static, `refreshInterval: 1h`) | `partner-gateway` frontendValidation + egress upstream validation | Rarely changes (10-year validity) |
| DFSP JWS public keys | Provided by DFSPs during onboarding | Vault KV at `secret/mcm/{dfsp}` | Vault Agent template or application config | ml-api-adapter (JWS verification) | On DFSP key rotation via MCM |

### Components

| Component | Deployed by | Cluster | Role in partner edge |
|-----------|-------------|---------|---------------------|
| **Vault** (PKI + KV) | `env-auth/` | Env | Issues hub certs, stores per-DFSP cert bundles, scheme CA |
| **MCM** | `env-app/` | Env | DFSP onboarding portal. Calls Vault PKI, writes cert bundles to KV, manages endpoint URLs and IP whitelists |
| **Vault Agent** (sidecar on MCM) | `env-app/` (MCM Helm values) | Env | Watches Vault KV, generates per-DFSP K8s resources via template + `kubectl apply` |
| **cert-manager** | `platform/` | All | Issues `hub-server-tls` from Vault PKI with auto-renewal |
| **ESO** | `platform/` | All | Syncs scheme CA from Vault KV to ConfigMap (static) |
| **partner-gateway** | `env-edge/` | Env | Gateway API with frontend mTLS for inbound DFSP traffic |
| **partner-egress-proxy** | `env-edge/` | Env | Minimal Service — CiliumEnvoyConfig intercepts traffic, Envoy handles per-DFSP mTLS origination |
| **CiliumEnvoyConfig** | Dynamic (Vault Agent) | Env | Per-DFSP upstream clusters with mTLS, route by `FSPIOP-Destination` header |
| **CiliumEgressGatewayPolicy** | `env-edge/` | Env | SNATs egress from partner-egress-proxy to partner-gateway IP |
| **CiliumNetworkPolicy** | Dynamic (Vault Agent) | Env | Inbound IP whitelist from Vault KV — targets all FSPIOP services (account-lookup, quoting, ml-api-adapter, bulk-api-adapter, transaction-requests) |

### GitOps Placement

```
gitops/
  env-edge/                                    # Partner edge (env clusters only)
    kustomization.yaml
    partner-gateway.yaml                       # Gateway: mTLS for DFSP inbound
    fspiop-httproute.yaml                      # HTTPRoute → ml-api-adapter
    partner-egress-proxy.yaml                  # Deployment + Service (egress proxy)
    egress-gateway-policy.yaml                 # CiliumEgressGatewayPolicy (consistent IP)
    vault-pki-issuer.yaml                      # ClusterIssuer (cert-manager → Vault PKI)
    hub-server-cert.yaml                       # Certificate (auto-renewal)
    scheme-ca-externalsecret.yaml              # ESO → scheme-ca ConfigMap
    vault-agent-rbac.yaml                      # RBAC for Vault Agent kubectl apply
```

The Vault Agent template (`vault-config-configmap.hcl`) lives in the MCM Helm values — it is part of the MCM deployment in `env-app/`, not a separate gitops path. Dynamic resources (K8s Secrets, CiliumEnvoyConfig, CiliumNetworkPolicy) are generated at runtime by the Vault Agent, not at artifact build time.

**Dependency chain for env clusters:**

```
platform → platform-config → vendor → env → env-data → env-auth → env-edge → env-app
                                                                      │
                                                        partner-gateway (needs cert-manager)
                                                        partner-egress-proxy (needs Cilium)
                                                        scheme-ca (needs ESO + Vault)
                                                                      │
                                                        env-app deploys MCM with Vault Agent
                                                        Vault Agent generates dynamic resources
```

### Static vs Dynamic Resources

| Resource | Type | Creator | Lifecycle |
|----------|------|---------|-----------|
| `partner-gateway` | Static | GitOps (`env-edge/`) | Deployed once, updated via artifact |
| `partner-egress-proxy` | Static | GitOps (`env-edge/`) | Deployed once |
| `CiliumEgressGatewayPolicy` | Static | GitOps (`env-edge/`) | Deployed once |
| `hub-server-tls` Certificate | Static | GitOps (`env-edge/`) + cert-manager | Auto-renewed |
| `scheme-ca` ExternalSecret | Static | GitOps (`env-edge/`) + ESO | Refreshed hourly |
| `fspiop-httproute` | Static | GitOps (`env-edge/`) | Deployed once |
| Per-DFSP K8s Secrets | **Dynamic** | Vault Agent template | Created/updated on DFSP onboarding |
| `CiliumEnvoyConfig` (all DFSP routes) | **Dynamic** | Vault Agent template | Regenerated on every DFSP change |
| `CiliumNetworkPolicy` (IP whitelist) | **Dynamic** | Vault Agent template | Regenerated on whitelist change |
| Central Ledger provisioning Jobs | **Dynamic** | Vault Agent template | One-shot per DFSP |

### What Is NOT Deployed

- **No standalone Envoy** — Cilium's embedded Envoy handles both Gateways and the egress CiliumEnvoyConfig
- **No Envoy Gateway controller** — Gateway API + CiliumEnvoyConfig covers all use cases
- **No custom xDS control plane** — Cilium acts as the xDS control plane; K8s Secrets + SDS replace custom SDS servers
- **No Istio / service mesh** — Cilium provides all needed L7 features natively
- **No per-DFSP Gateway listeners** — single `partner-gateway` listener with one scheme CA validates all DFSPs; per-DFSP routing is header-based in the egress proxy
- **No ESO for dynamic per-DFSP secrets** — ESO requires static manifests; Vault Agent template handles dynamic cert sync directly

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
- Harbor admin password (self-hosted CC only)
- Kubeconfig for CC cluster
- Talosconfig for node access (on-prem only)

**Store offline** (physical safe, air-gapped storage). Required for disaster recovery.

---

## Disaster Recovery

### Backup Strategy

| Component | Location | Criticality |
|-----------|----------|-------------|
| Recovery Kit | Offline physical safe | Critical |
| CC Terraform state | Offline or CC object store (MinIO on-prem, S3/GCS on cloud) | High |
| App Env state | CC object store (MinIO on-prem, S3/GCS on cloud) | High |
| Vault data | CC object store + external replica | High |

### Recovery: Total Loss of Control Center

1. Retrieve recovery kit and terraform state from offline storage
2. Provision new infrastructure
3. Run `terraform apply` with saved state
4. Restore object storage from external backup (MinIO buckets on-prem, S3/GCS on cloud)
5. Unseal Vault with recovery kit keys
6. FluxCD reconciles and reconnects to existing App Environments
