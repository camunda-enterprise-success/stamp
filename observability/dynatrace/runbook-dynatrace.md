# 📊 Runbook: Camunda 8.7 Zeebe monitoring in Dynatrace

**Related config:** [`camunda-otlp-values.yaml`](camunda-otlp-values.yaml) · [`otel-collector-dynatrace.yaml`](otel-collector-dynatrace.yaml) · [`metric-mapping-8.7.md`](metric-mapping-8.7.md)

## 🔭 Overview

Five Dynatrace **Platform Dashboards** that reproduce the Camunda-published Grafana dashboard
`grafana_original_baseline/8.7.35-zeebe.json` (26 rows, 211 panels) for a Camunda 8.7
Self-Managed cluster whose metrics reach Dynatrace over **OTLP**.

| Dashboard | Sections | Data tiles |
|---|---|---|
| [`8.7-zeebe-01-overview.json`](8.7-zeebe-01-overview.json) | General Overview, Start up, Cluster | 22 |
| [`8.7-zeebe-02-processing.json`](8.7-zeebe-02-processing.json) | Processing, Throughput, Latency, Backpressure | 46 |
| [`8.7-zeebe-03-storage.json`](8.7-zeebe-03-storage.json) | Journal, Logstream, RocksDB, Snapshots | 52 |
| [`8.7-zeebe-04-cluster.json`](8.7-zeebe-04-cluster.json) | Raft, Messaging, gRPC, Gateway, Backups, SWIM, DNS | 47 |
| [`8.7-zeebe-05-resources.json`](8.7-zeebe-05-resources.json) | Memory, CPU, IO, ES Exporter, Actor, Worker Jobs, Job push/stream | 36 |

