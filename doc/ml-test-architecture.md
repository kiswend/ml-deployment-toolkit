# ML-Test Cluster Architecture

## Overview

This document describes the design and implementation plan for the `ml-test` cluster type - a dedicated cluster for running test DFSPs with SDK scheme adapters, backend simulators, and **ml-mcm-agent** for automated certificate management via MCM. This provides production-realistic DFSP testing with proper mTLS, supporting both TTK (functional) and K6 (performance) testing.

## Context: Cleaner Architecture Evolution

### Current State
The repository currently has a single `ml` cluster that combines:
- Data layer (MySQL, Kafka, MongoDB)
- Auth services (Keycloak, Ory, Vault)
- Mojaloop core services
- Gateways (gw-int, gw-ext, proxy-ext-api)
- Grafana observability stack

### Proposed Architecture (4 Clusters)

See [potential-cleaner-ml-arch.md](potential-cleaner-ml-arch.md) for the visual diagram.

**1. ext-tools** - Shared infrastructure services
- MinIO/S3, Harbor, Forgejo
- (Grafana stack may move here or stay in ml)

**2. ml-data** - Dedicated data layer (optional future enhancement)
- MySQL (Percona XtraDB Cluster)
- Kafka (Strimzi)
- MongoDB (PSMDB)
- Note: Data layer operators have built-in PMM/JMX exporters, no separate monitoring agents needed

**3. ml** - Application/switch layer
- Auth services (Keycloak, Ory, Vault)
- Mojaloop core services
- Gateways
- Redis (local to app layer)
- Grafana observability stack
- Data layer (currently co-located, may separate later)

**4. ml-test** - Test DFSPs and clients (NEW - this document)
- DFSP simulators with SDK scheme adapters
- ml-mcm-agent for certificate management
- Test clients (TTK, K6)

### Design Rationale

**Why separate ml-test cluster?**
- Isolation: Test DFSP failures don't affect production switch
- Realism: Tests DFSP↔Hub communication over network, not in-cluster
- Flexibility: Can destroy/recreate test cluster without affecting ml
- Scale: Can scale test DFSPs independently (2 for functional, 8 for performance)

**Why not use native Mojaloop helm tests?**
- Native tests don't use SDK scheme adapters (unrealistic)
- No mTLS testing capability
- No MCM client integration testing
- Limited performance testing (TTK only, no K6)
- Bundled with switch deployment (not independent)

**Alternatives considered:**
- Keep test DFSPs in same cluster as ml: Simpler but less realistic, can start here for MVP
- Multi-cluster approach (like legacy perf test): Too complex, networking overhead

---

## ml-mcm-agent: Certificate Lifecycle Manager

### What is ml-mcm-agent?

**Repository**: `https://github.com/mojaloop/ml-mcm-agent` (cloned to `legacy/ml-mcm-agent`)

**Purpose**: Node.js-based configuration management service that wraps the Mojaloop MCM Client library, providing administrator-friendly interfaces (Terminal UI + REST API + CLI) for managing DFSP certificate lifecycles and SDK scheme-adapter configuration.

**Version**: 0.1.1 (January 2026)
**Language**: TypeScript + React (for TUI)
**Node.js Requirement**: >= 22.0.0

### Architecture

**Deployment Model**: Daemon + Client architecture
- **Daemon** (backend): Persistent service on port 3000, exposes REST API, manages MCM Client state machine
- **TUI** (frontend): Interactive Terminal UI (React + Ink) for operators
- **CLI**: Quick commands like `mcm-agent status`
- **REST API**: `/api/*` endpoints for programmatic access

**Deployment Patterns for ml-test**:
- **Sidecar** (recommended): Runs alongside SDK Scheme Adapter in same pod
- **Standalone**: Separate deployment per DFSP namespace
- **Job**: Init container that enrolls certs then exits

### How ml-mcm-agent Works

