# Deployment

[docs](../index.md) / [adopter](index.md) / Deployment

**Audiences:** adopter (deploy)

How to deploy, verify, and destroy Mojian environments. For configuration, see [Configuration](configuration.md). For architecture context, see [System Overview](../architecture/system-overview.md).

---

## Initialize

Download providers and initialize Terraform modules:

```bash
make init ENV=cc
```

Run this once for a new environment, or after changing providers or upgrading Terraform modules. The `init` step runs automatically as part of `plan` and `plan-apply`, so you rarely need to run it explicitly.

## Plan and apply

```bash
make plan ENV=cc          # Create execution plan (saved to artifacts/)
make apply ENV=cc         # Apply the saved plan
```

Or combine both steps to avoid stale plan errors:

```bash
make plan-apply ENV=cc
```

The `plan-apply` target creates a plan and applies it immediately. This is the recommended workflow because a plan can become stale if infrastructure changes between `plan` and `apply`.

### What happens during apply

Terraform executes modules in order:

1. **config-loader** -- reads `config.yaml`, resolves templates and placement
2. **Provider module** (proxmox, aws, or digitalocean) -- provisions the Kubernetes cluster
3. **flux-bootstrap** -- installs FluxCD controllers via Helm
4. **flux-config** -- creates OCIRepository, Kustomizations, ConfigMap, and Secret (only when `oci.repo.active: true`)

Once Flux is running, it reconciles the OCI artifact and deploys all gitops-managed services. This takes several minutes after Terraform completes.

---

## Verify

After `make apply` completes, verify the deployment.

### Set KUBECONFIG

```bash
export KUBECONFIG=$(pwd)/artifacts/cc/kubernetes/kubeconfig
```

### Check cluster health

```bash
# Nodes should be Ready
kubectl get nodes

# Flux controllers should be Running
kubectl get pods -n flux-system
```

### Check Flux reconciliation

```bash
# OCIRepository should show the artifact revision
kubectl get ocirepository -n flux-system

# All Kustomizations should be Ready
kubectl get kustomizations -n flux-system
```

### Tooling Cluster verification

For deployments with `cluster.role: cc`:

```bash
# Gateways should have addresses assigned
kubectl get gateways -n platform-system

# TLS certificates should be Ready
kubectl get certificates -n platform-system

# Tooling Cluster namespaces should exist
kubectl get ns vault harbor minio

# Services should be running
kubectl get pods -n vault
kubectl get pods -n harbor
kubectl get pods -n minio

# HTTPRoutes should be Accepted
kubectl get httproutes -A
```

### App Environment verification

For deployments with `cluster.role: env`:

```bash
# Mojaloop HelmRelease should be Ready
kubectl get helmrelease -n mojaloop

# Data layer operators and clusters
kubectl get perconaxtradbcluster -n mojaloop    # MySQL (PXC)
kubectl get strimzikafka -n mojaloop             # Kafka (if applicable)
kubectl get perconaservermongodb -n mojaloop      # MongoDB

# Auth stack
kubectl get pods -n auth

# All Gateways should have addresses
kubectl get gateways -n platform-system

# All Kustomizations should be Ready
kubectl get kustomizations -n flux-system
```

---

## Accessing Tooling Cluster services

The Tooling Cluster exposes services via Gateway API HTTPRoutes. URLs follow the pattern `{service}.int.{domain}` or `{service}.ext.{domain}`.

| Service | URL pattern | Purpose |
|---------|-------------|---------|
| Vault | `https://vault.int.{domain}` | Secrets management, PKI |
| Harbor | `https://harbor.int.{domain}` | OCI registry, pull-through proxy cache |
| MinIO | `https://minio.int.{domain}` | S3-compatible object storage console |
| Grafana | `https://grafana.int.{domain}` | Dashboards and alerting |

Where `{domain}` is the `dns.domain` value from the environment's `config.yaml`.

Harbor and MinIO are present on self-hosted (on-prem) Tooling Clusters only. Cloud deployments may use managed equivalents (S3, ECR/GHCR).

---

## Harbor proxy cache

When `oci.proxy.active: true`, the App Environment pulls container images through the Tooling Cluster's Harbor instance. Harbor acts as a transparent pull-through cache -- images are fetched from upstream registries on first pull and cached for subsequent requests.

This is configured at the Talos machine level (containerd registry mirrors), so all image pulls are transparently routed through Harbor without changes to Helm charts or pod specs.

### Verify proxy cache is working

