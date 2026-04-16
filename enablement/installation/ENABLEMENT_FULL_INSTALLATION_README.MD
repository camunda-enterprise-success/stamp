# Full Camunda Installation with Monitoring and Backup

This guide walks through deploying a full Camunda 8 stack including Prometheus/Grafana monitoring, OIDC-based permissions, and S3-backed backup/restore. It is designed to be run in a local Kubernetes cluster (e.g. kind) and gives you hands-on experience with platform capabilities TAM needs to be able to set up or troubleshoot in a customer environment.

## Architecture Overview

The deployment is built from **layered Helm values files**. Each file adds one concern on top of the previous:

| Values file | What it adds |
|------------|-------------|
| `minimal_setup.yaml` | Base orchestration config — single node, basic auth, minimal resources |
| `with_permissions.yaml` | OIDC integration with external Keycloak; roles, mapping rules, authorizations |
| `with_monitoring_alerting.yaml` | Enables Prometheus metrics scraping on Zeebe |
| `values_with_backup_restore.yml` | S3 backup config for Zeebe runtime and Elasticsearch history |

This layering means you can swap out individual concerns (e.g. replace `with_permissions.yaml` with a different auth setup) without touching the others.

## Prerequisites

Tools required locally:

- `helm` — package manager for Kubernetes
- `kubectl` (aliased as `k`) — Kubernetes CLI
- `kubens` — namespace switcher (from the `kubectx` package)
- `curl` and `jq` — used by the utility scripts to fetch tokens and call APIs

A running Kubernetes cluster. Locally, create one via:

```bash
make cluster.create   # from local/kubernetes/kind-single-region/
```

## S3 Bucket Setup

Set up the following bucket structure in your object storage before deploying:

```
s3://your-backup-bucket/
├── web-apps-indices/        ← Elasticsearch history snapshots (Operate, Tasklist data)
└── oc-runtime/              ← Zeebe runtime backups (in-flight process instances)
```

These two paths are kept separate because they use different backup mechanisms:
- **`oc-runtime`**: Zeebe's native backup API, which pauses exporting and snapshots the Raft log.
- **`web-apps-indices`**: Elasticsearch snapshot API, which captures the index state used by Operate, Tasklist, and Optimize.

> After creating your bucket, update all references to the bucket name and paths in the values and job YAML files. A find/replace on the example bucket name is the quickest approach.

---

# Installation

*(Run all commands from the `installation/` directory)*

## 01 Install Prometheus/Grafana

Monitoring is installed first so that Prometheus is ready to scrape metrics as soon as Camunda starts. The `kube-prometheus-stack` chart installs Prometheus, Grafana, AlertManager, and the Prometheus Operator (which manages `ServiceMonitor` resources) in a single release.

**Before running:** create `monitoring_alerting/grafana-secret.yaml.secret` by copying `grafana-secret.yaml.template` and filling in your admin credentials. Gmail credentials are only needed if you want alert emails.

```bash
# Load the Grafana alert rules into a ConfigMap so Grafana can provision them on startup
kubectl create configmap grafana-alerts \
  --from-file=monitoring_alerting/camunda-alerts-grafana-managed.yaml \
  -n default

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add stable https://charts.helm.sh/stable
helm repo update prometheus-community stable

# Apply the secret containing Grafana admin credentials
kubectl apply -f ./monitoring_alerting/grafana-secret.yaml.secret -n default

# Install the full monitoring stack
helm install metrics prometheus-community/kube-prometheus-stack \
  --wait --atomic \
  -f ./monitoring_alerting/prometheus-operator-values.yaml \
  --set prometheusOperator.tlsProxy.enabled=false \
  --namespace default
```

`--wait --atomic` ensures the command blocks until all pods are running. If any pod fails, Helm rolls back automatically.

## 02 Prepare Secrets

Camunda needs two sets of credentials stored as Kubernetes Secrets before the Helm install can succeed:

- **Keycloak OIDC client secrets** (`permissions/create-secrets.sh`): The OIDC clients (Identity, Operate, Tasklist, etc.) authenticate to Keycloak using client credentials. These secrets must match what is configured in Keycloak. Those are checked-in to git.
- **S3 credentials** (`backup_restore/create-secrets.sh`): Used by Zeebe and Elasticsearch to write backups to S3.

**Before running:** create `backup_restore/secrets.env.secret` from the template and fill in your S3 access key and secret key.

```bash
kubectl create ns camunda
kubens camunda
cd permissions && ./create-secrets.sh && cd ..
cd backup_restore && ./create-secrets.sh && cd ..
```

> TODO: Replace the consulting Keycloak with a locally deployed or commonly accessible instance so this works independently of the sandbox environment.

## 03 Install Camunda

The four `-f` flags compose the full configuration. Helm merges them in order — later files override earlier ones for any overlapping keys.

```bash
helm upgrade --install \
  --create-namespace \
  camunda camunda-platform \
  --repo https://helm.camunda.io \
  --version 13.5.0 \
  --namespace camunda \
  -f ./minimal_setup.yaml \
  -f ./with_permissions.yaml \
  -f ./with_monitoring_alerting.yaml \
  -f ./values_with_backup_restore.yml
```

Wait for all pods to be `Running`:

```bash
kubectl get pods -n camunda -w
```

## 04 Create some data

Deploy a test BPMN process and create process instances. This gives you data that you can verify survives a backup and restore.

```bash
export AUTH_TOKEN=$(../utils/get-token.sh)
../utils/deploy-bpmn.sh
../utils/create-process-instances.sh
```

`get-token.sh` fetches a bearer token from Keycloak using the benchmark client credentials. The token is passed to the subsequent scripts via `AUTH_TOKEN`.

> TODO: Replace these scripts with `c8ctl` once it is available.

