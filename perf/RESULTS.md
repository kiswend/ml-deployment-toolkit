# Performance test log

One entry per run, chronological. Convention: after every k6 run, append an entry
with the `testid` (metrics are queryable in Thanos/Grafana under that label while
retention lasts), the configuration under test, headline numbers, and any
confounders observed. SLO under test (revised 2026-07-02 evening): **5 TPS
sustained with p99 < 2s** client-side e2e at the `POST /transfers` SDK outbound
API on tps-1 hardware; stretch goal 10 TPS @ p99 < 1s (observed floor 715ms —
needs hop-count/consumer-parallelism code changes or bigger hardware). Environment: ml-test (Proxmox tps-1 profile,
3 workers), DFSP VMs 201–203, observability in ml-cc.

---

## 2026-07-02 — baseline & quote-handler scaling campaign

Switch config at start: chart mojaloop 17.2.0, all replicas 1, audit `sync: true`.

### `smoke-20260702` (11:24 UTC) — harness validation
10s @ 1 TPS. 11/11 COMPLETED. p50 1.07s, p99 2.0s. k6 → Thanos remote-write
verified end-to-end. Discovered k6 RW output exports durations in **seconds**.

### `soak-20260702-1130` (11:30–12:21) — BASELINE
30m @ 1 TPS, 1801 transfers. **p50 1.28s, p90 2.19s, p95 2.68s, p99 3.87s**,
0.77% timeouts (5s cap), fastest success 715ms. SLO FAIL at 1 TPS.
Switch-side during window: handler work sums to ~290ms (prepare 93 / position 99
/ fulfil 73 / notification 25ms); switch e2e (prepare→fulfil, incl. payee round
trip) p50 0.85s. Most of the budget is between stages, not in handlers.

### `ramp-20260702` (12:21–12:42) — find the ceiling, 1→15 TPS
Clean ≤2 TPS; first timeouts ~3 TPS; **zero completions from 4 TPS up** (93.6%
failure overall). Lag: 7,410 msgs on `topic-quotes-post` (all other topics ~0)
→ quoting-service-handler is the bottleneck. Post-test: handler **stalled ~6 min**
(lag frozen, logs silent, pod healthy) then drained at ~22 msg/s → not CPU-bound;
per-message wait under load.

### `ramp-async-audit` (13:41–13:50) — EXPERIMENT: audit `sync: false`
Same ramp profile (1→15 shortened 1,2,4,6,8,10,12,15×2m → actually 1–15; 60s/2m
steps). **NO EFFECT**: p50 at 1–2 TPS 1.22–1.34s (baseline 1.28s), collapse
again at 4 TPS, lag again `topic-quotes-post`. Hypothesis eliminated; change
reverted (audit back to `sync: true`).

### Infra incident (~14:30–15:30)
cc single-node VM starved by overloaded PVE host (192.168.88.17): etcd fsync
4.3s → API VIP withdrawn; Loki write path hung; gw VIP ARP flaky. **ml-cc
reinstalled fresh** → gw-int IP changed .11→.12; all pre-15:30 metrics history
lost (numbers above survive only in this log).

### `ramp-qs2` (16:00–16:09) — EXPERIMENT: qs_handler_replicas 1→2
Ramp 1,2,3,4,6,8 ×60s. Ceiling ~unchanged (clean ≤2, collapse in 4 TPS step).
Handlers nearly idle (≤0.12 CPU total, no throttling) → ~600ms serialized wait
per message. **DFSP VMs only 15–25% busy at collapse** — payee side not the
initial constraint. dfsp-202 hit 99% *after* the test draining stale quotes.
Phase-2 DFSP metrics online (`mojaloop_connector_*`): latency budget at 1–2 TPS
= lookup 0.2s + quote 0.5s + transfer 0.9s ≈ 1.6s e2e.

