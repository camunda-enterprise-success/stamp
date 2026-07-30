# Alert mapping — Camunda 8.7, Prometheus alerts → Dynatrace metric events

**Originals:** [`prometheus-grafana/prometheus-alerts/`](../prometheus-grafana/prometheus-alerts/)
**Same exercise for Datadog:** [`datadog_alerts/`](../datadog_alerts/)
**Related config:** [`dynatrace/metric-mapping-8.7.md`](../dynatrace/metric-mapping-8.7.md) ·
[`dynatrace/runbook-dynatrace.md`](../dynatrace/runbook-dynatrace.md)

This ports the same 20 Prometheus rules already ported to `datadog_alerts/` — this time to
Dynatrace, targeting the same ingest path as the `dynatrace/` dashboards: Camunda's **native
Micrometer OTLP push** (`management.otlp.metrics.export.enabled=true`), not a Prometheus scrape.
That choice matters more here than it did for Datadog, because it changes the actual metric key
spelling (see below) and because it surfaces two metrics the Datadog port used that **do not
exist on this ingest path in 8.7**.

## Format used

Each file is one [`builtin:anomaly-detection.metric-events`](https://docs.dynatrace.com/docs/dynatrace-api/environment-api/settings/schemas/builtin-anomaly-detection-metric-events)
Settings 2.0 object (`POST /api/v2/settings/objects`), the classic Davis "metric event" — stable
and API-managed, unlike the newer Grail/DQL-based custom alerting which is still a moving target.
The runbook's own deferred TODO ("Consider Davis metric events... alerting was out of scope for
this port") is exactly what this directory fills in.

Every file uses `queryDefinition.type: METRIC_SELECTOR` with a single self-contained
`metricSelector` string (filters, splits and math all inline), `modelProperties.type:
STATIC_THRESHOLD`, and one-minute-resolution samples. `violatingSamples == samples` reproduces
Prometheus' `for:` (condition must hold for every sample in the window, not just most of them);
`dealertingSamples` is fixed at 5 (not derived from the source rule — Prometheus has no dealerting
concept) unless the window itself is shorter than 5 samples.

## Metric key spelling: two conventions in one directory

- **Zeebe/Atomix/JVM metrics** (native Micrometer OTLP push): dotted keys, e.g.
  `zeebe.stream.processor.records.total` — taken from
  [`dynatrace/metric-mapping-8.7.md`](../dynatrace/metric-mapping-8.7.md#full-metric-mapping).
- **Elasticsearch metrics**: Elasticsearch is not a Micrometer app; its `elasticsearch_exporter`
  Prometheus endpoint reaches Dynatrace (if at all) through an OTel Collector's `prometheus`
  receiver, which — per the runbook's own step 1 — **keeps the underscored Prometheus spelling**
  (`elasticsearch_cluster_health_active_shards`, not dots). These alerts use underscores
  accordingly, unlike `datadog_alerts/`, which dotted everything because Datadog's OpenMetrics
  check converts names that way regardless of path.
- **Connectors metrics** (`logback_events_total`, `executor_queued_tasks`): Connectors is a
  separate Spring Boot runtime not covered by `camunda-otlp-values.yaml` (which only wires up
  `zeebe` / `zeebeGateway`). These alerts assume it is configured the same way and use dotted
  keys; if instead it is collector-scraped, swap in the underscored Prometheus names (noted in
  each file's `description`).
- **Kubernetes infrastructure** (pod restarts, PVC usage): sourced from Dynatrace's built-in
  `dt.kubernetes.*` metrics, per the runbook — this needs Dynatrace Kubernetes monitoring
  (Dynatrace Operator) regardless of how Camunda's own metrics arrive.

## Two metrics the Datadog port used that don't exist here

- **`grpc_server_handled_total`** (`zeebe-slo-request-failure-rate`): pre-Micrometer, dead in 8.7
  — `metric-mapping-8.7.md` only carries the histogram `grpc.server.processing.duration` forward,
  and Grail can't read a histogram's observation count (same reason three dashboard panels were
  rewritten). `zeebe-slo-request-failure-rate.json` substitutes
  `zeebe.gateway.failed.requests` / `zeebe.gateway.total.requests` — a gateway-wide failure ratio,
  not a per-gRPC-status-code one. Verify the `requestType` dimension name/values in your tenant
  before trusting the exclusion of `CreateProcessInstanceWithResult`.
- **`zeebe_blacklisted_instances_total`**: the legacy pre-Micrometer name for what 8.7 calls
  `zeebe.banned.instances.total` — same reason the dashboard port dropped 59 `or` fallback
  branches. Unlike `datadog_alerts/`, which mirrors the source rule's two-metric-OR shape as three
  files (`-banned`, `-blacklisted`, a composite) because Datadog can't OR two distinct metric
  queries in one monitor, this port is a **single file**, `zeebe-banned-instances.json`: 8.7 only
  emits one metric, and a Dynatrace `metricSelector` can express `>0` on it directly with no
  composite needed.

## Metrics inferred, not verified

`metric-mapping-8.7.md` only covers the Zeebe Grafana dashboard's metrics (35 `MetricsDoc`
enums). Three metrics used below are not in that table because they were out of scope for that
exercise, not because they're confirmed dead. Each is mapped by the same underscore→dot rule
verified everywhere else in the table (gauges/counters map verbatim, no unit suffix) and flagged
in its file:

| Metric | Used by | Grail key used here |
|---|---|---|
| `atomix_segment_count` | `zeebe-too-many-segments` | `atomix.segment.count` |
| `zeebe_camunda_exporter_process_instances_awaiting_archival` | `archiver-backlog-growing` | `zeebe.camunda.exporter.process.instances.awaiting.archival` |

## Conditions no metric-selector can express

Same limitation Datadog hit, for the same reason: a `STATIC_THRESHOLD` metric event (like a
Datadog query alert) evaluates one query against one threshold — there's no cross-metric `and
on(...)` join and no "is this still trending the same direction" check.

- **`archiver-backlog-growing`**: drops the original's `delta(...)[10m:1m] >= 0` (backlog not
  shrinking) condition, alerting on "backlog > 0 for 2h" alone.
- **`elastic-ilm-stopped`**, **`elastic-wrong-replica-count`**: drop the ES-version /
  data-node-count exclusion joins.

If you need the dropped half of any of these back, it requires a scheduled DQL query (a
Dynatrace Workflow on a timer, evaluating a multi-line query and raising a Davis event via the
`dt.events.ingest` API) rather than a metric event — out of scope here, same as it was for the
dashboards.

## Long `for:` windows vs. one-minute samples

Metric events sample once a minute, so `violatingSamples == samples` reproducing a Prometheus
`for: 1d` (`elastic-ilm-stopped`, `elastic-wrong-replica-count`) means `samples: 1440`. That's
mechanically what the JSON says, but verify your tenant's Settings UI/API doesn't cap the
practical sample count before relying on it — a scheduled Workflow is the more common way
Dynatrace users handle day-scale conditions.

## `severity` is not reproduced

Several source rules template `severity` off `label_cloud_camunda_io_channel` (`page` on Stable
channel clusters, `critical` otherwise). Metric events have no equivalent per-instance severity
field — the source rule's default (`critical`) is used, matching the simplification
`datadog_alerts/` already made for the same rules.
