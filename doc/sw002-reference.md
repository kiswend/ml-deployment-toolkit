# SW002 Reference: Partner mTLS Implementation

## Overview

This document describes how the SW002 deployment (Mojaloop on Kubernetes with Istio Ambient Mode) implements mutual TLS for DFSP partner connectivity. SW002 is a reference implementation from InFiTx, located at `legacy/infitx/sw002-main/`. The IaC3 partner edge design (see `deployment-architecture.md`) is directly inspired by this architecture, adapted from Istio to Cilium.

**Key files:**

| File | Purpose |
|------|---------|
| `apps/mcm/configmaps/vault-config-configmap.hcl` | Vault Agent template — generates all per-DFSP Kubernetes resources |
| `apps/mcm/istio-gateway.yaml` | Egress waypoint Gateway + RBAC + VirtualServices for MCM |
| `apps/mcm/values-mcm.yaml` | MCM Helm values with Vault integration |
| `apps/mojaloop/values-mojaloop.yaml` | Mojaloop Helm values (notification handler config) |
| `apps/mojaloop/values-mojaloop-override.yaml` | Per-environment overrides |
| `apps/istio/istio-main/values-istio-istiod.yaml` | Istio ambient mode configuration |

## Architecture

SW002 uses Istio Ambient Mode for transparent mTLS origination on outbound DFSP callbacks. The architecture has three core components:

1. **Vault Agent template** — dynamic controller that generates Istio resources from Vault KV
2. **Istio ServiceEntry + DestinationRule** — per-DFSP mTLS configuration
3. **ml-egress-waypoint** — Istio waypoint proxy (L7 Envoy) that performs the actual mTLS handshake

```
                            SW002 OUTBOUND FLOW
                            ═══════════════════

  ml-api-adapter-handler-notification
      │
      │  HTTP to http://dfspA.example.com:80 (plain HTTP, port 80)
      │  App has ZERO TLS awareness
      │
      ▼
  ztunnel (Istio ambient, per-node)
      │
      │  Intercepts outbound connection
      │  Sees ServiceEntry for dfspA.example.com
      │  Label: istio.io/use-waypoint: ml-egress-waypoint
      │  Routes to waypoint via HBONE protocol
      │
      ▼
  ml-egress-waypoint (Envoy L7 proxy)
      │
      │  DestinationRule: originate-mtls-for-dfspA-callback
      │    mode: MUTUAL
      │    credentialName: dfspA-clientcert-tls (K8s Secret)
      │    sni: dfspA.example.com
      │    port 80 → targetPort 443 (upgrade)
      │
      ▼
  dfspA.example.com:443 (mTLS established)
```

### Key Design Properties

1. **Transparent interception** — The notification handler sends plain HTTP to `http://dfspA.example.com:80`. It doesn't know about TLS, certs, or the proxy. Istio's ztunnel intercepts the connection and routes it through the waypoint.

2. **Port forwarding** — The ServiceEntry maps port 80 (HTTP) to targetPort 443 (HTTPS). The app sends HTTP; the waypoint upgrades to HTTPS with mTLS. This decouples the application from TLS entirely.

3. **Per-DFSP isolation** — Each DFSP gets its own K8s Secret (client cert), ServiceEntry (DNS routing), and DestinationRule (mTLS config). Cert compromise for one DFSP doesn't affect others.

4. **Dynamic onboarding** — The Vault Agent template re-renders whenever Vault KV changes. Adding a DFSP to `secret/onboarding_pm4mls/` automatically generates all Istio resources, syncs certs, and provisions the DFSP in Central Ledger.

## Vault Agent Template

The Vault Agent runs as a sidecar on the MCM pod. It authenticates to Vault via Kubernetes auth method and renders a Go template that iterates over all DFSPs in `secret/onboarding_pm4mls/`.

Source: `apps/mcm/configmaps/vault-config-configmap.hcl`

### Authentication

```hcl
auto_auth = {
  method "kubernetes" {
    mount_path = "auth/kubernetes"
    config = {
      role = "kubernetes-mcm-role"
    }
  }
  sink = {
    config = { path = "/home/vault/.token" }
    type = "file"
  }
}
```

### Per-DFSP Resource Generation

The template iterates over all DFSPs and generates five resources per DFSP:

```hcl
template {
  contents = <<EOH
{{ range secrets "secret/onboarding_pm4mls/" }}
{{ with secret (printf "secret/onboarding_pm4mls/%s" .) }}
```

