# Configuration

[docs](../index.md) / [adopter](index.md) / Configuration

**Audiences:** adopter (deploy)

How to configure Mojian environments. For the architecture behind these choices, see [System Overview](../architecture/system-overview.md) and [Provider Model](../architecture/provider-model.md).

---

## Named environments

Each deployment lives in its own directory under `config/environments/`. The `ENV=` variable tells Make which environment to operate on (default: `cc`).

Each environment has independent configuration, secrets, and Terraform state. A single repository clone manages multiple deployments.

```bash
make plan ENV=cc           # Tooling Cluster
make plan ENV=env-prod     # App Environment (production)
export ENV=cc && make plan # Set ENV for a session
```

### Directory structure

**Configuration** -- one directory per environment:

```
config/environments/
  cc/                  # Tooling Cluster (default)
    config.yaml        # Infrastructure and application config
    .env               # Secrets and credentials (git-ignored)
  env-prod/            # App Environment
    config.yaml
    .env
```

**Artifacts** -- Terraform state and outputs, per environment:

```
artifacts/
  cc/
    terraform/
      terraform.tfstate
      tfplan
    kubernetes/
      kubeconfig
    talos-config/        # on-prem only (talosconfig, machine configs)
  env-prod/
    terraform/
      terraform.tfstate
      tfplan
    kubernetes/
      kubeconfig
```

**Shared** -- referenced by all environments, never duplicated:

```
config/
  definitions/           # Talos/K8s versions, workload class definitions
  patches/               # Talos machine config patches
  providers/             # Provider-specific config and deployment templates
```

---

## Credentials (.env)

Each environment needs a `.env` file with secrets. Start from the sample:

```bash
cp config/.env.sample config/environments/<env>/.env
```

Edit the file and fill in values for your provider and deployment type. The Makefile maps clean variable names to `TF_VAR_*` automatically -- no `TF_VAR_` prefixes are needed in `.env` (except where the Terraform provider reads them natively).

### Provider credentials

Only the block for your chosen `infra.provider` is required.

**Proxmox** (native env vars -- read directly by the bpg/proxmox provider):

```bash
PROXMOX_VE_ENDPOINT="https://pve.example.com:8006"
PROXMOX_VE_API_TOKEN="user@pam!token_id=your-token-secret"
PROXMOX_VE_SSH_USERNAME="root"
PROXMOX_VE_SSH_PASSWORD="your-ssh-password"
PROXMOX_VE_INSECURE="true"
```

**AWS** (native env vars -- read directly by the hashicorp/aws provider):

```bash
AWS_REGION="us-east-1"
AWS_ACCESS_KEY_ID="your-access-key"
AWS_SECRET_ACCESS_KEY="your-secret-key"
```

**DigitalOcean:**

```bash
TF_VAR_digitalocean_token="your-do-token"
```

### OCI credentials

**OCI repo credentials (required when `oci.repo.active: true`):**

```bash
OCI_REPO_USERNAME="your-registry-username"
OCI_REPO_PASSWORD="your-registry-token"
```

These authenticate Flux against the OCI registry hosting the gitops artifact. For GitHub Container Registry, use a personal access token with `read:packages` scope.

**OCI proxy credentials (optional -- only when `oci.proxy.active: true` and Harbor requires auth):**

```bash
OCI_PROXY_USERNAME="your-harbor-username"
OCI_PROXY_PASSWORD="your-harbor-password"
```

### DNS credentials

Provider-specific. Only the variable for your chosen `dns.provider` is needed.

| DNS provider | Variable | Notes |
|-------------|----------|-------|
| DigitalOcean | `DIGITALOCEAN_TOKEN` | API token with DNS write access |
| Cloudflare | `CLOUDFLARE_API_TOKEN` | API token scoped to DNS zone |
| Route53 | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` | IAM user with Route53 permissions |
| PowerDNS | `POWERDNS_API_URL`, `POWERDNS_API_KEY` | PowerDNS API endpoint and key |

See [DNS strategy](../architecture/networking.md#dns-strategy) for how credentials flow from `.env` into the cluster.

### Tooling Cluster services

When deploying a Tooling Cluster (`cluster.role: cc`), additional credentials are needed:

```bash
HARBOR_ADMIN_PASSWORD="your-harbor-password"
MINIO_ROOT_USER="admin"
MINIO_ROOT_PASSWORD="your-minio-password"
GRAFANA_ADMIN_PASSWORD="your-grafana-password"
```

### App Environment services

App Environment clusters (`cluster.role: env`) require credentials for the data layer, auth stack, and OIDC integrations. Key variables include:

```bash
# Database passwords
MYSQL_ROOT_PASSWORD="..."
MYSQL_CENTRAL_LEDGER_PASSWORD="..."
MYSQL_ACCOUNT_LOOKUP_PASSWORD="..."
MYSQL_ORACLE_MSISDN_PASSWORD="..."
MONGODB_ROOT_PASSWORD="..."
MONGODB_APP_PASSWORD="..."
KEYCLOAK_DB_PASSWORD="..."
KRATOS_DB_PASSWORD="..."
KETO_DB_PASSWORD="..."
MCM_DB_PASSWORD="..."

