# Platform Team Guide

## Overview

This guide covers the platform team's responsibilities: building, publishing, and maintaining the OCI artifact that adopters consume via FluxCD. The platform team owns everything under `gitops/` and the platform service definitions — adopters never fork these files.

## Artifact Structure

The OCI artifact is a single package containing three directories. Each directory is a Kustomize root that Flux reconciles independently:

```
gitops/
  platform/          # Shared platform services (Cilium, cert-manager, external-dns, etc.)
  cc/                # Control Center services (Harbor, Vault, MinIO)
  env/               # App Environment services (Mojaloop app + dependencies)
```

**Deployment matrix:**

| Cluster role | Paths deployed | Order |
|-------------|----------------|-------|
| `cc` | `platform/` → `cc/` | platform first, cc depends on platform |
| `env` | `platform/` → `env/` | platform first, env depends on platform |

Flux uses `dependsOn` to enforce ordering — the role-specific Kustomization (cc or env) waits for platform to become healthy before reconciling.

## Directory Conventions

### platform/

Shared services deployed to every cluster. Add HelmReleases and Kustomizations here for infrastructure-level tools.

```
gitops/platform/
  kustomization.yaml           # Root kustomization — lists all resources
  namespace.yaml               # Platform namespace(s)
  cilium/
    helmrelease.yaml           # Cilium CNI
  cert-manager/
    helmrelease.yaml           # TLS automation
  external-dns/
    helmrelease.yaml           # DNS bridge (provider-agnostic via postBuild vars)
  ...
```

### cc/

Services specific to the Control Center management plane:

```
gitops/cc/
  kustomization.yaml
  namespace.yaml
  harbor/
    helmrelease.yaml           # OCI registry
  vault/
    helmrelease.yaml           # Secrets management
  minio/
    helmrelease.yaml           # Object storage for state/backups
  ...
```

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
| `${dns_provider}` | `config.yaml` | `digitalocean` |
| `${alert_email}` | `config.yaml` | `ops@example.com` |
| `${lb_ipam_range}` | `config.yaml` | `192.168.88.100-192.168.88.110` |

**Available secrets (from Secret `cluster-secrets`):**

| Variable | Source | Example |
|----------|--------|---------|
| `${digitalocean_token}` | `.env` | API token |
| `${oci_username}` | `.env` | Registry username |
| `${oci_password}` | `.env` | Registry password |

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

The Makefile handles OCI registry login automatically using credentials from `config/.env`. Set your GHCR credentials once:

```bash
# Generate a GitHub PAT with packages scope
gh auth refresh -s read:packages,write:packages

# Copy the token
gh auth token
```

Then add to `config/.env`:

```bash
OCI_USERNAME="your-github-username"
OCI_PASSWORD="ghp_xxxxxxxxxxxx"
```

All `make` gitops targets (`push-gitops`, `tag-gitops`, `list-artifacts`) use these credentials automatically via `--creds`.

For CI/CD, use `GITHUB_TOKEN` or a fine-grained PAT with `read:packages` + `write:packages` permissions.

### Push an artifact

```bash
# Push with auto-generated version (git SHA)
make push-gitops

# Push with explicit version
make push-gitops GITOPS_VERSION=v0.1.0

# Tag an existing version
make tag-gitops TAG=stable

# List all published versions
make list-artifacts
```

What `make push-gitops` does:
1. Packages the entire `gitops/` directory as an OCI artifact
2. Authenticates with credentials from `config/.env` (`OCI_USERNAME` / `OCI_PASSWORD`)
3. Pushes to the registry URL defined in `config/config.yaml` under `cluster.flux.artifact.url`
4. Tags with the git SHA (or explicit version)
5. Also tags as `latest`

### OCI registry URL

The artifact URL in `config/config.yaml` determines where artifacts are pushed and pulled:

```yaml
cluster:
  flux:
    artifact:
      url: "oci://ghcr.io/mojaloop/ml-gitops"
      version: "latest"
```

The URL format is `oci://<registry>/<owner>/<package-name>`:
- **GHCR**: `oci://ghcr.io/mojaloop/ml-gitops`
- **Harbor**: `oci://harbor.cc.example.com/mojaloop/ml-gitops`
- **ECR**: `oci://123456789.dkr.ecr.us-east-1.amazonaws.com/ml-gitops`

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
make push-gitops GITOPS_VERSION=v1.1.0
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
make tag-gitops TAG=stable

# Adopters can then pin to "stable" in their config.yaml:
# cluster.flux.artifact.version: "stable"
```

### Version coherence

All three directories (platform/, cc/, env/) ship in a single artifact. When you push `v1.2.0`, the adopter gets a coherent snapshot of all three paths. There is no risk of version drift between platform and role-specific paths.

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