#### 1. VaultSecret CR (cert sync)

Syncs the DFSP's client certificate bundle from Vault KV to a Kubernetes `kubernetes.io/tls` Secret:

```yaml
apiVersion: redhatcop.redhat.io/v1alpha1
kind: VaultSecret
metadata:
  name: {{ .Data.host }}-clientcert-tls
  namespace: mojaloop
spec:
  refreshPeriod: 1m0s
  vaultSecretDefinitions:
    - authentication:
        path: kubernetes
        role: policy-admin
        serviceAccount:
            name: default
      name: clientcertsecret
      path: secret/onboarding_pm4mls/{{ .Data.host }}
  output:
    name: {{ .Data.host }}-clientcert-tls
    stringData:
      ca.crt: '{{ `{{ .clientcertsecret.ca_bundle }}` }}'
      tls.key: '{{ `{{ .clientcertsecret.client_key }}` }}'
      tls.crt: '{{ `{{ .clientcertsecret.client_cert_chain }}` }}'
    type: kubernetes.io/tls
```

Note: The template has **two levels of Go template rendering** — the outer level is Vault Agent (`{{ .Data.host }}`), the inner level is the VaultSecret operator (`{{ .clientcertsecret.ca_bundle }}`). The inner templates are escaped with backticks to prevent Vault Agent from evaluating them.

The `VaultSecret` CRD is from the `redhatcop/vault-config-operator`. In IaC3, this is replaced by direct `kubectl apply` of K8s Secrets from the Vault Agent template (the cert data is already available in the template context, making the intermediate operator unnecessary).

#### 2. ServiceEntry (DNS registration + waypoint routing)

Registers the DFSP's external FQDN with the Istio mesh and routes traffic through the egress waypoint:

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: {{ .Data.host }}
  namespace: mojaloop
  labels:
    istio.io/use-waypoint: ml-egress-waypoint
spec:
  hosts:
  - '{{ .Data.fqdn }}'
  ports:
  - number: 80
    name: http
    protocol: HTTP
    targetPort: 443       # Port forwarding: app sends HTTP:80, mesh connects HTTPS:443
  - number: 443
    name: https
    protocol: HTTPS
  resolution: DNS
```

The `istio.io/use-waypoint: ml-egress-waypoint` label is the key mechanism — it tells Istio's ztunnel to route traffic to this FQDN through the `ml-egress-waypoint` Gateway instead of connecting directly.

#### 3. DestinationRule (mTLS origination)

Configures per-DFSP mutual TLS on the waypoint proxy:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: originate-mtls-for-{{ .Data.host }}-callback
  namespace: mojaloop
spec:
  host: {{ .Data.fqdn }}
  trafficPolicy:
    connectionPool:
      tcp:
        connectTimeout: 3s
        tcpKeepalive:
          time: 300s
          interval: 30s
          probes: 5
    loadBalancer:
      simple: ROUND_ROBIN
    portLevelSettings:
    - port:
        number: 80
      tls:
        mode: MUTUAL
        credentialName: {{ .Data.host }}-clientcert-tls
        sni: {{ .Data.fqdn }}
```

The `credentialName` references the K8s Secret created by the VaultSecret CR above. Istio's waypoint proxy reads this Secret and uses it for the mTLS handshake. The `sni` field ensures proper Server Name Indication.

#### 4. ConfigMap + Job (Central Ledger provisioning)

Registers the DFSP in Mojaloop's Central Ledger using the Testing Toolkit (TTK):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Data.host }}-ml-ttk-add-dfsp-conf
  namespace: mojaloop
data:
  cli-add-dfsp-environment.json: |
    {
      "inputValues": {
        "HOST_ACCOUNT_LOOKUP_SERVICE": "http://moja-account-lookup-service",
        "HOST_CENTRAL_LEDGER": "http://moja-centralledger-service",
        "DFSP_CALLBACK_URL": "http://{{ .Data.fqdn }}",
        "DFSP_NAME": "{{ .Data.host }}",
        "currency": "{{ .Data.currency_code }}"
      }
    }
```

Note: The callback URL is `http://{{ .Data.fqdn }}` — the real DFSP FQDN over HTTP. Istio intercepts this transparently and upgrades to mTLS via the ServiceEntry + DestinationRule. The application never connects directly to this URL.

