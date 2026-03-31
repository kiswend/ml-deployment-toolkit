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
| DFSP mTLS | Standalone Envoy (inbound) + CiliumEnvoyConfig (outbound) | Inbound mTLS verification via dedicated Envoy Deployment; outbound mTLS origination via Cilium's Envoy DaemonSet |

**Vendor-specific services (deployed by per-provider GitOps kustomizations):**

Each provider gets a vendor kustomization that fills the gaps between what the provider manages natively and what the generic platform layer expects. This ensures consistency (Cilium CNI everywhere, DNS-01 TLS everywhere) while using cloud-native services where available.

| Function | Talos — Proxmox, OpenStack (`talos/`) | AWS (`aws/`) | GCP (`gcp/`) |
|----------|----------------------------------------|-------------|-------------|
| Cilium HelmRelease | YES — full install with `gatewayAPI.enabled`, `lbIPAM.enabled`, `l2announcements` | YES — BYOCNI install with `gatewayAPI.enabled`, replaces VPC-CNI | NO — managed by GKE (Dataplane V2) |
| LB-IPAM pools | YES — `CiliumLoadBalancerIPPool` + L2 announcement | NO — AWS Cloud LB | NO — GKE Cloud LB |
| Storage provisioner | YES — OpenEBS hostpath | NO — EBS CSI is EKS add-on | NO — PD CSI auto-installed |
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

cert-manager's ClusterIssuer is inherently provider-specific in its `dns01` solver block — different providers have structurally different YAML (not just different values). ClusterIssuers and their DNS credential Secrets are therefore placed in the **dns-specific kustomizations** (`dns/digitalocean/`, `dns/cloudflare/`, `dns/route53/`, etc.), not in the shared `platform-config/`.

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

# Route53 DNS: standard AWS env vars (same as AWS infra provider, or IRSA — no credentials needed)
AWS_ACCESS_KEY_ID=xxx
AWS_SECRET_ACCESS_KEY=xxx

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
  platform-config/    # Always — shared config (gw-int + gw-ext Gateways with ${gateway_class_name}, wildcard TLS)

  # DNS-provider kustomizations — exactly one deployed per cluster (independent of infra provider)
  dns/
    digitalocean/     # ClusterIssuers (DO solver), DNS Secret, external-dns values patch
    cloudflare/       # ClusterIssuers (CF solver), DNS Secret, external-dns values patch
    route53/          # ClusterIssuers (Route53 solver), DNS Secret, external-dns values patch
    clouddns/         # ClusterIssuers (Cloud DNS solver), DNS Secret, external-dns values patch
    rfc2136/          # ClusterIssuers (rfc2136 solver), DNS Secret, external-dns values patch
    designate/        # ClusterIssuers (Designate webhook solver), DNS Secret, external-dns values patch

  # Vendor-specific kustomizations — exactly one deployed per cluster (infra gap-fillers)
  talos/              # Talos (Proxmox, OpenStack): Cilium, LB-IPAM, OpenEBS, MinIO, Harbor
  aws/                # AWS: Cilium (BYOCNI)
  gcp/                # GCP: (minimal — GKE manages Cilium, storage, LB)

  # Role-specific (unchanged)
  cc/                 # CC operators (vault-operator) + namespace definitions
  cc-config/          # CC services (Vault CR, SecretStore) — provider-agnostic only
  cc-routes/          # CC HTTPRoutes (vault, and conditionally harbor, minio)
  env/                # Env operators (Strimzi, Percona, Redis, Vault)
  env-data/           # Self-hosted env only: data layer CRs (MySQL, Kafka, MongoDB, Redis)
  env-auth/           # Auth layer (Keycloak, Ory stack)
  env-app/            # Mojaloop core app (MCM, Finance Portal, DFSP mTLS partner edge)
