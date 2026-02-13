# Platform Team Guide

## Overview

This guide covers the platform team's responsibilities: building, publishing, and maintaining the OCI artifact that adopters consume via FluxCD. The platform team owns everything under `gitops/` and the platform service definitions — adopters never fork these files.

## Artifact Structure

The OCI artifact is a single package containing multiple directories. Each directory is a Kustomize root that Flux reconciles independently:

```
gitops/
  platform/           # Shared platform services (cert-manager, external-dns, ESO, metrics-server)
  platform-config/    # Shared platform config (Gateway with ${gateway_class_name}, wildcard TLS)

  # Vendor-specific kustomizations — exactly one deployed per cluster
  talos/              # Talos (Proxmox, OpenStack): Cilium, LB-IPAM, OpenEBS, MinIO, Harbor, ClusterIssuers, DNS secret
  aws/                # AWS: Cilium (BYOCNI), ClusterIssuers (Route53), DNS secret
  gcp/                # GCP: ClusterIssuers (Cloud DNS), DNS secret

  # Role-specific
  cc/                 # CC operators (vault-operator) + namespace definitions
  cc-config/          # CC services (Vault CR, SecretStore)
  cc-routes/          # CC HTTPRoutes (vault, and conditionally harbor, minio)
  env/                # Env operators (Strimzi, Percona, Redis, Vault)
  env-data/           # On-prem/OpenStack env only: data layer CRs (MySQL, Kafka, MongoDB, Redis)
  env-auth/           # Auth layer (Keycloak, Ory stack)
  env-app/            # Mojaloop core app (MCM, Finance Portal)
```

Note: GatewayClass is not deployed by the artifact. It is auto-created by Cilium (`gatewayAPI.enabled: true`) or pre-created by the cloud provider (GKE, DOKS). The Gateway in `platform-config/` references `gatewayClassName: ${gateway_class_name}` — set to `cilium` on most providers, or a GKE-specific class on GCP.

**Deployment matrix:**

| Cluster role | Provider | Paths deployed | Order |
|-------------|----------|----------------|-------|
| `cc` | Proxmox | `platform/` → `platform-config/` → `talos/` → `cc/` → `cc-config/` → `cc-routes/` | talos deploys Cilium, LB-IPAM, OpenEBS, MinIO, Harbor, ClusterIssuers |
| `cc` | AWS | `platform/` → `platform-config/` → `aws/` → `cc/` → `cc-config/` → `cc-routes/` | aws deploys Cilium (BYOCNI), ClusterIssuers; uses S3 + ECR from IaC |
| `cc` | GCP | `platform/` → `platform-config/` → `gcp/` → `cc/` → `cc-config/` → `cc-routes/` | gcp deploys ClusterIssuers only; GKE manages Cilium + storage |
| `env` | Proxmox | `platform/` → `platform-config/` → `talos/` → `env/` → `env-data/` → `env-auth/` → `env-app/` | env-data deploys in-cluster MySQL, Kafka, MongoDB, Redis |
| `env` | AWS | `platform/` → `platform-config/` → `aws/` → `env/` → `env-auth/` → `env-app/` | No env-data — uses RDS, MSK, DocumentDB, ElastiCache |
| `env` | GCP | `platform/` → `platform-config/` → `gcp/` → `env/` → `env-auth/` → `env-app/` | No env-data — uses Cloud SQL, Managed Kafka, Memorystore |

Every provider gets a vendor kustomization — the concept is no longer "on-prem only". The vendor layer normalizes provider differences so all layers above it (cc, env, app) are generic. Flux uses `dependsOn` to enforce ordering.

## Directory Conventions

### platform/

Shared services deployed to every cluster. Add HelmReleases and Kustomizations here for infrastructure-level tools.

```
gitops/platform/
  kustomization.yaml           # Root kustomization — lists all resources
  namespace.yaml               # Platform namespace(s) — pod-security: privileged for Cilium envoy proxy
  cert-manager/
    helmrelease.yaml           # TLS automation (with Gateway API support enabled)
  external-dns/
    helmrelease.yaml           # DNS bridge — watches service + gateway-httproute sources
  external-secrets/
    helmrelease.yaml           # External Secrets Operator
  metrics-server/
    helmrelease.yaml           # Kubelet metrics aggregation
```