203 of the 211 baseline panels are ported. The 8 that are not, and the 59 that changed meaning,
are listed in [`metric-mapping-8.7.md`](metric-mapping-8.7.md#panels-that-changed-meaning) and in
each tile's own description.

> ℹ️ **Why five files.** Dynatrace Platform Dashboards have no collapsible rows — every tile is
> always rendered. A single 203-tile page is unusable, so the Grafana rows are grouped into five
> dashboards with markdown tiles as section headers. Each dashboard's header tile links to its
> siblings by filename.

### Assumed ingest path

**Camunda pushes OTLP directly to Dynatrace** (`management.otlp.metrics.export.enabled=true`,
Spring Boot's Micrometer `OtlpMeterRegistry`). Metric keys are therefore the **dotted Micrometer
meter names**:

```
timeseries records = sum(zeebe.stream.processor.records.total, rate:1s), by: {partition}
timeseries p99 = percentile(zeebe.stream.processor.latency, 99), by: {partition}
```

⚠️ If your cluster is instead scraped by an **OpenTelemetry Collector** (`prometheus` receiver →
`otlphttp`), the keys keep the Prometheus spelling (`zeebe_stream_processor_records_total`,
`zeebe_stream_processor_latency_seconds`) and **none of these dashboards will return data**.
Check which path you are on before anything else — step 1 below — and convert with the table in
[`metric-mapping-8.7.md`](metric-mapping-8.7.md#full-metric-mapping) if needed.

---

## 📋 Scope & prerequisites

- [ ] Camunda **8.7.x** Self-Managed (the metric names changed with the Micrometer migration in
      8.7 / 8.6.9 — these dashboards do not fit 8.6.8 or earlier, and 8.8 adds families they do
      not cover)
- [ ] Dynatrace SaaS with **Grail** and the *Metrics powered by Grail* rate card
      (`timeseries percentile` is licensed through it — without it every latency tile fails)
- [ ] Dynatrace **1.344 or later** (Dashboards app). From 1.344 a dashboard that fails schema
      validation does not load at all
- [ ] **Advanced OTLP metric dimensions** enabled on the environment — see step 2
- [ ] API token with the **`metrics.ingest`** scope, stored in a Secret named `dynatrace-otlp`
- [ ] User permissions to read metrics: `storage:metrics:read`, `storage:buckets:read`
- [ ] *For the infrastructure tiles only:* **Dynatrace Kubernetes monitoring** (Dynatrace
      Operator) on the cluster — PVC usage, container CPU/memory, restarts and throttling come
      from `dt.kubernetes.*`, not from Camunda

---

## ⚙️ Step 1 — Confirm which ingest path you are on

Run this in a **Notebook** before importing anything. It is the single fastest way to find out
whether these dashboards will work as shipped:

```dql
load "/dt/platform/metrics.metadata"
| filter matchesValue(metric.key, "*zeebe*")
| fields metric.key, kind, metric.type, unit, dimensions
| sort metric.key asc
```

| What you see | Meaning | Action |
|---|---|---|
| `zeebe.stream.processor.records.total`, dotted keys | Native OTLP push | ✅ Import as-is |
| `zeebe_stream_processor_records_total`, underscored keys | Collector scrape of `/actuator/prometheus` | Convert the keys (see the mapping file) or switch to the native push |
| nothing at all | Metrics are not arriving | Continue with step 2 |

Also check what you got for the histograms:

- `kind = histogram` for e.g. `zeebe.stream.processor.latency` → percentiles will work.
- `kind = count` instead → *Advanced OTLP metric dimensions* is off, or the histogram flavor is
  exponential. Fix it in step 2; percentiles are unavailable until you do.
- Dimension keys arriving lowercased (`valuetype` rather than `valueType`) → *Advanced OTLP
  metric dimensions* is off. The camelCase filters in these dashboards will not match.

---

## 📡 Step 2 — Configure ingest

Merge [`camunda-otlp-values.yaml`](camunda-otlp-values.yaml) into your Camunda Helm values.
Four settings there are load-bearing; each one fails **silently** if wrong:

| # | Setting | Why |
|---|---|---|
| 1 | `MANAGEMENT_OTLP_METRICS_EXPORT_AGGREGATIONTEMPORALITY=DELTA` | Dynatrace does not ingest cumulative counters or histograms — they are dropped at ingest. Micrometer defaults to `CUMULATIVE`, so **every Zeebe counter and every latency histogram disappears** without this. |
| 2 | `MANAGEMENT_OTLP_METRICS_EXPORT_BASETIMEUNIT=SECONDS` | Spring Boot's OTLP registry defaults to **milliseconds** while the Prometheus registry uses seconds. Leave the default and every latency tile — and every bucket boundary — is 1000× off versus the Grafana baseline. |
| 3 | `MANAGEMENT_OPENTELEMETRY_RESOURCE_ATTRIBUTES_K8S_*` | `pod` and `namespace` are Prometheus *target* labels, not metric labels: they do not exist on this path unless you set them as resource attributes. Without them the `$Namespace` / `$Pod` variables are empty and every tile filters to nothing. |
| 4 | `MANAGEMENT_OTLP_METRICS_EXPORT_HISTOGRAMFLAVOR=explicit_bucket_histogram` | Exponential histograms are ingested as gauges **without buckets**, so `percentile()` cannot work. |

Then enable **Advanced OTLP metric dimensions** in the environment
(*Settings → Metrics → OpenTelemetry / OTLP*). Without it: explicit-bucket histograms degrade to
counters, dimension keys are lowercased, and limits drop to 50 dimensions / 100-character keys.

`otel-collector-dynatrace.yaml` is optional — add the gateway if you want a single egress point,
`k8sattributes` enrichment, or queue buffering. Metric names are unchanged either way.

### ✅ Verification checklist

```dql
// 1. Are the core families present, and are they the right kind?
load "/dt/platform/metrics.metadata"
| filter in(metric.key, "zeebe.health", "zeebe.stream.processor.records.total",
            "zeebe.stream.processor.latency", "atomix.role")
| fields metric.key, kind, unit, dimensions
```

- [ ] `zeebe.health` → `gauge`, dimensions include `partition`
- [ ] `zeebe.stream.processor.records.total` → `count`, dimensions include `partition`, `action`
- [ ] `zeebe.stream.processor.latency` → **`histogram`**
- [ ] `atomix.role` → `gauge`, dimensions include `partition`

```dql
// 2. Do the k8s resource attributes exist? Both columns must be populated.
timeseries n = count(zeebe.health), by: {k8s.namespace.name, k8s.pod.name}
```

```dql
// 3. Do percentiles resolve? (fails without the Metrics powered by Grail rate card)
timeseries p99 = percentile(zeebe.stream.processor.latency, 99), by: {partition}
```

- [ ] one series per partition, values in **seconds** (a p99 in the tens of milliseconds reads as
      `0.0xx`; values in the tens or hundreds means base-time-unit is still milliseconds)

---

## 📈 Step 3 — Import the dashboards

1. **Dashboards** app → left panel → **Upload** → select `8.7-zeebe-01-overview.json`.
2. Repeat for the other four files.
3. Open each one and confirm the `Namespace`, `Pod` and `Partition` dropdowns are populated.

Upload runs the same validator that 1.344 applies at load time, so a successful upload is also
a schema check. To edit in place afterwards: dashboard name menu → **Edit JSON**.

### ✅ Verification checklist

- [ ] All five dashboards upload without a validation error
- [ ] `Namespace` lists your Camunda namespace; `Pod` lists the broker pods; `Partition` lists
      `1..n`
- [ ] **Overview → Health** honeycomb shows one green cell per partition
- [ ] **Overview → Topology** shows one row per pod/partition with role `3` on exactly one pod
      per partition (`0` Inactive, `1` Follower, `2` Candidate, `3` Leader)
- [ ] **Processing → Number of records not processed** is a small, flat number (this is the
      processing backlog)
- [ ] **Latency → Overall Processing Latency** draws three lines (p50/p90/p99)
- [ ] Infrastructure tiles (**Overview → PVC Disk Usage**, **CPU Throttling**) either show data
      or are empty *because* Dynatrace Kubernetes monitoring is not installed — not because of
      the ingest path

---

## 🧭 What the tiles are, and where they differ from Grafana

Every tile that deviates says so in its own **description** field, and all deviations are
catalogued in [`metric-mapping-8.7.md`](metric-mapping-8.7.md#panels-that-changed-meaning).
The classes of deviation:

| Class | Count | What changed |
|---|---|---|
| Heatmap → percentiles | 38 | Dynatrace cannot render a bucket distribution over time, so each histogram heatmap is a p50/p90/p99 line chart. Estimated percentiles are accurate to ~2.2 % and are not guaranteed to match PromQL's `histogram_quantile`. |
| Rewritten | 15 | No DQL equivalent for the original expression (`label_replace`, `and on(...)`, cAdvisor ratios, histogram observation counts). |
| Partially ported | 6 | A dead pre-Micrometer query was dropped from a tile that is otherwise complete. |
| Dropped | 8 | The metric does not exist on this path at all. |
| Delta-counter cumulation | 11 | Grafana charted monotonic Prometheus counters; delta-ingested counters are cumulated over the timeframe with `arrayCumulativeSum`. |

The three deviations most worth knowing before you rely on a tile:

1. **Backpressure → Backpressure Requests Limit** no longer filters to Raft leaders (DQL has no
   cross-metric join). Follower series are excluded by dropping all-zero series instead.
2. **gRPC → Total gRPC requests / requests per second** and **Overview → Requests handled by
   Gateway** use the `zeebe.gateway.total.requests` counter. Grail cannot query a histogram's
   observation count, so the original `grpc_*_count` rate is not reproducible.
3. **IO → disk and network throughput** (6 panels) are gone: they read cAdvisor
   `container_fs_*` / `container_network_*`, which have no Dynatrace container-level equivalent.
   A markdown tile in that section says so and points at the Kubernetes app.

### Multi-cluster tenants

The shipped filters use `k8s.namespace.name`, `k8s.pod.name` and `partition` only — Grafana's
`$cluster` variable is **not** reproduced, because `k8s.cluster.name` only exists if you set it
as a resource attribute. If you monitor several Camunda clusters in one tenant:

1. Set `MANAGEMENT_OPENTELEMETRY_RESOURCE_ATTRIBUTES_K8S_CLUSTER_NAME` (already present in
   `camunda-otlp-values.yaml`).
2. Add a `Cluster` variable to each dashboard (copy the `Namespace` variable, swap the dimension).
3. Either add `in(k8s.cluster.name, array($Cluster))` to the tile filters, or — simpler — define
   a **segment** per cluster and apply it to the dashboard; segments layer onto every tile query
   without editing DQL.

### Adding units and thresholds

The tiles ship without `unitsOverrides`, because Dynatrace does not publish the valid
`unitCategory` / `baseUnit` enums and an invalid value would stop the whole dashboard from
loading on 1.344. Column names carry the unit instead (`*_per_sec`, `*_bytes`, `p99` in seconds).
To format a tile: open it, set the unit in the visualization settings, then **Download** the
dashboard to keep the change.

---

## ✅ Post-deployment operational checklist

- [ ] Compare a handful of tiles against the existing Grafana dashboard while both run in
      parallel: **Processing per Partition**, **Overall Processing Latency (p99)**,
      **Number of records not exported**, **Total Dropped Requests**
- [ ] Confirm the export interval (`step: 30s`) is not coarser than the tile interval you read
- [ ] If you run the collector gateway, keep it at **one replica** — `cumulativetodelta` keeps
      per-series state and parallel replicas corrupt delta offsets
- [ ] Decide whether to keep `management.prometheus.metrics.export.enabled=true`; leaving it on
      costs little and keeps the Grafana baseline usable as a reference
- [ ] Consider Davis metric events for the signals in `Metrics _ Alerts 8.7 -> 8.8.xlsx`
      (alerting was out of scope for this port; `datadog_alerts/` shows the equivalent set)

---

## 🔧 Troubleshooting

| Symptom | Likely cause | Resolution |
|---|---|---|
| A dashboard does not render at all after upload | Schema validation failure (1.344+) | Re-upload the unmodified file; if you edited it, check every tile still has `title`, `query`, `visualization`, `visualizationSettings`, `querySettings` and no `subType` |
| Every tile is empty, variables are empty too | Metrics are not arriving, or keys are underscored | Run step 1's discovery query |
| Counters and latency tiles empty, gauges fine | Cumulative temporality — Dynatrace drops cumulative counters and histograms | Set `AGGREGATIONTEMPORALITY=DELTA`, restart the pods |
| Variables list nothing, but metrics exist | `k8s.pod.name` / `k8s.namespace.name` resource attributes not set | Apply the resource attributes from `camunda-otlp-values.yaml` |
| Latency values ~1000× too large | `base-time-unit` still milliseconds | Set `BASETIMEUNIT=SECONDS` |
| All percentile tiles error | Missing *Metrics powered by Grail* rate card, or the histogram was ingested as a counter | Check `kind` in step 1; enable Advanced OTLP metric dimensions and `explicit_bucket_histogram` |
| Percentile tiles empty but `kind = histogram` | Exponential histograms: Dynatrace ingests min/max/sum/count but no buckets | Set `HISTOGRAMFLAVOR=explicit_bucket_histogram` |
| Tiles split by `valueType` / `columnFamily` / `eventType` show nothing | Dimension keys were lowercased at ingest | Enable Advanced OTLP metric dimensions, or lowercase those dimension names in the DQL |
| A `mean = avg(<histogram>)` tile is empty | Tenant will not aggregate a histogram with `avg()` | Replace with `percentile(<key>, 50)` |
| Only one pod appears anywhere | `service.name` defaults to `Camunda` for every pod and no pod attribute is set | Set the resource attributes (step 2, item 3) |
| PVC / CPU / memory / restart tiles empty | Dynatrace Kubernetes monitoring not installed, or `k8s.persistentvolumeclaim.name` is named differently in your tenant | Install the Dynatrace Operator; verify the PVC dimension name with `load "/dt/platform/metrics.metadata" \| filter matchesValue(metric.key, "dt.kubernetes.persistentvolumeclaim*")` |
| Throughput tiles look like steps rather than a smooth curve | Export step (30s) is coarser than the tile interval | Lower `MANAGEMENT_OTLP_METRICS_EXPORT_STEP` or widen the dashboard timeframe |

---

## 📚 References

- [Dynatrace — dashboard document structure](https://docs.dynatrace.com/docs/analyze-explore-automate/dashboards-and-notebooks/document-api/document-structure-dashboards)
- [Dynatrace — manage dashboards (upload / download / edit JSON)](https://docs.dynatrace.com/docs/analyze-explore-automate/dashboards-and-notebooks/dashboards-new/get-started/dashboards-manage)
- [Dynatrace — DQL metric commands (`timeseries`)](https://docs.dynatrace.com/docs/platform/grail/dynatrace-query-language/commands/metric-commands)
- [Dynatrace — histogram metrics and percentiles](https://docs.dynatrace.com/docs/analyze-explore-automate/metrics/histograms)
- [Dynatrace — about OTLP metrics ingest (temporality, metric keys)](https://docs.dynatrace.com/docs/ingest-from/opentelemetry/otlp-api/ingest-otlp-metrics/about-metrics-ingest)
- [Camunda 8.7 — metrics](https://docs.camunda.io/docs/8.7/self-managed/operational-guides/monitoring/metrics/)
- [Micrometer — OTLP registry configuration](https://docs.micrometer.io/micrometer/reference/implementations/otlp.html)
