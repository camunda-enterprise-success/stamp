# 📊 Runbook: Camunda 8 Monitoring & Logging on EKS + AWS Observability

## 🔭 Overview

This runbook covers setting up AWS-native observability for Camunda 8 Self-Managed on EKS using:

- **Amazon CloudWatch Observability add-on** — pod and cluster metrics via Container Insights
- **ADOT Collector** — scrapes Camunda Prometheus endpoints and exports via EMF to CloudWatch Metrics
- **Fluent Bit DaemonSet** — ships container logs to CloudWatch Logs

> ℹ️ This runbook targets Camunda 8.7 on EKS. Components covered: Zeebe, Operate, Identity, Connectors. Extend patterns for Tasklist and Optimize as needed.

---

## 📋 Scope & Prerequisites

**Namespaces required:**

| Namespace | Purpose |
|---|---|
| `camunda` | Camunda components + Fluent Bit |
| `otel-collector` | ADOT Collector |
| `amazon-cloudwatch` | CloudWatch Observability add-on |

**Before you begin:**

- [ ] EKS cluster running with above namespaces created
- [ ] EKS OIDC provider configured
- [ ] IAM roles for service accounts (IRSA) ready to create

---

## 🔐 IAM / IRSA Setup

### Create IRSA Roles

Create three IAM roles with web identity trust to the cluster OIDC provider:

| Role Name | Used By |
|---|---|
| `camunda-ds-eks-*-sa-cloudwatch-role` | CloudWatch Observability add-on |
| `camunda-ds-eks-*-sa-fluent-bit-role` | Fluent Bit |
| `camunda-ds-eks-*-sa-adot-collector-role` | ADOT Collector |

### IAM Policy Permissions

**Fluent Bit:**
```json
{
  "Effect": "Allow",
  "Action": [
    "logs:CreateLogGroup",
    "logs:CreateLogStream",
    "logs:DescribeLogGroups",
    "logs:DescribeLogStreams",
    "logs:PutLogEvents"
  ],
  "Resource": "*"
}
```

**ADOT Collector:**
```json
{
  "Effect": "Allow",
  "Action": [
    "cloudwatch:PutMetricData",
    "logs:*"
  ],
  "Resource": "*"
}
```

**CloudWatch add-on:** Follow [AWS docs](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/install-CloudWatch-Observability-EKS-addon.html) for cluster/EC2 read access and CloudWatch metrics/logs permissions.

### Trust Policy — Restrict to Exact Service Accounts

```json
{
  "Condition": {
    "StringEquals": {
      "oidc.eks.<region>.amazonaws.com/id/<OIDC_ID>:sub": [
        "system:serviceaccount:camunda:fluent-bit-sa",
        "system:serviceaccount:otel-collector:adot-collector",
        "system:serviceaccount:amazon-cloudwatch:cloudwatch-agent",
        "system:serviceaccount:amazon-cloudwatch:amazon-cloudwatch-observability-controller-manager"
      ]
    }
  }
}
```

Annotate each service account after creation:

```bash
kubectl annotate serviceaccount <sa-name> \
  --namespace <namespace> \
  eks.amazonaws.com/role-arn=arn:aws:iam::ACCOUNT_ID:role/<role-name>
```

---

## 📡 Install & Verify CloudWatch Observability

### Install

1. In the AWS Console: **EKS → Cluster → Add-ons → Get more add-ons → Amazon CloudWatch Observability**
2. Select the CloudWatch IRSA role
3. In additional configuration, disable container logs (Fluent Bit handles these):

```json
{
  "containerLogs": {
    "enabled": false
  }
}
```

### ✅ Verification Checklist

```bash
kubectl get pods -n amazon-cloudwatch
# All pods should be Running
```

In **CloudWatch → Metrics → ContainerInsights**, confirm metrics are visible for `ClusterName = camunda-ds-eks-cluster-<env>`:

- [ ] CPU Utilization
- [ ] Memory Utilization
- [ ] Disk Utilization
- [ ] Network RX/TX
- [ ] Cluster Failures

---

## 📝 Install & Verify Fluent Bit (Camunda Logs)

### Prepare `fluent-bit.yaml`