Note: No GatewayClass here — it is auto-created by Cilium (on-prem HelmRelease or cloud-managed).

### platform-config/

Provider-agnostic configuration that depends on platform services being ready (e.g. cert-manager must exist before the Gateway can reference a ClusterIssuer):

```
gitops/platform-config/
  kustomization.yaml
  gateway/
    gateway.yaml               # Shared Gateway — wildcard TLS (*.${domain}), gatewayClassName: ${gateway_class_name}
```

Note: ClusterIssuers and DNS credential Secrets have moved to the vendor-specific kustomizations (`talos/`, `aws/`, `gcp/`) because the `dns01` solver block is structurally different per DNS provider and cannot be parameterized with simple variable substitution.

### Vendor-specific kustomizations (talos/, aws/, gcp/)

Each provider gets exactly one vendor kustomization that fills the gaps between what the provider manages natively and what the generic platform layer expects. This is the "generalization layer" that normalizes provider differences.

```
gitops/talos/                          # Talos (Proxmox, OpenStack)
  kustomization.yaml
  namespace.yaml
  cilium/
    helmrelease.yaml                   # Cilium CNI (Phase 2 — adopts bootstrap install)
  lb-ipam/
    lb-ipam.yaml                       # L2AnnouncementPolicy + CiliumLoadBalancerIPPool
  openebs/
    helmrelease.yaml                   # OpenEBS hostpath storage
  minio/
    helmrelease.yaml                   # MinIO standalone (S3-compat object storage)
    externalsecret.yaml                # MinIO credentials from Vault
  harbor/
    helmrelease.yaml                   # Harbor OCI registry + proxy cache
    ...                                # proxy-cache setup files
  cert-manager/
    letsencrypt.yaml                   # ClusterIssuers (prod + staging) with DNS-01 solver
    dns-secret.yaml                    # DNS provider token (DigitalOcean, Cloudflare, etc.)
```

```
gitops/aws/                            # AWS EKS
  kustomization.yaml
  cilium/
    helmrelease.yaml                   # Cilium BYOCNI (replaces VPC-CNI, gatewayAPI.enabled)
  cert-manager/
    letsencrypt.yaml                   # ClusterIssuers with Route53 DNS-01 solver
    dns-secret.yaml                    # Route53 credentials (or empty if using IRSA)
```

```
gitops/gcp/                            # GCP GKE
  kustomization.yaml
  cert-manager/
    letsencrypt.yaml                   # ClusterIssuers with Cloud DNS solver
    dns-secret.yaml                    # Cloud DNS credentials (or empty if using Workload Identity)
```

Note: GatewayClass is not deployed in vendor kustomizations — it is auto-created by Cilium when `gatewayAPI.enabled: true`, or pre-created by the cloud provider (GKE, DOKS).

### cc/

Operators for the Control Center management plane. Also defines namespaces for CC services. On self-hosted providers, all CC namespaces are created (vault, harbor, minio). On managed providers, only `vault` is created — Harbor and MinIO namespaces are not needed since those services are replaced by managed equivalents (ECR/GAR, S3/GCS).

```
gitops/cc/
  kustomization.yaml
  namespace.yaml               # cc-system + vault (+ harbor + minio on self-hosted only)
  vault-operator/
    helmrelease.yaml           # Vault operator (runs in cc-system)
```

### cc-config/

Control Center services. Depends on cc/ (operators and namespaces must be ready). Contains only provider-agnostic services — Harbor and MinIO have moved to vendor kustomizations (self-hosted profile only). HTTPRoutes are in `cc-routes/` (deployed after services are healthy):

```
gitops/cc-config/
  kustomization.yaml
  vault/
    vault.yaml                 # Vault CR + RBAC (vault namespace)
    secretstore.yaml           # ClusterSecretStore pointing to vault.vault:8200
```

Note: Harbor and MinIO are deployed by the vendor kustomization (`talos/`) on Talos providers. On managed providers (AWS, GCP), Terraform creates the equivalents (S3/GCS bucket, ECR/Artifact Registry) and passes endpoints as substitution variables.