```

Two independent provider dimensions determine which kustomizations are deployed:
- **Infrastructure provider** (`infra.provider`) selects the vendor kustomization — holds Cilium (if self-managed), LB config, storage/registry gap-fillers
- **DNS provider** (`dns.provider`) selects the DNS kustomization — holds ClusterIssuers, DNS credential Secret, external-dns values patch

This separation means any combination works (e.g. Proxmox + Cloudflare, AWS + DigitalOcean DNS). Adding a new DNS provider requires only a new `dns/{provider}/` directory — zero Terraform changes. Adding a new infra provider requires a new vendor kustomization + Terraform module.

GatewayClass is not in the artifact. It is auto-created by Cilium — either by the self-managed HelmRelease (`gatewayAPI.enabled: true`) or by the cloud-managed Cilium installation. On GCP, GKE provides its own GatewayClasses backed by Google Cloud Load Balancers.

**Deployment matrix:**

| Cluster | Infra | DNS | Kustomizations | Notes |
|---------|-------|-----|---------------|-------|
| CC | Proxmox | digitalocean | platform → dns/digitalocean → platform-config → talos → cc → cc-config → cc-routes | talos: Cilium, LB-IPAM, OpenEBS, MinIO, Harbor |
| CC | Proxmox | cloudflare | platform → dns/cloudflare → platform-config → talos → cc → cc-config → cc-routes | Same infra, different DNS — works seamlessly |
| CC | AWS | route53 | platform → dns/route53 → platform-config → aws → cc → cc-config → cc-routes | aws: Cilium (BYOCNI); uses EBS + S3 + ECR |
| CC | GCP | clouddns | platform → dns/clouddns → platform-config → gcp → cc → cc-config → cc-routes | gcp: minimal; GKE manages Cilium + storage |
| Env | Proxmox | digitalocean | platform → dns/digitalocean → platform-config → talos → env → env-data → env-auth → env-app | env-data: in-cluster MySQL, Kafka, MongoDB, Redis |
| Env | AWS | route53 | platform → dns/route53 → platform-config → aws → env → env-auth → env-app | No env-data — uses RDS, MSK, DocumentDB, ElastiCache |

**Dependency chain:**

```
platform → dns/{dns_provider} → platform-config → vendor (talos|aws|gcp)
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
Once the cluster is running and Flux is reconciling, a Cilium HelmRelease in the vendor kustomization (`talos/`) takes over management. Flux adopts the existing Cilium installation, enabling version upgrades, configuration changes, and Helm values management through GitOps.

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
| Proxmox | Self-managed: Talos extraManifests → Flux HelmRelease (`talos/`) | `cilium` | Auto-created by Cilium Helm (`gatewayAPI.enabled`) | Installed via Talos extraManifests |
| OpenStack | Self-managed: Talos extraManifests → Flux HelmRelease (`talos/`) | `cilium` | Auto-created by Cilium Helm (`gatewayAPI.enabled`) | Installed via Talos extraManifests |
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
| Harbor | Local OCI registry + pull-through cache | Vendor kustomization (`talos/`) | Not deployed — uses ECR (AWS) or Artifact Registry (GCP) |
| MinIO | S3-compatible object storage | Vendor kustomization (`talos/`) | Not deployed — uses S3 (AWS) or GCS (GCP) |
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
- Proxmox (`talos/`): Cilium HelmRelease, LB-IPAM, OpenEBS, MinIO, Harbor, ClusterIssuers
- OpenStack (`talos/`): same as Proxmox — Cilium, LB-IPAM, OpenEBS, Harbor; all Talos providers share one kustomization
- AWS (`aws/`): Cilium BYOCNI, ClusterIssuers (Route53); uses EBS, S3, ECR from Terraform
- GCP (`gcp/`): ClusterIssuers (Cloud DNS) only; GKE manages Cilium, storage, and LB natively

**Data layer (env clusters):**
- Self-hosted profile (Proxmox, OpenStack): `env-data/` kustomization deploys in-cluster MySQL (Percona), Kafka (Strimzi), MongoDB (Percona), Redis
- Managed profile (AWS, GCP): Terraform provisions RDS/Cloud SQL, MSK/Managed Kafka, DocumentDB/Atlas, ElastiCache/Memorystore and passes endpoints to GitOps via ConfigMap substitution. `env-data/` is not deployed.

**Partner connectivity:**
- Internal traffic: Cilium with network policies
- External partners: CiliumEnvoyConfig for inbound + outbound mTLS (see Partner Edge section below)

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

| Function | Talos — Proxmox, OpenStack (`talos/`) | AWS (`aws/`) | GCP (`gcp/`) |
|----------|----------------------------------------|-------------|-------------|
| **Cilium HelmRelease** | Full install: `gatewayAPI.enabled`, `lbIPAM.enabled`, `l2announcements` | BYOCNI install: `gatewayAPI.enabled`, replaces VPC-CNI | Not deployed — managed by GKE Dataplane V2 |
| **LB-IPAM pools** | `CiliumLoadBalancerIPPool` + L2 announcement policy | Not deployed — AWS Cloud LB | Not deployed — GKE Cloud LB |
| **Storage provisioner** | OpenEBS hostpath HelmRelease | Not deployed — EBS CSI is EKS add-on (IaC) | Not deployed — PD CSI auto-installed by GKE |
| **MinIO** | Standalone MinIO HelmRelease | Not deployed — S3 bucket created by IaC | Not deployed — GCS bucket created by IaC |
| **Harbor** | Harbor HelmRelease + proxy cache setup Job | Not deployed — ECR created by IaC | Not deployed — Artifact Registry created by IaC |
| **ClusterIssuers** | `dns/{provider}` kustomization (independent of infra) | `dns/{provider}` kustomization | `dns/{provider}` kustomization |
| **DNS credential Secret** | `dns/{provider}` kustomization | `dns/{provider}` kustomization | `dns/{provider}` kustomization |

### GitOps Layer — Generic (All Providers)

These kustomizations are provider-agnostic and consume substitution variables from the IaC-generated ConfigMap/Secret.

| Kustomization | Contents | Parameterization |
|--------------|----------|------------------|
| `platform/` | metrics-server, external-dns (base, no provider config), cert-manager, ESO | `${dns_provider}` (provider name only) |
| `dns/{provider}` | ClusterIssuers (prod + staging), DNS credential Secret, external-dns values patch | DNS credentials from `cluster-secrets` (provider-specific keys) |
| `platform-config/` | gw-int + gw-ext Gateways with wildcard TLS | `${gateway_class_name}`, `${domain}` |
| `cc/` | vault-operator, namespace definitions | None |
| `cc-config/` | Vault CR, ESO SecretStore | `${domain}` |
| `cc-routes/` | HTTPRoutes for vault (and conditionally harbor, minio) | `${domain}` |
| `env/` | Strimzi, Percona XtraDB, Percona MongoDB, Redis operators, Vault operator | None |
| `env-data/` | Data layer CRs (MySQL, Kafka, MongoDB, Redis clusters) | Database passwords via `cluster-secrets` |
| `env-auth/` | Keycloak, Ory stack (Kratos, Keto, Oathkeeper), Vault CR, HTTPRoutes | `${domain}`, auth DB endpoints, OIDC secrets |
| `env-app/` | Mojaloop core, MCM, Finance Portal, DFSP mTLS partner edge | Data endpoints, `${domain}` |

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