# Auth
KEYCLOAK_ADMIN_PASSWORD="..."
HUBOP_OIDC_SECRET="..."
MCM_OIDC_CLIENT_SECRET="..."
DFSP_OIDC_CLIENT_SECRET="..."
ROLE_ASSIGN_SVC_SECRET="..."

# SMTP (Keycloak DFSP invitation emails)
SMTP_HOST="smtp.example.com"
SMTP_PORT="587"
SMTP_USER="..."
SMTP_PASSWORD="..."

# Backup (when backup.s3 is configured)
BACKUP_S3_ACCESS_KEY="..."
BACKUP_S3_SECRET_KEY="..."
```

Refer to `.env.sample` for the complete list with descriptions.

---

## Infrastructure config (config.yaml)

Each environment's `config.yaml` has the following sections. Only the sections relevant to your deployment type are required.

### 1. Infrastructure provider

Selects the infrastructure provider and its specific settings.

```yaml
infra:
  provider: "proxmox"  # proxmox | aws | digitalocean

  # --- Proxmox ---
  proxmox:
    placement:
      placement-group-1: "node0"
      placement-group-2: "node1"

  # --- AWS ---
  # aws:
  #   region: "us-east-1"
  #   vpc_cidr: "10.0.0.0/16"
  #   availability_zones:
  #     - "us-east-1a"
  #     - "us-east-1b"

  # --- DigitalOcean ---
  # digitalocean:
  #   region: "nyc1"
  #   vpc_cidr: "10.10.0.0/16"
```

For Proxmox, the `placement` map ties deployment template placement groups to physical Proxmox node names. For cloud providers, specify the region and optional VPC CIDR.

### 2. Deployment template

Selects the cluster topology. Templates are defined in `config/providers/{provider}/deployment-templates.yaml`.

```yaml
template: "h1m1"
```

**Proxmox templates:**

| Template | Description | Nodes |
|----------|-------------|-------|
| `h1m1` | Single mixed-plane node | 1 node (control + worker) |
| `h2c1w3` | 2 hosts, 1 control + 3 workers | 4 VMs |
| `h2c1w4` | 2 hosts, 1 control + 4 workers | 5 VMs |
| `h2c3w3` | 2 hosts, 3 control + 3 workers | 6 VMs |
| `h3c3w3` | 3 hosts, 3 control + 3 workers | 6 VMs |
| `h2c1w3k3d3` | 2 hosts, dedicated Kafka + DB nodes | 10 VMs |
| `h1m1-dfsp` | Single mixed-plane, DFSP simulator | 1 node |

**Cloud templates (AWS and DigitalOcean):**

| Template | Description | Nodes |
|----------|-------------|-------|
| `micro` | Minimal single-node | 1 node |
| `tiny` | Two-node | 2 nodes |
| `small` | Three-node | 3 nodes |
| `small3m3w` | Six-node | 6 nodes |

See [Provider Model](../architecture/provider-model.md) for detailed specifications (CPU, memory, storage) of each template.

### 3. Cluster parameters

```yaml
cluster:
  name: "my-cc"
  role: "cc"               # cc = Tooling Cluster, env = App Environment
  vip: "192.168.0.240"     # on-prem only: floating VIP for the K8s API
  flux:
    version: "2.7.2"
```

| Field | Description |
|-------|-------------|
| `name` | Cluster name. Used in resource naming and Terraform state. |
| `role` | `cc` for Tooling Cluster, `env` for App Environment. Determines which gitops kustomizations are deployed. |
| `vip` | On-prem only. Floating IP for the Kubernetes API server, managed by Talos VIP. Not used for cloud providers. |
| `flux.version` | FluxCD operator version. |

### 4. DNS

```yaml
dns:
  provider: "digitalocean"
  domain: "cc1.example.com"
```

The DNS provider is independent from the infrastructure provider. Any combination works (e.g., Proxmox + Cloudflare, AWS + DigitalOcean). See [DNS strategy](../architecture/networking.md#dns-strategy) for details.

The domain value determines service URLs. For a Tooling Cluster with domain `cc1.example.com`:
- Vault: `vault.int.cc1.example.com`
- Harbor: `harbor.int.cc1.example.com`
- Grafana: `grafana.int.cc1.example.com`

### 5. Application

```yaml
app:
  lb_ipam:
    range: "192.168.0.241-192.168.0.243"
  alert_email: "ops@example.com"