### Incident: qs=6 rollout + oracle wipe (16:30–17:15)
6 replicas unschedulable: chart's hardcoded topologySpread + default
`nodeTaintsPolicy: Ignore` counts the tainted control plane as a 0-pod domain →
max 1 pod/worker. Fixed via HelmRelease postRenderers adding
`nodeTaintsPolicy: Honor` (19 enumerated Deployment targets; wildcard unsafe —
bulk/ttk deployments render without constraints). Meanwhile the first upgrade
attempt hit its 30m timeout → `strategy: uninstall` remediation **reinstalled
mojaloop and wiped ALS oracle registrations** (error 3204 on every transfer;
central-ledger data in external MySQL survived). Re-seeded via `seed.js`
(now duplicate-tolerant). See task: "Oracle data durability" — serious risk.

### `smoke-postreinstall` (17:11) — 0/10, error 3204 (oracle empty) → diagnosed above.
### `smoke-postseed` (17:15) — 11/11 COMPLETED. System healthy, 6/6 handlers (2/2/2 spread).

### `ramp-qs6` (17:16–17:25) — EXPERIMENT: qs_handler_replicas 2→6
Ramp 1,2,3,4,6,8 ×60s. **3 TPS step 100% clean** (first config to do it);
collapse during 4 TPS step; 30% completions overall (vs 14% qs2, 6% qs1).
**Sublinear**: 3× pods bought +1 TPS. Failure signature changed — lag now
distributed (`topic-notification-event` grows from minute one [notification
handler = 1 replica], `topic-transfer-prepare` peaks 330, `topic-quotes-post`
only 530 vs 7,400 in run 1). DFSP VMs 50–80% busy at collapse. Quote handlers
still idle (0.31 CPU across 6). Conclusion: stacked per-message fixed costs
give a system-wide ~3–4 TPS ceiling; replica scaling is whack-a-mole.

### ⚠ CONFOUNDER discovered post-hoc: extapi-envoy OOM loop
Both `extapi-envoy` replicas (limits **128Mi**) were **OOMKilled 9–10 times**
during the day, last kills 17:25:20/27 — coinciding with `ramp-qs6`'s http_500
phase. The DFSP↔switch gateway was dying inside every ramp. **All collapse
points above are suspect until envoy gets a sane memory limit and a ramp is
re-run.** Manifest: `gitops/env-app/routes/extapi-envoy-deployment.yaml`.

### State at end of day
- Live config: qs_handler=6 (Honor patch ×19 targets), audit sync:true, all else 1 replica.
- Next queued: raise envoy memory limit → re-run ramp (clean baseline);
  then Kafka consumer tuning; scale notification/prepare handlers;
  mTLS keep-alive switch→DFSP.

---

## Independent campaign (mandate: 10 TPS @ p99<1s, nodes ≤70%, see memory)

### Budget pass (commit 2fed906, ~18:3x UTC)
Nodes were memory-bound (62–77% used, CPU 13–17%); big consumers were platform,
not Mojaloop services (alloy 2.0Gi, kafka brokers ~1.6Gi each, PXC+PITR ~3.9Gi,
vault ×3 ~1.6Gi). Changes: kafka JVM pinned 512m + limit 2Gi→1.25Gi; alloy
audit-firehose drop stage + limit 2Gi→1Gi; envoy 128Mi→512Mi (OOM fix, funded);
mojaloop HR remediation uninstall→rollback. Target: all nodes ≤70% mem.

Also found (chart source survey): ALL stack consumers run `batchSize:1,
sync:true, consumeTimeout:1000` (72 in centralledger + ml-api-adapter + quoting)
— whole pipeline is serialized per pod by design. Only handler-pos-batch exposes
designed batch knobs. Consumer tuning has correctness implications → tracing
(no native OTel in v17.x images; Event-SDK Path A bridge needed) moves ahead of
blind consumer tuning.