**Harbor proxy cache (self-hosted CC only):** On self-hosted providers (Proxmox, OpenStack), Harbor is deployed by the vendor kustomization and a setup Job configures it as a pull-through cache for upstream registries. App Environments pull all images through `harbor.${domain}/<project>/<image>` instead of hitting public registries directly. This enables air-gapped operation and reduces external bandwidth. On managed providers (AWS, GCP), Harbor is not deployed — Terraform creates a managed OCI registry (ECR, Artifact Registry) and container images are pulled directly from public registries or via the cloud provider's native caching.

The proxy cache setup files:

- `proxy-cache-oci-secret.yaml` — Kubernetes Secret with OCI credentials via Flux `${oci_repo_username}` / `${oci_repo_password}` substitution. Mounted by the Job for authenticated upstream access.
- `proxy-cache-externalsecret.yaml` — ExternalSecret pulling Harbor admin password from Vault (via ClusterSecretStore) into the `harbor` namespace.
- `proxy-cache-configmap.yaml` — Idempotent shell script that creates registry endpoints and proxy cache projects via Harbor's REST API. Handles create-or-update logic and type mismatch recovery (registry type is immutable — the script deletes and recreates if the type changes).
- `proxy-cache-job.yaml` — One-shot Job (alpine:3, backoffLimit: 5) that waits for Harbor readiness then runs the setup script.

**Registry adapter types:** Harbor has specialized adapters for different registries. Using the correct adapter is critical for authentication:

| Upstream | Harbor adapter type | Credential | Notes |
|----------|-------------------|------------|-------|
| docker.io | `docker-hub` | None (public) | Harbor's native Docker Hub adapter |
| ghcr.io | `github-ghcr` | `basic` (username + PAT) | Required for private packages; handles GitHub token exchange |
| quay.io | `docker-registry` | None (public) | Generic Docker Registry v2 adapter |
| registry.k8s.io | `docker-registry` | None (public) | Generic Docker Registry v2 adapter |

The `github-ghcr` adapter is required for ghcr.io because it handles GitHub's token exchange protocol. Using the generic `docker-registry` adapter with ghcr.io fails for private repositories. The credential type must be `basic` (not `secret`) — ghcr.io requires both username and token for the auth handshake.

**Adding more proxy caches:** To add a new upstream registry, edit `proxy-cache-configmap.yaml` and add a `create_registry` + `create_project` call. Choose the adapter type from Harbor's supported adapters (`docker-hub`, `docker-registry`, `github-ghcr`, `aws-ecr`, `google-gcr`, `ali-acr`, `tencent-tcr`, `volcengine-cr`). Delete the existing Job to trigger re-creation on next Flux reconciliation.

### env/

Services specific to App Environments (workload clusters):

```
gitops/env/
  kustomization.yaml
  namespace.yaml
  mojaloop/
    helmrelease.yaml           # Mojaloop application
  ...
```

## Variable Substitution

Adopter-specific values are injected at reconciliation time via Flux `postBuild.substituteFrom`. The platform team authors manifests with variable placeholders — the adopter never edits the artifact.

**Available variables (from ConfigMap `cluster-config`):**

| Variable | Source | Example |
|----------|--------|---------|
| `${cluster_name}` | `config.yaml` | `cc` |
| `${cluster_vip}` | `config.yaml` | `192.168.88.10` |
| `${domain}` | `config.yaml` | `example.com` |
| `${dns_provider}` | `config.yaml` | `digitalocean`, `aws`, `google`, `cloudflare` |
| `${alert_email}` | `config.yaml` | `ops@example.com` |
| `${lb_ipam_range}` | `config.yaml` | `192.168.88.100-192.168.88.110` |
| `${gateway_class_name}` | `config.yaml` | `cilium`, `gke-l7-regional-external-managed` |
| `${s3_endpoint}` | TF output (CC self-hosted) | `http://minio.minio:9000` (Harbor S3 backend, self-hosted CC only) |
| `${s3_bucket}` | TF output (CC self-hosted) | `harbor` (Harbor S3 backend, self-hosted CC only) |
| `${s3_region}` | TF output (CC self-hosted) | `us-east-1` (Harbor S3 backend, self-hosted CC only) |
| `${mysql_central_ledger_host}` | TF output (env managed) | `ml.xxx.rds.amazonaws.com` |
| `${kafka_host}` | TF output (env managed) | `b-1.ml-msk.xxx.kafka.amazonaws.com` |
| `${mongodb_host}` | TF output (env managed) | `ml.xxx.docdb.amazonaws.com` |
| `${redis_host}` | TF output (env managed) | `ml.xxx.cache.amazonaws.com` |

