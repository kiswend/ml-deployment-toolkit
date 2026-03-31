# Known Issues

## Cilium v1.18.8 — BPF Dead Code Elimination Probe Failure

**Date:** 2026-03-23
**Affected version:** Cilium v1.18.8 (Helm chart released 2026-03-23)
**Affected environments:** Talos Linux v1.12.x (kernel 6.18.x)
**Status:** Pinned to v1.18.7 in `gitops/talos/cilium/helmrelease.yaml`

### Symptoms

- Cilium agent pod enters `CrashLoopBackOff` immediately after startup
- All pods requiring CNI networking fail with `unable to connect to Cilium agent: connection refused`
- Cascading failures: vault-operator, hubble-relay, hubble-ui, and any newly scheduled pods cannot create sandboxes
- Existing pods with established network connections may continue running

### Error

```
level=error msg="Start hook failed" \
  function="datapath.initDatapath.func1 (pkg/datapath/cells.go:181) (agent.datapath)" \
  error="requirements failed: Require support for dead code elimination (Linux 5.1 or newer)"

level=error msg="Failed to start hive" \
  error="requirements failed: Require support for dead code elimination (Linux 5.1 or newer)"

panic: Start or stop failed to finish on time, aborting forcefully.
```

### Root Cause

Cilium v1.18.8 introduced a regression in the BPF feature probe for dead code elimination. Despite the kernel being 6.18.8 (well above the stated 5.1 minimum), the probe fails. This is a Cilium-side regression — the same kernel works correctly with Cilium v1.18.7.

The error message is misleading: it is not a kernel version issue but a broken BPF verifier probe in the v1.18.8 release.

### Timeline

- **v1.18.7** (released 2026-03-02): Works correctly on Talos v1.12.x / kernel 6.18.x
- **v1.18.8** (released 2026-03-23 ~10:00 UTC): Breaks BPF dead code elimination probe
- The `version: "1.18.x"` semver range in the HelmRelease auto-resolved to v1.18.8, triggering the issue on any cluster that reconciled after the release

### Fix

Pinned Cilium chart version from `"1.18.x"` to `"1.18.7"` in `gitops/talos/cilium/helmrelease.yaml`.

### Resolution Path

Monitor Cilium releases for v1.18.9 or a fix announcement. Once confirmed fixed, update the pin or revert to the `"1.18.x"` semver range.

### References