```yaml
cloudWatch:
  enabled: true
  logGroupName: /eks/camunda-ds-eks-cluster-<env>/fluent-bit-camunda-logs
  region: eu-west-1  # set your region

serviceAccount:
  create: true
  name: fluent-bit-sa
  annotations:
    eks.amazonaws.com/role-arn: <fluent-bit-role-arn>

inputs:
  tail:
    path: /var/log/containers/*.log
    tag: kube.*

filters:
  kubernetes:
    enabled: true
  # ⚠️ WARNING: The grep filter below drops INFO logs.
  # Either remove it entirely or add a second output for errors-only.
  # grep:
  #   regex: log (?i)\b(stderr|error|warn|warning|exception|stacktrace)\b

outputs:
  - name: cloudwatch_logs
    match: "kube.*"
    region: eu-west-1
    log_group_name: /eks/camunda-ds-eks-cluster-<env>/fluent-bit-camunda-logs
    log_stream_prefix: camunda
    auto_create_group: true
```

> ⚠️ **Important:** The default grep filter drops INFO-level logs, meaning you'll only see errors in CloudWatch. Remove or relax this filter to get full log visibility for Camunda components.

### Install

```bash
helm repo add aws-for-fluent-bit https://aws.github.io/eks-charts
helm repo update

helm install fluent-bit aws-for-fluent-bit/aws-for-fluent-bit \
  --namespace camunda \
  --set cloudWatch.enabled=true \
  -f fluent-bit.yaml
```

### ✅ Verification Checklist

```bash
kubectl get pods -n camunda -l app.kubernetes.io/name=fluent-bit
# All pods should be Running
```

In **CloudWatch → Log groups**, confirm:

- [ ] Log group `/eks/camunda-ds-eks-cluster-<env>/fluent-bit-camunda-logs` exists and is receiving logs
- [ ] Logs from Zeebe, Operate, Identity, and Connectors are present
- [ ] No Fluent Bit authentication or throttling errors
- [ ] INFO-level logs are present (not just errors) — if missing, check grep filter

---

## 📈 Install & Verify ADOT Collector (Camunda Metrics)

### Option A — ADOT Operator (Recommended)

1. In the AWS Console: **EKS → Cluster → Add-ons → Get more add-ons → AWS Distro for OpenTelemetry**
2. Select the ADOT IRSA role
3. Verify the operator is running:

```bash
kubectl get pods -n otel-collector
# opentelemetry-operator pod should be Running
```

4. Apply the `OpenTelemetryCollector` CR in daemonset mode:

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: adot-collector
  namespace: otel-collector
spec:
  mode: daemonset
  serviceAccount: adot-collector
  config: |
    receivers:
      prometheus:
        config:
          scrape_configs:
            - job_name: camunda-operate
              scrape_interval: 10s
              static_configs:
                - targets:
                    - camunda-operate.camunda.svc.cluster.local:9600
              metrics_path: /operate/actuator/prometheus

            - job_name: camunda-zeebe
              scrape_interval: 10s
              static_configs:
                - targets:
                    - camunda-zeebe.camunda.svc.cluster.local:9600
              metrics_path: /actuator/prometheus

            - job_name: camunda-identity
              scrape_interval: 10s
              static_configs:
                - targets:
                    - camunda-identity.camunda.svc.cluster.local:82
              metrics_path: /actuator/prometheus

            - job_name: camunda-connectors
              scrape_interval: 10s
              static_configs:
                - targets:
                    - camunda-connectors.camunda.svc.cluster.local:8080
              metrics_path: /actuator/prometheus

    exporters:
      awsemf/prometheus:
        namespace: CamundaPrometheus-<env>
        log_group_name: /aws/eks/camunda-<env>/prometheus
        region: eu-west-1

    service:
      pipelines:
        metrics:
          receivers: [prometheus]
          exporters: [awsemf/prometheus]