### Three-LB Architecture

Each App Environment uses three LoadBalancer IPs with distinct security profiles:

```
                            App Environment
  ┌──────────────────────────────────────────────────────────────────────────┐
  │                                                                          │
  │   gw-int (operators)        gw-ext (DFSPs — no mTLS)     gw-extapi     │
  │   *.int.${domain} :443      *.ext.${domain} :443          (Envoy       │
  │   TLS termination           TLS termination               Deployment   │
  │   IP: A (LB-IPAM)          IP: B (LB-IPAM)               — mTLS)      │
  │     │                        │                            extapi.      │
  │     ├── ttk.int.            ├── mcm.ext.                  ${domain}:443│
  │     ├── settlement.int.      ├── keycloak.ext.            IP: C        │
  │     ├── intapi.int.          │                            (LB-IPAM)    │
  │     └── simulator.int.       │                               │         │
  │           │                  │                      ┌────────┼────────┐ │
  │     Oathkeeper → services    │                      ▼        ▼        ▼ │
  │                              │                  account-  quoting  ml-api│
  │                              │                  lookup    service  adapter│
  │                              │                  service           (inbound)
  │                              │                                          │
  │                              │                   ▼        ▼        ▼    │
  │                              │               account-  quoting  notif.  │
  │                              │               lookup    handler  handler  │
  │                              │               handler     │        │     │
  │                              │                   └───────┼────────┘     │
  │                              │                           ▼              │
  │                              │                 dfsp-callback-mtls (CEC) │
  │                              │                   Cilium Envoy DaemonSet │
  │                              │                           │              │
  └──────────────────────────────┼───────────────────────────┼──────────────┘
                                                             │ mTLS
                                                             ▼
                                                       Partner DFSPs
```

| LoadBalancer | Audience | Hostname pattern | TLS mode | Backend |
|-------------|----------|-----------------|----------|---------|
| `gw-int` | Hub operators, admin UIs | `*.int.${domain}` | TLS termination (SIMPLE) | Oathkeeper → internal services |
| `gw-ext` | DFSPs (non-mTLS services) | `*.ext.${domain}` | TLS termination (SIMPLE) | MCM pm4mlapi, Keycloak OIDC |
| `cilium-gateway-gw-extapi` | DFSPs (FSPIOP APIs) | `extapi.${domain}` | **mTLS** (client cert required) | Standalone Envoy Deployment → account-lookup, quoting, ml-api-adapter, transaction-requests |