- [cilium/cilium#44216](https://github.com/cilium/cilium/issues/44216) — BPF verifier regression on kernel 6.18.x
- [siderolabs/talos#12726](https://github.com/siderolabs/talos/issues/12726) — eBPF verifier issue with Cilium on Talos 1.12.x

---

## Cilium Major Version Upgrade — CRD API Version Ordering Constraint

**Date:** 2026-03-23
**Context:** Attempted upgrade from Cilium v1.18.7 to v1.19.2

### Problem

When upgrading Cilium across a major version that graduates CRD API versions (e.g. `cilium.io/v2alpha1` → `cilium.io/v2`), the API version promotion in manifest files **cannot be done in the same Flux kustomization pass** as the HelmRelease version bump.

Flux performs a server-side dry-run of all manifests before applying. If the kustomization includes both:
1. The HelmRelease upgrade (which installs new CRDs with the `v2` API)
2. Resources referencing the new `v2` API (e.g. `CiliumLoadBalancerIPPool`, `CiliumL2AnnouncementPolicy`)

The dry-run fails because the `v2` CRDs don't exist yet — the HelmRelease hasn't been applied.

### Error

```
CiliumL2AnnouncementPolicy/default-l2-policy dry-run failed: no matches for kind "CiliumL2AnnouncementPolicy" in version "cilium.io/v2"
```

### Affected Files

- `gitops/talos/cilium/helmrelease.yaml` — Cilium HelmRelease (installs CRDs via `upgrade.crds: CreateReplace`)
- `gitops/talos/lb-ipam/lb-ipam.yaml` — `CiliumLoadBalancerIPPool` and `CiliumL2AnnouncementPolicy` (both `v2alpha1`)

### Correct Upgrade Sequence

The upgrade must be done in **two pushes**:

1. **Push 1:** Upgrade HelmRelease version only (e.g. `1.18.7` → `1.19.2`), keep `v2alpha1` API versions in lb-ipam. Cilium 1.19 still accepts `v2alpha1` (backward compatible). This installs the new CRDs including `v2`.
2. **Push 2:** After Cilium 1.19 is running and CRDs are installed, promote `v2alpha1` → `v2` in lb-ipam manifests.

### Additional Notes for Cilium 1.18 → 1.19

- Add `SYSLOG` capability to `securityContext.capabilities.ciliumAgent` (required in 1.19)
- Cilium 1.19 does **not** auto-install Gateway API CRDs — Talos extraManifests still required
- Cilium 1.19 requires Gateway API CRDs v1.4.1 (current bootstrap uses v1.4.0, which works but should be bumped)
- Cilium 1.19 tested matrix covers K8s 1.31–1.34; K8s 1.35 is untested but uses stable APIs
- Never use semver ranges (e.g. `"1.19.x"`) — always pin exact versions to avoid surprise patch regressions

---

## MCM Vault Token Expiry — HTTP 500 on All Vault-Backed Operations

**Date:** 2026-03-27
**Affected component:** MCM (Connection Manager) API — `mojaloop/connection-manager-api`
**Affected chart:** `mojaloop/connection-manager` v1.4.0 (image v3.1.2)
**Status:** Mitigated — Vault role TTL increased to 768h in `gitops/env-auth/vault/vault.yaml`

### Symptoms

- MCM UI shows "There was an internal error. Please try again later" on PM4ML Credentials, TLS certificates, hub server certs, JWS certs, and any page that reads/writes Vault secrets
- MCM API returns HTTP 500 on all Vault-backed endpoints (`/api/dfsps/*/credentials`, `/api/dfsps/*/enrollments/*`, `/api/hub/servercerts`, `/api/dfsps/jwscerts`)
- Errors appear **after the MCM pod has been running for longer than the Vault token TTL** (default: 1 hour)
- A pod restart immediately fixes the issue (until the token expires again)

### Error

```
Error: 2 errors occurred:
	* permission denied
	* invalid token
```

```
Error retrieving API credentials:
  dfspId: "test-dfsp-107"
  error: "2 errors occurred: * permission denied * invalid token"
```

### Root Cause

MCM uses `node-vault` (a Node.js Vault HTTP client) which has **no token renewal logic**. The full library is 248 lines (`node_modules/node-vault/src/index.js`) with zero timers, renewal, or re-authentication:

1. At startup, MCM calls `vault.kubernetesLogin({role: "mcm", jwt: <SA token>})`
2. `node-vault` stores the returned `client_token` in `client.token` (a plain string property)
3. Every subsequent Vault request uses this cached token via `X-Vault-Token` header
4. After the Vault token TTL expires (configured on the `mcm` Kubernetes auth role), **all requests fail**
5. `node-vault` has no mechanism to detect expiry or re-authenticate

The Vault Kubernetes auth role `mcm` was configured with `ttl: 1h`, meaning every MCM pod became non-functional after 1 hour of uptime.

### Mitigation

Increased the Vault role TTL from `1h` to `768h` (32 days, Vault's default max lease TTL) in `gitops/env-auth/vault/vault.yaml`:

```yaml
auth:
  - type: kubernetes
    roles:
      - name: mcm
        ...
        ttl: 768h   # was: 1h
```

This is safe because:
- The token is bound to a K8s service account — if the pod dies, the token is orphaned and auto-revoked by Vault's periodic GC
- No pod realistically runs 32 days without a deploy/restart cycle
- Other Vault clients (cert-manager, ESO, vault-agent) handle token renewal internally; MCM is the only client affected

### Workaround (immediate)

If the error occurs before the TTL fix is deployed, restart the MCM API pod:

```bash
kubectl rollout restart deploy/mcm-connection-manager-api -n mcm
```

### Bug Report for MCM Dev Team

**Repository:** `mojaloop/connection-manager-api`
**Summary:** Vault token expires after TTL, causing all Vault operations to fail with `permission denied` + `invalid token`

**Problem:** The `node-vault` library used by MCM (`node_modules/node-vault/src/index.js`) stores the Vault token as a plain string after `kubernetesLogin()` and never renews it. After the token's TTL expires, every Vault call fails. The library has no renewal, expiry detection, or re-authentication logic.

**Impact:** All PKI operations (cert signing, enrollment, credentials) and KV operations (DFSP secrets) stop working. The MCM UI shows internal errors on most pages.

**Suggested fix:** Either:
1. Wrap `node-vault` calls with a token-refresh middleware that re-authenticates via `kubernetesLogin()` when a 403 is received
2. Set up a periodic timer to call `vault.tokenRenewSelf()` before TTL expiry (node-vault exposes this method via its auto-generated commands)
3. Replace `node-vault` with `@hashicorp/vault-client` or similar library that handles token lifecycle

**Evidence:** `node-vault/src/index.js` line 80 sets `client.token` once; lines 222-227 update it only during login. No timer or renewal exists in the 248-line source.

---

## Database Migration Corruption on Fresh Deployments — Duplicate Key Name (Error 1061)

**Date:** 2026-03-30
**Affected components:** Any service using MySQL schema migrations — Kratos v1.3.1 (chart 0.55.0), Keto (chart 0.55.0), Keycloak (Liquibase)
**Affected database:** Percona XtraDB Cluster 8.0.44
**Status:** Fixed — increased HelmRelease timeout from default 5m to 15m

### Symptoms

- Pods stuck in `Init:Error` / `CrashLoopBackOff` on automigrate init containers
- Keycloak stuck in `CrashLoopBackOff` during Liquibase migration
- MySQL `Error 1061 (42000): Duplicate key name '<index_name>'` in migration logs
- Observed index names: `identity_credential_identifiers_identifier_nid_uq_idx` (Kratos), `sessions_identity_id_nid_idx` (Kratos), `IDX_OFFLINE_CSS_PRELOAD` (Keycloak)
- The error persists across pod restarts — every retry hits the same duplicate key

### Root Cause

A race condition between Flux HelmRelease remediation and database migrations during fresh deployments:

1. Flux installs HelmReleases → Deployments created → pods start
2. Init containers fail because secrets (from Vault via ESO) don't exist yet — Vault is still initializing
3. After the default **5m Helm timeout**, Flux considers the install failed → triggers remediation → **uninstalls the entire release**, killing all pods — including any pod that may have started running migrations
4. Flux retries (unlimited retries) → reinstalls → same cycle
5. If a pod was mid-migration when killed, MySQL DDL statements (`CREATE INDEX`, `CREATE TABLE`) are **auto-committed immediately** by MySQL, but the migration tracking record (which marks the migration as complete) is rolled back because the process was terminated
6. All subsequent migration attempts fail because the schema object (index/table) exists but the migration framework doesn't know it was already applied

This affects any service that runs schema migrations against PXC during initial deployment, not just Kratos. Keycloak (Liquibase) and Keto are equally vulnerable.

### Fix

Increased `spec.timeout` from default 5m to **15m** on affected HelmReleases (`helmrelease-kratos.yaml`, `helmrelease-keto.yaml`). This gives dependencies (Vault, ESO, PXC) time to come online before Flux triggers remediation and kills pods mid-migration.

```yaml
spec:
  timeout: 15m
```

Keycloak is managed by the Keycloak operator (not a direct HelmRelease with automigrate), so its migration runs inside the main container. The 15m timeout on the parent kustomization provides sufficient time.

### Recovery (if corruption already occurred)

On **fresh deployments with no user data**, drop and recreate the affected databases:

```bash
# Get the MySQL root password
MYSQL_ROOT_PWD=$(kubectl get secret -n mojaloop mojaloop-db-secrets -o jsonpath='{.data.root}' | base64 -d)

# Drop and recreate all affected databases in one command
kubectl exec -n mojaloop mojaloop-db-pxc-0 -- mysql -u root -p"$MYSQL_ROOT_PWD" -e "
  DROP DATABASE IF EXISTS kratos;   CREATE DATABASE kratos;
  DROP DATABASE IF EXISTS keto;     CREATE DATABASE keto;
  DROP DATABASE IF EXISTS keycloak; CREATE DATABASE keycloak;
"

# Restart affected pods to re-run migrations
kubectl delete pod -n ory -l app.kubernetes.io/name=kratos
kubectl delete pod -n ory -l app.kubernetes.io/name=keto
kubectl delete pod -n keycloak keycloak-0
```

On **existing environments with user data**, do NOT drop databases. Instead, manually insert the missing migration record:

```sql
-- For Kratos: check which migration is failing in the logs, then insert it
INSERT INTO kratos.schema_migration (version, version_self) VALUES (<missing_version>, 0);

-- For Keycloak: mark the Liquibase changeset as executed
INSERT INTO keycloak.DATABASECHANGELOG (ID, AUTHOR, FILENAME, DATEEXECUTED, ORDEREXECUTED, EXECTYPE, MD5SUM, DESCRIPTION)
  SELECT '<changeset_id>', '<author>', '<filename>', NOW(), COALESCE(MAX(ORDEREXECUTED),0)+1, 'MARK_RAN', '', ''
  FROM keycloak.DATABASECHANGELOG;
```
