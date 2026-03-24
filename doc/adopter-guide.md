# Adopter Guide

## Overview

This guide walks through deploying a Mojaloop cluster using ml-iac3. As an adopter, you configure two files per environment (`config.yaml` and `.env`), run Terraform via Make, and get a Kubernetes cluster with FluxCD reconciling platform services customized to your environment.

You never fork or edit the platform bundle — all personalization flows through your local configuration.

A single clone can manage multiple deployments (CC, app environments) using the `ENV=` variable.

## Prerequisites

### Tools

| Tool | Version | Install |
|------|---------|---------|
| Terraform | >= 1.0 | [hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install) |
| Flux CLI | >= 2.0 | [fluxcd.io/flux/cmd](https://fluxcd.io/flux/cmd/) |
| GitHub CLI | latest | [cli.github.com](https://cli.github.com/) |

### Provider-specific

| Provider | Additional requirements |
|----------|----------------------|
| **Proxmox** | Proxmox VE API access (token or password), SSH access to nodes |
| **AWS** | AWS CLI configured, IAM user/role with EKS + VPC + EC2 permissions |
| **DigitalOcean** | API token with read/write scope |

## Quick Start

```bash
# 1. Clone the repository
git clone <repo-url> && cd ml-iac3

# 2. Set up the CC environment
mkdir -p config/environments/cc
cp config/.env.sample config/environments/cc/.env
# Edit config/environments/cc/.env with your provider credentials
# Edit config/environments/cc/config.yaml — select provider, template, cluster settings

# 3. Deploy
make plan ENV=cc       # Review what will be created
make apply ENV=cc      # Provision infrastructure
```

## Configuration

### Named Environments

Each deployment (CC, app environment) lives in its own directory under `config/environments/`:

```
config/environments/
  cc/
    config.yaml    # Infrastructure config for this environment
    .env           # Secrets for this environment (git-ignored)
  env-prod/
    config.yaml
    .env
```

The `ENV=` variable tells Make which environment to use:

```bash
make plan ENV=cc              # Plan Control Center
make plan-apply ENV=env-prod  # Plan + apply App Environment

# Or export for a session
export ENV=cc
make plan
make apply
make push-gitops
```

If `ENV` is not specified, it defaults to `cc`.

Each environment gets its own Terraform state and artifacts:

```
artifacts/
  cc/
    terraform/terraform.tfstate
    terraform/tfplan
    kubernetes/kubeconfig
    talos-config/
    talos-secrets/
  env-prod/
    terraform/...
    kubernetes/...
```

### config/environments/\<env\>/.env — Credentials

Copy the sample and fill in values for your provider:

```bash
cp config/.env.sample config/environments/cc/.env
```

#### Proxmox

```bash
PROXMOX_VE_ENDPOINT="https://pve.example.com:8006"
PROXMOX_VE_API_TOKEN="user@pam!token_id=your-token-secret"
PROXMOX_VE_SSH_USERNAME="root"
PROXMOX_VE_SSH_PASSWORD="your-ssh-password"
PROXMOX_VE_INSECURE="true"
```

#### AWS

```bash
AWS_REGION="us-east-1"
AWS_ACCESS_KEY_ID="your-access-key"
AWS_SECRET_ACCESS_KEY="your-secret-key"
```

#### DigitalOcean

```bash
TF_VAR_digitalocean_token="your-do-token"
```

#### OCI-REPO credentials (all providers)

Required when pulling from a private OCI registry. Also used by `make push-gitops` for authentication.

```bash
OCI_REPO_USERNAME="your-github-username"
OCI_REPO_PASSWORD="ghp_xxxxxxxxxxxx"
```

Generate a GitHub PAT:

```bash
# Add packages scope to your GitHub CLI session
gh auth refresh -s read:packages,write:packages

# Retrieve the token
gh auth token
```

For public GHCR packages, OCI-REPO credentials are not required for pull. They are still needed for push (`make push-gitops`).

#### OCI-PROXY credentials (optional)

Only needed when `oci.proxy.active: true` in `config.yaml` and Harbor requires authentication.

```bash
OCI_PROXY_USERNAME=""
OCI_PROXY_PASSWORD=""
```

### config/environments/\<env\>/config.yaml — Infrastructure

The config file has 6 sections. Edit the values for your environment:

#### 1. Provider selection

```yaml
infra:
  provider: "proxmox"    # proxmox | aws | digitalocean
```

**Proxmox** — maps abstract placement groups to physical nodes:

```yaml
infra:
  provider: "proxmox"
  proxmox:
    placement:
      placement-group-1: "node0"
      placement-group-2: "node1"
      placement-group-3: "node0"
```

**AWS** — set the region:

```yaml
infra:
  provider: "aws"
  aws:
    region: "us-east-1"
```

**DigitalOcean** — set the region:

```yaml
infra:
  provider: "digitalocean"
  digitalocean:
    region: "nyc1"
```

#### 2. Deployment template

```yaml
template: "h1m1"    # Topology name — see available templates below
```

Templates are provider-specific and define cluster topology (node count, sizes, placement). Available templates depend on the selected provider.

**Proxmox templates:**

| Template | Description |
|----------|-------------|
| `h1m1` | 1 host, 1 mixed-plane node (control-plane + worker) |
| `h2c3w3` | 2 hosts, 3 control-plane on host 1, 3 workers on host 2 |
| `h3c3w3` | 3 hosts, 1 control-plane + 1 worker per host |
| `micro` | 1 host, 1 mixed-plane (minimal resources) |
| `tiny` | 1 host, 1 control-plane + 1 worker |
| `small` | 2 hosts, 1 control-plane + 1 worker per host |
| `small3m3w` | 3 hosts, 3 control-plane + 3 workers distributed |

**DigitalOcean / AWS templates:**

| Template | Description |
|----------|-------------|
| `micro` | 1 node (smallest footprint) |
| `small` | 3 nodes |
| `medium` | 3 nodes (larger instance sizes) |

#### 3. Cluster parameters

```yaml
cluster:
  name: "cc"                          # Cluster name (used in resource naming)
  role: "cc"                          # cc | env — determines which gitops paths are deployed
  vip: "192.168.88.10"               # Proxmox: floating VIP for K8s API
  flux:
    version: "2.7.2"                  # FluxCD version
```

**Cluster role:**

| Role | Paths deployed | Use case |
|------|---------------|----------|
| `cc` | `platform/` + `cc/` | Control Center — hosts Harbor, Vault, MinIO |
| `env` | `platform/` + `env/` | App Environment — hosts Mojaloop workloads |

#### 4. DNS

```yaml
dns:
  provider: "digitalocean"            # digitalocean | cloudflare | aws
  domain: "example.com"
```

#### 5. Application parameters

```yaml
app:
  lb_ipam:
    range: "192.168.88.100-192.168.88.110"   # On-prem LB IP range
  alert_email: "ops@example.com"
```

#### 6. OCI configuration

```yaml
oci:
  repo:
    active: true                    # Enable Flux OCI reconciliation
    url: "oci://ghcr.io/mojaloop/ml-gitops"
    version: "latest"               # OCI tag — "latest" or pinned version
  proxy:
    active: false                   # Enable container image proxy through Harbor
    url: "harbor.cc.example.com"    # Harbor proxy cache URL
```

**OCI repo** — The platform team's OCI registry where the Flux gitops artifact lives. Required for Flux. Set `active: false` to install Flux controllers only (empty cluster for testing).

**OCI proxy** — CC's Harbor as a transparent pull-through cache for container images. Configured at Talos level (`machine.registries.mirrors`) so containerd routes image pulls through Harbor. CC typically has it inactive (CC IS the proxy). App Environments enable it to cache images locally.

| Scenario | `oci.repo.active` | `oci.proxy.active` |
|----------|-------------------|---------------------|
| CC cluster | `true` | `false` (CC IS the proxy) |
| App Env (internet) | `true` (direct GHCR) | `true` |
| App Env (air-gapped) | `true` (URL points through Harbor) | `true` |
| Testing (empty cluster) | `false` | `false` |

## Multiple Environments

A single clone can manage multiple independent deployments:

```bash
# Set up CC environment
mkdir -p config/environments/cc
cp config/.env.sample config/environments/cc/.env
# Edit config/environments/cc/config.yaml and .env

# Deploy CC
make plan ENV=cc
make apply ENV=cc

# Set up app environment
mkdir -p config/environments/env-prod
cp config/.env.sample config/environments/env-prod/.env
# Edit config/environments/env-prod/config.yaml and .env

# Deploy env-prod
make plan ENV=env-prod
make apply ENV=env-prod
```

Each environment is fully independent — different provider, template, cluster settings, credentials, and Terraform state.

### Migration from single config

If you have an existing deployment with `config/config.yaml` and `config/.env`:

```bash
# 1. Move config files
mkdir -p config/environments/cc
mv config/config.yaml config/environments/cc/config.yaml
cp config/.env config/environments/cc/.env

# 2. Move artifacts
mv artifacts/ artifacts-old/
mkdir -p artifacts/cc
mv artifacts-old/* artifacts/cc/

# 3. Re-init with new backend
make init ENV=cc
```

## Deployment

### Initialize

```bash
make init ENV=cc
```

Downloads Terraform providers and initializes modules. Run once, or after changing provider configuration.

### Plan and apply

```bash
make plan ENV=cc       # Creates execution plan (saved to artifacts/cc/terraform/tfplan)
make apply ENV=cc      # Applies the saved plan
```

Or combined:

```bash
make plan-apply ENV=cc   # Plan + apply in one step (avoids stale plan errors)
```

### Verify

After `make apply` completes:

```bash
# Set kubeconfig
export KUBECONFIG=$(pwd)/artifacts/cc/kubernetes/kubeconfig

# Check nodes
kubectl get nodes

# Check Flux controllers
kubectl get pods -n flux-system

# If oci.repo.active is true, check reconciliation
kubectl get ocirepositories -n flux-system
kubectl get kustomizations -n flux-system

# For CC clusters — check Gateway API ingress
kubectl get gatewayclass                       # cilium → Accepted
kubectl get gateway -n platform-system         # main-gateway → Programmed, has LB IP
kubectl get certificates -n platform-system    # wildcard-tls → Ready (DNS-01 validated)
kubectl get clusterissuer                      # letsencrypt-prod/staging → Ready

# Check namespace isolation
kubectl get pods -n vault                      # vault pods
kubectl get pods -n harbor                     # harbor pods
kubectl get pods -n minio                      # minio pods
kubectl get pods -n cc-system                  # only vault-operator

# Check routes
kubectl get httproute -n vault                 # vault route → Accepted
kubectl get httproute -n harbor                # harbor route → Accepted
kubectl get httproute -n minio                 # minio-console route → Accepted
```

### Accessing CC Services

Once the CC cluster is fully reconciled, services are available at their HTTPS subdomains:

| Service | URL | Purpose |
|---------|-----|---------|
| Vault | `https://vault.{domain}` | Secrets management UI/API |
| Harbor | `https://harbor.{domain}` | OCI registry UI |
| MinIO | `https://minio.{domain}` | Object storage console |

TLS certificates are automatically provisioned by cert-manager using DNS-01 challenges (DigitalOcean DNS TXT validation). DNS A records are auto-created by external-dns from HTTPRoute hostnames.

### Harbor Proxy Cache

Harbor is automatically configured as a pull-through cache for upstream OCI registries. A setup Job runs after Harbor deploys and creates proxy cache projects for the major registries:

| Upstream registry | Harbor project | Registry adapter | Auth |
|-------------------|---------------|-----------------|------|
| docker.io | `docker-hub` | `docker-hub` | Public (no credentials) |
| ghcr.io | `ghcr` | `github-ghcr` | Authenticated (OCI credentials from `.env`) |
| quay.io | `quay` | `docker-registry` | Public |
| registry.k8s.io | `k8s` | `docker-registry` | Public |

App Environments pull all images through Harbor instead of hitting public registries directly. This enables air-gapped operation — once an image is cached, internet access is no longer required.

**Verify proxy cache setup:**

```bash
export KUBECONFIG=$(pwd)/artifacts/cc/kubernetes/kubeconfig

# Check the setup Job completed
kubectl get job harbor-proxy-cache-setup -n harbor

# View setup logs
kubectl logs job/harbor-proxy-cache-setup -n harbor

# Check registry endpoints
kubectl get secret harbor-admin -n harbor -o jsonpath='{.data.password}' | base64 -d
# Use the password below as HARBOR_PASS
```

**Test with curl:**

```bash
HARBOR_PASS="<harbor-admin-password>"
DOMAIN="<your-domain>"

# List tags from a public Docker Hub image
curl -sk -u "admin:$HARBOR_PASS" \
  "https://harbor.$DOMAIN/v2/docker-hub/library/alpine/tags/list"

# List tags from a public ghcr.io image
curl -sk -u "admin:$HARBOR_PASS" \
  "https://harbor.$DOMAIN/v2/ghcr/fluxcd/flux-cli/tags/list"

# List tags from a private ghcr.io repo (requires OCI credentials configured)
curl -sk -u "admin:$HARBOR_PASS" \
  "https://harbor.$DOMAIN/v2/ghcr/<owner>/<repo>/tags/list"

# Pull a manifest through the proxy
curl -sk -u "admin:$HARBOR_PASS" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" \
  "https://harbor.$DOMAIN/v2/docker-hub/library/nginx/manifests/latest"

# List all proxy cache projects via Harbor API
curl -sk -u "admin:$HARBOR_PASS" \
  "https://harbor.$DOMAIN/api/v2.0/projects"

# List all registry endpoints via Harbor API
curl -sk -u "admin:$HARBOR_PASS" \
  "https://harbor.$DOMAIN/api/v2.0/registries"
```

The URL pattern is `harbor.$DOMAIN/v2/<project>/<image-path>/tags/list`, where `<project>` maps to the upstream registry.

**Pull path reference for App Environments:**

| Original image | Via Harbor proxy |
|----------------|-----------------|
| `docker.io/library/nginx:latest` | `harbor.$DOMAIN/docker-hub/library/nginx:latest` |
| `ghcr.io/fluxcd/flux-cli:v2.7.5` | `harbor.$DOMAIN/ghcr/fluxcd/flux-cli:v2.7.5` |
| `quay.io/cilium/cilium:v1.16` | `harbor.$DOMAIN/quay/cilium/cilium:v1.16` |
| `registry.k8s.io/metrics-server:v0.7` | `harbor.$DOMAIN/k8s/metrics-server:v0.7` |

### Observability Stack

The Control Center includes a modern observability stack based on Grafana Labs' LGTM stack (Loki, Grafana, Tempo, Mimir):

| Component | Purpose | Storage | Access |
|-----------|---------|---------|--------|
| **Mimir** | Prometheus-compatible metrics storage | MinIO S3 (`mimir` bucket) | `https://mimir.int.${domain}` |
| **Loki** | Log aggregation and querying | MinIO S3 (`loki` bucket) | `https://loki.int.${domain}` |
| **Tempo** | Distributed tracing backend | MinIO S3 (`tempo` bucket) | `https://tempo.int.${domain}` |
| **Grafana** | Unified observability UI | PVC (1Gi) | `https://grafana.int.${domain}` |

All services are exposed via the internal Gateway (`gw-int`) and are automatically configured as datasources in Grafana with cross-linking (traces → logs → metrics).

**Default retention (7 days):**
- **Mimir**: 168 hours (~60 MB for typical ml-test workload)
- **Loki**: 168 hours (~700 MB for typical ml-test workload)
- **Tempo**: 168 hours (~280 MB for typical ml-test workload)
- **Total**: ~1.2 GB

**Access Grafana:**

```bash
export KUBECONFIG=$(pwd)/artifacts/ml-cc/kubernetes/kubeconfig

# Get admin password from cluster-secrets
kubectl get secret cluster-secrets -n flux-system \
  -o jsonpath='{.data.grafana_admin_password}' | base64 -d

# Or check Vault directly
kubectl exec -n vault vault-0 -- vault kv get -format=json secret/observability \
  | jq -r '.data.data.grafanaAdminPassword'
```

Then navigate to `https://grafana.int.${domain}` and login with username `admin` and the password retrieved above.

**Extending retention:**

To increase retention beyond 7 days, edit the HelmRelease values in `gitops/cc-observability/`:

**Mimir** ([gitops/cc-observability/mimir/helmrelease.yaml](gitops/cc-observability/mimir/helmrelease.yaml:68-69)):
```yaml
limits_config:
  compactor_blocks_retention_period: 720h  # 30 days (was 168h)
```

**Loki** ([gitops/cc-observability/loki/helmrelease.yaml](gitops/cc-observability/loki/helmrelease.yaml:56-57)):
```yaml
limits_config:
  retention_period: 720h  # 30 days (was 168h)
```

**Tempo** ([gitops/cc-observability/tempo/helmrelease.yaml](gitops/cc-observability/tempo/helmrelease.yaml:58)):
```yaml
retention: 720h  # 30 days (was 168h)
```

After editing, push the updated artifact and Flux will reconcile:

```bash
make push-gitops ENV=ml-cc
```

**Storage estimates:**

| Retention | Mimir | Loki | Tempo | Total |
|-----------|-------|------|-------|-------|
| 7 days    | ~60 MB | ~700 MB | ~280 MB | ~1.2 GB |
| 14 days   | ~120 MB | ~1.4 GB | ~560 MB | ~2 GB |
| 30 days   | ~260 MB | ~3 GB | ~1.2 GB | ~4.5 GB |
| 90 days   | ~780 MB | ~9 GB | ~3.6 GB | ~13.4 GB |

Estimates assume a typical ml-test workload (~30 pods, ~100 req/sec peak, ~1500 active metric series). Adjust based on your actual workload and available MinIO storage capacity.

### Outputs

| Artifact | Path | Provider |
|----------|------|----------|
| Kubeconfig | `artifacts/<env>/kubernetes/kubeconfig` | All |
| Talos client config | `artifacts/<env>/talos-config/talosconfig` | Proxmox only |
| Per-instance Talos configs | `artifacts/<env>/talos-config/{instance}.yaml` | Proxmox only |
| Talos secrets backup | `artifacts/<env>/talos-secrets/secrets.yaml` | Proxmox only |

## Upgrading

### Upgrade platform services (oci.repo.active: true)

When the platform team publishes a new artifact version:

**Option A — automatic (using `latest` tag):**

No action needed. Flux polls the OCI source every 10 minutes and applies changes automatically.

**Option B — pinned version:**

Update `config/environments/<env>/config.yaml`:

```yaml
oci:
  repo:
    version: "v1.2.0"   # New version
```

Then re-apply:

```bash
make plan-apply ENV=cc
```

### Upgrade infrastructure

To change cluster topology, provider settings, or Flux version:

1. Edit `config/environments/<env>/config.yaml`
2. Run `make plan ENV=<env>` — review changes carefully
3. Run `make apply ENV=<env>`

## Destroy

```bash
make destroy ENV=cc          # Destroys all infrastructure (5-second safety delay)
```

If resources are already manually deleted:

```bash
make destroy-fast ENV=cc     # Skip refresh (3-second safety delay)
```

## Provider-Specific Notes

### Proxmox

- **VIP**: Set `cluster.vip` to an unused IP in your network. Talos manages the floating VIP across control-plane nodes.
- **Placement**: Map logical placement groups to physical Proxmox nodes. The deployment template references placement groups; `config.yaml` resolves them to real nodes.
- **Talos access**: Use `talosctl` with the generated config:
  ```bash
  export TALOSCONFIG=$(pwd)/artifacts/cc/talos-config/talosconfig
  talosctl health --nodes 192.168.88.10
  ```

### AWS (EKS)

- **IAM**: Terraform creates IAM roles for the EKS cluster and node groups. Your AWS credentials must have permission to create IAM roles, VPCs, and EKS clusters.
- **VPC**: A dedicated VPC is created with subnets across available AZs.
- **Kubeconfig**: Uses `aws eks get-token` for authentication — requires AWS CLI configured on any machine that uses the kubeconfig.

### DigitalOcean (DOKS)

- **Token**: The same `TF_VAR_digitalocean_token` is used for cluster provisioning and DNS (if `dns.provider: digitalocean`).
- **VPC**: A dedicated VPC is created in the selected region.

## Troubleshooting

### Common issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| `make apply` — stale plan error | State changed between plan and apply | Use `make plan-apply ENV=<env>` instead |
| Flux pods not running | Flux bootstrap failed | Check `kubectl get pods -n flux-system`, re-run `make plan-apply ENV=<env>` |
| OCIRepository `not ready` | Wrong URL or missing credentials | Verify `oci.repo.url` in config.yaml, check `.env` has correct `OCI_REPO_USERNAME` / `OCI_REPO_PASSWORD` values |
| Kustomization stuck on `dependency not ready` | Platform kustomization has errors | Run `kubectl get kustomizations -n flux-system` — fix platform errors first |
| Proxmox VMs not getting IP | DHCP or network misconfiguration | Check Proxmox VM console, verify bridge network settings |
| EKS node group unhealthy | IAM or subnet issues | Check `aws eks describe-nodegroup`, verify IAM policies |

### Known Issues

#### Mojaloop migration job fails with "BackoffLimitExceeded" on fresh deployments

**Symptom:**

```bash
kubectl get helmrelease mojaloop -n flux-system
# Status: False - InstallFailed
# Message: "failed pre-install: job moja-centralledger-service-migration failed: BackoffLimitExceeded"

kubectl get kustomization env-app -n flux-system
# Status: False - HealthCheckFailed
# Message: "failed early due to stalled resources: [HelmRelease/flux-system/mojaloop status: 'Failed']"
```

**Root Cause:**

Race condition between PXC operator user creation and Helm pre-install migration jobs. When deploying a fresh environment:

1. PXC cluster reports `state: initializing` for ~7-10 minutes after pod creation
2. During this window, the PXC operator is creating databases and users declaratively from `spec.users[]`
3. If Helm pre-install migration jobs (Mojaloop, Kratos, Keto, Oathkeeper) start before user creation completes, they fail with "Access denied for user"
4. Migration jobs have `backoffLimit: 1` (only 1 retry allowed), so they hit `BackoffLimitExceeded` and never recover
5. Flux HelmRelease `install.remediation.retries: 3` exhausts retries, enters `Stalled` state

**Timeline observed:**
- `T+0`: PXC cluster created
- `T+0 to T+7min`: PXC state = `initializing`, users being created
- `T+7min`: PXC operator completes user creation (central_ledger, account_lookup, kratos, keto, etc.)
- `T+7min+`: Migration jobs that start now succeed

**Workaround:**

If the HelmRelease fails, simply retry it:

```bash
export KUBECONFIG=artifacts/<env>/kubernetes/kubeconfig

# Check which HelmRelease failed
kubectl get helmrelease -n flux-system | grep False

# Suspend and resume to trigger retry
flux suspend helmrelease mojaloop -n flux-system
flux resume helmrelease mojaloop -n flux-system

# Monitor progress
kubectl get helmrelease mojaloop -n flux-system --watch
```

The retry will succeed because database users now exist.

**Prevention:**

This issue is timing-dependent. If your deployment starts slowly enough (e.g., pulling large images on first deploy), the migration jobs may start after the 7-minute window and succeed automatically. Future deployments (with cached images) are more likely to hit the race condition.

To avoid manual intervention:
- Wait ~10 minutes after `make apply` before checking HelmRelease statuses
- If you see migration failures early in deployment, wait for PXC to reach `state: ready` before retrying
- Check PXC status: `kubectl get pxc mojaloop-db -n mojaloop -o jsonpath='{.status.state}'`

**Permanent fix (future):**

This will be addressed in a future release by increasing the Helm job `backoffLimit` to allow retries during the PXC initialization window.

### Useful commands

```bash
# Terraform state inspection
make show ENV=cc          # Full state
make list ENV=cc          # Resource list

# Clean slate
make clean                # Remove local artifacts (all environments)
make destroy ENV=cc       # Tear down infrastructure

# Flux debugging
kubectl get events -n flux-system --sort-by='.lastTimestamp'
flux get all -n flux-system
flux logs --level=error
```