A Kubernetes Job runs the TTK test collection (`collections/hub/provisioning/new_participants/new_dfsp.json`) against the Mojaloop backend to register the DFSP with its callback URL, currency, and settlement parameters.

### IP Whitelisting (AuthorizationPolicy)

A second Vault Agent template generates an Istio `AuthorizationPolicy` for inbound IP whitelisting. It combines IPs from two Vault KV paths:

```hcl
template {
  contents = <<EOH
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: dfsp-whitelist-ingress-policy
  namespace: mojaloop
spec:
  targetRefs:
    - kind: Service
      name: moja-account-lookup-service
    - kind: Service
      name: moja-ml-api-adapter-service
    - kind: Service
      name: moja-quoting-service
    - kind: Service
      name: moja-transaction-requests-service
  action: DENY
  rules:
  - from:
      - source:
          notRemoteIpBlocks: [
            {{ range Vault "secret/whitelist_fsps" }}{{ . }},{{ end }}
            {{ range Vault "secret/whitelist_pm4mls" }}{{ . }},{{ end }}
            10.21.0.0/17   # Cluster-internal CIDR
          ]
    to:
      - operation:
          hosts: ["extapi.sw002.mojaloop.live", "extapi.sw002.mojaloop.live:*"]
  EOH
  destination = "/vault/secrets/tmp/whitelist.yaml"
  command = "kubectl apply -f /vault/secrets/tmp/whitelist.yaml"
}
```

This DENY policy rejects traffic from any IP **not** in the whitelist. The whitelist is rebuilt from all DFSPs whenever any DFSP's IP list changes in Vault.

## Egress Waypoint

The `ml-egress-waypoint` is an Istio waypoint proxy — a per-namespace L7 Envoy that handles traffic requiring advanced features (mTLS origination, header routing, retries).

Source: `apps/mcm/istio-gateway.yaml` (lines 98–136)

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: ml-egress-waypoint
  namespace: mojaloop
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE           # HTTP-Based Overlay Network Environment
    allowedRoutes:
      namespaces:
        from: All
```

HBONE (HTTP-Based Overlay Network Environment) is Istio ambient mode's internal protocol for pod-to-waypoint communication. The ztunnel on each node encapsulates traffic in HBONE and routes it to the waypoint.

The waypoint's service account needs RBAC to read the per-DFSP cert Secrets:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ml-egress-waypoint-cert-access
  namespace: mojaloop
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ml-egress-waypoint-cert-access-binding
  namespace: mojaloop
subjects:
- kind: ServiceAccount
  name: ml-egress-waypoint
  namespace: mojaloop
roleRef:
  kind: Role
  name: ml-egress-waypoint-cert-access
  apiGroup: rbac.authorization.k8s.io
```

## Notification Handler

The `ml-api-adapter-handler-notification` is a **separate Kubernetes Deployment** (not part of ml-api-adapter-service). It reads transfer notification events from Kafka and sends HTTP callbacks to DFSP endpoints.

Source: `apps/mojaloop/values-mojaloop.yaml` (line 401)

```yaml
ml-api-adapter:
  ml-api-adapter-handler-notification:
    replicaCount: 1
    # ... uses HANDLER_WITH_PROXY config (Redis proxy cache, not HTTP proxy)
```

The notification handler is configured with `PROXY_CONFIG` which refers to Mojaloop's internal Redis proxy cache for participant lookups — this is **not** an HTTP proxy. The handler sends plain HTTP to whatever callback URL is registered for the DFSP in Central Ledger.

The `bulk-api-adapter-handler-notification` handles bulk transfer callbacks using the same pattern.

## MCM Configuration

MCM connects to Vault for certificate management:

Source: `apps/mcm/values-mcm.yaml`

```yaml
vault:
  auth:
    k8s:
      enabled: true
      role: mcm
      mountPoint: kubernetes
  endpoint: "http://vault.vault.svc.cluster.local:8200"
  mounts:
    pki: pki-sw002                            # PKI secrets engine (cert issuance)
    kv: secret/mcm                            # KV store (MCM operational data)
    dfspClientCertBundle: secret/onboarding_pm4mls    # Per-DFSP cert bundles
    dfspInternalIPWhitelistBundle: secret/whitelist_pm4mls
    dfspExternalIPWhitelistBundle: secret/whitelist_fsps
  pkiServerRole: server-cert-role
  pkiClientRole: client-cert-role
  signExpiryHours: 43800                      # ~5 years
```

