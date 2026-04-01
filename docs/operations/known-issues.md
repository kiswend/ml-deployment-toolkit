# Known Issues (Operations)

[docs](../index.md) / [operations](index.md) / Known Issues

**Audiences:** adopter (operate)

Runtime known issues encountered during Mojian operations. For deployment issues, see [adopter known issues](../adopter/known-issues.md). For platform build issues, see [platform known issues](../platform/known-issues.md).

---

### MCM Vault token expiry -- HTTP 500 on Vault-backed operations (MCM v3.1.2)

**Symptoms:**
MCM API returns HTTP 500 for all operations that read/write Vault (DFSP enrollment, certificate management). Vault audit log shows an expired token.

**Root cause:**
MCM uses the `node-vault` library which never renews Vault tokens. The Vault Kubernetes auth token has a default TTL that expires while the MCM pod is running.

**Fix/workaround:**
The Vault K8s auth role `mcm` is configured with `ttl: 768h` (32 days). If the MCM pod has been running longer than the TTL without a restart, restart it:

```bash
kubectl rollout restart deploy/mcm -n mcm
```

**Prevention:**
MCM pods restart on artifact updates during Flux reconciliation. The 768h TTL covers normal deployment cycles. If deployments are infrequent (more than 30 days between updates), monitor MCM pod age and schedule periodic restarts.

---

### Thanos Receive data loss window (~2 hours)

**Symptoms:**
Gap in metrics data visible in Grafana after a Thanos Receive pod crash or restart. Queries for the period around the restart return no data or partial data.

**Root cause:**
Thanos Receive writes TSDB blocks to S3 every ~2 hours. Until a block is complete and uploaded, data exists only in the local WAL (write-ahead log). A pod crash loses uncommitted WAL data.

**Fix/workaround:**
WAL replay on restart recovers most data. Gaps of up to 2 hours are expected after crashes and cannot be recovered.

**Prevention:**
Ensure the Receive pod has sufficient memory to avoid OOM kills -- this is the most common cause of unexpected restarts. Monitor Receive pod restarts via the Kubernetes Cluster dashboard in Grafana.

---

### Kratos intermittent MySQL migration failure (Kratos v1.3.1)

**Symptoms:**
Kratos pod crash-loops with MySQL migration errors on fresh deploy. Logs show `Access denied` or schema migration failures.

**Root cause:**
Race condition between Kratos startup and PXC operator user creation. Kratos migration starts before the PXC operator finishes creating the `kratos` database user (~7-10 minutes after PXC CR creation).

**Fix/workaround:**
The HelmRelease timeout is set to 15 minutes to allow PXC user creation to complete. If the pod is still crash-looping after 15 minutes, suspend and resume:

```bash
flux suspend helmrelease kratos -n flux-system
flux resume helmrelease kratos -n flux-system
```

**Prevention:**
The `env-data` kustomization has a CEL health check gating on PXC `status.state == 'ready'`. Ensure the `env-auth` kustomization depends on `env-data` in the Flux dependency chain. The race occurs because PXC reporting `ready` does not guarantee all declarative users have been created -- the operator processes `spec.users[]` asynchronously after cluster readiness.
