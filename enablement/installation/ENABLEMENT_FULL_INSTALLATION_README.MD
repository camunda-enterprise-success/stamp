# Prerequisites

## S3 Buckets
Set up the following bucket structure in your object storage:
```
s3://your-backup-bucket/
├── web-apps-indices/        ← Web Apps History snapshots (backupHistory)
└── oc-runtime/              ← Zeebe runtime backups (backupRuntime)
```

# Backup

## 01 Install Prometheus/Grafana
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add stable https://charts.helm.sh/stable
helm repo update prometheus-community stable
kubectl apply -f ./04_monitoring_alerting/grafana-secret.yaml.secret -n default
helm install metrics prometheus-community/kube-prometheus-stack \
  --wait --atomic \
  -f ./04_monitoring_alerting/prometheus-operator-values.yaml \
  --set prometheusOperator.tlsProxy.enabled=false \
  --namespace default
```

### 02 Prepare Secrets
```bash
cd 03_permissions && ./create-secrets.sh && cd ..
```

```bash
cd 08_backup_restore && ./create-secrets.sh && cd ..
```

## 03 Install Camunda
```bash
helm upgrade --install \
--create-namespace \
camunda camunda-platform \
--repo https://helm.camunda.io \
--version 13.5.0 \
--namespace camunda \
-f ./01_minimal_setup.yaml \
-f ./03_with_permissions.yaml \
-f ./04_with_monitoring_alerting.yaml \
-f ./08_values_with_backup_restore.yml
```

## 04 Create some data
```bash
export AUTH_TOKEN=$(../utils/get-token.sh)
../utils/deploy-bpmn.sh
../utils/create-process-instances.sh
```

## 05 Register Snapshot Repositories
```bash
k apply -f ./08_backup_restore/register-snapshot-job.yaml
```

## 06 Create Backup ConfigMap
Update with your backup ID:
```bash
kubectl create configmap camunda-backup-config -n camunda --from-literal=BACKUP_ID=1
```

## 07 Execute Backup
```bash
k apply -f ./08_backup_restore/take-backup-job.yaml
```


# Restore

## 01 Delete Cluster and PVCs
```bash
k delete ns camunda
```

## 02 Re-create Cluster & Configmap & secrets
```bash
k create ns camunda
kubens camunda
kubectl create configmap camunda-backup-config -n camunda --from-literal=BACKUP_ID=1
sleep 5:pod:
cd 03_permissions && ./create-secrets.sh && cd ..
sleep 5
cd 08_backup_restore && ./create-secrets.sh && cd ..
```

```bash
helm upgrade --install \
  --create-namespace \
  camunda camunda-platform \
  --repo https://helm.camunda.io \
  --version 13.5.0 \
  --namespace camunda \
  -f ./01_minimal_setup.yaml \
  -f ./03_with_permissions.yaml \
  -f ./04_with_monitoring_alerting.yaml \
  -f ./08_values_with_backup_restore.yml
```

## 03 Re-register Repositories
```bash
k apply -f ./08_backup_restore/register-snapshot-job.yaml
```

## 04 Scale Down Components
```bash
k scale statefulset camunda-zeebe --replicas=0
```

## 05 Delete Indices
```bash
k apply -f ./08_backup_restore/delete-camunda-indices-job.yaml
```

## 06 Restore Snapshots
Uses backup ID from ConfigMap:
```bash
k apply -f ./08_backup_restore/es-snadpshot-restore-job.yaml
```

## 07 Restore Zeebe
```bash
k delete pvc data-camunda-zeebe-0
```

```bash
helm upgrade --install \
  --create-namespace \
  camunda camunda-platform \
  --repo https://helm.camunda.io \
  --version 13.5.0 \
  --namespace camunda \
  -f ./08_backup_restore/08_values_to_restore_oc.yml
```

#### Return to Normal Operation
```bash
helm upgrade --install \
  --create-namespace \
  camunda camunda-platform \
  --repo https://helm.camunda.io \
  --version 13.5.0 \
  --namespace camunda \
  -f ./01_minimal_setup.yaml \
  -f ./03_with_permissions.yaml \
  -f ./04_with_monitoring_alerting.yaml \
  -f ./08_values_with_backup_restore.yml
```