```bash
# On the App Environment cluster:
# Check that nodes have registry mirrors configured (Talos)
talosctl get registries.mirrors

# Pull an image and verify it appears in Harbor's proxy cache projects
kubectl run test --image=nginx:latest --restart=Never
kubectl delete pod test
```

In Harbor's web UI, proxy cache projects show cached images with their upstream source and pull count.

---

## Outputs

After a successful `make apply`, the following artifacts are produced:

| Artifact | Path | Description |
|----------|------|-------------|
| Terraform state | `artifacts/{env}/terraform/terraform.tfstate` | Full infrastructure state |
| Terraform plan | `artifacts/{env}/terraform/tfplan` | Last executed plan |
| Kubeconfig | `artifacts/{env}/kubernetes/kubeconfig` | Cluster access credentials |
| Talosconfig | `artifacts/{env}/talos-config/talosconfig` | Talos API credentials (on-prem only) |

Terraform also exposes these outputs:

| Output | Description |
|--------|-------------|
| `cluster_name` | The cluster name from config |
| `cluster_endpoint` | Kubernetes API endpoint (VIP for on-prem, managed endpoint for cloud) |
| `kubeconfig_path` | Absolute path to the kubeconfig file |
| `talosconfig_path` | Absolute path to talosconfig (on-prem only, null for cloud) |
| `flux_installed` | Whether FluxCD controllers are installed |
| `oci_repo_active` | Whether Flux OCI reconciliation is active |

View outputs with:

```bash
cd src && terraform output
```

---

## Commands reference

All commands run from the repository root. `ENV=` selects the environment (default: `cc`).

### Main commands

| Command | Description |
|---------|-------------|
| `make plan ENV=<env>` | Create Terraform execution plan (saved to `artifacts/{env}/terraform/tfplan`) |
| `make apply ENV=<env>` | Apply the saved plan. Fails if no plan exists. |
| `make plan-apply ENV=<env>` | Create plan and apply immediately. Recommended workflow. |

### Alternative apply commands

| Command | Description |
|---------|-------------|
| `make apply-direct ENV=<env>` | Apply directly without a saved plan (auto-approve). Skips the plan file. |
| `make apply-force ENV=<env>` | Alias for `plan-apply`. |

### Utility commands

| Command | Description |
|---------|-------------|
| `make init ENV=<env>` | Initialize Terraform (download providers, configure backend). Runs automatically with `plan` and `plan-apply`. |
| `make validate` | Validate Terraform configuration syntax. |
| `make fmt` | Format Terraform files recursively. |
| `make show` | Display current Terraform state. |
| `make list` | List all resources in Terraform state. |
| `make clean` | Remove all artifacts (`artifacts/` directory). |

### GitOps artifact commands

| Command | Description |
|---------|-------------|
| `make push-gitops ENV=<env>` | Push `gitops/` directory as OCI artifact. Version defaults to the current git SHA; also tagged `latest`. |
| `make push-gitops ENV=<env> GITOPS_VERSION=v1.0.0` | Push with an explicit version tag. |
| `make tag-gitops TAG=<tag>` | Add an additional tag to the current artifact version. |
| `make list-artifacts ENV=<env>` | List published OCI artifact versions. |

### Rendering commands

| Command | Description |
|---------|-------------|
| `make render` | Render all pre-rendered manifests (Jsonnet to YAML). |
| `make render-thanos` | Render Thanos manifests only. |

### Destroy commands

| Command | Description |
|---------|-------------|
| `make destroy ENV=<env>` | Destroy all infrastructure. 5-second safety delay before execution. |
| `make destroy-fast ENV=<env>` | Destroy without refreshing state first. Use when resources are already gone. 3-second safety delay. |

---

## Destroy

To tear down an environment:

```bash
make destroy ENV=cc
```

This destroys all Terraform-managed infrastructure for the environment. There is a 5-second safety delay before execution -- press Ctrl+C to cancel.

If resources have already been deleted outside of Terraform (e.g., VMs manually removed), use the fast variant to skip the state refresh:

```bash
make destroy-fast ENV=cc
```

Destroy does not remove the `artifacts/` directory. Run `make clean` separately to remove local artifacts.

**Warning:** Destroy is irreversible. For Tooling Clusters, this removes Vault (secrets), Harbor (cached images), and MinIO (backups). Ensure the recovery kit is stored offline before destroying a Tooling Cluster. See [Security](../architecture/security.md) for recovery kit details.
