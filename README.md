# STAMP — Structured Technical Account Manager Platform Setup

STAMP is an opinionated, modular Helm values library for deploying and configuring **Camunda 8.8** in customer environments. It is designed to let TAMs quickly layer scenario-specific configurations on top of a tested baseline, rather than building values files from scratch each time.

> **Companion library:** STAMP is intended to be used alongside the official [camunda-deployment-references](https://github.com/camunda/camunda-deployment-references) repository. That repo provides reference architectures and IaC; STAMP provides TAM-focused overlays, runbooks, and scenario configs that layer on top of those foundations.

---

## Repository Structure

```
stamp/
├── README.md
│
├── base-values/                          # Starting point for every deployment
│   ├── values-orchestration-cluster.yaml       # Core 1-node Camunda 8.8 values (basic auth)
│   ├── values-local-tls.yaml                   # mkcert CA trust overlay (local HTTPS)
│   ├── camunda-credentials.yaml                # Credential references
│   ├── !!!-operators/                          # 🚧 Operator configs
│   └── !!!-management-cluster/                 # 🚧 Management cluster config
│
├── auth/                                 # Authentication overlays (layer on top of base)
│   ├── !!!-entra/                        # 🚧 Microsoft Entra ID / OIDC
│   ├── !!!-keycloak/                     # 🚧 Keycloak OIDC
│   └── !!!-irsa/                         # 🚧 AWS IRSA
│
├── backups/                              # Backup destination overlays
│   ├── s3/
│   │   ├── s3-backup-values.yaml         # S3 backup Helm values
│   │   └── s3-backup-runbook.md          # S3 backup runbook
│   ├── azure-blob/
│   │   ├── azure-blob-backup-values.yaml # 🚧 
│   │   └── azure-blob-backup-runbook.md  # 🚧 
│   └── gcs/
│       ├── gcs-backup-values.yaml       # 🚧
│       └── gcs-backup-runbook.md        # 🚧
│
└── observability/                        # Observability stack overlays
    ├── prometheus-grafana/
    │   ├── prometheus-grafana-values.yaml  # kube-prometheus-stack values
    │   └── prometheus-grafana-runbook.md   # Setup and wiring guide
    ├── !!!-dynatrace/                      # 🚧 Dynatrace integration
    └── cloudwatch/                         # CloudWatch integration
```

> Directories prefixed with `!!!-` are reserved placeholders for future scenarios. They are intentionally empty.

---

## Quickstart

### 1. Install the Camunda baseline

```bash
helm repo add camunda https://helm.camunda.io && helm repo update

helm upgrade --install camunda camunda/camunda-platform \
  --version 13.7.0 \
  --namespace camunda --create-namespace \
  -f base-values/values-orchestration-cluster.yaml
```

Default login: `demo` / `demo`

### 2. Layer on scenario configs

Additional overlays are passed with `-f` flags in order, each overriding or extending the previous:

```bash
# Local HTTPS with mkcert CA trust
helm upgrade --install camunda camunda/camunda-platform \
  --version 13.7.0 \
  --namespace camunda --create-namespace \
  -f base-values/values-orchestration-cluster.yaml \
  -f base-values/values-local-tls.yaml

# S3 backups
helm upgrade --install camunda camunda/camunda-platform \
  --version 8.8 \
  --namespace camunda --create-namespace \
  -f base-values/values-orchestration-cluster.yaml \
  -f base-values/values-local-tls.yaml \
  -f backups/s3/s3-backup-values.yaml
```

---

## Base Values

### `base-values/values-orchestration-cluster.yaml`

The core starting point for a TAM-assisted deployment. Key characteristics:

- **Auth:** Basic auth (`demo`/`demo`) — suitable for POC/demo environments
- **Cluster size:** 1 node, 1 partition, replication factor 1
- **Elasticsearch:** Deployed via subchart with 1 master + 1 data node (15Gi each)
- **Ingress:** nginx, host `camunda.example.com` with TLS
- **Disabled by default:** Console, WebModeler, Optimize, Identity, Keycloak, PostgreSQL

Update `global.ingress.host` and the orchestration `ingress.grpc.host` before deploying to a real cluster.

### `base-values/values-local-tls.yaml`

Overlay for local development environments using a [mkcert](https://github.com/FiloSottile/mkcert)-generated CA. Configures all Camunda components to trust the local CA certificate via a `mkcert-ca` ConfigMap:

| Component type | Trust mechanism |
|---|---|
| Java (WebModeler restapi, Connectors, Identity, Optimize, Orchestration/Zeebe) | `initContainer` copies JVM cacerts, imports CA via `keytool`, sets `JAVA_TOOL_OPTIONS` |
| Node.js (WebModeler webapp, websockets, Console) | `NODE_EXTRA_CA_CERTS` env var |

**Prerequisite:** Ensure the ConfigMap is created by the [camunda-deployment-references](https://github.com/camunda/camunda-deployment-references) repository before installing:
```bash
./procedure/certs-create-ca-configmap.sh
```

---

## Observability

### Prometheus + Grafana (`observability/prometheus-grafana/`)

Deploys [`kube-prometheus-stack`](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) with cross-namespace ServiceMonitor, PodMonitor, and Probe discovery pre-configured.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f observability/prometheus-grafana/prometheus-grafana-values.yaml
```

Key settings to review before deploying:

| Setting | Location | Default |
|---|---|---|
| `storageClassName` | `prometheus.prometheusSpec.storageSpec` | commented out (uses cluster default) |
| `grafana.adminPassword` | top-level | `changeme` |
| `retention` / `retentionSize` | `prometheus.prometheusSpec` | 30d / 40GB |
| Grafana ingress | `grafana.ingress` | disabled |

Once deployed, enable Camunda ServiceMonitors by adding to your Camunda values:
```yaml
prometheusServiceMonitor:
  enabled: true
```

See [`prometheus-grafana-runbook.md`](observability/prometheus-grafana/prometheus-grafana-runbook.md) for the full setup walkthrough including Grafana dashboard import.

**Not included:** Alertmanager (disabled by default — enable when the customer is ready for alerting).

---

## Backups

STAMP provides per-destination overlays with paired values + runbook files. Each backup destination is self-contained:

| Destination | Values file | Runbook |
|---|---|---|
| AWS S3 | `backups/s3/s3-backup-values.yaml` | `backups/s3/s3-backup-runbook.md` |
| Azure Blob Storage | `backups/azure-blob/azure-blob-backup-values.yaml` | `backups/azure-blob/azure-blob-backup-runbook.md` |
| Google Cloud Storage | `backups/gcs/gcs-backup-values.yaml` | `backups/gcs/gcs-backup-runbook.md` |

---

## Authentication

Auth overlays are in progress. Planned providers:

| Provider | Directory |
|---|---|
| Microsoft Entra ID (OIDC) | `auth/!!!-entra/` |
| Keycloak (OIDC) | `auth/!!!-keycloak/` |
| AWS IRSA | `auth/!!!-irsa/` |

---

## Notes

- STAMP values files are **overlays**, not standalone configs. Always deploy starting from a base values file.
- Resource requests in STAMP are intentionally minimal for demo/POC use. Scale up for production.
- The `!!!-` prefix on a directory means it is a planned placeholder — not yet populated.
- Elasticsearch sizing in the baseline is minimal (1g heap, ~1.5Gi memory request). Increase for any sustained load.