## 05 Register Snapshot Repositories

Before Elasticsearch can take snapshots, it needs to know where to store them. This job calls the Elasticsearch snapshot repository registration API to create a named repository pointing at the S3 bucket.

```bash
kubectl apply -f ./backup_restore/register-snapshot-job.yaml
```

Check the job completed successfully:

```bash
kubectl logs -n camunda -l job-name=register-snapshot -f
```

## 06 Create Backup ConfigMap

The backup jobs read the desired backup ID from a shared ConfigMap rather than having it hardcoded. This allows you to increment the ID for each backup without editing the job YAML.

```bash
kubectl create configmap camunda-backup-config \
  -n camunda \
  --from-literal=BACKUP_ID=1
```

> TODO: Consider switching to a local MinIO instance instead of AWS S3 to remove the cloud dependency.

## 07 Execute Backup

The backup job performs a **coordinated backup** of both Zeebe and Elasticsearch in sequence:

1. Calls the Zeebe Gateway management API to **pause exporting** (`soft=true`). This stops Zeebe from writing new records to Elasticsearch while allowing in-flight processing to continue.
2. Waits for the Zeebe backup to complete (polls up to 20 minutes).
3. Triggers an Elasticsearch snapshot of the web-apps indices.
4. **Resumes exporting** once both are complete.

This coordination ensures the Zeebe runtime backup and the Elasticsearch history snapshot are consistent with each other — critical for a correct restore.

```bash
kubectl apply -f ./backup_restore/take-backup-job.yaml
```

Monitor progress:

```bash
kubectl logs -n camunda -l job-name=take-backup -f
```

---

# Restore

The restore procedure recreates the system from the S3 backups.

## 01 Delete Cluster and PVCs

Deleting the namespace removes all pods and their PersistentVolumeClaims, wiping local Zeebe data. This is intentional — Zeebe will restore from the S3 backup in a later step.

```bash
kubectl delete ns camunda
```

## 02 Re-create Namespace, ConfigMap, and Secrets

Re-create everything that must exist before Helm can install:

```bash
kubectl create ns camunda
kubens camunda
kubectl create configmap camunda-backup-config -n camunda --from-literal=BACKUP_ID=1
sleep 5
cd permissions && ./create-secrets.sh && cd ..
cd backup_restore && ./create-secrets.sh && cd ..
```

Then re-deploy Camunda in its normal configuration (not restore mode yet). Elasticsearch needs to be running before we can restore indices into it.
Mandatory to get index templates created.

```bash
helm upgrade --install \
  --create-namespace \
  camunda camunda-platform \
  --repo https://helm.camunda.io \
  --version 13.5.0 \
  --namespace camunda \
  -f ./minimal_setup.yaml \
  -f ./with_permissions.yaml \
  -f ./with_monitoring_alerting.yaml \
  -f ./values_with_backup_restore.yml
```

## 03 Re-register Snapshot Repositories

Elasticsearch's snapshot repository registration is stored in cluster metadata, which was lost when the namespace was deleted. Re-register it:

```bash
kubectl apply -f ./backup_restore/register-snapshot-job.yaml
```

## 04 Scale Down Zeebe

Before restoring Elasticsearch indices, Zeebe must be stopped. If Zeebe keeps running while indices are being replaced, it will continue writing new records and conflict with the restore operation.

```bash
kubectl scale statefulset camunda-zeebe --replicas=0
```

Wait until all Zeebe pods are gone:

```bash
kubectl get pods -n camunda -l app.kubernetes.io/component=zeebe-broker -w
```

## 05 Delete Existing Indices

The current Elasticsearch indices (created by the fresh deploy) must be removed before restoring from the snapshot. Restoring into a non-empty index is not supported.

```bash
kubectl apply -f ./backup_restore/delete-camunda-indices-job.yaml
```

> Use `delete-camunda-indices-dryrun-job.yaml` first to preview which indices will be deleted without actually removing them.

## 06 Restore Elasticsearch Snapshots

This job reads `BACKUP_ID` from the ConfigMap, finds the corresponding snapshot in the registered repository, and restores it into Elasticsearch. It handles both the orchestration (Zeebe) and web-apps (Operate/Tasklist) index repositories.

```bash
kubectl apply -f ./backup_restore/es-snapshot-restore-job.yaml
```

Monitor until complete:

```bash
kubectl logs -n camunda -l job-name=es-snapshot-restore -f
```

## 07 Restore Zeebe Runtime

Delete Zeebe's local PVC (which is empty since Zeebe was scaled down before any data was written) and then redeploy with restore mode enabled. The `values_to_restore_oc.yml` overlay sets `ZEEBE_RESTORE=true` and `SPRING_PROFILES_INCLUDE=backup`, which tells Zeebe to read its initial state from the S3 backup rather than starting fresh.

```bash
kubectl delete pvc data-camunda-zeebe-0
```

```bash
helm upgrade --install \
  --create-namespace \
  camunda camunda-platform \
  --repo https://helm.camunda.io \
  --version 13.5.0 \
  --namespace camunda \
  -f ./backup_restore/values_to_restore_oc.yml
```

## Return to Normal Operation

Once Zeebe has completed its restore (check logs for `Restore completed`), redeploy with the standard values to disable restore mode and resume normal operation:

```bash
helm upgrade --install \
  --create-namespace \
  camunda camunda-platform \
  --repo https://helm.camunda.io \
  --version 13.5.0 \
  --namespace camunda \
  -f ./minimal_setup.yaml \
  -f ./with_permissions.yaml \
  -f ./with_monitoring_alerting.yaml \
  -f ./values_with_backup_restore.yml
```

Verify in Operate that the process instances from before the backup are visible and that no data was lost.



> TODO: Add `benchmarking` example