# Grafana Dashboards

## Provisioning Approach

Dashboards are provisioned via **Grafana sidecar + ConfigMaps** (not CRDs, not inline HelmRelease values).

- Grafana's sidecar container watches for ConfigMaps with label `grafana_dashboard: "1"`
- Dashboard JSON is embedded in ConfigMap `data` field
- Folder organization via `grafana_folder` annotation on each ConfigMap
- Hot-reload on ConfigMap changes — no Grafana pod restart required
- Day-0 provisioning (initial deploy) and day-N operations (add/modify/delete) both supported

### Folder Structure

| Grafana Folder | Disk Path | Purpose |
|----------------|-----------|---------|
| Infrastructure | `gitops/cc-observability/grafana/dashboards/infrastructure/` | Node, cluster, namespace, pod-level resource monitoring |
| Data Layer | `gitops/cc-observability/grafana/dashboards/data-layer/` | MySQL/PXC, Kafka, Redis, MongoDB |
| Mojaloop | `gitops/cc-observability/grafana/dashboards/mojaloop/` | Application-level transfer, ALS, notification metrics |
| Platform | `gitops/cc-observability/grafana/dashboards/platform/` | Loki, Thanos, Flux, Cilium (deferred — requires ml-cc self-scrape) |

### ConfigMap Format

Each dashboard is a separate YAML file containing a ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dashboard-<name>
  namespace: observability
  labels:
    grafana_dashboard: "1"
  annotations:
    grafana_folder: "<folder name>"
data:
  <name>.json: |
    { ... dashboard JSON ... }
```

### HelmRelease Changes Required

The Grafana HelmRelease (`gitops/cc-observability/grafana/helmrelease.yaml`) needs the sidecar enabled:

```yaml
sidecar:
  dashboards:
    enabled: true
    label: grafana_dashboard
    labelValue: "1"
    folderAnnotation: grafana_folder
    provider:
      foldersFromFilesStructure: false
    searchNamespace: observability
```

### Design Decisions

- **ConfigMap + sidecar over inline values**: hot-reload, clean git diffs (one file per dashboard), scalable
- **ConfigMap + sidecar over Grafana Operator CRDs**: no additional operator dependency, native Helm chart feature
- **Folder annotation over filesystem folders**: simpler — sidecar handles folder creation automatically
- **All dashboards include `cluster_name` variable**: centralized observability, Thanos receives from multiple clusters

---

## Datasources

All dashboards target these datasources (configured in Grafana HelmRelease):

| Name | UID | Type | URL | Default |
|------|-----|------|-----|---------|
| Thanos | `thanos` | prometheus | `http://thanos-query.observability.svc.cluster.local:9090` | Yes |
| Loki | `loki` | loki | `http://loki-gateway.observability.svc.cluster.local` | No |
| Tempo | `tempo` | tempo | `http://tempo.observability.svc.cluster.local:3100` | No |

Dashboard JSON must reference datasources by UID (e.g. `"uid": "thanos"`), not by name.

---

## Metrics Inventory (Verified Against Live Data)

Metrics verified against Thanos data from ml-test cluster (2026-03-24 17:00–22:00 UTC). This is the authoritative source for dashboard queries — do not use legacy metric names without verifying here.

### Infrastructure Metrics

**Source: node-exporter (338 metrics)**

Key metrics for dashboards:

