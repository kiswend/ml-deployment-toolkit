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

**Bundle creation:** OCI bundles containing:
- Terraform modules for infrastructure provisioning
- Platform services (see below)

**Platform Services:**

| Component | Tool | Purpose |
|-----------|------|---------|
| CNI & Internal Mesh | Cilium | Internal networking, network policies, internal mTLS |
| Partner Edge | Envoy | External mTLS with dynamic partner onboarding (xDS/SDS) |
| Certificates | cert-manager + trust-manager | TLS automation, CA distribution to network edge |
| Storage | OpenEBS (Mayastor/LVM) | High-performance local storage for data layers |
| DNS | external-dns | Bridge K8s services to provider DNS (Route53, Cloudflare, DigitalOcean, PowerDNS) |

### DNS Configuration Strategy

The platform must support multiple DNS providers (e.g., AWS Route53, Cloudflare, DigitalOcean) with different authentication requirements. To maintain a clean separation between Infrastructure as Code (IaC) and GitOps:

1.  **Configuration Source:** DNS provider settings and credentials are defined in the IaC configuration (`config.yaml`).
2.  **IaC Responsibility:** Terraform reads this configuration and generates a provider-specific `values.yaml` blob. This blob contains the exact nested structure required by the `external-dns` Helm chart for that specific provider.
3.  **Secret Injection:** Terraform injects this blob into a Kubernetes Secret (e.g., `cluster-config`) in the GitOps controller's namespace.
4.  **GitOps Consumption:** The FluxCD `HelmRelease` for `external-dns` references this secret using `valuesFrom`. This allows the GitOps manifest to remain generic while the specific configuration is supplied dynamically by the infrastructure layer.

**Distribution:** Publish validated bundles to public OCI registry

### Stage 3: Adopter Control Center

**Bootstrap process:**
1. Pull OCI bundle via CLI
2. Configure `config/.env` with provider credentials
3. Configure `config/config.yaml` with infrastructure settings
4. Run `terraform apply`

**Control Center hosts:**

| Service | Purpose |
|---------|---------|
| Harbor | Local OCI registry - source of truth and cache |
| Vault | Secrets management, internal CA, partner keys |
| MinIO | Infrastructure state and backup storage |
| FluxCD | GitOps reconciliation (OCI-based, not Git) |
| tf-controller | Terraform automation for downstream environments |

### Stage 4: Adopter App Environment

**Creation flow:**
1. Push environment config to CC Harbor
2. CC FluxCD detects change
3. tf-controller provisions the App Environment
4. App Environment pulls artifacts from CC Harbor

**Customization:** Flux Kustomize patches handle provider differences:
- AWS: NLB annotations, EBS storage classes
- On-prem: MetalLB/IPAM, local storage

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