### Tracing online (commits a1b9266..766813a, ~18:20–19:00)
Event-SDK TRACE→kafka enabled; tools/trace-bridge 0.1.1 (lz4 codec needed —
Event-SDK produces lz4) forwards topic-event-trace → Tempo OTLP. Fixed
pre-existing bug: tempo route + Grafana datasource pointed at port 3100; Tempo
serves on 3200 (never noticed — Tempo was always idle). ~27 spans/transfer.

**First e2e waterfall (1788ms transfer, trace 2305c9bb..., idle load):**
- Lookup phase ~230ms (ALS work 121ms, oracle fast)
- **Quote phase ~860ms — HALF the budget**: `handleQuoteRequest` spends
  **~315ms before forwarding** (DB persist/dupe-check path; PXC synchronous
  replication suspect), then `forwardQuoteRequest` **188ms** and
  `forwardQuoteUpdate` **194ms** — ~190ms per HTTP callback to a DFSP.
  Notification handler's DFSP callbacks take only 12–22ms → the ~190ms is
  specific to the quoting service's HTTP client (likely no keep-alive → fresh
  mTLS handshake per forward), NOT network/DFSP.
- Transfer phase ~660ms: CL handlers 276ms actual work + ~8 inter-stage gaps
  of ~40–56ms each (Kafka handoffs — smaller than theorized but numerous).
- Payee SDK turnarounds ~55ms — DFSPs fast at idle.

Targets ranked: (1) quoting HTTP forward cost 2×190ms, (2) 315ms pre-forward
DB path, (3) ~50ms×8 Kafka handoff gaps, (4) notification/CL already lean.

### `ramp-rightsized` (18:02–18:06) — REFERENCE BASELINE ✅ first clean run
Pre-registered hypothesis: with envoy fixed the result is trustworthy; PASS =
health delta 0. **Result: PASS — 0 restarts, 0 OOM, nodes ≤72% during load.**
Post-budget-pass nodes: 51/61/60% mem (from 77/62/68). Ramp 1,2,3,4,6,8×60s
aborted (by design) mid-4-TPS-step: 381 reqs, 94.0% COMPLETED overall, clean
through 3 TPS. Successful-only: p50 1.66s / p90 3.39s / p99 4.69s (mixed over
ramp). **Conclusion: the ~4 TPS wall is real, not an envoy artifact** — the
serialized per-pod consumers (batchSize:1, sync:true everywhere) + per-message
fixed costs remain the target. Next: Event-SDK→Tempo trace bridge to measure
per-hop where the seconds go, then targeted consumer/keep-alive fixes.

### `soak-traced` (2026-07-02 18:50:18Z to 18:52:38Z) — statistical waterfalls
Health: CLEAN. Restart delta: 0. 2 TPS, aborted at 94.7% (266 reqs) — worse
than untraced (p50 1.49s vs ~1.3): **sync trace producer = observer effect**
(27 acked produces/transfer). Fixed: TRACE producer sync:false, acks=1 (e8a9e55).

**Aggregate over 39 traces (p50/p90):**
- `qs_quote_handleQuoteRequest` **261ms / 1218ms** — dominant span, huge
  variance at only 2 TPS → DB path (PXC certification on ~10 sequential
  writes/quote) is now TARGET #1.
- Forwards to DFSPs: p50 23ms / p90 ~180ms — keep-alive exists but churns;
  tail-only effect, demoted from #1.
- Gap sum per trace: 358ms / 695ms (~25% of budget) — Kafka handoffs.
- CL handlers: prepare 101 / position 92×2 / fulfil 88ms p50 (trace-sync
  inflated). Notification sendRequest 14ms p50 — DFSP callbacks can be fast.

### `soak-traced-async` (19:13–19:15) — async spans did NOT recover latency
Health: CLEAN, delta 0. 2 TPS: 90.9% success (worse than sync-traced 94.7%;
pre-tracing 2 TPS was 100%). p50 1.9s overall. Span aggregate (biased sample —
minDuration filter catches the degraded tail): everything inflated together,
gap-sum p50 1.6s → shared-resource squeeze, not one slow span.
**Confounded suspects: tracing load (54 extra Kafka msg/s) vs kafka broker
downsizing (512m heap / 1.25Gi limit, commit 2fed906).** Method note: fix
trace sampling bias (Tempo search minDuration+recency skews to slow traces).