| Metric | Use |
|--------|-----|
| `node_cpu_seconds_total` | CPU utilization by mode (user/system/idle/iowait) |
| `node_load1`, `node_load5`, `node_load15` | Load averages |
| `node_memory_MemTotal_bytes`, `node_memory_MemAvailable_bytes`, `node_memory_MemFree_bytes` | Memory utilization |
| `node_memory_Buffers_bytes`, `node_memory_Cached_bytes`, `node_memory_Slab_bytes` | Memory breakdown |
| `node_filesystem_size_bytes`, `node_filesystem_avail_bytes`, `node_filesystem_free_bytes` | Disk utilization |
| `node_disk_read_bytes_total`, `node_disk_written_bytes_total` | Disk I/O throughput |
| `node_disk_reads_completed_total`, `node_disk_writes_completed_total` | Disk IOPS |
| `node_disk_io_time_seconds_total` | Disk busy time (for utilization %) |
| `node_network_receive_bytes_total`, `node_network_transmit_bytes_total` | Network throughput |
| `node_network_receive_errors_total`, `node_network_transmit_errors_total` | Network errors |
| `node_pressure_cpu_waiting_seconds_total` | PSI — CPU pressure |
| `node_pressure_memory_stalled_seconds_total` | PSI — memory pressure |
| `node_pressure_io_waiting_seconds_total` | PSI — I/O pressure |
| `node_context_switches_total`, `node_intr_total` | Kernel activity |
| `node_nf_conntrack_entries`, `node_nf_conntrack_entries_limit` | Conntrack saturation |
| `node_uname_info`, `node_os_info`, `node_exporter_build_info` | Node identity |

**Source: cAdvisor / kubelet (68 container_* + 129 kubelet_*)**

| Metric | Use |
|--------|-----|
| `container_cpu_usage_seconds_total` | Container CPU usage |
| `container_cpu_cfs_throttled_seconds_total`, `container_cpu_cfs_periods_total` | CPU throttling (critical for perf analysis) |
| `container_memory_working_set_bytes` | Container memory (OOM killer basis) |
| `container_memory_rss`, `container_memory_cache` | Memory breakdown |
| `container_memory_usage_bytes` | Total container memory |
| `container_oom_events_total` | OOM kills |
| `container_network_receive_bytes_total`, `container_network_transmit_bytes_total` | Container network |
| `container_fs_usage_bytes`, `container_fs_limit_bytes` | Container filesystem |
| `container_spec_cpu_quota`, `container_spec_cpu_period` | CPU limits (for limit % calculation) |
| `container_spec_memory_limit_bytes` | Memory limit |
| `kubelet_volume_stats_used_bytes`, `kubelet_volume_stats_capacity_bytes` | PVC utilization |
| `kubelet_running_pods`, `kubelet_running_containers` | Kubelet load |
| `kubelet_pod_start_duration_seconds_*` | Pod startup latency |

**Source: kube-state-metrics (247 metrics)**

| Metric | Use |
|--------|-----|
| `kube_pod_status_phase` | Pod phase distribution |
| `kube_pod_container_status_restarts_total` | Restart tracking |
| `kube_pod_container_status_waiting_reason` | Pending/CrashLoop detection |
| `kube_pod_container_resource_requests`, `kube_pod_container_resource_limits` | Resource allocation |
| `kube_deployment_spec_replicas`, `kube_deployment_status_replicas_available` | Deployment health |
| `kube_statefulset_replicas`, `kube_statefulset_status_replicas_ready` | StatefulSet health |
| `kube_daemonset_status_desired_number_scheduled`, `kube_daemonset_status_number_ready` | DaemonSet health |
| `kube_node_status_condition` | Node conditions (Ready, MemoryPressure, DiskPressure) |
| `kube_node_status_allocatable`, `kube_node_status_capacity` | Node resource capacity |
| `kube_persistentvolumeclaim_status_phase`, `kube_persistentvolumeclaim_resource_requests_storage_bytes` | PVC status |
| `kube_namespace_status_phase` | Namespace health |

### MySQL / PXC Metrics (1,247 metrics)

**Source: PXC operator built-in mysqld-exporter (port 9104)**

Standard mysqld-exporter metrics (`mysql_global_status_*`, `mysql_global_variables_*`) plus PXC/Galera-specific metrics.

Core operational metrics:

| Metric | Use |
|--------|-----|
| `mysql_up` | Instance availability |
| `mysql_global_status_uptime` | Uptime |
| `mysql_global_status_threads_connected`, `mysql_global_status_threads_running` | Connection load |
| `mysql_global_status_max_used_connections` | Peak connections |
| `mysql_global_variables_max_connections` | Connection limit |
| `mysql_global_status_queries`, `mysql_global_status_questions` | QPS |
| `mysql_global_status_slow_queries` | Slow query rate |
| `mysql_global_status_commands_total` | Per-command breakdown (select, insert, update, delete) |
| `mysql_global_status_handlers_total` | Handler statistics (read_rnd, read_next, etc.) |
| `mysql_global_status_created_tmp_disk_tables` | Temp-on-disk (perf indicator) |
| `mysql_global_status_select_full_join` | Full joins (missing indexes) |
| `mysql_global_status_innodb_buffer_pool_read_requests`, `mysql_global_status_innodb_buffer_pool_reads` | Buffer pool hit ratio |
| `mysql_global_status_innodb_buffer_pool_bytes_data`, `mysql_global_status_innodb_buffer_pool_bytes_dirty` | Buffer pool usage |
| `mysql_global_variables_innodb_buffer_pool_size` | Buffer pool config |
| `mysql_global_status_innodb_row_lock_waits`, `mysql_global_status_innodb_row_lock_time` | Lock contention |
| `mysql_global_status_innodb_row_ops_total` | InnoDB row operations |
| `mysql_global_status_innodb_data_reads`, `mysql_global_status_innodb_data_writes` | InnoDB I/O |
| `mysql_global_status_innodb_os_log_written` | Redo log throughput |
| `mysql_global_status_bytes_received`, `mysql_global_status_bytes_sent` | Network throughput |
| `mysql_global_status_aborted_connects`, `mysql_global_status_aborted_clients` | Connection errors |
| `mysql_global_status_table_locks_waited` | Table lock contention |

PXC / Galera cluster metrics:

| Metric | Use |
|--------|-----|
| `mysql_galera_evs_repl_latency_avg_seconds`, `_max_seconds`, `_min_seconds` | Replication latency |
| `mysql_galera_gcache_size_bytes` | Galera cache size |
| `mysql_galera_status_info`, `mysql_galera_variables_info` | Cluster identity |
| `mysql_global_status_wsrep_cluster_size` | Cluster membership |
| `mysql_global_status_wsrep_cluster_status` | Cluster state (Primary/Non-Primary) |
| `mysql_global_status_wsrep_connected` | Cluster connectivity |
| `mysql_global_status_wsrep_ready` | Node readiness |
| `mysql_global_status_wsrep_local_state` | Node state (Joined/Synced/Donor) |
| `mysql_global_status_wsrep_flow_control_paused` | Flow control (cluster-wide write throttling) |
| `mysql_global_status_wsrep_flow_control_recv`, `_sent` | Flow control events |
| `mysql_global_status_wsrep_local_recv_queue`, `_avg`, `_max` | Receive queue depth |
| `mysql_global_status_wsrep_local_send_queue`, `_avg`, `_max` | Send queue depth |
| `mysql_global_status_wsrep_local_cert_failures` | Certification conflicts (write conflicts) |
| `mysql_global_status_wsrep_local_bf_aborts` | Brute-force aborts |
| `mysql_global_status_wsrep_replicated`, `mysql_global_status_wsrep_replicated_bytes` | Outbound replication |
| `mysql_global_status_wsrep_received`, `mysql_global_status_wsrep_received_bytes` | Inbound replication |
| `mysql_global_status_wsrep_local_commits` | Local committed transactions |
| `mysql_global_status_wsrep_cert_deps_distance` | Certification dependency window |

### Kafka Metrics (57 metrics)

**Source: Strimzi JMX exporter (port 9404 on broker pods)**

| Metric | Use |
|--------|-----|
| `kafka_server_brokertopicmetrics_bytesinpersec_total` | Broker bytes in (per topic and aggregate) |
| `kafka_server_brokertopicmetrics_bytesoutpersec_total` | Broker bytes out |
| `kafka_server_brokertopicmetrics_messagesinpersec_total` | Message rate |
| `kafka_server_brokertopicmetrics_totalproducerequestspersec_total` | Produce request rate |
| `kafka_server_brokertopicmetrics_totalfetchrequestspersec_total` | Fetch request rate |
| `kafka_server_brokertopicmetrics_failedproducerequestspersec_total` | Failed produces |
| `kafka_server_brokertopicmetrics_failedfetchrequestspersec_total` | Failed fetches |
| `kafka_server_brokertopicmetrics_replicationbytesinpersec_total` | ISR replication traffic |
| `kafka_server_replicamanager_leadercount` | Leader partition count per broker |
| `kafka_server_replicamanager_partitioncount` | Total partitions per broker |
| `kafka_server_replicamanager_underreplicatedpartitions` | Under-replicated (health alarm) |
| `kafka_controller_kafkacontroller_activecontrollercount` | Active controller (should be 1) |
| `kafka_controller_kafkacontroller_offlinepartitionscount` | Offline partitions (health alarm) |
| `kafka_network_requestmetrics_requestspersec_total` | Request throughput by type/version |
| `kafka_log_log_size` | Log size per topic/partition |
| `kafka_server_fetcherlagmetrics_consumerlag` | Internal replication lag |
| `kafka_broker_info` | Broker identity |