**Why three LBs instead of two?** Gateway API does not support `tls.mode: Mutual` — the HTTPS listener only supports `Terminate` (SIMPLE TLS). The extapi endpoint requires mTLS with Vault PKI certificates (not Let's Encrypt), so it cannot share a Gateway with gw-int or gw-ext. A standalone Envoy Deployment handles mTLS termination behind its own LoadBalancer Service.

Both `gw-int` and `gw-ext` Gateways are defined in `platform-config/` (deployed on all clusters). The extapi Envoy Deployment and its supporting resources are defined in `env-app/routes/` (deployed only on env clusters).

### Mojaloop PKI Model

Mojaloop mandates a **single shared scheme CA** for all participants. This simplifies the mTLS architecture:

| Property | Value |
|----------|-------|
| CA model | Single scheme-level CA (private, not public) |
| CA key | RSA 4096-bit, sha512WithRSAEncryption, 10-year validity |
| Platform certs | RSA 2048-bit minimum, sha256WithRSAEncryption, 2-year validity |
| Cert types per participant | TLS (transport), JWS (signing), JWE (encryption) — no key reuse |
| CA management | Vault PKI secrets engine, operated via MCM |

All DFSPs and the Hub receive certificates from the same CA. The `dfsp-ca-bundle` Secret (vault-agent rendered) concatenates all DFSP CA bundles — this handles both single-CA deployments (same cert repeated, harmless) and multi-CA deployments (multiple intermediate CAs from the scheme CA chain).

**Vault PKI roles:**

| Role | Purpose | Flags | Consumer |
|------|---------|-------|----------|
| `server-cert-role` | Hub server cert for extapi endpoint | `serverFlag: true`, `clientFlag: false` | cert-manager `ClusterIssuer` (`vault-pki-issuer`) → `extapi-tls` Certificate |
| `client-cert-role` | Hub client certs for outbound callbacks to DFSPs | `serverFlag: false`, `clientFlag: true` | MCM → Vault KV → Vault Agent → per-DFSP `{host}-clientcert-tls` Secrets |

**cert-manager integration:** A `ClusterIssuer` (`vault-pki-issuer`) is backed by the Vault PKI engine and uses `server-cert-role` to issue the Hub server cert. cert-manager handles automatic renewal. The wildcard certs for `gw-int` and `gw-ext` continue to use Let's Encrypt (public CA) — only the extapi mTLS endpoint uses the scheme CA.

### CA Rotation (Planned, Zero-Downtime)

CA rotation is a **manual, coordinated** multi-party process — MCM orchestrates, never automated. Zero-downtime is achieved by ensuring both old and new CAs are trusted before any cert is re-issued.

```
Phase 1: Prepare
  - New CA created alongside old CA in Vault PKI
  - No cert changes yet — Hub and DFSPs still use old-CA certs

Phase 2: Update trust bundles
  - dfsp-ca-bundle updated to include both old + new CA
  - DFSPs update their trust stores to include new CA
  - All parties now trust BOTH CAs → safe to switch certs

Phase 3: Re-issue certs
  - Hub server cert re-issued under new CA (cert-manager auto-renewal picks it up)
  - DFSP client certs re-issued under new CA via MCM
  - Each re-issue is atomic (old cert → new cert), but safe because both CAs are trusted

Phase 4: Cleanup
  - Remove old CA from all trust bundles
  - Old CA decommissioned
```

The critical invariant: **trust bundles are updated before certs are re-issued**. The cert swap itself is instantaneous (K8s Secret update → Envoy `watched_directory` hot-reload for inbound, Cilium SDS hot-reload for outbound), but it never breaks a handshake because the other side already trusts both CAs.

### Security Layers

Five security layers protect Hub–DFSP communication:

| Layer | Mechanism | Scope |
|-------|-----------|-------|
| **1. mTLS** | X.509 mutual certificate authentication (TLSv1.2+) | Transport — both directions |
| **2. JWS** | JSON Web Signatures (RFC 7515) on HTTP request bodies | Message integrity — requests only (not responses) |
| **3. IP whitelisting** | Deferred — mTLS client cert verification is the primary security boundary | Network — future enhancement |
| **4. OAuth 2.0** | API authorization (Keycloak OIDC) | Application — inbound only |
| **5. ILP** | Interledger Protocol cryptographic transfer proof | Transfer integrity — end-to-end |

JWS provides **end-to-end integrity** — even the Hub cannot modify a message body without detection. The `FSPIOP-Signature` HTTP header carries the detached JWS. Protected headers include `FSPIOP-URI`, `FSPIOP-HTTP-Method`, `FSPIOP-Source`, and `FSPIOP-Destination`.

### Inbound Flow (DFSP → Hub)

Inbound mTLS is handled by a **standalone Envoy Deployment** (2 replicas) behind a dedicated LoadBalancer Service. This is static infrastructure — configured via GitOps, not per-DFSP.

```
DFSP ──mTLS──▶ cilium-gateway-gw-extapi Service (LB IP C, port 443)
                │
                │  Normal K8s service routing (selector: app=extapi-envoy)
                │
                ▼
              Envoy Deployment: extapi-envoy (2 replicas, port 8443)
                │
                │  DownstreamTlsContext:
                │  1. Hub presents extapi-tls cert (cert-manager, Vault PKI scheme CA)
                │  2. Requests DFSP client certificate
                │  3. Validates client cert against dfsp-ca-bundle (vault-agent rendered)
                │  4. require_client_certificate: true
                │
                ▼
              HTTP Connection Manager — path-based routing:
                │
                ├── /participants        → moja-account-lookup-service:80        (Discovery)
                ├── /parties             → moja-account-lookup-service:80        (Discovery)
                ├── /quotes              → moja-quoting-service:80               (Agreement)
                ├── /fxQuotes            → moja-quoting-service:80               (Agreement)
                ├── /transfers           → moja-ml-api-adapter-service:80        (Transfer)
                ├── /fxTransfers         → moja-ml-api-adapter-service:80        (Transfer)
                ├── /transactionRequests → moja-transaction-requests-service:80
                └── /authorizations      → moja-transaction-requests-service:80
```

All FSPIOP endpoints share the **same mTLS handshake** — one `dfsp-ca-bundle`, one hub server cert, one Envoy listener. Per-DFSP identity is established at the TLS layer (client cert CN/SAN), not per-service.

**Why standalone Envoy instead of CiliumEnvoyConfig?** Cilium v1.18's CEC classifies all `spec.services` listeners as "east/west L7 LB" in the BPF data plane. External traffic (from DFSPs outside the cluster) has no Cilium pod identity, causing Cilium's mandatory `cilium.l7policy` filter to reject requests with HTTP 500. Gateway API resources use a separate "north/south" BPF path that handles external traffic correctly, but Gateway API does not support `tls.mode: Mutual`. A standalone Envoy Deployment bypasses Cilium's BPF L7 redirect entirely — traffic flows through normal K8s service routing to real pod endpoints.

**Envoy resources** (`env-app/routes/`):

- **`extapi-envoy-config.yaml`** — ConfigMap with Envoy bootstrap config: listener on `0.0.0.0:8443`, `DownstreamTlsContext` with `require_client_certificate: true`, path-based routing, `STRICT_DNS` clusters pointing to K8s service DNS names
- **`extapi-envoy-deployment.yaml`** — Deployment (2 replicas, `envoyproxy/envoy`), mounts `extapi-tls` and `dfsp-ca-bundle` Secrets as volumes
- **`extapi-service.yaml`** — LoadBalancer Service with `selector: {app: extapi-envoy}`, port 443 → targetPort 8443
- **`extapi-cert.yaml`** — cert-manager Certificate (Vault PKI scheme CA), unchanged

Secrets are mounted as volumes (not Cilium SDS). Envoy watches the filesystem via `watched_directory` and hot-reloads certificates when K8s updates the mounted Secret volumes — zero-downtime cert and CA bundle rotation.

**Outbound mTLS (Hub → DFSP) continues to use CiliumEnvoyConfig** — the `dfsp-callback-mtls` CEC handles pod-to-pod traffic where Cilium's east/west path is correct.

### Outbound Flow (Hub → DFSP)

Outbound is architecturally harder: the Hub sends callbacks to **dynamic DFSP endpoints** (any domain, registered at runtime via MCM) and must present **per-DFSP client certificates**. CiliumEnvoyConfig + CiliumNetworkPolicy handle this transparently — zero additional pods.

**All three phases** produce outbound callbacks — each has a dedicated handler service that sends HTTP callbacks to the DFSP's registered callback URL:

| Phase | Handler service | Callback example | Kafka topic |
|-------|----------------|------------------|-------------|
| **Discovery** | `account-lookup-service` (inline) | `PUT /parties/{Type}/{ID}` | N/A (synchronous) |
| **Agreement** | `quoting-service` (inline) | `PUT /quotes/{ID}` | N/A (synchronous) |
| **Transfer** | `ml-api-adapter-handler-notification` | `PUT /transfers/{ID}` | `topic-notification-event` |

Handler services send plain HTTP to DFSP FQDNs. The CiliumNetworkPolicy intercepts this egress traffic and redirects it through the CEC's Envoy listener, which originates mTLS transparently.

```
account-lookup-service  ─┐
quoting-service          ─┤  HTTP to dfsp.fqdn (plain, no TLS awareness)
notification-handler     ─┘
    │
    │  CiliumNetworkPolicy: dfsp-callback-egress
    │  endpointSelector: {} (all pods in mojaloop namespace)
    │  toFQDNs: [all enrolled DFSP FQDNs]
    │  listener: → dfsp-callback-mtls CEC
    │
    ▼
CiliumEnvoyConfig: dfsp-callback-mtls (Cilium Envoy DaemonSet)
    │
    │  Route config: virtual hosts per DFSP
    │  Matches on Host header (DFSP FQDN) → per-DFSP Envoy cluster
    │
    │  Per-DFSP cluster: STRICT_DNS → dfsp.fqdn:443
    │  UpstreamTlsContext (MUTUAL):
    │    - client cert: mojaloop/{host}-clientcert-tls (SDS)
    │    - SNI: dfsp.fqdn
    │
    ▼
dfsp.fqdn:443 (mTLS established)
```

**Key design decisions:**

- **All handler services** send plain HTTP. They have zero TLS awareness — mTLS is entirely infrastructure-managed via CiliumNetworkPolicy egress interception. DFSP onboarding enables mTLS for all three phases simultaneously.
- **Routing uses the Host header** (DFSP FQDN) to select the per-DFSP upstream cluster and cert. The CiliumNetworkPolicy `listener` field transparently redirects matching egress traffic through the CEC.
- **Zero additional pods** — Cilium's existing Envoy DaemonSet (via CiliumEnvoyConfig) handles all mTLS origination. No standalone Envoy deployment, no egress proxy pod.
- **CiliumNetworkPolicy with `toFQDNs` + `listener`** is the key primitive: it intercepts egress to specific FQDNs and redirects through the CEC's Envoy for mTLS origination.

### Dynamic Resource Generation (Vault Agent)

DFSPs are onboarded dynamically via MCM. A Vault Agent Deployment in the `mcm` namespace watches `secret/onboarding_pm4mls/` in Vault KV and `kubectl apply`s resources whenever the DFSP list changes.

```
MCM onboards DFSP-A
    │
    ▼
Vault PKI: issue client cert (client-cert-role)
Vault KV:  store at secret/onboarding_pm4mls/dfspA
           (host, fqdn, client_cert, client_key, ca_bundle, currency)
    │
    ▼
Vault Agent Deployment (mcm namespace, periodic re-render ~5 min)

Template 1 — callback.yaml:
{{ range secrets "secret/onboarding_pm4mls/" }}
    │
    │  kubectl apply --prune -l vault-agent/template=callback
    │  --prune-allowlist: Secret, CiliumEnvoyConfig, CiliumNetworkPolicy
    │
    ├──▶ K8s Secret: {host}-clientcert-tls (mojaloop namespace)
    │      type: kubernetes.io/tls (ca.crt, tls.key, tls.crt)
    │      Per-DFSP client cert for outbound mTLS origination
    │
    ├──▶ K8s Secret: dfsp-ca-bundle (mojaloop namespace)
    │      Concatenation of all DFSP ca_bundle fields
    │      Referenced by inbound extapi-envoy Deployment for client verification
    │
    ├──▶ CiliumEnvoyConfig: dfsp-callback-mtls (mojaloop namespace)
    │      Listener: accepts redirected egress traffic
    │      Per-DFSP virtual hosts (matched by Host header/FQDN)
    │      Per-DFSP upstream clusters: STRICT_DNS → dfsp-fqdn:443
    │      Per-DFSP UpstreamTlsContext with cert via Cilium SDS
    │
    └──▶ CiliumNetworkPolicy: dfsp-callback-egress (mojaloop namespace)
           endpointSelector: {} (all pods)
           toFQDNs: [all DFSP FQDNs]
           listener: → dfsp-callback-mtls CEC

Template 2 — onboarding.yaml:
{{ range secrets "secret/onboarding_pm4mls/" }}
    │
    │  kubectl apply --prune -l vault-agent/template=onboarding
    │
    ├──▶ ConfigMap: {host}-ml-ttk-add-dfsp-conf
    │      TTK CLI config with DFSP-specific provisioning parameters
    │
    └──▶ Job: {host}-onboard-dfsp-{timestamp}
           Runs TTK CLI to provision DFSP in central-ledger
           (create participant, set limits, fund settlement, register callbacks)
```

The Vault Agent Deployment has its own ServiceAccount (`vault-agent` in `mcm` namespace) with RBAC permissions to create/manage Secrets, ConfigMaps, Jobs, CiliumEnvoyConfigs, and CiliumNetworkPolicies in the `mojaloop` namespace (see `vault-agent-rbac.yaml`).

**Prune strategy:** `kubectl apply --prune` with label selector `vault-agent/template=callback` automatically removes resources for DFSPs that were de-enrolled from Vault. When no DFSPs are enrolled, the template renders empty and the fallback deletes all labeled resources.

ESO is **not used** for per-DFSP secrets — ESO requires static `ExternalSecret` manifests, which cannot handle the dynamic DFSP list. The Vault Agent template creates K8s Secrets directly via `kubectl apply`, with the cert data already available in the template context. Cilium SDS watches these Secrets and hot-pushes them to Envoy — zero-downtime cert rotation.

### Certificate Lifecycle

| Certificate | Issued by | Stored in | Synced to K8s via | Consumed by | Rotation |
|-------------|-----------|-----------|-------------------|-------------|----------|
| Hub server cert (`extapi-tls`) | cert-manager → Vault PKI (`server-cert-role`) | K8s Secret (cert-manager managed) | cert-manager (auto-renewal) | `extapi-envoy` Deployment (volume mount + `watched_directory`) | Automatic (cert-manager) |
| Hub client cert per-DFSP (`{host}-clientcert-tls`) | MCM → Vault PKI → Vault KV | Vault KV at `secret/onboarding_pm4mls/{dfsp}` | Vault Agent template (`kubectl apply`) | `dfsp-callback-mtls` CEC (Cilium SDS) | Vault Agent re-renders on KV change |
| DFSP CA bundle (`dfsp-ca-bundle`) | Concatenation of per-DFSP `ca_bundle` fields | Vault KV (per-DFSP) → combined by Vault Agent | Vault Agent template (`kubectl apply`) | `extapi-envoy` Deployment (volume mount + `watched_directory`) | Vault Agent re-renders on DFSP change |
| DFSP JWS public keys | Provided by DFSPs during onboarding | Vault KV at `secret/mcm/{dfsp}` | Vault Agent template or application config | ml-api-adapter (JWS verification) | On DFSP key rotation via MCM |

### Components

| Component | Deployed by | Namespace | Role in partner edge |
|-----------|-------------|-----------|---------------------|
| **Vault** (PKI + KV) | `env-auth/` | vault | Issues hub certs, stores per-DFSP cert bundles |
| **MCM** | `env-app/` | mcm | DFSP onboarding portal. Calls Vault PKI, writes cert bundles to KV |
| **Vault Agent** (Deployment) | `env-app/` | mcm | Watches Vault KV, generates per-DFSP K8s/Cilium resources via template + `kubectl apply` |
| **cert-manager** | `platform/` | cert-manager | Issues wildcard certs (Let's Encrypt) for gw-int/gw-ext; issues `extapi-tls` server cert from Vault PKI scheme CA with auto-renewal |
| **gw-ext** (Gateway) | `platform-config/` | platform-system | SIMPLE TLS for DFSP-facing non-mTLS services (MCM pm4mlapi, Keycloak OIDC) |
| **extapi-envoy** (Deployment + Service) | `env-app/routes/` | mojaloop | Inbound mTLS: standalone Envoy Deployment + LoadBalancer Service + Certificate |
| **dfsp-callback-mtls** (CEC) | Dynamic (Vault Agent) | mojaloop | Outbound mTLS: per-DFSP upstream clusters with mTLS origination |
| **dfsp-callback-egress** (CNP) | Dynamic (Vault Agent) | mojaloop | Redirects egress to DFSP FQDNs through CEC for mTLS origination |

### GitOps Placement

All partner edge resources live in `env-app/` — there is no separate `env-edge/` kustomization.

```
gitops/
  platform-config/
    gateway/
      gateway.yaml                         # gw-int: *.int.${domain} (internal ops)
      gateway-ext.yaml                     # gw-ext: *.ext.${domain} (DFSP non-mTLS)
  env-app/
    routes/
      extapi-service.yaml                  # LoadBalancer Service for mTLS inbound (selector: extapi-envoy)
      extapi-cert.yaml                     # cert-manager Certificate (Vault PKI scheme CA)
      extapi-envoy-config.yaml             # ConfigMap: Envoy bootstrap config (mTLS + routing)
      extapi-envoy-deployment.yaml         # Deployment: standalone Envoy (2 replicas)
      mcm-ext-httproute.yaml               # MCM → gw-ext (SIMPLE TLS)
      keycloak-ext-httproute.yaml          # Keycloak → gw-ext (SIMPLE TLS)
      referencegrant-ext.yaml              # ReferenceGrant for gw-ext cross-namespace
    mcm/
      vault-agent-configmap.yaml           # Vault Agent HCL templates (callback + onboarding)
      vault-agent-deployment.yaml          # Vault Agent Deployment
      vault-agent-rbac.yaml                # RBAC: vault-agent SA → mojaloop namespace
```

Dynamic resources (K8s Secrets, CiliumEnvoyConfig, CiliumNetworkPolicy, onboarding Jobs) are generated at runtime by the Vault Agent, not at artifact build time. The `dfsp-ca-bundle` Secret is also consumed by the static `extapi-envoy` Deployment via volume mount.

**Dependency chain for env clusters:**

```
platform → platform-config → vendor → env → env-data → env-auth → env-auth-config → env-app
                                                                                        │
                                                          extapi-envoy Deployment (needs cert-manager + dfsp-ca-bundle)
                                                          gw-ext Gateway (needs cert-manager)
                                                          Vault Agent (needs Vault from env-auth)
                                                          Vault Agent generates dynamic resources
```

### Static vs Dynamic Resources

| Resource | Type | Creator | Lifecycle |
|----------|------|---------|-----------|
| `gw-ext` Gateway | Static | GitOps (`platform-config/`) | Deployed once, updated via artifact |
| `cilium-gateway-gw-extapi` Service | Static | GitOps (`env-app/routes/`) | Deployed once |
| `extapi-tls` Certificate | Static | GitOps (`env-app/routes/`) + cert-manager | Auto-renewed |
| `extapi-envoy` Deployment + ConfigMap (inbound) | Static | GitOps (`env-app/routes/`) | Deployed once |
| `mcm-ext` HTTPRoute | Static | GitOps (`env-app/routes/`) | Deployed once |
| `keycloak-ext` HTTPRoute | Static | GitOps (`env-app/routes/`) | Deployed once |
| Per-DFSP TLS Secrets | **Dynamic** | Vault Agent template | Created/updated on DFSP onboarding |
| `dfsp-ca-bundle` Secret | **Dynamic** | Vault Agent template | Regenerated on every DFSP change |
| `dfsp-callback-mtls` CEC (outbound) | **Dynamic** | Vault Agent template | Regenerated on every DFSP change |
| `dfsp-callback-egress` CNP | **Dynamic** | Vault Agent template | Regenerated on every DFSP change |
| Per-DFSP onboarding ConfigMaps | **Dynamic** | Vault Agent template | Created per DFSP |
| Per-DFSP onboarding Jobs | **Dynamic** | Vault Agent template | One-shot per DFSP |

### What Is NOT Deployed

- **No Istio / service mesh** — removed entirely; Cilium + standalone Envoy provide all needed L7 features
- **No Envoy Gateway controller** — Gateway API (for gw-int/gw-ext) + standalone Envoy (for extapi mTLS) + CiliumEnvoyConfig (for outbound mTLS) covers all use cases
- **No custom xDS control plane** — Cilium acts as the xDS control plane for outbound CEC; standalone Envoy uses file-based config with `watched_directory` for cert hot-reload
- **No per-DFSP Gateway listeners** — single `extapi-envoy` listener with combined CA bundle validates all DFSPs; per-DFSP routing is Host-header-based in the outbound CEC
- **No ESO for dynamic per-DFSP secrets** — ESO requires static manifests; Vault Agent template handles dynamic cert sync directly
- **No egress proxy pod** — CiliumNetworkPolicy `listener` field transparently redirects egress through CEC's Envoy
- **No CiliumEnvoyConfig for inbound mTLS** — Cilium CEC's east/west BPF path rejects external traffic (no pod identity); standalone Envoy Deployment handles inbound mTLS instead
- **No IP whitelisting** (deferred) — mTLS client cert verification is the primary security boundary; IP whitelisting can be added later as an Envoy RBAC filter
- **No CiliumEgressGatewayPolicy** (deferred) — consistent source IP for outbound callbacks not yet implemented

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

### Stateful Services and Backup Strategy

App Environment clusters have five stateful services. Each has a different backup mechanism and criticality level:

| Service | Operator | Replicas | Storage | Backup Method | Restore Method | Criticality |
|---------|----------|----------|---------|---------------|----------------|-------------|
| **MySQL (PXC)** | Percona XtraDB | 1 + HAProxy | 8Gi | Operator-native: XtraBackup → S3 (scheduled) | `PerconaXtraDBClusterRestore` CR | **High** — all transactional data |
| **MongoDB (PSMDB)** | Percona MongoDB | 3 (replica set) | 3Gi × 3 | Operator-native: pbm logical → S3 (scheduled) | `PerconaServerMongoDBRestore` CR | **High** — bulk/reporting data |
| **Vault** | bank-vaults | 1 | 1Gi | Raft snapshots → S3 (CronJob) | `vault operator raft snapshot restore` | **High** — DFSP certs, PKI, secrets |
| **Kafka** | Strimzi | 3 (KRaft) | 8Gi × 3 | None needed — transient message queue | Redeploy (topics declarative via TopicOperator) | **Low** — no persistent business state |
| **Redis** | OT Redis | 1 | 1Gi | None needed — TTK cache only | Redeploy | **None** — ephemeral cache |

Additional non-service state:

| Component | Location | Backup Method | Criticality |
|-----------|----------|---------------|-------------|
| Recovery Kit | Offline physical safe | Manual (generated at bootstrap) | **Critical** — contains unseal keys |
| Terraform state | CC object store (MinIO on-prem, S3/GCS on cloud) | Object storage replication | **High** |
| GitOps artifact | OCI registry (GHCR, Harbor) | OCI registry replication | **Medium** — rebuildable from source |

### Backup Architecture

Backups are **automatic and continuous** — the backup configuration is part of the gitops artifact and deploys with `make push-gitops` + `make plan-apply`. No manual setup is needed after initial deployment.

```
                    App Environment (env cluster)
  ┌─────────────────────────────────────────────────────────────────┐
  │                                                                 │
  │   MySQL (PXC)          MongoDB (PSMDB)         Vault           │
  │   spec.backup:         spec.backup:            CronJob:        │
  │     schedule: daily      tasks: daily            schedule: daily│
  │     storage: s3-minio    storage: s3-minio       raft snapshot  │
  │     keep: 7              keep: 7                 → upload to S3 │
  │         │                    │                        │         │
  └─────────┼────────────────────┼────────────────────────┼─────────┘
            │                    │                        │
            ▼                    ▼                        ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │                     MinIO (CC cluster)                          │
  │                                                                 │
  │   mysql-backups/          mongodb-backups/     vault-snapshots/ │
  │     daily-full-2026-02-23   daily-logical-...   vault-2026-...  │
  │     daily-full-2026-02-22   daily-logical-...   vault-2026-...  │
  │     ...                     ...                  ...            │
  │                                                                 │
  │   Retention: 7 days (operator-managed for MySQL/MongoDB,       │
  │              CronJob-managed for Vault)                         │
  └─────────────────────────────────────────────────────────────────┘
```

**S3 credentials flow:** MinIO credentials are stored in CC Vault → ESO syncs them to a `minio-s3-credentials` Secret in the `mojaloop` namespace → Percona operators and the Vault backup CronJob read from this Secret.

On **managed cloud providers** (AWS, GCP), MinIO is replaced by native S3/GCS. The backup configuration uses the same `s3` storage type — only the endpoint URL and credentials change (via Flux substitution variables).

### Backup Configuration (GitOps)

Backup schedules and retention are configured declaratively in the CRs and deploy automatically:

**MySQL** — `spec.backup` in `gitops/env-data/mysql/mojaloop-db.yaml`:
- XtraBackup to S3 (hot backup, no downtime)
- Scheduled via operator (cron expression in CR)
- Retention managed by operator (`keep: N`)

**MongoDB** — `spec.backup` in `gitops/env-data/mongodb/bulk-mongodb.yaml`:
- Percona Backup for MongoDB (pbm) logical backup to S3
- Scheduled via operator (cron expression in CR)
- Retention managed by operator (`keep: N`)

**Vault** — CronJob in `gitops/env-auth/vault/`:
- `vault operator raft snapshot save` (atomic, consistent)
- Upload to MinIO/S3 via CLI
- Retention managed by CronJob (delete old snapshots)
- Requires migration from `file` → `raft` storage backend

**Kafka and Redis** do not need backup:
- Kafka topics are transient message queues; topic definitions are declarative (Strimzi TopicOperator) and recreated from gitops. Data replication factor 3 with min ISR 2 handles node failures.
- Redis is a TTK cache with no persistent business state.

### Restore Workflow

Restore is a **manual, deliberate operation** — never automatic during deployment. It is invoked separately after infrastructure is running:

```bash
make plan-apply ENV=ml-test              # 1. Deploy fresh infrastructure
                                          #    Flux reconciles: operators install,
                                          #    CRs create empty databases,
                                          #    Vault bootstraps from externalConfig

make restore ENV=ml-test                  # 2. Restore all services from latest backup
make restore ENV=ml-test SVC=mysql        # 2. Or restore only MySQL
make restore ENV=ml-test SVC=vault BACKUP=2026-02-20  # 2. Or restore specific backup
```

**Why restore is separate from deploy:**
- Restore is destructive — it overwrites current data with a backup snapshot
- Different services may need different restore points
- A fresh deploy without restore is valid — declarative config (`externalConfig`, `startupSecrets`, operator CR `users[]`) bootstraps everything; only runtime state (enrolled DFSPs, issued certs) is lost
- Restore requires operators and CRs to be ready (deployment must complete first)

**Restore order matters** — services have dependencies:

```
1. Vault (restore first — other services depend on its secrets)
     ↓
2. MySQL + MongoDB (restore in parallel — independent)
     ↓
3. Verify: Mojaloop services reconnect, ESO refreshes secrets
     ↓
4. Vault Agent re-renders DFSP resources (CEC, CNP, Secrets)
```

**Per-service restore mechanism:**

| Service | Restore Mechanism | Downtime |
|---------|------------------|----------|
| **MySQL** | Create `PerconaXtraDBClusterRestore` CR → operator restores from S3 | Brief (cluster restart) |
| **MongoDB** | Create `PerconaServerMongoDBRestore` CR → operator restores from S3 | Brief (replica set restart) |
| **Vault** | `vault operator raft snapshot restore` → overwrites all Vault state | Brief (Vault restart) |

After restore, the bank-vaults operator reconciles Vault's `externalConfig` (policies, auth, secrets engines) on top of the restored data. `startupSecrets` are idempotent and only write if the key doesn't exist.

### Vault Bootstrap vs Restore

Vault has a chicken-and-egg relationship with other services (ESO reads secrets from Vault, MCM writes to Vault). The deployment handles this through layered initialization:

| Layer | Source | Contains | Survives Fresh Deploy? |
|-------|--------|----------|----------------------|
| **1. externalConfig** | GitOps (Vault CR) | Auth methods, policies, secret engines, PKI config, roles | Yes — declarative, always applied |
| **2. startupSecrets** | GitOps (Vault CR) | Initial secrets (Kratos DSN, Keto DSN, Finance Portal) | Yes — idempotent, written if missing |
| **3. Runtime state** | MCM / applications | DFSP onboarding data, issued PKI certs, whitelist entries | **No** — requires restore |

A fresh deploy without restore creates a fully functional environment — you just need to re-onboard DFSPs through MCM. Restore recovers the runtime state so enrolled DFSPs and their certificates are preserved.

### Recovery: Total Loss of App Environment

1. Retrieve terraform state from CC object store
2. `make plan-apply ENV=<env>` — provisions new infrastructure, FluxCD reconciles the full gitops chain
3. Wait for operators and CRs to become ready (~5–10 minutes)
4. `make restore ENV=<env>` — restores MySQL, MongoDB, and Vault from latest S3 backups
5. Verify: Mojaloop services reconnect, Vault Agent re-renders DFSP resources
6. DFSPs can resume operations (mTLS certs restored, callback endpoints preserved)

### Recovery: Total Loss of Control Center

1. Retrieve recovery kit and terraform state from offline storage
2. Provision new CC infrastructure: `make plan-apply ENV=cc`
3. Restore MinIO data from external backup (contains all App Env backups)
4. Unseal Vault with recovery kit keys
5. FluxCD reconciles — CC services (Harbor, Vault, MinIO) come back online
6. App Environments reconnect automatically (OCI source, transit auto-unseal)