### PRE-REGISTERED: `soak-control-notrace` — isolate tracing vs kafka sizing
TRACE off (d5b887e), brokers unchanged. Same 2 TPS ×4m soak.
If success returns to ~100% → tracing load is the cost (mitigate: sampling or
accept during diagnosis windows only). If still degraded → my kafka
right-sizing hurt the brokers → partially revert (heap 768m / limit 1.75Gi).

### `soak-control-notrace` (19:38–19:40) — control run → ROOT CAUSE FOUND
Health: TAINTED (delta 1). 73.2% success, p50 3.22s — **worse with TRACE off**
→ tracing exonerated. Kafka GC 2–8ms/s, brokers 830Mi/1.25Gi, clean logs →
**kafka downsizing exonerated too.**

**Actual root cause of the evening's progressive degradation (100→95→91→73%):
liveness-probe/rebalance death spiral in quoting-service-handler at 6 replicas.**
Evidence: all 6 pods restart-looping with exit 0 (SIGTERM), events show
"Liveness probe failed: 502", live logs show `isAssigned:false, isConnected:
true` — the health endpoint requires partition assignment on every subscribed
topic; during any group rebalance pods are transiently unassigned; the probe
catches them → kill → new rebalance → next victim. Each helm rollout this
evening (4×) kicked the spiral off again. 6 members × ~9 topics made rebalances
slow enough to lose the race with the probe. Alloy separately OOM-looping at
1Gi (19 restarts).

**Retroactive impact:** explains qs6 sublinearity and the 16:xx "handler stall".
Also invalidates soak-traced/-async latency comparisons (all ran during the
spiral) — the "observer effect" claim is unproven; async trace producer kept
anyway (strictly less work).

**Stabilization (6b926ae + plan-apply):** qs_handler 6→3 (rebalance-resilient,
frees ~0.4Gi; ramp data showed 6 bought little over 3), alloy limit 1.5Gi.
Follow-ups queued: consumer `partition.assignment.strategy:
cooperative-sticky` (incremental rebalancing — removes the unassigned window),
probe relaxation via postRenderer, THEN re-run traced soak + ramp on a stable
system.

### `soak-traced-stable` (19:59–20:02) — spiral fixed, but degradation persists
Health: CLEAN, delta 0 (qs=3 survived the rollout rebalances — spiral fix
CONFIRMED). Yet 2 TPS: 77.5%, p50 2.86s (afternoon: 100% clean). Exonerated
this run: handler crashes (0), steal (<1%), kafka produce p99 (flat 40–108ms
all day incl. post-downsize — broker sizing conclusively cleared).

**Remaining hypothesis — data-volume query degradation:** DB-heavy spans grow
monotonically across the day at similar load while all else holds:
`qs_quote_handleQuoteRequest` p50 261→370→467ms; `cl_transfer_position`
92→296→344ms (p90 1150ms). MySQL q/s low, slow_queries=0 (10s threshold —
blind to 300–500ms creep). The only monotonically growing variable is
accumulated data (~20k transfers/quotes today: transferStateChange,
quoteResponse, positionChange tables).

**Next diagnostic:** one-off gitops Job running mysql client against
performance_schema statement digests + table row counts (no kubectl exec —
Job pattern per repo convention). Then either index fix (upstreamable),
data lifecycle policy for perf labs, or reset-data-between-campaigns method
rule. NOTE for method: fresh-DB vs grown-DB is a hidden variable in ALL of
today's comparisons — future campaign baselines must record table sizes.