#### 1. Initialization Flow
```
Pod starts → mcm-agent sidecar starts → Daemon initializes
│
├─ Load environment variables (VAULT_ENDPOINT, VAULT_AUTH_K8S_ROLE, etc.)
├─ Authenticate to Vault using K8s ServiceAccount token
│  └─ POST /v1/auth/kubernetes/login (role: mcm-agent-dfsp-101)
│
├─ Load configuration from Vault KV
│  └─ GET /v1/secret/data/mcm-agent/dfsp-101/config
│     Returns: { mcm: {...}, sdk: {...}, vault: {...} }
│
├─ Initialize MCM Client State Machine
│  ├─ Create Vault client (PKI + KV access)
│  ├─ Create AuthModel (OIDC token refresh for MCM server)
│  ├─ Create DFSPCertificateModel (cert operations)
│  ├─ Create DFSPEndpointModel (endpoint registration)
│  └─ Start ConnectionStateMachine
│
└─ Start REST API server on port 3000
```

#### 2. Certificate Enrollment Flow
```
Init container → curl POST /api/actions/create-int-ca
│
mcm-agent → ConnectionStateMachine → CREATE_INT_CA event
│
├─ Call DFSPCertificateModel.createInternalCA()
│  └─ Vault: POST /v1/pki/root/generate/internal
│     Creates root CA in Vault PKI
│
└─ Transition to next state → CREATE_DFSP_CLIENT_CERT

Init container → curl POST /api/actions/create-client-csr
│
mcm-agent → CREATE_DFSP_CLIENT_CERT event
│
├─ Generate CSR using Vault PKI
│  └─ POST /v1/pki/issue/mcm-client-role
│
├─ Authenticate to MCM Server via OIDC
│  └─ POST https://keycloak.int.${domain}/realms/dfsps/protocol/openid-connect/token
│     Body: grant_type=client_credentials, client_id=dfsp-101-client
│     Response: JWT access token
│
├─ Submit CSR to MCM Server
│  └─ POST https://mcm.ext.${domain}/api/dfsps/dfsp-101/enrollments
│     Headers: Authorization: Bearer {jwt_token}
│     Body: { csr: "...", dfspId: "dfsp-101" }
│
├─ MCM Server signs CSR via Vault PKI
│  └─ Response: { certificate: "...", ca_chain: [...] }
│
├─ Store cert in Vault
│  └─ POST /v1/pki/certs
│
├─ Write cert to shared volume
│  └─ /certs/client-cert.pem, /certs/client-key.pem, /certs/ca-bundle.pem
│
└─ Transition → CREATE_DFSP_SERVER_CERT

Init container → curl POST /api/actions/create-server-cert
│
mcm-agent → CREATE_DFSP_SERVER_CERT event
│
├─ Generate server cert using Vault PKI
│  └─ POST /v1/pki/issue/mcm-server-role
│     Params: CN=dfsp-101.test.${domain}, alt_names=[...], ttl=8760h
│
├─ Write to shared volume
│  └─ /certs/inbound-cert.pem, /certs/inbound-key.pem, /certs/inbound-cacert.pem
│
└─ State transitions to RUNNING
```

#### 3. SDK Consumes Certificates
```
Init container completes → SDK Scheme Adapter starts
│
SDK reads environment variables:
├─ INBOUND_MUTUAL_TLS_ENABLED=true
├─ OUTBOUND_MUTUAL_TLS_ENABLED=true
├─ IN_CA_CERT_PATH=/secrets/inbound-cacert.pem
├─ IN_SERVER_CERT_PATH=/secrets/inbound-cert.pem
├─ IN_SERVER_KEY_PATH=/secrets/inbound-key.pem
├─ OUT_CA_CERT_PATH=/secrets/ca-bundle.pem
├─ OUT_CLIENT_CERT_PATH=/secrets/client-cert.pem
└─ OUT_CLIENT_KEY_PATH=/secrets/client-key.pem

SDK starts TLS server:
└─ https.createServer({ key, cert, ca, requestCert: true })
   Listens on port 4000 (HTTPS with mTLS)
```

#### 4. Certificate Renewal (Background)
```
mcm-agent background loop (every 60 seconds):
│
├─ Check certificate expiry
│  └─ GET /v1/pki/cert/{serial}
│
├─ If expiry < 30 days:
│  ├─ Send RENEW_DFSP_CLIENT_CERT event
│  ├─ Repeat enrollment flow
│  ├─ Write new cert to shared volume
│  └─ Trigger SDK rolling restart
│
└─ SDK pod restarts → Loads new cert → mTLS continues
```

### ml-mcm-agent REST API

**Base URL**: `http://localhost:3000` (within pod)

#### Health Check
```
GET /health
Response: { status: "ok", mcmClient: { initialized, running } }
```