## DFSP Onboarding End-to-End

When a DFSP is onboarded via the MCM portal:

```
1. DFSP operator logs into MCM (Keycloak, dfsps realm)

2. MCM generates/signs certificates:
   a. DFSP submits CSR → MCM signs via Vault PKI (client-cert-role)
   b. MCM stores signed cert + key + CA bundle in Vault KV:
      secret/onboarding_pm4mls/{dfsp-host}
        ├── host: "dfspA"
        ├── fqdn: "callback.dfspA.example.com"
        ├── currency_code: "USD"
        ├── isProxy: "false"
        ├── client_cert_chain: "-----BEGIN CERTIFICATE-----..."
        ├── client_key: "-----BEGIN RSA PRIVATE KEY-----..."
        └── ca_bundle: "-----BEGIN CERTIFICATE-----..."

3. MCM stores DFSP IP addresses in Vault KV:
   secret/whitelist_pm4mls/{dfsp-host}: "203.0.113.0/24"
   secret/whitelist_fsps/{dfsp-host}: "203.0.113.0/24"

4. Vault Agent template re-renders (~5 min cycle):
   kubectl apply generates:
   a. VaultSecret CR → K8s Secret: dfspA-clientcert-tls (mojaloop namespace)
   b. ServiceEntry: dfspA (with istio.io/use-waypoint label)
   c. DestinationRule: originate-mtls-for-dfspA-callback
   d. ConfigMap: dfspA-ml-ttk-add-dfsp-conf
   e. Job: dfspA-onboard-dfsp (TTK provisioning)
   f. AuthorizationPolicy: dfsp-whitelist-ingress-policy (rebuilt with new IP)

5. VaultSecret operator syncs cert from Vault to K8s Secret (refreshPeriod: 1m)

6. Istio waypoint picks up the DestinationRule and cert Secret

7. TTK Job provisions DFSP in Central Ledger:
   - Registers callback URL: http://callback.dfspA.example.com
   - Creates participant record with currency and settlement config

8. DFSP is live — can send/receive transfers
```

## Mapping to IaC3 (Cilium)

| SW002 (Istio Ambient) | IaC3 (Cilium) | Notes |
|---|---|---|
| Vault Agent template | Vault Agent template | Same mechanism, different output CRDs |
| `VaultSecret` CR (redhatcop operator) | Direct `kubectl apply` of K8s Secret | Simpler — no operator dependency |
| `ServiceEntry` + waypoint label | `partner-egress-proxy` Service + CiliumEnvoyConfig `backendServices` | Explicit proxy replaces transparent mesh interception |
| `DestinationRule` (per-DFSP mTLS) | Per-DFSP upstream cluster in CiliumEnvoyConfig | Single CiliumEnvoyConfig contains all DFSPs |
| `ml-egress-waypoint` (istio-waypoint Gateway) | Pause container Deployment (Cilium Envoy does work) | No standalone Envoy needed |
| `AuthorizationPolicy` (IP whitelist) | `CiliumNetworkPolicy` (fromCIDR) | Same data, different CRD |
| Callback URL: `http://dfsp.example.com` (transparent) | Callback URL: `http://partner-egress-proxy.mojaloop.svc` | Routes by `FSPIOP-Destination` header |
| Istio ambient ztunnel (transparent intercept) | CiliumEnvoyConfig `backendServices` (explicit intercept) | Cilium lacks ServiceEntry equivalent |
| HBONE protocol (pod → waypoint) | Standard TCP (pod → proxy Service → Cilium Envoy) | No special protocol needed |

### Key Architectural Difference

In SW002, Istio's `ServiceEntry` enables **transparent interception** — the notification handler sends to the real DFSP FQDN and Istio reroutes through the waypoint without the application knowing. Cilium does not have a ServiceEntry equivalent, so the IaC3 design uses an **explicit egress proxy Service**. The callback URL in Central Ledger points to the proxy, and the `FSPIOP-Destination` header (already set by the notification handler) drives per-DFSP routing in the CiliumEnvoyConfig.

The trade-off: slightly less transparent (callback URL is the proxy, not the DFSP FQDN), but eliminates the Istio dependency while preserving all security properties (per-DFSP certs, mTLS origination, IP whitelisting, zero TLS awareness in the application).
