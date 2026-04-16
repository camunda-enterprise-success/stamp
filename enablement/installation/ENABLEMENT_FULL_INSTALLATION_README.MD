# Prerequisites

## (Local) Kubernetes Cluster
Can be created e.g. via `make cluster.create` in local/kubernetes/kind-single-region

## S3 Buckets
Set up the following bucket structure in your object storage:
```
s3://your-backup-bucket/
├── web-apps-indices/        ← Web Apps History snapshots (backupHistory)
└── oc-runtime/              ← Zeebe runtime backups (backupRuntime)
```

!!! Important: Updates on the Buckets have to be also applied in the subsequent files. Can initially be done via find/replace. In a second version, real placeholders should be used. 

# Full Installation including Backup

## 01 Install Prometheus/Grafana
```bash
kubectl create configmap grafana-alerts --from-file=monitoring_alerting/camunda-alerts-grafana-managed.yaml -n default 
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add stable https://charts.helm.sh/stable
helm repo update prometheus-community stable
kubectl apply -f ./monitoring_alerting/grafana-secret.yaml.secret -n default
helm install metrics prometheus-community/kube-prometheus-stack \
  --wait --atomic \
  -f ./monitoring_alerting/prometheus-operator-values.yaml \
  --set prometheusOperator.tlsProxy.enabled=false \
  --namespace default
```

### 02 Prepare Secrets
```bash
k create ns camunda
kubens camunda &&
cd permissions && ./create-secrets.sh && cd .. &&
cd backup_restore && ./create-secrets.sh && cd ..
```

## 03 Install Camunda
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

## 04 Create some data
```bash
export AUTH_TOKEN=$(../utils/get-token.sh)
../utils/deploy-bpmn.sh
../utils/create-process-instances.sh
```

## 05 Register Snapshot Repositories
```bash
k apply -f ./backup_restore/register-snapshot-job.yaml
```

## 06 Create Backup ConfigMap
Update with your backup ID:
```bash
kubectl create configmap camunda-backup-config -n camunda --from-literal=BACKUP_ID=1
```

## 07 Execute Backup
```bash
k apply -f ./backup_restore/take-backup-job.yaml
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
sleep 5
cd permissions && ./create-secrets.sh && cd .. &&
cd backup_restore && ./create-secrets.sh && cd ..
```

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

## 03 Re-register Repositories
```bash
k apply -f ./backup_restore/register-snapshot-job.yaml
```

## 04 Scale Down Components
```bash
k scale statefulset camunda-zeebe --replicas=0
```

## 05 Delete Indices
```bash
k apply -f ./backup_restore/delete-camunda-indices-job.yaml
```

## 06 Restore Snapshots
Uses backup ID from ConfigMap:
```bash
k apply -f ./backup_restore/es-snapshot-restore-job.yaml
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
  -f ./backup_restore/values_to_restore_oc.yml
```

#### Return to Normal Operation
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