#### Configuration Management
```
GET /api/config                    # Returns current DFSP configuration
POST /api/config                   # Save config, hot-reload MCM client
PATCH /api/config                  # Merge with existing, reload
GET /api/config/versions           # List Vault versioning metadata
POST /api/config/validate          # Validate schema without saving
```

#### Status & Monitoring
```
GET /api/status
Response:
{
  "initialized": boolean,
  "running": boolean,
  "currentState": string,
  "states": {
    "CREATE_INT_CA": { "status": "completed", "lastUpdated": "..." },
    "CREATE_DFSP_CLIENT_CERT": { "status": "completed", "lastUpdated": "..." },
    ...
  },
  "certificateExpiry": {
    "dfspClient": "2027-03-11T10:01:00Z",
    "dfspServer": "2027-03-11T10:02:00Z"
  }
}
```

#### Certificate Actions
```
POST /api/actions/create-int-ca        # Create internal CA
POST /api/actions/create-ext-ca        # Upload external CA (PEM)
POST /api/actions/create-client-csr    # Generate client CSR for MCM enrollment
POST /api/actions/create-server-cert   # Create server certificate (inbound TLS)
POST /api/actions/recreate-jws         # Regenerate JWS signing keys
```

### Configuration Schema

**Storage**: HashiCorp Vault KV v2 mount at `secret/mcm-agent/{dfspId}/config`

**Structure**:
```json
{
  "common": {
    "dfspId": "dfsp-101"
  },
  "mcm": {
    "serverEndpoint": "https://mcm.ext.${domain}",
    "auth": {
      "enabled": true,
      "creds": {
        "clientId": "dfsp-101-client",
        "clientSecret": "${DFSP_101_MCM_SECRET}"
      }
    },
    "hubIamProviderUrl": "https://keycloak.int.${domain}/realms/dfsps",
    "certExpiryThresholdDays": 30
  },
  "sdk": {
    "fqdn": "dfsp-101.test.${domain}",
    "callbackUrl": "https://dfsp-101.test.${domain}",
    "currencies": ["USD"],
    "peerEndpoint": "https://ml-api-adapter.mojaloop.svc.cluster.local:443",
    "alsEndpoint": "https://account-lookup-service.mojaloop.svc.cluster.local:443",
    "tls": {
      "outboundMutual": true,
      "inboundMutual": true
    }
  },
  "dfspServerCsrParameters": {
    "subject": { "CN": "dfsp-101.test.${domain}", "C": "US", "O": "DFSP-101" },
    "extensions": {
      "subjectAltName": {
        "dns": ["dfsp-101.test.${domain}"],
        "ips": []
      }
    }
  }
}
```

### Vault Configuration

**Environment Variables** (required at daemon startup):
```bash
# Vault Connection
VAULT_ENDPOINT=http://vault.vault.svc.cluster.local:8200
VAULT_KV_MOUNT=secret                      # KV v2 mount for agent config
VAULT_STATE_MACHINE_KV_MOUNT=secrets       # KV v1 mount for state machine state
VAULT_PKI_MOUNT=pki                        # PKI mount

# Authentication
VAULT_AUTH_K8S_ROLE=mcm-agent-dfsp-101     # K8s auth role
VAULT_K8S_TOKEN_FILE=/var/run/secrets/kubernetes.io/serviceaccount/token

# Server
PORT=3000
HOST=0.0.0.0
NODE_ENV=production
LOG_LEVEL=info

# PKI Settings
VAULT_PKI_SERVER_ROLE=mcm-server-role
VAULT_PKI_CLIENT_ROLE=mcm-client-role
VAULT_SIGN_EXPIRY_HOURS=8760
VAULT_KEY_LENGTH=4096

# Config Path
VAULT_CONFIG_PATH=mcm-agent/dfsp-101/config
```

**Vault Setup per DFSP**:
- Create K8s auth role: `mcm-agent-dfsp-{N}`
- Policy grants access to:
  - `secret/data/mcm-agent/dfsp-{N}/*` (KV v2 for config)
  - `pki/issue/mcm-client-role` (PKI for CSR signing)
  - `pki/issue/mcm-server-role` (PKI for server certs)

---

## ml-test Cluster Architecture

### Namespace Layout