```

| Field | Description |
|-------|-------------|
| `lb_ipam.range` | On-prem only. IP range for Cilium LB-IPAM (LoadBalancer Service IPs). App Environments need 3 IPs (gw-int, gw-ext, gw-extapi). Tooling Clusters need 2 IPs (gw-int, gw-ext). Not used for cloud providers. |
| `alert_email` | Recipient for Alertmanager notifications. |

### 6. Backup (env clusters)

```yaml
backup:
  s3:
    endpoint: "https://s3.int.cc1.example.com"
    bucket: "backups"
    region: "us-east-1"
```

S3-compatible endpoint for database backups (Percona operator). On-prem deployments typically point at the Tooling Cluster's MinIO. Cloud deployments can use managed S3. Credentials (`BACKUP_S3_ACCESS_KEY`, `BACKUP_S3_SECRET_KEY`) live in `.env`.

### 7. Observability (env clusters)

```yaml
observability:
  loki_url: "https://loki.int.cc1.example.com/loki/api/v1/push"
  mimir_url: "https://thanos.int.cc1.example.com/api/v1/receive"
```

Remote write endpoints for centralized observability. Env clusters push logs and metrics to the Tooling Cluster's Loki and Thanos/Mimir receivers. Omit this section if the env cluster handles its own observability.

### 8. OCI configuration

```yaml
oci:
  repo:
    active: true
    url: "oci://ghcr.io/your-org/mojian"
    version: "latest"

  proxy:
    active: false
    url: "harbor.int.cc1.example.com"
```

| Field | Description |
|-------|-------------|
| `repo.active` | Enable Flux OCI reconciliation. When `false`, Flux is installed but no kustomizations are created. |
| `repo.url` | OCI registry URL for the gitops artifact. Prefixed with `oci://`. |
| `repo.version` | OCI tag. Use `latest` to track the most recent push, or pin to a specific version. |
| `proxy.active` | Enable container image pull-through via Harbor. |
| `proxy.url` | Harbor proxy cache hostname (no `oci://` prefix). Used in Talos machine registry mirrors. |

**OCI scenario table:**

| Scenario | `oci.repo.active` | `oci.proxy.active` | Notes |
|----------|-------------------|---------------------|-------|
| Tooling Cluster | `true` | `false` | The Tooling Cluster IS the proxy -- it hosts Harbor |
| App Env (internet access) | `true` | `true` | Pulls images through Tooling Cluster's Harbor |
| App Env (air-gapped) | `true` | `true` | `repo.url` points to Harbor; all images via proxy |
| Testing (empty cluster) | `false` | `false` | Flux installed but no reconciliation |

---

## Example: minimal Tooling Cluster config

```yaml
infra:
  provider: "proxmox"
  proxmox:
    placement:
      placement-group-1: "pve-node-1"

template: "h1m1"

cluster:
  name: "my-cc"
  role: "cc"
  vip: "10.0.0.100"
  flux:
    version: "2.7.2"

dns:
  provider: "digitalocean"
  domain: "cc.example.com"

app:
  lb_ipam:
    range: "10.0.0.101-10.0.0.102"
  alert_email: "ops@example.com"

oci:
  repo:
    active: true
    url: "oci://ghcr.io/your-org/mojian"
    version: "latest"
  proxy:
    active: false
    url: ""
```

## Example: App Environment config

```yaml
infra:
  provider: "proxmox"
  proxmox:
    placement:
      placement-group-1: "pve-node-1"
      placement-group-2: "pve-node-2"

template: "h2c1w3"

cluster:
  name: "env-prod"
  role: "env"
  vip: "10.0.0.110"
  flux:
    version: "2.7.2"

dns:
  provider: "digitalocean"
  domain: "prod.example.com"

app:
  lb_ipam:
    range: "10.0.0.111-10.0.0.113"
  alert_email: "ops@example.com"

backup:
  s3:
    endpoint: "https://s3.int.cc.example.com"
    bucket: "backups"
    region: "us-east-1"

observability:
  loki_url: "https://loki.int.cc.example.com/loki/api/v1/push"
  mimir_url: "https://thanos.int.cc.example.com/api/v1/receive"

oci:
  repo:
    active: true
    url: "oci://ghcr.io/your-org/mojian"
    version: "latest"
  proxy:
    active: true
    url: "harbor.int.cc.example.com"
```