**Available secrets (from Secret `cluster-secrets`):**

| Variable | Source | Example |
|----------|--------|---------|
| `${digitalocean_token}` | `.env` | API token (DigitalOcean DNS) |
| `${oci_repo_username}` | `.env` | OCI repo registry username |
| `${oci_repo_password}` | `.env` | OCI repo registry password |
| `${oci_proxy_username}` | `.env` | OCI proxy (Harbor) username — self-hosted CC only |
| `${oci_proxy_password}` | `.env` | OCI proxy (Harbor) password — self-hosted CC only |
| `${minio_root_user}` | `.env` | MinIO root user (CC self-hosted) |
| `${minio_root_password}` | `.env` | MinIO root password (CC self-hosted) |
| `${harbor_admin_password}` | `.env` | Harbor admin password (CC self-hosted) |
| `${mysql_*_password}` | `.env` | Database passwords (env clusters) |

### Example: using variables in a HelmRelease

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: external-dns
  namespace: platform-system
spec:
  values:
    provider: ${dns_provider}
    domainFilters:
      - ${domain}
    extraArgs:
      - --txt-owner-id=${cluster_name}
```

Flux replaces `${dns_provider}` with the adopter's value from the ConfigMap at apply time.

## Building and Publishing

### Prerequisites

- [Flux CLI](https://fluxcd.io/flux/cmd/) >= 2.0
- [GitHub CLI](https://cli.github.com/) (`gh`) — for authentication
- Write access to the target OCI registry (GHCR by default)

### Authentication

The Makefile handles OCI registry login automatically using credentials from the environment's `.env` file. Set your GHCR credentials once:

```bash
# Generate a GitHub PAT with packages scope
gh auth refresh -s read:packages,write:packages

# Copy the token
gh auth token
```

Then add to `config/environments/<env>/.env`:

```bash
OCI_REPO_USERNAME="your-github-username"
OCI_REPO_PASSWORD="ghp_xxxxxxxxxxxx"
```

All `make` gitops targets (`push-gitops`, `tag-gitops`, `list-artifacts`) use these credentials automatically via `--creds`.

For CI/CD, use `GITHUB_TOKEN` or a fine-grained PAT with `read:packages` + `write:packages` permissions.

### Push an artifact

```bash
# Push with auto-generated version (git SHA)
make push-gitops ENV=cc

# Push with explicit version
make push-gitops ENV=cc GITOPS_VERSION=v0.1.0

# Tag an existing version
make tag-gitops ENV=cc TAG=stable

# List all published versions
make list-artifacts ENV=cc
```

What `make push-gitops` does:
1. Packages the entire `gitops/` directory as an OCI artifact
2. Authenticates with credentials from `config/environments/<env>/.env` (`OCI_REPO_USERNAME` / `OCI_REPO_PASSWORD`)
3. Pushes to the registry URL defined in `config/environments/<env>/config.yaml` under `oci.repo.url`
4. Tags with the git SHA (or explicit version)
5. Also tags as `latest`

### OCI registry URL

The artifact URL in `config/environments/<env>/config.yaml` determines where artifacts are pushed and pulled:

```yaml
oci:
  repo:
    active: true
    url: "oci://ghcr.io/mojaloop/ml-gitops"
    version: "latest"