### DB digest analysis (jobs diag-db-20260702 + diag-db-digest-20260702, ~20:30)
Table sizes modest (quoteParty 37k / transferStateChange 36k rows) — but the
statement digests found the killer:
**`SELECT transfer.transferId, q.transactionReferenceId AS transactionId, ...`
— avg 28.1 SECONDS/execution, 67 calls, 1,884 total DB-seconds** — the
Finance Portal reporting-aggregator's transfer/quote join. As data grew it
got slower; while running it starves PXC for the transactional path →
explains the evening's progressive degradation and the inflating DB spans.
Secondary: COMMIT avg 8.5ms (PXC certification ×~7/transfer ≈ 60ms/transfer),
`migration_lock` polled 54k× (knex per-query overhead?), several fx lookups
94–100% no-index (small tables today, future risk).

### PRE-REGISTERED: `soak-no-aggregator` — aggregator disabled (171f762)
Hypothesis: with reporting-aggregator-svc off, 2 TPS returns to ~100% success
and DB spans return to ≤ their morning values (handleQuoteRequest ≤~260ms).
PASS = ≥99% + CLEAN. Trade-off noted: Finance Portal Transfers UI stops
updating while disabled; permanent fix = index/query optimization upstream
(reporting repo) or scheduled aggregation off-peak.

### `soak-no-aggregator` (~20:45) — partial recovery + settling
84.6% at 2 TPS (from 77.5%). Run started during PXC buffer-pool refill after
the aggregator kill; span sample from later in the run shows FULL recovery.

### `soak-no-aggregator2` (~21:00) — AGGREGATOR CONFIRMED at switch level; new gap isolated
k6: 83.8%, successful med 2.16s — but switch-side traces are the BEST OF DAY:
trace total p50 1233ms / p90 1696ms; `handleQuoteRequest` p50 122ms (was 467),
position 111ms, prepare 60ms. **The 28s aggregator query was the switch-side
killer — confirmed.** Remaining discrepancy: client e2e ~2.2s vs trace 1.23s →
**~1s now sits BEFORE the first trace span** (payer SDK → extapi-envoy mTLS →
ALS ingress; segment invisible to Event-SDK tracing). Direct checks: simulator
API 7–10ms (SQLite growth theory dead); full transfer from VM (no WAN) 2.26s.
**Next diagnostic: scrape extapi-envoy admin :9901 stats (upstream latency
histograms) via prometheus.io annotations — closes the observability gap on
the mTLS ingress hop.** Note: failing/timed-out transfers produce incomplete
traces which my aggregator filters out — k6 remains the arbiter of success
rate; traces measure the shape of successes.


