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