```
ml-test cluster:
├── platform-system/             # Gateway namespace
│   ├── gw-test                  # Gateway (*.test.${domain})
│   └── extapi-mtls-test         # CiliumEnvoyConfig (optional, if testing mTLS)
│
├── dfsp-101/                    # First test DFSP
│   ├── sdk-scheme-adapter       # Pod with SDK + mcm-agent sidecar
│   ├── backend-simulator        # Mojaloop simulator backend
│   ├── redis-cache              # SDK cache
│   ├── dfsp-101-httproute       # dfsp-101.test.${domain}
│   └── vault-auth-role          # K8s auth role for mcm-agent
│
├── dfsp-102/                    # Second test DFSP
│   └── (same structure)
│
└── test-cases/                  # Test execution namespace
    ├── ttk-runner               # TTK pod for functional tests
    ├── k6-operator              # K6 Operator + TestRun CRs
    └── test-data-configmap      # MSISDN ranges, FSP pairs
```

### Component Placement

| Component | Namespace | Count | Purpose |
|-----------|-----------|-------|---------|
| SDK Scheme Adapter | dfsp-{N} | 12 replicas/DFSP | FSPIOP protocol adapter |
| ml-mcm-agent | dfsp-{N} | 1 sidecar/DFSP | Certificate lifecycle manager |
| Mojaloop Simulator | dfsp-{N} | 1 replica/DFSP | Backend simulation |
| Redis Cache | dfsp-{N} | 1 replica/DFSP | SDK cache |
| HTTPRoute | dfsp-{N} | 1/DFSP | `dfsp-{N}.test.${domain}` |
| TTK Runner | test-cases | 1 pod | Functional test execution |
| K6 Operator | test-cases | 1 deployment | Performance test orchestration |
| Gateway gw-test | platform-system | 1 | Ingress for test DFSPs |

### Pod Architecture (DFSP)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dfsp-101-sdk
  namespace: dfsp-101
