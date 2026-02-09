# Adopter Guide

## Overview

This guide walks through deploying a Mojaloop cluster using ml-iac3. As an adopter, you configure two files (`config.yaml` and `.env`), run Terraform via Make, and get a Kubernetes cluster with FluxCD reconciling platform services customized to your environment.

You never fork or edit the platform bundle — all personalization flows through your local configuration.

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

# 2. Configure credentials
cp config/.env.sample config/.env
# Edit config/.env with your provider credentials

# 3. Configure infrastructure
# Edit config/config.yaml — select provider, template, cluster settings

# 4. Deploy
make plan          # Review what will be created
make apply         # Provision infrastructure
```

## Configuration

### config/.env — Credentials

Copy the sample and fill in values for your provider:

```bash
cp config/.env.sample config/.env
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

#### Flux OCI credentials (all providers)

Required when pulling from a private OCI registry. Also used by `make push-gitops` for authentication.

```bash
OCI_USERNAME="your-github-username"
OCI_PASSWORD="ghp_xxxxxxxxxxxx"
```

Generate a GitHub PAT:

```bash
# Add packages scope to your GitHub CLI session
gh auth refresh -s read:packages,write:packages

# Retrieve the token
gh auth token
```

For public GHCR packages, OCI credentials are not required for pull. They are still needed for push (`make push-gitops`).

### config/config.yaml — Infrastructure

The config file has 5 sections. Edit the values for your environment:

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
    mode: "none"                      # none | oci
    artifact:
      url: "oci://ghcr.io/mojaloop/ml-gitops"
      version: "latest"               # OCI tag — "latest" or pinned version
```

**Cluster role:**

| Role | Paths deployed | Use case |
|------|---------------|----------|
| `cc` | `platform/` + `cc/` | Control Center — hosts Harbor, Vault, MinIO |
| `env` | `platform/` + `env/` | App Environment — hosts Mojaloop workloads |

**Flux mode:**

| Mode | Behavior |
|------|----------|
| `none` | Flux controllers installed but no sources configured — empty cluster |
| `oci` | Flux reconciles from the OCI artifact (normal operation) |

Start with `mode: "none"` to validate infrastructure, then switch to `"oci"` to enable GitOps.

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

## Deployment

### Initialize

```bash
make init
```

Downloads Terraform providers and initializes modules. Run once, or after changing provider configuration.

### Plan and apply

```bash
make plan         # Creates execution plan (saved to artifacts/terraform/tfplan)
make apply        # Applies the saved plan
```

Or combined:

```bash
make plan-apply   # Plan + apply in one step (avoids stale plan errors)
```

### Verify

After `make apply` completes:

```bash
# Set kubeconfig
export KUBECONFIG=$(pwd)/artifacts/kubernetes/kubeconfig

# Check nodes
kubectl get nodes

# Check Flux controllers
kubectl get pods -n flux-system

# If flux.mode is "oci", check reconciliation
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

### Outputs

| Artifact | Path | Provider |
|----------|------|----------|
| Kubeconfig | `artifacts/kubernetes/kubeconfig` | All |
| Talos client config | `artifacts/talos-config/talosconfig` | Proxmox only |
| Per-instance Talos configs | `artifacts/talos-config/{instance}.yaml` | Proxmox only |
| Talos secrets backup | `artifacts/talos-secrets/secrets.yaml` | Proxmox only |

## Upgrading

### Upgrade platform services (Flux mode: oci)

When the platform team publishes a new artifact version:

**Option A — automatic (using `latest` tag):**

No action needed. Flux polls the OCI source every 10 minutes and applies changes automatically.

**Option B — pinned version:**

Update `config/config.yaml`:

```yaml
cluster:
  flux:
    artifact:
      version: "v1.2.0"   # New version
```

Then re-apply:

```bash
make plan-apply
```

### Upgrade infrastructure

To change cluster topology, provider settings, or Flux version:

1. Edit `config/config.yaml`
2. Run `make plan` — review changes carefully
3. Run `make apply`

## Destroy

```bash
make destroy          # Destroys all infrastructure (5-second safety delay)
```

If resources are already manually deleted:

```bash
make destroy-fast     # Skip refresh (3-second safety delay)
```

## Provider-Specific Notes

### Proxmox

- **VIP**: Set `cluster.vip` to an unused IP in your network. Talos manages the floating VIP across control-plane nodes.
- **Placement**: Map logical placement groups to physical Proxmox nodes. The deployment template references placement groups; `config.yaml` resolves them to real nodes.
- **Talos access**: Use `talosctl` with the generated config:
  ```bash
  export TALOSCONFIG=$(pwd)/artifacts/talos-config/talosconfig
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
| `make apply` — stale plan error | State changed between plan and apply | Use `make plan-apply` instead |
| Flux pods not running | Flux bootstrap failed | Check `kubectl get pods -n flux-system`, re-run `make plan-apply` |
| OCIRepository `not ready` | Wrong URL or missing credentials | Verify `artifact.url` in config.yaml, check `.env` has correct `OCI_USERNAME` / `OCI_PASSWORD` values |
| Kustomization stuck on `dependency not ready` | Platform kustomization has errors | Run `kubectl get kustomizations -n flux-system` — fix platform errors first |
| Proxmox VMs not getting IP | DHCP or network misconfiguration | Check Proxmox VM console, verify bridge network settings |
| EKS node group unhealthy | IAM or subnet issues | Check `aws eks describe-nodegroup`, verify IAM policies |

### Useful commands

```bash
# Terraform state inspection
make show             # Full state
make list             # Resource list

# Clean slate
make clean            # Remove local artifacts
make destroy          # Tear down infrastructure

# Flux debugging
kubectl get events -n flux-system --sort-by='.lastTimestamp'
flux get all -n flux-system
flux logs --level=error
```