```

The URL format is `oci://<registry>/<owner>/<package-name>`:
- **GHCR** (Platform Team public registry): `oci://ghcr.io/mojaloop/ml-gitops`
- **Harbor** (self-hosted CC only — Proxmox, OpenStack): `oci://harbor.cc.example.com/mojaloop/ml-gitops`
- **ECR** (managed CC on AWS): `oci://123456789.dkr.ecr.us-east-1.amazonaws.com/ml-gitops`
- **Artifact Registry** (managed CC on GCP): `oci://us-docker.pkg.dev/project-id/ml-gitops`

The package name (`ml-gitops`) is arbitrary — it is created on first push.

## Adding Platform Services

### Step 1: Add manifests to the appropriate directory

```bash
mkdir -p gitops/platform/my-service
```

Create the HelmRelease or raw manifests:

```yaml
# gitops/platform/my-service/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: my-service
  namespace: platform-system
spec:
  interval: 10m
  chart:
    spec:
      chart: my-service
      version: "1.2.3"
      sourceRef:
        kind: HelmRepository
        name: my-repo
  values:
    domain: ${domain}
```

### Step 2: Register in kustomization.yaml

```yaml
# gitops/platform/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - my-service/helmrelease.yaml
```

### Step 3: Publish

```bash
make push-gitops ENV=cc GITOPS_VERSION=v1.1.0
```

Flux detects the new artifact version (polls every 10 minutes or on next reconciliation) and deploys the new service.

## Version Management

### Versioning strategy

- Use git SHA for development (`make push-gitops` — default)
- Use semantic versions for releases (`make push-gitops GITOPS_VERSION=v1.0.0`)
- `latest` tag always points to the most recent push
- Adopters pin to `latest` (default) or a specific version in their `config.yaml`

### Promoting versions

```bash
# Tag a tested version as stable
make tag-gitops ENV=cc TAG=stable

# Adopters can then pin to "stable" in their config.yaml:
# oci.repo.version: "stable"
```

### Version coherence

All directories (platform/, platform-config/, vendor kustomizations, cc/, cc-config/, cc-routes/, env/, env-data/, env-auth/, env-app/) ship in a single artifact. When you push `v1.2.0`, the adopter gets a coherent snapshot of all paths. There is no risk of version drift between platform, vendor, and role-specific paths.

## CI/CD Integration

### GitHub Actions example

```yaml
name: Publish GitOps Artifact
on:
  push:
    branches: [main]
    paths: ['gitops/**']
  release:
    types: [published]

jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      packages: write
    steps:
      - uses: actions/checkout@v4

      - name: Install Flux CLI
        uses: fluxcd/flux2/action@main

      - name: Push artifact
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          echo "$GITHUB_TOKEN" | flux login ghcr.io --username=flux --password-stdin

          VERSION="${GITHUB_REF_NAME}"
          if [ "${{ github.event_name }}" = "push" ]; then
            VERSION="${GITHUB_SHA::7}"
          fi

          flux push artifact oci://ghcr.io/${{ github.repository_owner }}/ml-gitops:${VERSION} \
            --path=./gitops \
            --source="${{ github.server_url }}/${{ github.repository }}" \
            --revision="${GITHUB_SHA::7}"

          flux tag artifact oci://ghcr.io/${{ github.repository_owner }}/ml-gitops:${VERSION} \
            --tag=latest
```

## Troubleshooting

### Verify artifact contents

```bash
# Pull and inspect locally
flux pull artifact oci://ghcr.io/mojaloop/ml-gitops:latest --output ./tmp-artifact
ls -la ./tmp-artifact/
```

### Check Flux reconciliation status (on a running cluster)

```bash
# Check OCI source
kubectl get ocirepositories -n flux-system

# Check kustomization status
kubectl get kustomizations -n flux-system

# View events
kubectl events -n flux-system --for=kustomization/platform
```

### Common issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| `OCIRepository not ready` | Bad URL or auth | Verify `config.yaml` URL matches the pushed artifact. Check `oci-credentials` secret exists. |
| `Kustomization failed` | Invalid YAML or missing variable | Run `kustomize build gitops/platform/` locally. Check all `${variables}` are defined in `cluster-config` ConfigMap. |
| `dependency not ready` | Platform kustomization unhealthy | Fix platform errors first — the role-specific kustomization waits for platform. |