**Source: Strimzi Kafka Exporter (port 9404 on exporter pod)**

| Metric | Use |
|--------|-----|
| `kafka_consumergroup_lag` | Consumer group lag (critical for Mojaloop perf) |
| `kafka_consumergroup_current_offset` | Consumer progress |
| `kafka_consumergroup_members` | Consumer group membership |
| `kafka_topic_partitions` | Partition count per topic |
| `kafka_topic_partition_current_offset` | Topic write progress |
| `kafka_topic_partition_oldest_offset` | Earliest available offset |
| `kafka_topic_partition_replicas` | Replica count |
| `kafka_topic_partition_in_sync_replica` | ISR count |
| `kafka_topic_partition_under_replicated_partition` | Under-replicated flag |
| `kafka_topic_partition_leader` | Partition leader broker |
| `kafka_topic_partition_leader_is_preferred` | Leader balance |

**Missing (requires JMX rule additions — see Known Gaps):**

- KRaft controller metrics (`kafka.raft:*`)
- Request handler pool idle (`kafka.server<type=KafkaRequestHandlerPool>`)
- Socket server idle (`kafka.network<type=SocketServer>`)
- JVM metrics (`java.lang:*`)

### Redis Metrics (161 metrics)

**Source: redis-exporter (port 9121)**

| Metric | Use |
|--------|-----|
| `redis_up` | Instance availability |
| `redis_uptime_in_seconds` | Uptime |
| `redis_connected_clients` | Client connections |
| `redis_blocked_clients` | Blocked clients (BLPOP etc.) |
| `redis_memory_used_bytes`, `redis_memory_max_bytes` | Memory utilization |
| `redis_memory_used_rss_bytes` | RSS memory (actual OS allocation) |
| `redis_mem_fragmentation_ratio` | Memory fragmentation |
| `redis_evicted_keys_total` | Evictions (capacity alarm) |
| `redis_keyspace_hits_total`, `redis_keyspace_misses_total` | Hit ratio |
| `redis_commands_total` | Per-command call count |
| `redis_commands_duration_seconds_total` | Per-command latency |
| `redis_commands_processed_total` | Total ops |
| `redis_connections_received_total` | Connection rate |
| `redis_rejected_connections_total` | Rejected connections |
| `redis_net_input_bytes_total`, `redis_net_output_bytes_total` | Network throughput |
| `redis_db_keys`, `redis_db_keys_expiring` | Key count per database |
| `redis_connected_slaves` | Replication status |
| `redis_cpu_sys_seconds_total`, `redis_cpu_user_seconds_total` | CPU usage |
| `redis_rdb_last_bgsave_duration_sec` | Persistence latency |
| `redis_aof_current_size_bytes` | AOF size |
| `redis_slowlog_length` | Slow commands |
| `redis_latest_fork_seconds` | Fork latency (BGSAVE/BGREWRITE) |
| `redis_allocator_frag_ratio`, `redis_allocator_rss_ratio` | Allocator health |
| `redis_latency_percentiles_usec` | Command latency percentiles |

### MongoDB Metrics

**Source: PSMDB operator built-in exporter (port 9216)**

| Metric | Status |
|--------|--------|
| `mongodb_up` | Only metric collected |

The PSMDB exporter is not exposing operational metrics. This needs investigation — see Known Gaps.

### Mojaloop Application Metrics (396 metrics)

