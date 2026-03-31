# Runbook: Observability — Prometheus + Grafana for Camunda

**Related config:** [`../configs/observability-prometheus-grafana/values.yaml`](../configs/observability-prometheus-grafana/values.yaml)

## Overview

This runbook covers deploying the `kube-prometheus-stack` Helm chart using the STAMP values file, which scrapes ServiceMonitors, PodMonitors, and Probes across all namespaces. It then covers wiring up Camunda-specific ServiceMonitors and importing dashboards into Grafana.

Alertmanager is **not included** in this setup.

---

## Prerequisites

- Kubernetes cluster 
- `helm` and `kubectl` configured
- Sufficient cluster resources — Prometheus is memory-intensive; the STAMP config sets low requests, but for a production environment this will have to be increased.
- Persistent storage available in the cluster 

---

## 1. Review the Values File

Before deploying, open [`../configs/observability-prometheus-grafana/values.yaml`](../configs/observability-prometheus-grafana/values.yaml) and set:

| Field | Location | Notes                                                                                                                       |
|---|---|-----------------------------------------------------------------------------------------------------------------------------|
| `storageClassName` | `prometheus.prometheusSpec.storageSpec` | Match your cluster's storage class (e.g. `gp3`, `standard`, `managed-premium`). Omit this to rely on your clusters default. |
| `grafana.adminPassword` | `grafana.adminPassword` | Change from `changeme` or use `adminPasswordSecret`                                                                         |
| `grafana.ingress` | `grafana.ingress` | Enable and set host if exposing Grafana externally                                                                          |
| `retention` / `retentionSize` | `prometheus.prometheusSpec` | Default is 30d / 40GB — adjust to storage budget                                                                            |

---

## 2. Install kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  -f generic/configs/observability-prometheus-grafana/values.yaml \
  --wait
```

Verify all pods are running:

```bash
kubectl get pods -n monitoring
```

You should see pods for: `prometheus-server`, `grafana`, `kube-state-metrics`, and `node-exporter` (one per node).

---

## 3. Enable Metrics and Deploy ServiceMonitors in Camunda

Add the following to your Camunda `values.yaml` . This deploys ServiceMonitor resources for all Camunda components.

```yaml
  prometheusServiceMonitor:
    enabled: true
```

Verify ServiceMonitors were created
```bash
kubectl get servicemonitor -n camunda
```

The STAMP values file sets `serviceMonitorSelectorNilUsesHelmValues: false` and `serviceMonitorNamespaceSelector: any: true`, so Prometheus will pick these up automatically without requiring any specific labels, and you can deploy in any namespace.

---

## 4. Verify Prometheus is Scraping Camunda

```bash
# Port-forward to Prometheus UI
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring
```

Open `http://localhost:9090` and navigate to **Status → Targets**. You should see the Camunda endpoints listed and `UP`.

If targets are missing, check **Status → Service Discovery** to see whether Prometheus found the ServiceMonitors.

---

## 5. Access Grafana

```bash
# Port-forward to Grafana
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring
```

Open `http://localhost:3000` and log in with `admin` and the password set in the values file.

If you used the default `changeme` or want to retrieve it from the secret:

```bash
kubectl get secret prometheus-grafana \
  --namespace monitoring \
  -o jsonpath="{.data.admin-password}" | base64 --decode
```

---

## 6. Import Camunda Dashboards

The STAMP values file enables the Grafana dashboard sidecar with `searchNamespace: ALL`. Any ConfigMap with the label `grafana_dashboard: "1"` in any namespace is automatically loaded into Grafana within ~30 seconds.

**Option A: ConfigMap (GitOps-friendly)**

```bash
# Download dashboard JSON from Camunda docs or grafana.com
# then create a ConfigMap from it
kubectl create configmap camunda-zeebe-dashboard \
  --from-file=zeebe-dashboard.json \
  --namespace camunda

kubectl label configmap camunda-zeebe-dashboard \
  grafana_dashboard=1 \
  --namespace camunda
```

**Option B: Grafana UI**

Navigate to **Dashboards → Import** and paste the JSON or enter a Grafana.com dashboard ID. Search [grafana.com/grafana/dashboards](https://grafana.com/grafana/dashboards) for "Camunda" to find community dashboards.

---

## 7. Key Camunda Metrics

---

## 8. Troubleshooting

---