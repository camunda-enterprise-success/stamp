# Metric mapping — Camunda 8.7 Zeebe, Prometheus → Dynatrace (OTLP push)

**Related config:** [`../runbook-dynatrace.md`](../runbook-dynatrace.md) · dashboards `8.7-zeebe-0*.json`

This is the reference used to port `grafana_original_baseline/8.7.35-zeebe.json` to Dynatrace.
It assumes Camunda's **native OTLP metrics push** (`management.otlp.metrics.export.enabled=true`,
Micrometer `OtlpMeterRegistry`) — see [`camunda-otlp-values.yaml`](camunda-otlp-values.yaml).

## How the names were derived

Micrometer's OTLP registry uses `NamingConvention.dot`, which is the identity function, so the
**OTLP metric key is the Micrometer meter name verbatim**. The meter names below were read from
the 35 `*MetricsDoc.java` (`MeterDocumentation`) enums in `camunda/camunda` at tag **8.7.35**,
plus the meters registered outside those enums (`SequencerMetrics`, `ScheduledCommandCacheMetrics`,
`ElasticsearchMetrics`, `RocksDbMetricsDoc`'s composed names).

Converting the Prometheus names by hand is wrong in four ways:

| Rule | Example |
|---|---|
| Most counters already end in `.total`; Prometheus does not double the suffix | `zeebe.stream.processor.records.total` → `zeebe_stream_processor_records_total` |
| Some counters do **not**, and Prometheus appends `_total` itself | `zeebe.flow.control` → `zeebe_flow_control_total`; `zeebe.log.appender.record.appended` → `zeebe_log_appender_record_appended_total` |
| Timers gain `_seconds` in Prometheus; the OTLP key has no unit suffix | `zeebe.stream.processor.latency` → `zeebe_stream_processor_latency_seconds_bucket` |
| Histogram families collapse: no `_bucket` / `_sum` / `_count` keys, and no `le` dimension | `percentile(zeebe.stream.processor.latency, 95)` |

`*_seconds_max` gauges do not exist on this path — Micrometer 1.15.12 does not publish them for OTLP.

The 8.7 Grafana dashboard queries **both** the Micrometer names and the pre-Micrometer
(Prometheus simpleclient) names via `or` fallbacks. Zeebe moved to Micrometer in 8.7 (backported
to 8.6.9) with no compatibility shim, so the legacy branch is dead and was dropped — 59 `or`
expressions removed. This also fixes a bug in the baseline where the legacy branch of several
heatmaps was missing `by (le)`.

## Dimensions

Prometheus **metric labels** become OTLP data-point attributes with identical names, so
`partition`, `action`, `exporter`, `valueType`, `intent`, `context`, `outcome`, `columnFamily`
and friends are unchanged — including camelCase, provided **Advanced OTLP metric dimensions** is
enabled on the tenant (without it, Dynatrace lowercases dimension keys and the camelCase filters
in these dashboards will not match).

Prometheus **target labels** are not metric labels and do not survive; they come from resource
attributes you set on the pods instead:

| Grafana label | Grail dimension | Source |
|---|---|---|
| `pod` | `k8s.pod.name` | resource attribute (`camunda-otlp-values.yaml`) |
| `namespace` | `k8s.namespace.name` | resource attribute |
| `cluster` | `k8s.cluster.name` | resource attribute — **not used in the shipped filters**, see the runbook |
| `instance` | `service.instance.id` | Micrometer / collector |
| `container` | `k8s.container.name` | Dynatrace Kubernetes monitoring (infrastructure tiles only) |
| `persistentvolumeclaim` | `k8s.persistentvolumeclaim.name` | Dynatrace Kubernetes monitoring — **verify in your tenant** |

## Kubernetes infrastructure metrics

Camunda's OTLP push carries no cAdvisor or kube-state-metrics data, so the infrastructure tiles
were re-sourced from Dynatrace's built-in Kubernetes metrics. These require **Dynatrace
Kubernetes monitoring** (Dynatrace Operator) on the cluster.

| Grafana | Dynatrace built-in |
|---|---|
| `kubelet_volume_stats_used_bytes` / `_capacity_bytes` / `_available_bytes` | `dt.kubernetes.persistentvolumeclaim.used` / `.capacity` / `.available` |
| `container_cpu_usage_seconds_total` | `dt.kubernetes.container.cpu_usage` |
| `container_cpu_cfs_throttled_periods_total / container_cpu_cfs_periods_total` | `dt.kubernetes.container.cpu_throttled` (already a ratio) |
| `container_memory_rss` | `dt.kubernetes.container.memory_working_set` |
| `kube_pod_container_resource_limits_memory_bytes` / `_requests_memory_bytes` | `dt.kubernetes.container.limits_memory` / `.requests_memory` |
| `kube_pod_container_status_restarts_total`, `kube_pod_container_status_ready` | `dt.kubernetes.container.restarts` |

## PromQL → DQL idioms used

| PromQL | DQL |
|---|---|
| `sum(rate(x_total[$__rate_interval])) by (l)` | `timeseries v = sum(x.total, rate:1s), by:{l}` |
| `sum(x_total)` (monotonic counter view) | `timeseries v = sum(x.total)` + `\| fieldsAdd v = arrayCumulativeSum(v)` |
| `max by (partition) (gauge)` | `timeseries v = max(gauge), by:{partition}` |
| `histogram_quantile(0.95, sum(rate(h_bucket[…])) by (le, l))` | `timeseries p95 = percentile(h, 95), by:{l}` |
| heatmap over `h_bucket` | `timeseries {p50 = percentile(h,50), p90 = …, p99 = …}` |
| `rate(h_sum)/rate(h_count)` | `timeseries mean = avg(h)` |
| `sum(rate(a))/sum(rate(b))` | two columns + `\| fieldsAdd ratio = a[] / b[]`, with `default:0` + `nonempty:true` |
| `A - B` (position lag) | two columns + `\| fieldsAdd delta = a[] - b[]` |
| `x > 0` / `!= 0` (sample filter) | `\| filter arrayMax(x) > 0` |
| `$namespace` / `$pod` / `$partition` | `filter: {in(k8s.namespace.name, array($Namespace)) and …}` |
| `$__rate_interval` | omitted — the tile's timeframe drives the interval |

Because Dynatrace ingests **delta** counters, `sum(counter)` returns the count within each
interval, which is Prometheus' `increase()`, not its monotonic counter. Tiles that reproduced a
monotonic counter add `arrayCumulativeSum` and say so in the tile description.

## Panels that changed meaning

### Rewritten (15)

- **Pod Restarts** (`General Overview`, panel 116): Grafana derived restarts from `1 - kube_pod_container_status_ready`; this uses the Dynatrace built-in container restart counter instead, so the tile shows restart events per interval rather than a readiness flag (requires Dynatrace Kubernetes monitoring).
- **Requests handled by Gateway per sec** (`General Overview`, panel 62): Grafana joined the dead `grpc_server_handled_total` with the gRPC histogram's `_count` via `label_replace`. Dynatrace cannot read a histogram's observation count, so this uses the `zeebe.gateway.total.requests` counter split by requestType.
- **Cluster Load** (`General Overview`, panel 612): `avg(load > 0)`: the `> 0` filter excludes partitions with no measured load, so partitions are filtered before averaging. Shows no data when flow-control write rate limits are disabled, exactly like the original.
- **Processing Error Handling Phase** (`Processing`, panel 602): Grafana rendered this as a state timeline over `> 0`. Dynatrace has no state-timeline visualization, so the numeric phase is charted and series that never leave NO_ERROR are filtered out.
- **Backpressure Requests Limit** (`Backpressure`, panel 568): Grafana restricted this to Raft leaders with `and on(...) (atomix_role == 3)`. DQL has no cross-metric join filter, so all pods are included and all-zero series (followers, which report no limit) are filtered out instead.
- **RocksDB Memory usage** (`RocksDB`, panel 154): Four-metric sum, as in the original. The `num_keys * 10` term is Grafana's rough estimate of key-count memory and is kept verbatim; the original applied `rate()` to that gauge, which was a bug, so the gauge value is used directly.
- **Total gRPC requests** (`gRPC`, panel 26): Replaces the `label_replace` + `or on(method, statusCode)` join with the `zeebe.gateway.total.requests` counter (see the note on tile 62). The delta counter is cumulated over the timeframe to give the running total the original panel showed.
- **gRPC requests per second (range = 1m)** (`gRPC`, panel 27): Replaces the `label_replace` + `or on(method, statusCode)` join; adds the failed-request counter so the status dimension of the original panel is still represented.
- **Take Backup Latency** (`Backups`, panel 325): Grafana divided the histogram's `_sum` by its `_count` over a hard-coded 1h window; on this ingest path the histogram carries both, so `avg()` is used and the tile follows the dashboard timeframe instead of a fixed 1h.
- **GC Count per second** (`Memory`, panel 285): Grafana rated the GC histogram's observation count (`jvm_gc_pause_seconds_count`). Grail cannot query a histogram's observation count, so this charts GC pause duration percentiles instead.
- **GC proportion per second** (`Memory`, panel 286): Time spent in GC per second, from the sum of the GC pause histogram. Verify in your tenant that `sum()` over a histogram returns the sum of observations; if it does not, use `percentile(jvm.gc.pause, 99)` as a proxy.
- **CPU Throttling (AVG)** (`CPU`, panel 614): Grafana computed throttled_periods / periods from cAdvisor. `dt.kubernetes.container.cpu_throttled` is already the throttling ratio (requires Dynatrace Kubernetes monitoring).
- **JVM Thread count** (`CPU`, panel 294): Grafana used four targets, two of them pre-Micrometer names that are dead in 8.7. This charts live and daemon threads plus their difference in one tile.
- **Elasticsearch Exporter (Flush Failure Rate)** (`Elasticsearch Exporter`, panel 255): Grafana divided failed flushes by the flush histogram's observation count. Grail cannot query a histogram's observation count, so this shows failed flushes per second rather than a failure ratio.
- **Number Jobs in "Buffer"** (`Worker Jobs`, panel 564): Both counters arrive as OTLP delta values, so each is cumulated over the timeframe before subtracting -- subtracting the raw deltas would show backlog *growth*, not backlog size. Requires the job worker application to export OTLP as well; the brokers do not emit `zeebe.client.*`.

### Partially ported (6)

Targets listed here were dropped from an otherwise complete tile; each tile names the
dropped query in its description.

- **Atomix Partition Server Startup time** (`Start up`, panel 170): atomix_partition_server_startup_time: only atomix.partition.server.bootstrap.time / .join.time exist in 8.7
- **Create Process Instance Latency (gRPC)** (`gRPC`, panel 22): pre-Micrometer name, dead in 8.7: grpc_server_handled_latency_seconds_bucket
- **Activate Jobs Latency (gRPC)** (`gRPC`, panel 23): pre-Micrometer name, dead in 8.7: grpc_server_handled_latency_seconds_bucket
- **Complete Job Latency (gRPC)** (`gRPC`, panel 24): pre-Micrometer name, dead in 8.7: grpc_server_handled_latency_seconds_bucket
- **JVM Memory usage** (`Memory`, panel 98): pre-Micrometer name, dead in 8.7: jvm_memory_bytes_used
- **Buffer Pool Memory Usage** (`Memory`, panel 35): pre-Micrometer name, dead in 8.7: jvm_buffer_pool_used_bytes

### Dropped entirely (8)

- **Number of journal seek (per second)** (`Journal`, panel 560): the journal-seek rate needs a histogram's observation count, which Grail cannot query
- **Sequencer Queue Size** (`Logstream`, panel 356): zeebe_sequencer_queue_size (meter does not exist in 8.7)
- **Read IOPS** (`IO`, panel 379): container_fs_reads_total (cAdvisor disk IOPS)
- **Write IOPS** (`IO`, panel 381): container_fs_writes_total (cAdvisor disk IOPS)
- **Read bytes/s** (`IO`, panel 122): container_fs_reads_bytes_total (cAdvisor disk throughput)
- **Written bytes/s** (`IO`, panel 124): container_fs_writes_bytes_total (cAdvisor disk throughput)
- **Network bytes/s transmitted** (`IO`, panel 126): container_network_transmit_bytes_total (cAdvisor network)
- **Network bytes/s received** (`IO`, panel 127): container_network_receive_bytes_total (cAdvisor network)

### Heatmaps rendered as percentiles (38)

Dynatrace cannot draw a bucket distribution over time, so every Grafana histogram heatmap became
a p50/p90/p99 line chart of the same histogram. Note that Dynatrace's estimated percentiles are
accurate to about 2.2% and are **not guaranteed to match** PromQL's `histogram_quantile`.

- **Operation Duration** (`Cluster`, panel 598): p50/p90/p99 line chart
- **Batch processing command count** (`Processing`, panel 418): p50/p90/p99 line chart
- **Process Instance Execution Time** (`Latency`, panel 132): p50/p90/p99 line chart
- **Job Activation Time** (`Latency`, panel 133): p50/p90/p99 line chart
- **Job Life Time** (`Latency`, panel 135): p50/p90/p99 line chart
- **Overall Processing Latency** (`Latency`, panel 28): p50/p90/p99 line chart
- **Record Processing Duration** (`Latency`, panel 233): p50/p90/p99 line chart
- **Batch Event Replay Duration** (`Latency`, panel 269): p50/p90/p99 line chart
- **Post commit task execution duration** (`Latency`, panel 420): p50/p90/p99 line chart
- **Batch processing duration (in seconds)** (`Latency`, panel 419): p50/p90/p99 line chart
- **Commit latency** (`Latency`, panel 235): p50/p90/p99 line chart
- **Record write latency** (`Latency`, panel 234): p50/p90/p99 line chart
- **Journal Flush Latency** (`Journal`, panel 89): p50/p90/p99 line chart
- **Journal append latency** (`Journal`, panel 401): p50/p90/p99 line chart
- **Segment Creation Time** (`Journal`, panel 386): p50/p90/p99 line chart
- **Segment Allocation Time** (`Journal`, panel 81): p50/p90/p99 line chart
- **Segment Flush Latency** (`Journal`, panel 426): p50/p90/p99 line chart
- **Compacting time** (`Journal`, panel 78): p50/p90/p99 line chart
- **Last Written Index Update** (`Journal`, panel 391): p50/p90/p99 line chart
- **Segment Seek Latency** (`Journal`, panel 559): p50/p90/p99 line chart
- **Sequencer Batch Entry Count** (`Logstream`, panel 357): p50/p90/p99 line chart
- **Sequencer Batch Size (KB)** (`Logstream`, panel 358): p50/p90/p99 line chart
- **Snapshot Operation Duration** (`Snapshots`, panel 112): p50/p90/p99 line chart
- **Snapshot Files Sizes (1m)** (`Snapshots`, panel 106): p50/p90/p99 line chart
- **Append Entry Latency** (`Raft`, panel 86): p50/p90/p99 line chart
- **Time Between Heartbeats** (`Raft`, panel 70): p50/p90/p99 line chart
- **Request response latency** (`Messaging`, panel 339): p50/p90/p99 line chart
- **Request size distribution** (`Messaging`, panel 341): p50/p90/p99 line chart
- **Create Process Instance Latency (gRPC)** (`gRPC`, panel 22): p50/p90/p99 line chart
- **Activate Jobs Latency (gRPC)** (`gRPC`, panel 23): p50/p90/p99 line chart
- **Complete Job Latency (gRPC)** (`gRPC`, panel 24): p50/p90/p99 line chart
- **Gateway Request Latency** (`Gateway`, panel 164): p50/p90/p99 line chart
- **Status Query Latency** (`Backups`, panel 323): p50/p90/p99 line chart
- **Swim Probe Latency** (`SWIM Protocol`, panel 547): p50/p90/p99 line chart
- **Elasticsearch Exporter (Flush Duration)** (`Elasticsearch Exporter`, panel 20): p50/p90/p99 line chart
- **Elasticsearch Exporter (Bulk Size)** (`Elasticsearch Exporter`, panel 21): p50/p90/p99 line chart
- **Actor Task Execution Latency** (`Actor`, panel 538): p50/p90/p99 line chart
- **Actor Job Scheduling Latency** (`Actor`, panel 540): p50/p90/p99 line chart

## Full metric mapping

| Prometheus family (8.7 `/actuator/prometheus`) | Grail metric key (OTLP push) | kind |
|---|---|---|
| `atomix_append_entries_data_rate_total` | `atomix.append.entries.data.rate` | counter |
| `atomix_append_entries_latency_seconds` | `atomix.append.entries.latency` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `atomix_append_entries_rate_total` | `atomix.append.entries.rate` | counter |
| `atomix_commit_entries_rate_total` | `atomix.commit.entries.rate` | counter |
| `atomix_compaction_time_ms_seconds` | `atomix.compaction.time.ms` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `atomix_election_latency_in_ms` | `atomix.election.latency.in.ms` | gauge |
| `atomix_heartbeat_miss_count_total` | `atomix.heartbeat.miss.count` | counter |
| `atomix_heartbeat_time_in_s_seconds` | `atomix.heartbeat.time.in.s` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `atomix_journal_append_data_rate_total` | `atomix.journal.append.data.rate` | counter |
| `atomix_journal_append_latency_seconds` | `atomix.journal.append.latency` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `atomix_journal_append_rate_total` | `atomix.journal.append.rate` | counter |
| `atomix_journal_flush_time_seconds` | `atomix.journal.flush.time` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `atomix_journal_open_time` | `atomix.journal.open.time` | gauge |
| `atomix_journal_seek_latency_seconds` | `atomix.journal.seek.latency` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `atomix_last_flushed_index_update_seconds` | `atomix.last.flushed.index.update` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `atomix_non_committed_entries` | `atomix.non_committed.entries` | gauge |
| `atomix_non_replicated_entries` | `atomix.non_replicated.entries` | gauge |
| `atomix_partition_raft_append_index` | `atomix.partition.raft.append.index` | gauge |
| `atomix_partition_raft_commit_index` | `atomix.partition.raft.commit.index` | gauge |
| `atomix_partition_server_bootstrap_time` | `atomix.partition.server.bootstrap.time` | gauge |
| `atomix_partition_server_join_time` | `atomix.partition.server.join.time` | gauge |
| `atomix_raft_messages_received_total` | `atomix.raft.messages.received` | counter |
| `atomix_raft_messages_send_total` | `atomix.raft.messages.send` | counter |
| `atomix_role` | `atomix.role` | gauge |
| `atomix_segment_allocation_time_seconds` | `atomix.segment.allocation.time` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `atomix_segment_creation_time_seconds` | `atomix.segment.creation.time` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `atomix_segment_flush_time_seconds` | `atomix.segment.flush.time` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `atomix_segment_truncate_time_seconds` | `atomix.segment.truncate.time` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `atomix_snapshot_replication_duration_milliseconds` | `atomix.snapshot.replication.duration.milliseconds` | gauge |
| `container_cpu_cfs_throttled_periods_total` | `dt.kubernetes.container.cpu_throttled` | gauge |
| `container_cpu_usage_seconds_total` | `dt.kubernetes.container.cpu_usage` | gauge |
| `container_memory_rss` | `dt.kubernetes.container.memory_working_set` | gauge |
| `grpc_server_processing_duration_seconds` | `grpc.server.processing.duration` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `jvm_buffer_memory_used_bytes` | `jvm.buffer.memory.used` | gauge |
| `jvm_buffer_total_capacity_bytes` | `jvm.buffer.total.capacity` | gauge |
| `jvm_gc_pause_seconds` | `jvm.gc.pause` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `jvm_memory_committed_bytes` | `jvm.memory.committed` | gauge |
| `jvm_memory_max_bytes` | `jvm.memory.max` | gauge |
| `jvm_memory_used_bytes` | `jvm.memory.used` | gauge |
| `jvm_threads_daemon_threads` | `jvm.threads.daemon` | gauge |
| `jvm_threads_live_threads` | `jvm.threads.live` | gauge |
| `kube_pod_container_resource_limits_memory_bytes` | `dt.kubernetes.container.limits_memory` | gauge |
| `kube_pod_container_resource_requests_memory_bytes` | `dt.kubernetes.container.requests_memory` | gauge |
| `kube_pod_container_status_restarts_total` | `dt.kubernetes.container.restarts` | counter |
| `kubelet_volume_stats_available_bytes` | `dt.kubernetes.persistentvolumeclaim.available` | gauge |
| `kubelet_volume_stats_capacity_bytes` | `dt.kubernetes.persistentvolumeclaim.capacity` | gauge |
| `kubelet_volume_stats_used_bytes` | `dt.kubernetes.persistentvolumeclaim.used` | gauge |
| `netty_allocator_memory_used` | `netty.allocator.memory.used` | gauge |
| `process_files_max_files` | `process.files.max` | gauge |
| `process_files_open_files` | `process.files.open` | gauge |
| `zeebe_actor_job_scheduling_latency_seconds` | `zeebe.actor.job.scheduling.latency` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_actor_task_execution_count_total` | `zeebe.actor_task_execution_count` | counter |
| `zeebe_actor_task_execution_latency_seconds` | `zeebe.actor.task.execution.latency` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_actor_task_queue_length` | `zeebe.actor.task.queue.length` | gauge |
| `zeebe_backpressure_append_limit` | `zeebe.backpressure.append.limit` | gauge |
| `zeebe_backpressure_requests_limit` | `zeebe.backpressure.requests.limit` | gauge |
| `zeebe_backup_operations_in_progress` | `zeebe.backup.operations.in.progress` | gauge |
| `zeebe_backup_operations_latency_seconds` | `zeebe.backup.operations.latency` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_backup_operations_total` | `zeebe.backup.operations.total` | counter |
| `zeebe_banned_instances_total` | `zeebe.banned.instances.total` | gauge |
| `zeebe_broker_close_step_latency` | `zeebe.broker.close.step.latency` | gauge |
| `zeebe_broker_health_nodes` | `zeebe.broker.health.nodes` | gauge |
| `zeebe_broker_jobs_fail_try_count_total` | `zeebe.broker.jobs.fail.try.count` | counter |
| `zeebe_broker_jobs_push_fail_count_total` | `zeebe.broker.jobs.push.fail.count` | counter |
| `zeebe_broker_jobs_push_fail_try_count_total` | `zeebe.broker.jobs.fail.try.count` | counter |
| `zeebe_broker_jobs_pushed_count_total` | `zeebe.broker.jobs.pushed.count` | counter |
| `zeebe_broker_start_step_latency` | `zeebe.broker.start.step.latency` | gauge |
| `zeebe_checkpoint_id` | `zeebe.checkpoint.id` | gauge |
| `zeebe_checkpoint_position` | `zeebe.checkpoint.position` | gauge |
| `zeebe_checkpoint_records_total` | `zeebe.checkpoint.records.total` | counter |
| `zeebe_client_worker_job_activated_total` | `zeebe.client.worker.job.activated` | counter |
| `zeebe_client_worker_job_handled_total` | `zeebe.client.worker.job.handled` | counter |
| `zeebe_cluster_changes_id` | `zeebe.cluster.changes.id` | gauge |
| `zeebe_cluster_changes_operation_attempts_total` | `zeebe.cluster.changes.operation.attempts` | counter |
| `zeebe_cluster_changes_operation_duration_seconds` | `zeebe.cluster.changes.operation.duration` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_cluster_changes_operations_completed` | `zeebe.cluster.changes.operations.completed` | gauge |
| `zeebe_cluster_changes_operations_pending` | `zeebe.cluster.changes.operations.pending` | gauge |
| `zeebe_cluster_changes_status` | `zeebe.cluster.changes.status` | gauge |
| `zeebe_cluster_changes_version` | `zeebe.cluster.changes.version` | gauge |
| `zeebe_cluster_topology_version` | `zeebe.cluster.topology.version` | gauge |
| `zeebe_deferred_append_count_total` | `zeebe.deferred.append.count.total` | counter |
| `zeebe_dns_error_total` | `zeebe.dns.error` | counter |
| `zeebe_dns_failed_total` | `zeebe.dns.failed` | counter |
| `zeebe_dns_success_total` | `zeebe.dns.success` | counter |
| `zeebe_dns_written_total` | `zeebe.dns.written` | counter |
| `zeebe_dropped_request_count_total` | `zeebe.dropped.request.count.total` | counter |
| `zeebe_elasticsearch_exporter_bulk_memory_size` | `zeebe.elasticsearch.exporter.bulk.memory.size` | gauge |
| `zeebe_elasticsearch_exporter_bulk_size` | `zeebe.elasticsearch.exporter.bulk.size` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_elasticsearch_exporter_failed_flush_total` | `zeebe.elasticsearch.exporter.failed.flush` | counter |
| `zeebe_elasticsearch_exporter_flush_duration_seconds` | `zeebe.elasticsearch.exporter.flush.duration.seconds` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_elasticsearch_exporter_flush_latency_seconds` | `zeebe.elasticsearch.exporter.flush.latency` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_element_instance_events_total` | `zeebe.element.instance.events.total` | counter |
| `zeebe_evaluated_dmn_elements_total` | `zeebe.evaluated.dmn.elements.total` | counter |
| `zeebe_executed_instances_total` | `zeebe.executed.instances.total` | counter |
| `zeebe_execution_latency_current_cached_instances` | `zeebe.execution.latency.current.cached.instances` | gauge |
| `zeebe_exporter_events_total` | `zeebe.exporter.events.total` | counter |
| `zeebe_exporter_exporting_duration_seconds` | `zeebe.exporter.exporting.duration` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_exporter_last_exported_position` | `zeebe.exporter.last.exported.position` | gauge |
| `zeebe_exporter_last_updated_exported_position` | `zeebe.exporter.last.updated.exported.position` | gauge |
| `zeebe_exporter_state` | `zeebe.exporter.state` | gauge |
| `zeebe_exporting_latency_seconds` | `zeebe.exporting.latency` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_flow_control_exporting_rate` | `zeebe.flow.control.exporting.rate` | gauge |
| `zeebe_flow_control_partition_load` | `zeebe.flow.control.partition.load` | gauge |
| `zeebe_flow_control_total` | `zeebe.flow.control` | counter |
| `zeebe_flow_control_write_rate_limit` | `zeebe.flow.control.write.rate.limit` | gauge |
| `zeebe_flow_control_write_rate_maximum` | `zeebe.flow.control.write.rate.maximum` | gauge |
| `zeebe_gateway_failed_requests_total` | `zeebe.gateway.failed.requests` | counter |
| `zeebe_gateway_job_stream__total` | `zeebe.gateway.job.stream.` | counter |
| `zeebe_gateway_job_stream_aggregated_stream_clients` | `zeebe.gateway.job.stream.aggregated.stream.clients` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_gateway_job_stream_clients` | `zeebe.gateway.job.stream.clients` | gauge |
| `zeebe_gateway_job_stream_push_fail_try_total` | `zeebe.gateway.job.stream.push.fail.try` | counter |
| `zeebe_gateway_job_stream_push_total` | `zeebe.gateway.job.stream.push` | counter |
| `zeebe_gateway_job_stream_servers` | `zeebe.gateway.job.stream.servers` | gauge |
| `zeebe_gateway_job_stream_streams` | `zeebe.gateway.job.stream.streams` | gauge |
| `zeebe_gateway_request_latency_seconds` | `zeebe.gateway.request.latency` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_gateway_topology_partition_roles` | `zeebe.gateway.topology.partition.roles` | gauge |
| `zeebe_gateway_total_requests_total` | `zeebe.gateway.total.requests` | counter |
| `zeebe_health` | `zeebe.health` | gauge |
| `zeebe_incident_events_total` | `zeebe.incident.events.total` | counter |
| `zeebe_job_activation_time_seconds` | `zeebe.job.activation.time` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_job_events_total` | `zeebe.job.events.total` | counter |
| `zeebe_job_life_time_seconds` | `zeebe.job.life.time` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_leader_transition_latency_seconds` | `zeebe.leader.transition.latency` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_log_appender_append_latency_seconds` | `zeebe.log.appender.append.latency` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_log_appender_commit_latency_seconds` | `zeebe.log.appender.commit.latency` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_log_appender_last_appended_position` | `zeebe.log.appender.last.appended.position` | gauge |
| `zeebe_log_appender_last_committed_position` | `zeebe.log.appender.last.committed.position` | gauge |
| `zeebe_log_appender_record_appended_total` | `zeebe.log.appender.record.appended` | counter |
| `zeebe_long_polling_queued_current` | `zeebe.long.polling.queued.current` | gauge |
| `zeebe_messaging_inflight_requests` | `zeebe.messaging.inflight.requests` | gauge |
| `zeebe_messaging_request_count_total` | `zeebe.messaging.request.count` | counter |
| `zeebe_messaging_request_response_latency_seconds` | `zeebe.messaging.request.response.latency` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_messaging_request_size_kb` | `zeebe.messaging.request.size.kb` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_messaging_response_count_total` | `zeebe.messaging.response.count` | counter |
| `zeebe_pending_incidents_total` | `zeebe.pending.incidents.total` | gauge |
| `zeebe_process_instance_creations_total` | `zeebe.process.instance.creations.total` | counter |
| `zeebe_process_instance_execution_time_seconds` | `zeebe.process.instance.execution.time` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_received_request_count_total` | `zeebe.received.request.count.total` | counter |
| `zeebe_replay_event_batch_replay_duration_seconds` | `zeebe.replay.event.batch.replay.duration` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_replay_events_total` | `zeebe.replay.events.total` | counter |
| `zeebe_replay_last_source_position` | `zeebe.replay.last.source.position` | gauge |
| `zeebe_rocksdb_latency_seconds` | `zeebe.rocksdb.latency` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_rocksdb_live_estimate_live_data_size` | `zeebe.rocksdb.live.estimate.live.data.size` | gauge |
| `zeebe_rocksdb_live_estimate_num_keys` | `zeebe.rocksdb.live.estimate.num.keys` | gauge |
| `zeebe_rocksdb_live_num_entries_imm_mem_tables` | `zeebe.rocksdb.live.num.entries.imm.mem.tables` | gauge |
| `zeebe_rocksdb_memory_block_cache_capacity` | `zeebe.rocksdb.memory.block.cache.capacity` | gauge |
| `zeebe_rocksdb_memory_block_cache_pinned_usage` | `zeebe.rocksdb.memory.block.cache.pinned.usage` | gauge |
| `zeebe_rocksdb_memory_block_cache_usage` | `zeebe.rocksdb.memory.block.cache.usage` | gauge |
| `zeebe_rocksdb_memory_cur_size_active_mem_table` | `zeebe.rocksdb.memory.cur.size.active.mem.table` | gauge |
| `zeebe_rocksdb_memory_cur_size_all_mem_tables` | `zeebe.rocksdb.memory.cur.size.all.mem.tables` | gauge |
| `zeebe_rocksdb_memory_estimate_table_readers_mem` | `zeebe.rocksdb.memory.estimate.table.readers.mem` | gauge |
| `zeebe_rocksdb_memory_size_all_mem_tables` | `zeebe.rocksdb.memory.size.all.mem.tables` | gauge |
| `zeebe_rocksdb_sst_live_sst_files_size` | `zeebe.rocksdb.sst.live.sst.files.size` | gauge |
| `zeebe_rocksdb_sst_total_sst_files_size` | `zeebe.rocksdb.sst.total.sst.files.size` | gauge |
| `zeebe_rocksdb_writes_actual_delayed_write_rate` | `zeebe.rocksdb.writes.actual.delayed.write.rate` | gauge |
| `zeebe_rocksdb_writes_is_write_stopped` | `zeebe.rocksdb.writes.is.write.stopped` | gauge |
| `zeebe_rocksdb_writes_mem_table_flush_pending` | `zeebe.rocksdb.writes.mem.table.flush.pending` | gauge |
| `zeebe_rocksdb_writes_num_running_compactions` | `zeebe.rocksdb.writes.num.running.compactions` | gauge |
| `zeebe_rocksdb_writes_num_running_flushes` | `zeebe.rocksdb.writes.num.running.flushes` | gauge |
| `zeebe_sequencer_batch_length_bytes` | `zeebe.sequencer.batch.length.bytes` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_sequencer_batch_size` | `zeebe.sequencer.batch.size` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_smp_members_incarnation_number` | `zeebe.smp.members.incarnation.number` | gauge |
| `zeebe_snapshot_count_total` | `zeebe.snapshot.count` | counter |
| `zeebe_snapshot_duration_seconds` | `zeebe.snapshot.duration` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_snapshot_file_size_megabytes` | `zeebe.snapshot.file.size.megabytes` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_snapshot_persist_duration_seconds` | `zeebe.snapshot.persist.duration` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_snapshot_size_bytes` | `zeebe.snapshot.size.bytes` | gauge |
| `zeebe_stream_processor_batch_processing_commands` | `zeebe.stream.processor.batch.processing.commands` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_stream_processor_batch_processing_duration_seconds` | `zeebe.stream.processor.batch.processing.duration` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_stream_processor_batch_processing_post_commit_tasks_seconds` | `zeebe.stream.processor.batch.processing.post.commit.tasks` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_stream_processor_batch_processing_retry_total` | `zeebe.stream.processor.batch.processing.retry` | counter |
| `zeebe_stream_processor_error_handling_phase` | `zeebe.stream.processor.error.handling.phase` | gauge |
| `zeebe_stream_processor_last_processed_position` | `zeebe.stream.processor.last.processed.position` | gauge |
| `zeebe_stream_processor_latency_seconds` | `zeebe.stream.processor.latency` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_stream_processor_processing_duration_seconds` | `zeebe.stream.processor.processing.duration` *(histogram: `_bucket`/`_sum`/`_count` collapse into this key, `le` is gone)* | histogram |
| `zeebe_stream_processor_records_total` | `zeebe.stream.processor.records.total` | counter |
| `zeebe_stream_processor_scheduled_command_cache_size` | `zeebe.stream.processor.scheduled.command.cache.size` | gauge |
| `zeebe_stream_processor_startup_recovery_time` | `zeebe.stream.processor.startup.recovery.time` | gauge |
| `zeebe_stream_processor_state` | `zeebe.stream.processor.state` | gauge |
| `zeebe_try_to_append_total` | `zeebe.try.to.append.total` | counter |