```

### ✅ Verification Checklist

```bash
kubectl get pods -n otel-collector
# adot-collector-* and controller pods should be Running
```

In **CloudWatch → Metrics → `CamundaPrometheus-<env>`**, confirm the following metrics are visible:

- [ ] `zeebe_health`
- [ ] `zeebe_dropped_request_count_total`
- [ ] `zeebe_stream_processor_records_total`
- [ ] `zeebe_exporter_events_total`
- [ ] `operate_import_queue_size`
- [ ] `operate_import_processing_duration_seconds`
- [ ] Archiver latency metrics

---

## ✅ Post-Deployment Operational Checklist

Run after any change to monitoring or logging configuration:

- [ ] **Cluster health** — Container Insights shows sane CPU, memory, disk, network; no sustained >90% usage
- [ ] **Camunda pods** — All pods in `camunda` namespace are `Running` with correct readiness
- [ ] **Logs** — CloudWatch log group contains recent entries from Zeebe, Operate, Identity, Connectors; no Fluent Bit auth or throttling errors
- [ ] **Metrics** — `zeebe_health` healthy for all partitions; `zeebe_dropped_request_count_total` near zero and not trending up; `zeebe_stream_processor_records_total` and `zeebe_exporter_events_total` increasing under load; Operate import queues stable
- [ ] **Dashboard** — `camunda-<env>-monitoring-dashboard` loads and all widgets show data

---

## 🔔 Recommended CloudWatch Alarms

Use these as starting points. Refine thresholds after performance testing.

### Zeebe Health & Backpressure

| # | Alarm | Metric | Condition | Action |
|---|---|---|---|---|
| 1 | Zeebe partition unhealthy | `zeebe_health` per partition | Average < 1 for 2/3 periods of 1 min | Page platform on-call |
| 2 | Zeebe backpressure dropping requests | Rate of `zeebe_dropped_request_count_total` | Rate > 0 for 5 min | Warn team; investigate CPU/memory, exporters, client load |
| 3 | Zeebe processing stalled | `zeebe_stream_processor_records_total` per partition | Sum == 0 over 5 min during expected traffic | Page if during business hours; check logs |

### Operate Import & Archiver

| # | Alarm | Metric | Condition | Action |
|---|---|---|---|---|
| 4 | Operate import queue building up | `operate_import_queue_size` (sum) | Sum > N for 10 min | Check Zeebe exporter, Operate importer logs, storage |
| 5 | Operate import latency high | `operate_import_processing_duration_seconds` | Average > X seconds for 5 min | Investigate Elasticsearch performance, CPU, index size |
| 6 | Operate archiver lagging | Rate of `operate_archived_process_instances_total` vs `operate_events_processed_finished_process_instances_total` | Archiving rate < Y% of finished processes over 60 min | Check `operate_archiver_*_query_seconds` |

### Infrastructure Saturation

| # | Alarm | Metric | Condition | Action |
|---|---|---|---|---|
| 7 | Cluster CPU saturation | ContainerInsights CPU Utilization | Average > 80% for 15 min | Scale nodes or investigate runaway pods |
| 8 | Cluster memory saturation | ContainerInsights Memory Utilization | Average > 80% for 15 min | Scale nodes or investigate memory leaks |
| 9 | Node filesystem high | `node_filesystem_utilization` p90 | p90 > 85% for 15 min | Expand PVCs or clean up data |
| 10 | Node failures | `cluster_failed_node_count` | > 0 | Investigate node health immediately |

### Logging Pipeline

| # | Alarm | Metric | Condition | Action |
|---|---|---|---|---|
| 11 | Fluent Bit error rate | Metric filter on Fluent Bit log group for `ERROR`/throttling | Count above baseline for 5 min | Check IRSA permissions and CloudWatch quotas |
| 12 | Log ingestion stalled | Metric filter counting log events from Zeebe/Operate pods | Count == 0 for 10 min while pods are running | Check Fluent Bit DaemonSet and log group config |

---

## 🔧 Troubleshooting

| Symptom | Likely Cause | Resolution |
|---|---|---|
| No metrics in CloudWatch | ADOT pods not reaching Camunda DNS | Check `kubectl logs -n otel-collector` for connection errors; verify service DNS names and ports |
| ADOT auth failure | IRSA misconfigured | Confirm `cloudwatch:PutMetricData` permission and trust policy includes ADOT service account |
| No Camunda logs in CloudWatch | Fluent Bit not scheduled on all nodes | Check DaemonSet: `kubectl get ds -n camunda`; confirm log group name and region match |
| Only error logs visible | Aggressive grep filter | Remove or relax the grep filter in `fluent-bit.yaml` |
| Metrics present but no dashboard data | Wrong CloudWatch namespace | Confirm `namespace: CamundaPrometheus-<env>` in ADOT CR matches dashboard metric source |
| Fluent Bit throttling | CloudWatch PutLogEvents rate limit | Reduce log volume with sampling or increase throughput limits |