spec:
  serviceAccountName: mcm-agent-dfsp-101  # For Vault K8s auth

  initContainers:
    # Wait for mcm-agent and trigger enrollment
    - name: mcm-enroll
      image: curlimages/curl:latest
      command: ["/bin/sh", "-c"]
      args:
        - |
          # Wait for mcm-agent daemon
          until curl -f http://localhost:3000/health; do sleep 2; done

          # Create internal CA
          curl -X POST http://localhost:3000/api/actions/create-int-ca \
            -H "Content-Type: application/json" \
            -d '{"subject": {"CN": "dfsp-101-ca"}}'

          # Create client CSR (enrolls with MCM Hub)
          curl -X POST http://localhost:3000/api/actions/create-client-csr \
            -H "Content-Type: application/json" \
            -d '{"subject": {"CN": "dfsp-101-client"}}'

          # Create server cert (inbound)
          curl -X POST http://localhost:3000/api/actions/create-server-cert \
            -H "Content-Type: application/json" \
            -d @/config/server-csr-params.json

          # Wait for completion
          while true; do
            STATUS=$(curl -s http://localhost:3000/api/status | jq -r '.running')
            if [ "$STATUS" = "true" ]; then
              echo "Enrollment complete"
              break
            fi
            sleep 5
          done

  containers:
    # SDK Scheme Adapter
    - name: sdk-scheme-adapter
      image: mojaloop/sdk-scheme-adapter:v24.10.5
      ports:
        - containerPort: 4000
          name: https
      volumeMounts:
        - name: tls-certs
          mountPath: /secrets
        - name: jws-keys
          mountPath: /jwsSigningKey.key
          subPath: jwsSigningKey.key
      env:
        - name: INBOUND_MUTUAL_TLS_ENABLED
          value: "true"
        - name: OUTBOUND_MUTUAL_TLS_ENABLED
          value: "true"
        - name: IN_CA_CERT_PATH
          value: /secrets/inbound-cacert.pem
        - name: IN_SERVER_CERT_PATH
          value: /secrets/inbound-cert.pem
        - name: IN_SERVER_KEY_PATH
          value: /secrets/inbound-key.pem
        - name: OUT_CA_CERT_PATH
          value: /secrets/ca-bundle.pem
        - name: OUT_CLIENT_CERT_PATH
          value: /secrets/client-cert.pem
        - name: OUT_CLIENT_KEY_PATH
          value: /secrets/client-key.pem
        - name: DFSP_ID
          value: "dfsp-101"
        - name: ALS_ENDPOINT
          value: "https://account-lookup-service.mojaloop.svc.cluster.local:443"
        - name: QUOTES_ENDPOINT
          value: "https://quoting-service.mojaloop.svc.cluster.local:443"
        - name: TRANSFERS_ENDPOINT
          value: "https://ml-api-adapter.mojaloop.svc.cluster.local:443"

    # ml-mcm-agent sidecar
    - name: mcm-agent
      image: mojaloop/ml-mcm-agent:latest
      ports:
        - containerPort: 3000
          name: api
      env:
        - name: VAULT_ENDPOINT
          value: http://vault.vault.svc.cluster.local:8200
        - name: VAULT_KV_MOUNT
          value: secret
        - name: VAULT_PKI_MOUNT
          value: pki
        - name: VAULT_AUTH_K8S_ROLE
          value: mcm-agent-dfsp-101
        - name: VAULT_CONFIG_PATH
          value: mcm-agent/dfsp-101/config
        - name: PORT
          value: "3000"
      volumeMounts:
        - name: tls-certs
          mountPath: /certs
        - name: jws-keys
          mountPath: /jws-keys

  volumes:
    - name: tls-certs
      emptyDir: {}
    - name: jws-keys
      emptyDir: {}
```

### Integration Points

#### 1. With Vault (ml cluster)
```
ml-mcm-agent ←→ Vault
│
├─ Authentication: K8s ServiceAccount token
├─ Configuration retrieval: GET secret/data/mcm-agent/dfsp-101/config
├─ Certificate operations:
│  ├─ POST pki/root/generate/internal (create CA)
│  ├─ POST pki/issue/mcm-client-role (client cert)
│  └─ POST pki/issue/mcm-server-role (server cert)
└─ Token renewal (every 5 min)
```

#### 2. With MCM Server (ml cluster)
```
ml-mcm-agent ←→ MCM Server
│
├─ OIDC Authentication:
│  └─ POST https://keycloak.int.${domain}/realms/dfsps/protocol/openid-connect/token
│     Credentials: dfsp-101-client / secret
│     Returns: JWT access token (auto-refresh)
│
├─ CSR Enrollment:
│  └─ POST https://mcm.ext.${domain}/api/dfsps/dfsp-101/enrollments
│     Headers: Authorization: Bearer {jwt_token}
│     Body: { csr: "...", dfspId: "dfsp-101" }
│
└─ Endpoint Registration:
   └─ POST https://mcm.ext.${domain}/api/dfsps/dfsp-101/endpoints
      Body: { url: "https://dfsp-101.test.${domain}", type: "FSPIOP" }
```

#### 3. With SDK Scheme Adapter (shared volume)
```
ml-mcm-agent ←→ SDK Scheme Adapter
│
Shared Volume: emptyDir (tmpfs)
/secrets/
├─ inbound-cert.pem      ← mcm-agent writes, SDK reads
├─ inbound-key.pem       ← mcm-agent writes, SDK reads
├─ inbound-cacert.pem    ← mcm-agent writes, SDK reads
├─ client-cert.pem       ← mcm-agent writes, SDK reads
├─ client-key.pem        ← mcm-agent writes, SDK reads
└─ ca-bundle.pem         ← mcm-agent writes, SDK reads

Lifecycle:
  Init: mcm-agent enrolls → writes certs → SDK starts → reads certs
  Renewal: mcm-agent renews → overwrites → triggers restart → SDK reloads
```

#### 4. With Mojaloop Core (ml cluster)
```
Outbound (DFSP → Hub):
SDK → CiliumEnvoyConfig (extapi-mtls) → Mojaloop Services
├─ SDK uses client-cert.pem from mcm-agent
└─ CEC validates against dfsp-ca-bundle (from MCM Vault Agent)

Inbound (Hub → DFSP):
Mojaloop → CiliumEnvoyConfig (dfsp-callback-mtls) → Gateway → SDK
├─ CEC adds Hub client cert (from MCM Vault Agent)
└─ SDK validates against inbound-cacert.pem (Hub CA from MCM)
```

---

## Implementation Phases

### Phase 1: MVP - Static Certs (2-3 weeks)

**Goal**: Get test DFSPs running without mTLS

#### Deliverables:
- GitOps structure: `gitops/test/dfsp-template/`, `gitops/test/test-cases/`
- 2 test DFSPs (dfsp-101, dfsp-102)
- SDK + simulator + redis (mojaloop-simulator Helm chart)
- HTTPRoute: `dfsp-{N}.test.${domain}`
- Static certificates via cert-manager (Vault issuer)
- No mTLS: `OUTBOUND_MUTUAL_TLS_ENABLED: false`, `INBOUND_MUTUAL_TLS_ENABLED: false`
- TTK runner with adapted test collections
- K6 operator basic setup
- Target: TTK golden path passes, 100 TPS for 1 minute

#### Files to Create:
```
gitops/test/
├── kustomization.yaml
├── gateway/gateway-test.yaml
├── dfsp-template/
│   ├── helmrelease.yaml          # mojaloop-simulator chart
│   ├── httproute.yaml
│   └── certificate.yaml          # cert-manager Certificate
├── test-cases/
│   ├── ttk-runner.yaml
│   └── k6-operator.yaml
└── README.md
```

#### Configuration Changes:
- Add `test` to valid `cluster.role` values
- Add Flux substitution vars: `dfsp_count`, `dfsp_replicas`, `test_domain`
- Update `src/modules/flux-config/main.tf` to deploy `test` kustomization conditionally

---

### Phase 2: MCM Agent Integration (3-4 weeks)

**Goal**: Full mTLS with automated certificate enrollment via MCM

#### Deliverables:
- ml-mcm-agent deployed as sidecar in each DFSP pod
- Vault K8s auth roles per DFSP
- Keycloak OIDC clients per DFSP (realm: `dfsps`)
- Init container for automated enrollment
- mTLS enabled: `OUTBOUND_MUTUAL_TLS_ENABLED: true`, `INBOUND_MUTUAL_TLS_ENABLED: true`
- TTK tests passing with mTLS
- Certificate auto-renewal working
- Prometheus metrics for mcm-agent state

#### Files to Create:
```
gitops/test/dfsp-template/
├── mcm-agent-deployment.yaml     # Sidecar container spec
├── vault-auth-role.yaml          # K8s auth role
├── init-config-job.yaml          # Seeds Vault config
└── mcm-oidc-client.yaml          # Keycloak client

gitops/test/mcm-monitoring/
├── servicemonitor.yaml           # Prometheus scrape config
└── grafana-dashboard.yaml        # Certificate lifecycle dashboard
```

#### Configuration to Seed (per DFSP):
- Vault KV: `secret/mcm-agent/dfsp-{N}/config` (JSON structure)
- Keycloak: Client `dfsp-{N}-client` with client_credentials grant
- Vault Policy: Access to `secret/mcm-agent/dfsp-{N}/*` and PKI roles

---

### Phase 3: Scale & Performance (2-3 weeks)

**Goal**: Validate at production scale (8 DFSPs, 2000 TPS)

#### Deliverables:
- Scale to 8 DFSPs (dfsp-101 through dfsp-108)
- 12 SDK replicas per DFSP (performance tuning)
- K6 TestRun CRs for scenarios:
  - Steady-state: 500 TPS sustained
  - Burst: 2000 TPS peak
  - Soak: 100 TPS for 8 hours
- Success criteria: >95% success rate, <500ms p95 latency
- Certificate rotation testing (short TTL, validate renewal)
- Grafana dashboards for test metrics
- Documentation: `doc/test-cluster-guide.md`, `doc/mcm-agent-integration.md`

---

## TTK Test Case Adaptation

### Current TTK Structure
```
legacy/testing-toolkit-test-cases/
├── collections/
│   ├── hub/provisioning/          # DFSP onboarding
│   ├── hub/golden_path/           # P2P transfers
│   └── dfsp/                      # DFSP-side tests
└── environments/
    ├── hub.json                   # Switch URLs
    └── provisioning_dfsp.json     # DFSP simulator URLs
```

### URL Replacement Strategy

**Problem**: TTK tests reference hardcoded hosts like `testfsp1.local`, `payerfsp.local`

**Solution**: Automated replacement via init container
```bash
find /ttk-collections -name "*.json" -exec sed -i \
  's/testfsp1.local/dfsp-101.test.${domain}/g; \
   s/testfsp2.local/dfsp-102.test.${domain}/g; \
   s/payerfsp.local/dfsp-101.test.${domain}/g; \
   s/payeefsp.local/dfsp-102.test.${domain}/g' {} \;
```

### Environment Variables for TTK
```yaml
HUB_HOST: ml-api-adapter.mojaloop.svc.cluster.local
ALS_HOST: account-lookup-service.mojaloop.svc.cluster.local
DFSP_101_HOST: dfsp-101.test.${domain}
DFSP_102_HOST: dfsp-102.test.${domain}
```

---

## Performance Testing with K6

### Legacy Performance Test (Reference)

**Architecture** (ml-perf-whitepaper-ws):
- Switch cluster (3-node HA MicroK8s)
- 8 DFSP clusters (fsp201-fsp208, single-node each)
- k6 cluster (1-node)
- Static certificates (shared CA + shared client cert)
- mTLS via NGINX Ingress annotations
- 12 SDK replicas per DFSP for 2000 TPS

**Key Findings**:
- 2000 TPS sustained with 12 SDK replicas per DFSP
- Extended liveness/readiness probes (180s period)
- Connection reuse enabled in k6
- Kafka partitions matched handler replica counts

### K6 Test Scenarios for ml-test

**Functional Validation** (100 TPS):
```javascript
export default function () {
  // GET parties
  http.get('https://dfsp-101.test.${domain}/parties/MSISDN/123456');

  // POST quotes
  http.post('https://dfsp-101.test.${domain}/quotes', {
    from: 'MSISDN/111',
    to: 'MSISDN/222',
    amount: 100
  });

  // POST transfers
  http.post('https://dfsp-101.test.${domain}/simpleTransfers', {
    from: 'MSISDN/111',
    to: 'MSISDN/222',
    amount: 100
  });
}
```

**Performance Target** (2000 TPS):
- 8 DFSPs (250 TPS each)
- 12 SDK replicas per DFSP
- Duration: 10 minutes
- Success rate: >95%
- p95 latency: <500ms

---

## Key Design Decisions

### 1. Sidecar Pattern for ml-mcm-agent
**Why**: Per-DFSP isolation, shared volume for certs, independent lifecycle
**Alternative**: Standalone deployment per namespace (more complex networking)

### 2. Init Container for Enrollment
**Why**: Ensures certs ready before SDK starts
**Alternative**: SDK waits for certs (requires retry logic)

### 3. Vault for Config Storage
**Why**: Consistent with ml-iac3 patterns, versioned config, secure
**Alternative**: ConfigMaps (less secure, no versioning)

### 4. K8s Auth for Vault
**Why**: Simpler than AppRole, leverages service accounts
**Alternative**: AppRole (requires secret management)

### 5. Same Cluster as ml (Initially)
**Why**: Simpler networking, easier MVP
**Alternative**: Separate ml-test cluster (better isolation, can destroy independently)

### 6. Automated TTK URL Replacement
**Why**: Script-based, repeatable, version-controlled
**Alternative**: Manual editing (error-prone, not repeatable)

### 7. Both TTK and K6
**Why**: TTK validates functional correctness, K6 validates performance
**Alternative**: TTK only (insufficient for performance validation)

---

## Open Questions / Decisions Needed

1. **Same cluster or separate ml-test cluster?**
   - Recommendation: Same cluster for MVP (simpler), separate later if needed

2. **How many DFSPs for MVP?**
   - Recommendation: 2 (payer/payee), scale to 4, then 8 for performance

3. **TTK collection source?**
   - Use `legacy/testing-toolkit-test-cases` as base
   - Or fetch from GitHub: `mojaloop/testing-toolkit-test-cases`

4. **MCM OIDC client creation?**
   - Manual via MCM UI initially
   - Automate via Keycloak CRs later

5. **Performance test priority?**
   - Recommendation: TTK first (functional correctness), K6 after TTK passes

6. **Certificate rotation testing?**
   - Set short TTL in Vault (e.g., 1 hour)
   - Validate mcm-agent auto-renewal
   - Test SDK rolling restart on cert update

---

## Success Criteria

### Phase 1 (MVP):
- ✅ 2 test DFSPs deployed via `make plan-apply ENV=ml-test`
- ✅ TTK golden path passes (P2P transfer payer→payee)
- ✅ 100 TPS sustained for 1 minute, >95% success rate
- ✅ No mTLS (simple TLS only)

### Phase 2 (MCM Integration):
- ✅ ml-mcm-agent sidecar running per DFSP
- ✅ Automated certificate enrollment via MCM
- ✅ mTLS enabled SDK ↔ Mojaloop
- ✅ TTK tests passing with mTLS
- ✅ Certificate auto-renewal working (tested with short TTL)

### Phase 3 (Scale):
- ✅ 8 DFSPs deployed
- ✅ 2000 TPS peak load achieved
- ✅ >95% success rate, <500ms p95 latency
- ✅ Certificate rotation validated (zero downtime)
- ✅ Grafana dashboards operational

---

## References

### Documentation
- [potential-cleaner-ml-arch.md](potential-cleaner-ml-arch.md) - Architecture diagram
- [deployment-architecture.md](deployment-architecture.md) - Current ml-iac3 architecture
- [platform-team-guide.md](platform-team-guide.md) - OCI artifact publishing

### Code Repositories
- `legacy/ml-mcm-agent/` - MCM agent source code (cloned from `https://github.com/mojaloop/ml-mcm-agent`)
- `legacy/testing-toolkit-test-cases/` - TTK test collections
- `legacy/ml-perf/ml-perf-whitepaper-ws/` - Legacy performance test setup
- `gitops/env-app/mcm/` - Current MCM server deployment

### Key Files
- `legacy/ml-mcm-agent/src/services/mcm-client-wrapper.ts` - MCM client orchestrator
- `legacy/ml-mcm-agent/src/api/routes/actions.ts` - Certificate action endpoints
- `legacy/ml-mcm-agent/src/config/schema.ts` - Configuration schema (Zod)
- `gitops/env-app/mcm/vault-agent-configmap.yaml` - Hub-side DFSP provisioning automation

### Helm Charts
- `legacy/ml-helm/helm/sdk-scheme-adapter` - SDK chart (v2.7.0, app v24.10.5)
- `legacy/ml-helm/helm/mojaloop-simulator` - Simulator chart (bundles SDK + backend + redis)

---

## Next Steps

When resuming this work:

1. **Review this document** to understand the full context
2. **Decide on cluster strategy**: Same cluster as ml or separate ml-test?
3. **Start with Phase 1**: Deploy test DFSPs without mTLS
4. **Validate TTK**: Adapt test collections, run golden path
5. **Add MCM integration**: Implement Phase 2 with ml-mcm-agent sidecar
6. **Scale to performance**: Phase 3 with 8 DFSPs, 2000 TPS

**Command to deploy**:
```bash
make plan-apply ENV=ml-test    # When cluster.role=test is implemented
```

---

## Appendix: Complete mTLS Flow Example

```
1. TTK Test Client initiates transfer:
   POST https://dfsp-101.test.${domain}/simpleTransfers
   Body: { from: MSISDN/111, to: MSISDN/222, amount: 100 }
   │
   └─→ Gateway gw-test → SDK Outbound API

2. SDK Scheme Adapter processes:
   │
   ├─ Lookup payee (DFSP 102):
   │  GET https://account-lookup-service:443/parties/MSISDN/222
   │  [mTLS: client-cert.pem from mcm-agent]
   │  └─→ CiliumEnvoyConfig validates → ALS returns dfsp-102
   │
   ├─ Request quote:
   │  POST https://quoting-service:443/quotes
   │  [mTLS: client-cert.pem from mcm-agent]
   │  └─→ CiliumEnvoyConfig validates → Quoting Service processes
   │      └─→ Quoting Service calls back to dfsp-101:
   │          PUT https://dfsp-101.test.${domain}/quotes/{id}
   │          [mTLS: Hub client cert from MCM Vault Agent]
   │          └─→ SDK inbound validates against inbound-cacert.pem
   │
   ├─ Execute transfer:
   │  POST https://ml-api-adapter:443/transfers
   │  [mTLS: client-cert.pem from mcm-agent]
   │  └─→ ML API Adapter processes
   │      └─→ Calls back to dfsp-101:
   │          PUT https://dfsp-101.test.${domain}/transfers/{id}
   │          [mTLS: Hub client cert]
   │          └─→ SDK inbound validates → Transfer complete
   │
   └─ Return success to TTK

3. TTK validates:
   ✓ Transfer completed
   ✓ All mTLS handshakes succeeded
   ✓ No certificate errors
```

---

**Document Status**: Draft for future implementation
**Last Updated**: 2026-03-14
**Next Review**: When resuming ml-test implementation