**Source: Mojaloop Node.js services (prom-client, scraped via pod annotations)**

**IMPORTANT: Metric naming has changed from legacy.** The old service-specific prefixes (`moja_cl_`, `moja_als_`, `moja_qs_`, `moja_sim_`) are gone. Current metrics use a flat `moja_` prefix. The `moja_ml_` prefix still exists for ML API Adapter. Legacy dashboards will not work without query rewrites.

Transfer pipeline (Central Ledger):

| Metric | Type | Use |
|--------|------|-----|
| `moja_transfer_prepare_*` | histogram | Transfer prepare latency and count |
| `moja_transfer_fulfil_*` | histogram | Transfer fulfil latency and count |
| `moja_transfer_position_*` | histogram | Position processing latency |
| `moja_transfer_position_batch_*` | histogram | Batch position processing (new) |
| `moja_transfer_get_*` | histogram | Transfer lookup |
| `moja_handler_transfers_*` | histogram | Transfer handler total |
| `moja_handlers_transfer_validator_*` | histogram | Transfer validation |
| `moja_domain_transfer_*` | histogram | Domain layer transfer processing |
| `moja_domain_position_*` | histogram | Domain layer position processing |
| `moja_model_transfer_*` | histogram | DB model layer transfer |
| `moja_model_participant_*` | histogram | DB model layer participant lookup |
| `moja_model_position_*` | histogram | DB model layer position |
| `moja_model_settlementModel_*` | histogram | Settlement model lookup (new) |

FX transfer pipeline (new — not in legacy dashboards):

| Metric | Type | Use |
|--------|------|-----|
| `moja_fx_transfer_prepare_*` | histogram | FX transfer prepare |
| `moja_fx_transfer_fulfil_*` | histogram | FX transfer fulfil |
| `moja_fx_handler_transfers_*` | histogram | FX handler total |
| `moja_fx_model_transfer_*` | histogram | FX DB model layer |
| `moja_fx_domain_cyril_*` | histogram | FX Cyril domain processing (6 operations) |

ML API Adapter:

| Metric | Type | Use |
|--------|------|-----|
| `moja_ml_transfer_prepare_*` | histogram | API adapter prepare |
| `moja_ml_transfer_fulfil_*` | histogram | API adapter fulfil |
| `moja_ml_transfer_fulfil_error_*` | histogram | API adapter fulfil errors (new) |
| `moja_ml_transfer_get_*` | histogram | API adapter get |
| `moja_ml_fx_transfer_prepare_*` | histogram | FX API adapter prepare (new) |
| `moja_ml_fx_transfer_fulfil_*` | histogram | FX API adapter fulfil (new) |
| `moja_ml_fx_transfer_get_*` | histogram | FX API adapter get (new) |
| `moja_tx_transfer_*` | histogram | End-to-end transaction |
| `moja_tx_transfer_prepare_*` | histogram | E2E prepare phase |
| `moja_tx_transfer_fulfil_*` | histogram | E2E fulfil phase |
| `moja_notification_event_*` | histogram | Notification processing |
| `moja_notification_event_delivery_*` | histogram | Notification delivery |
| `moja_notification_event_getEndpoint_*` | histogram | Endpoint resolution |
| `moja_notification_event_process_msg_*` | histogram | Message processing |
| `moja_notification_event_getEndpoint_fx_*` | histogram | FX endpoint resolution (new) |

Account Lookup Service:

| Metric | Type | Use |
|--------|------|-----|
| `moja_ing_getPartiesByTypeAndID_*` | histogram | Ingress: GET parties |
| `moja_ing_putPartiesByTypeAndID_*` | histogram | Ingress: PUT parties |
| `moja_ing_putPartiesErrorByTypeIDAndSubID_*` | histogram | Ingress: parties error callback |
| `moja_ing_getParticipantsByTypeAndID_*` | histogram | Ingress: GET participants |
| `moja_ing_postParticipantsbyTypeAndID_*` | histogram | Ingress: POST participants |
| `moja_ing_deleteParticipantsByTypeAndID_*` | histogram | Ingress: DELETE participants |
| `moja_ing_putParticipantsByTypeIDAndSubID_*` | histogram | Ingress: PUT participants |
| `moja_ing_putParticipantsErrorByTypeAndID_*` | histogram | Ingress: participants error callback |
| `moja_getPartiesByTypeAndID_*` | histogram | Domain: parties lookup |
| `moja_putPartiesByTypeAndID_*` | histogram | Domain: parties callback |
| `moja_getParticipantsByTypeAndID_*` | histogram | Domain: participants lookup |
| `moja_postParticipants_*` | histogram | Domain: register participant |
| `moja_deleteParticipants_*` | histogram | Domain: deregister participant |
| `moja_fetchParticipant_*`, `moja_fetchParticipants_*` | histogram | Participant fetch operations |
| `moja_egress_sendRequestToParticipant_*` | histogram | Egress: outbound request |
| `moja_egress_getParticipantEndpoint_*` | histogram | Egress: endpoint resolution |
| `moja_egress_validateParticipant_*` | histogram | Egress: participant validation |
| `moja_egress_oracleRequest_*` | histogram | Egress: oracle lookup |
| `moja_model_externalParticipant_*` | histogram | External participant model (new) |
| `moja_model_oracleEndpoints_*` | histogram | Oracle endpoints model (new) |
| `moja_model_participant_batch_*` | histogram | Batch participant model (new) |
| `moja_getEndpoint_*` | histogram | Generic endpoint resolution |
| `moja_getParticipant_*` | histogram | Generic participant fetch |
| `moja_sendRequest_*` | histogram | Generic outbound request |

Node.js runtime (all services):

| Metric | Use |
|--------|-----|
| `moja_nodejs_heap_size_total_bytes`, `moja_nodejs_heap_size_used_bytes` | Heap utilization |
| `moja_nodejs_heap_space_size_*` | Per-space heap breakdown |
| `moja_nodejs_external_memory_bytes` | External memory (Buffers, etc.) |
| `moja_nodejs_eventloop_lag_seconds` | Event loop lag (critical for perf) |
| `moja_nodejs_eventloop_lag_p50_seconds`, `_p90_seconds`, `_p99_seconds` | Event loop lag percentiles |
| `moja_nodejs_eventloop_lag_max_seconds`, `_mean_seconds` | Event loop lag extremes |
| `moja_nodejs_gc_duration_seconds_*` | GC pause duration histogram |
| `moja_nodejs_active_handles`, `moja_nodejs_active_resources` | Handle/resource count |
| `moja_process_cpu_seconds_total` | Process CPU |
| `moja_process_resident_memory_bytes` | Process RSS |
| `moja_process_heap_bytes` | Process heap |
| `moja_process_open_fds`, `moja_process_max_fds` | File descriptor usage |
| `moja_nodejs_version_info` | Node.js version |

Reporting API runtime (`moja_ra_api*` prefix):

| Metric | Use |
|--------|-----|
| `moja_ra_apinodejs_heap_size_*`, `moja_ra_apinodejs_eventloop_lag_*` | Same Node.js runtime metrics, different prefix |
| `moja_ra_apiprocess_cpu_seconds_total`, `moja_ra_apiprocess_resident_memory_bytes` | Process metrics |

Note: the `moja_ra_api` prefix appears to be a concatenation artifact (`moja_` + service prefix `ra_api` + metric name). These follow the same Node.js runtime schema.

### Additional Runtime Metrics (from Go services on the cluster)

| Prefix | Source | Count | Notes |
|--------|--------|-------|-------|
| `go_*` | kube-state-metrics, other Go services | ~130 | Go runtime: goroutines, GC, memory, scheduler |
| `nodejs_*` | Node.js services (unprefixed) | ~24 | Duplicates of `moja_nodejs_*` but without moja prefix |
| `process_*` | Various | ~13 | Generic process metrics |

---

## Known Gaps

### 1. Kafka JMX Rules (Task #1)

**Status:** Pending — requires ml-test cluster

The `kafka-metrics-configmap.yaml` needs additional JMX rules for:

- **KRaft metrics** (`kafka.raft:*`) — controller latency, replication health, epoch, watermarks. Critical for performance analysis in KRaft mode (no ZooKeeper).
- **Request handler pool** (`kafka.server<type=KafkaRequestHandlerPool>`) — broker request processing capacity, idle percentage.
- **Socket server** (`kafka.network<type=SocketServer>`) — network thread saturation.
- **JVM metrics** (`java.lang:*`) — heap usage, GC behavior, CPU load. Needed for Kafka Cluster Overview and performance analysis under load.

**File:** `gitops/env-data/kafka/kafka-metrics-configmap.yaml`

### 2. Strimzi Operator Scrape Annotations (Task #2)

**Status:** Pending — requires ml-test cluster

The Strimzi operator pod needs Prometheus scrape annotations to expose `strimzi_*` metrics (reconciliation health, certificate expiration). These are useful for diagnosing operator-level issues.

**File:** `gitops/env/strimzi/helmrelease.yaml`

### 3. MongoDB Exporter

**Status:** Needs investigation

Only `mongodb_up` is being collected from the PSMDB operator's built-in exporter. Expected metrics (`mongodb_ss_*`, `mongodb_mongod_*`) are absent. Possible causes:
- Exporter not enabled in PSMDB CR
- Exporter running but metrics path/port mismatch
- Service annotations missing or incorrect

**File to check:** `gitops/env-data/mongodb/` (PSMDB CR and metrics service)

### 4. ml-cc Self-Scrape

**Status:** Deferred

Loki, Thanos, and Grafana self-monitoring metrics are not collected (no Alloy on ml-cc). Platform folder dashboards will be empty until this is addressed. Not blocking for ml-test-focused work.

---

## Legacy Dashboard Reference

The legacy repos (sw002, sw012 in `legacy/infitx/`) used Grafana Operator CRDs (`GrafanaDashboard`) and contained ~45 dashboards each. Key differences from what we're building:

| Aspect | Legacy (sw002/sw012) | Current (ml-iac3) |
|--------|---------------------|-------------------|
| Provisioning | Grafana Operator CRDs | ConfigMap + sidecar |
| Metric prefixes | `moja_cl_*`, `moja_ml_*`, `moja_als_*`, `moja_qs_*`, `moja_sim_*` | Flat `moja_*` (except `moja_ml_*` still exists) |
| Service mesh | Istio dashboards (5) | Not applicable (Cilium, no sidecar proxy metrics) |
| Storage | Longhorn | OpenEBS |
| Kafka | Basic JMX + Kafka Exporter | Same JMX rules, planning to add KRaft/JVM |
| FX transfers | Not present | New `moja_fx_*` metrics need new dashboards |
| Multi-cluster | Single cluster | `cluster_name` variable, centralized Thanos |

Legacy dashboards **cannot be used as-is** — they serve as layout/panel inspiration only. All queries must be rewritten against verified metric names documented above.

---

## Dashboard Design Principles

### Methodology

- **USE method** (Utilization, Saturation, Errors) for infrastructure and data layer
- **RED method** (Rate, Errors, Duration) for Mojaloop application services
- **Performance analysis focus** — dashboards must support identifying bottlenecks under load

### Grafana Standards

- Use `timeseries` panel type (not deprecated `graph`)
- Use `stat` panels for key indicators (uptime, cluster size, error rate)
- Include `$cluster_name` template variable on every dashboard
- Include `$namespace` variable where applicable
- Use datasource UID `thanos` (not name)
- Prefer `rate()` over `irate()` for smoother trends at 30s scrape interval
- Use `histogram_quantile()` for latency percentiles (p50, p90, p99)
- Set reasonable default time range (last 1 hour for operational, last 6 hours for perf analysis)

### Performance Analysis Considerations

Dashboards should surface:
- **Throughput**: transfers/sec, messages/sec, queries/sec
- **Latency**: p50/p90/p99 at each pipeline stage (API → handler → domain → model → DB)
- **Saturation**: CPU throttling, memory pressure, Kafka consumer lag, MySQL connection pool, event loop lag
- **Errors**: failed transfers, Kafka produce/fetch failures, MySQL aborted connections, certification conflicts
- **Resource efficiency**: CPU/memory usage vs limits, buffer pool hit ratio, cache hit ratio