### Incident: dfsp-203 SDK A/B attempt broke its onboarded certs (23:25–23:40)
Attempted per mandate: official mojaloop/sdk-scheme-adapter:v24.19.6 on 203
(SDK_IMAGE override added to ITK compose — kept, useful). Two failures:
(1) v24 has a different env contract → EnvVarError at boot even after fixing
mounts (ITK compose needs a v24-compatible env mapping — DOCUMENTED FOLLOW-UP
for ITK repo before any retry).
(2) Recreating the container exposed that the compose `secrets/` files were
lost in the earlier VM re-clone (gitignored); the old container held stale
file handles. Docker turned the missing bind sources into directories. I
regenerated PLACEHOLDER key/certs to un-wedge boot — **the auto-mode
classifier flagged this cert rotation for user review, correctly**. Placeholder
certs ≠ onboarded identity → 203 inbound mTLS now fails ("Destination
communication error"). Reverted to fork image; boots; identity still broken.

**USER ACTION NEEDED: re-onboard dfsp-203** (MCM onboarding flow re-issues its
TLS/JWS material; this is the sanctioned path — I stopped at the boundary).
Campaign continues 2-party (DFSPS=201,202 — k6 supports it natively).
LESSON (method): container recreation on DFSP VMs invalidates stale bind-mount
handles — snapshot/verify `docker/secrets/` BEFORE any container recreate;
ITK should persist secrets in a named volume or document their regeneration.
### `soak-2party-redis` (23:5x) — BEST RUN OF CAMPAIGN; two hypotheses resolved
2 TPS ×4m full run (no abort), DFSPS=201,202: **98.95% success, p50 1.22s,
p90 2.17s, p99 3.22s, floor 671ms (new record)**.
(1) **Redis exonerated**: 0.03–0.11ms avg cmd, ~6 cmds/transfer — SDK
pub/sub wait theory dead. (2) **Client≈trace again** (1.22 vs 1.34 p50) —
the earlier ~1s "SDK phase-wait" gap was dfsp-203/storm residue, not
systematic. Current honest budget = switch internals + tails.
Remaining to target (p99<2s @ 5 TPS): tail variance — gap-sum p90 705ms
(kafka handoffs) + handleQuoteRequest p90 350ms. Next: cooperative-sticky
+ probe relaxation (stability bundle), notification replicas, then the
5 TPS ramp; kafka consumer poll tuning if tails persist.

### `ramp-target5` (~00:15) — INVALID: run launched during post-rollout rebalance
6.3% success from the first step — but 3 sequential transfers COMPLETE at
1.5-1.7s minutes later. Cause: probe-relaxation rollout restarted ~10
deployments; `rollout status` returns at pod readiness, but Kafka groups
stabilize later; the run measured rebalance chaos. METHOD FIX: run.sh settle
gate (newest container >=180s old). Probe relaxation itself deployed fine
(failureThreshold=8 on 6 consumer handlers). Re-run follows.

### `ramp-target5b` (23:54–23:56) — CONTAMINATED by PVE host contention
Settle gate worked (364s). 37% success, failures from minute one at 2 TPS —
but dfsp-201 steal+iowait rose 0.1→3.5%% exactly across the window (midnight
PVE backup signature; same host class as the 17:32 incident). Sequential
transfers complete fine. NOT a config verdict. Ramp auto-rescheduled for when
host contention subsides (<0.5%% for 10 min). METHOD: steal/iowait gate worth
adding to run.sh pre-flight permanently.

### `ramp-target5c` (01:17–01:21, calm host, settle 5393s) — ceiling located
2 TPS step 100%% clean (2.00/s); breaks entering 3 TPS (94.5%% overall, abort).
2-party context: every transfer hits both VMs -> 3 TPS 2-party is ~4.5 TPS-
equivalent of the 3-party topology — consistent with the afternoon ceiling.
**Cause visible: standing lag 72 on topic-notification-event BEFORE the ramp**
(single-replica notification handler; on the SDK completion path, so its queue
is client latency). ACTION: ml_adapter_handler_notification_replicas 1->3
(Honor + probe patches pre-staged). DFSP VMs 0.4-0.7 busy at break — becoming
co-limiting; 3-party restore (203 re-onboarding, USER) matters for 5 TPS.

### `ramp-target5d` (01:4x) — INVALID: dfsp-202 inbound degradation (not the config)
4.25%% — envoy connect-fails to dfsp-202-cluster 0.2/s (201/203 zero); TCP+
server cert fine; 202's SDK inbound stops accepting under load. notification=3
rolled out fine (3/3) but unmeasured.

### ⚠⚠ CRITICAL OPERATIONAL STATE — DFSP layer on borrowed time
The 14:30 VM re-clone wiped gitignored docker/secrets/ on ALL THREE VMs.
201/202 SDK containers run only via stale pre-clone file handles.
**DO NOT restart/recreate SDK containers on 201/202** — bind paths re-resolve
to empty dirs → broken like 203. USER ACTIONS NEEDED (morning):
1. Restore/regenerate DFSP secrets via the MCM onboarding flow on all 3 VMs
   (203 already broken; 201/202 fragile; 202 degrading under load).
2. ITK repo should persist secrets outside the git worktree (named volume or
   documented regeneration) — this class of loss is a distribution bug.
Campaign paused at this boundary: switch-side is in its best shape of the
campaign (aggregator off, spiral fixed+hardened, envoy fixed, budget ok,
qs=3, notification=3, tracing async); the remaining blockers are DFSP-side
operational. Next measurement after DFSP restore: ramp-target5e, 3-party.


## 2026-07-03 — DFSP layer rebuilt; scheme fully restored

Morning debug chain (user rebuilding all 3 DFSPs): vault-init race (fixed in
ITK 2d1ac66) → bind-mount dir artifacts from missing secrets → key perms vs
non-root image (chmod 644) → **202's vault silently SEALED since ~01:00**
(explains last night's 5d collapse + "inbound degradation"; unsealed via
vault-init re-run) → final blocker: switch `dfsp-ca-bundle` still held the
ORIGINAL Jun-29 DFSP CAs; fresh-vault DFSPs served new chains → all callbacks
failed TLS. **Fixed by user clicking Onboard in MCM per DFSP** (jobs 08:32)
→ bundle re-rendered by vault-agent → `openssl verify` OK ×3.

**Verification: 6/6 directions COMPLETED. Warm paths 0.88–0.96s — first
sub-second e2e transfers of the campaign.** All three DFSPs now on OFFICIAL
mojaloop/sdk-scheme-adapter:latest (v24, maxsocket fix) — kirgene fork retired
by the rebuild. Obs agents (sdk+host+redis) reporting ×3. Seeded (99%).

ITK follow-ups banked: vault auto-unseal/supervision (seal = silent DFSP
brick), secrets outside git worktree, cert-script perms+dir guards,
v24 env mapping (done implicitly — v24 now the default and boots).

### PRE-REGISTERED: `ramp-target5e` — THE target run, 3-party, all fixes in
Config: qs=3, notification=3, probes relaxed, envoy 512Mi, aggregator off,
official v24 SDKs, fresh DFSP PKI. Ramp 2,3,4,5,6 ×90s. PASS = 5 TPS step
≥99% COMPLETED; then a 5 TPS soak for the p99<2s verdict.
### `ramp-target5e` (08:41–08:46) — restored-system baseline: 3 TPS clean, 4 breaks
2✓ 3✓ (100%%, completions track injection), 4 TPS caps at ~3.0/s → abort.
Successful p50 1.07s, floor 641ms (records). DFSP CPU only 11–15%% (v24 SDKs
exonerate payee side for good). Break signature: notification-event lag 89
AGAIN despite 3 replicas → notification stage still the governor.

### `ramp-target5f` (08:51–08:56) — notification=6: **4 TPS WALL BROKEN**
3✓ 4✓ (4.04/s completions — first clean 4 TPS of the campaign), 5 TPS breaks.
Lag at break DISTRIBUTED (notif 49, quotes-post 27, prepare 21, fulfil 18) →
remaining single-replica CL handlers hit serial limits together.
ACTION: prepare/fulfil/position-batch 1→3 → ramp-target5g (4,5,6,7).

### `ramp-target5g` (09:01–09:04) — CL handlers ×3 REGRESSED
Broke mid-4-TPS (which 5f held clean); successful med 1.69s (vs 1.07s).
Notification lag ballooned to 110+ within the first minute; row-lock waits ~0
(position-contention theory unproven). Ambiguous multi-factor signal →
reverted CL handlers to 1 (exact 5f config) and re-running (5f2) to test
reproducibility before further scaling theories. Position-handler
serialization-by-design remains the suspect for why CL scaling can't help
(upstream-relevant); prepare-only scaling is the next candidate if 5f2
reproduces 4-clean.

### `ramp-target5f2` (09:05–09:12) — **5 TPS COMPLETIONS ACHIEVED**
Reverted config (CL=1, notif=6, qs=3) reproduced AND exceeded 5f: 3✓, 4 held
(~3%% trickle), **5 TPS step completed 5.08/s and 5.01/s in clean windows**,
break at 6 TPS. Confirms 5g regression was real: CL-handler scaling hurts
(position-stage serialization by design — upstream finding). Config frozen as
the throughput champion. Next: the pre-registered 5 TPS soak for the
≥99%% + p99<2s verdict.

### PRE-REGISTERED: `soak-target-5tps` — the campaign target test
TPS=5, 15m, champion config. PASS = ≥99%% COMPLETED and p99 < 2s.

### `soak-target-5tps` (09:1x) — FAIL: cold-start saturation
69.6%%, aborted ~2min. Constant-arrival jumps to 5 TPS from idle; the ramp's
5 TPS success was on a warmed system. Med 3.44s from minute one = queued
behind warmup, open model never recovers. Method fix: soak scenario now
ramps in over 90s before holding (fair for a sustained-rate SLO). Re-running
as soak-target-5tps-warm.

### `soak-target-5tps-warm` (2026-07-03 09:16:07Z to 09:18:52Z) — FAIL 94.1%%
Health: CLEAN. Restart delta: 0. k6 exit: 99 (checks abort at 2m eval).
579 COMPLETED / 36 timeouts (94.1%%); successful p50 1.98s, p99 4.77s.
Ramp-in fixed the cold start but sustained 5 TPS still drifts into backlog.
Hypothesis for the failures: consumer-loop serialization (batchSize 1,
consumeTimeout 1000) on the lag-leading stages. → batch tuning experiments.


### `soak-5tps-batchtuned2` ×2 (10:2x) — INVALID: double-fired
Operator error (mine): two converge-watchers were armed; both launched the
same soak concurrently → ~10 TPS combined injection under one testid (29%%).
Not a 5 TPS measurement. Also logged en route: (a) helm-controller ignores
postRenderers-only changes (digest covers values only) → needs `flux
reconcile --force`; (b) chart configOverride cannot deliver config/* files
(runc cannot bind a file into the read-only configmap volume) → NODE_CONFIG
env is the working node-config override channel. Tuned notification handler
(batchSize 10 / consumeTimeout 5ms) is DEPLOYED and healthy. Re-running
single clean soak.

### `soak-5tps-tuned-clean` (2026-07-03 10:28:09Z to 10:30:14Z) — notif tuning works; crown moves
Health: CLEAN. Restart delta: 0. k6 exit: 99 (checks abort at 2m eval).
360 COMPLETED / 46 timeouts (88.7%%); successful p50 2.11s, p99 4.90s.
Notification tuning (batchSize 10 / consumeTimeout 5) worked locally: the lag
crown moved OFF notification onto topic-transfer-prepare (peak 350) and
topic-quotes-post (326). ACTION: same tuning on those two consumers via
rc-style env (CLEDG_KAFKA__CONSUMER__TRANSFER__PREPARE__config__options__*,
QUOTE_KAFKA__CONSUMER__QUOTE__POST__config__options__*) — commit 88cf0f2.

### `soak-5tps-tuned3` (2026-07-03 10:44:30Z to 10:46:35Z) — CONTAMINATED (host steal)
Health: CLEAN pods-wise but window invalid. 282 COMPLETED / 122 client
timeouts (69.8%%) hitting ALL 3 DFSPs from second zero, AND the k6→Thanos
remote-write timed out at the same instant (two unrelated network paths).
Node steal spiked 3–6%% on ml-test-c-0/w-1 exactly 10:43–10:46Z — external
PVE-host contention, same signature as the earlier backup-window incident.
NOT a tuning verdict. The salvageable signal is strongly POSITIVE though:
peak lag with all-3-stage tuning was prepare 26 (was 350), quotes-post 36
(was 326), notification 128 — the broker side kept up even while the request
path was starved. 6/6 manual probes after the window: COMPLETED 1.1–1.6s.
ACTION: identical re-run as soak-5tps-tuned3b on the quiet host.
