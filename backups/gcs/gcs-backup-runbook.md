# GCS Backup Setup Runbook — Camunda 8.8 (Single Cluster, Google Cloud Storage)

## Overview

This runbook covers how to configure Google Cloud Storage (GCS) as the backup store for a Camunda 8.8 single-cluster deployment managed via Helm. It covers both the Zeebe partition backup store and the Elasticsearch snapshot repository used by the web applications (Operate, Tasklist) and Optimize.

> **Note:** Camunda 8.8 introduced breaking changes to the Operate and Tasklist backup flow. Ensure you are using the 8.8-compatible backup procedure if migrating from an earlier version.

---

## Prerequisites

- A running Camunda 8.8 single-cluster Helm deployment
- `kubectl` and `helm` CLI access to the cluster
- A GCS bucket for backups (or two separate buckets — see note below)
- A GCP service account with read/write access to the GCS bucket(s)
- The `repository-gcs` plugin installed on Elasticsearch (included in Elastic's official Docker image by default)

> **Tip:** You can use a single GCS bucket for both Zeebe and Elasticsearch backups, as long as you configure different `basePath` / `base_path` values for each.

---

## Step 1: Create the GCS Bucket

Create your GCS bucket in your target GCP region. Example:

```bash
gcloud storage buckets create gs://camunda-backups \
  --location=europe-west1 \
```

---

## Step 2: Create a Service Account and Key

Create a GCP service account with the minimum required permissions:

```bash
# Create the service account
gcloud iam service-accounts create camunda-backup-sa \
  --display-name="Camunda Backup Service Account"

# Grant Storage Object Admin on the bucket
gcloud storage buckets add-iam-policy-binding gs://camunda-backups \
  --member="serviceAccount:camunda-backup-sa@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"

# Generate and download a JSON key file
gcloud iam service-accounts keys create camunda-backup-sa-key.json \
  --iam-account=camunda-backup-sa@YOUR_PROJECT_ID.iam.gserviceaccount.com
```

Store the key file securely — you will need it in the next step.

> **Production recommendation:** Prefer Workload Identity over static JSON key files where possible, to avoid managing long-lived credentials.

---

## Step 3: Store GCS Credentials as a Kubernetes Secret

```bash
kubectl create secret generic camunda-gcs-backup-credentials \
  --from-file=service-account-key.json=camunda-backup-sa-key.json \
  --namespace camunda
```

---

## Step 4: Configure Zeebe GCS Backup Store

Add the following to your `values.yaml` under the `orchestration` section. In Camunda 8.8, backup config is passed via `orchestration.configuration`:

```yaml
orchestration:
  configuration: |-
    zeebe:
      broker:
        data:
          backup:
            store: GCS
            gcs:
              bucketName: camunda-backups
              basePath: zeebe

  env:
    - name: GOOGLE_APPLICATION_CREDENTIALS
      value: /var/secrets/google/service-account-key.json

  extraVolumes:
    - name: gcs-credentials
      secret:
        secretName: camunda-gcs-backup-credentials

  extraVolumeMounts:
    - name: gcs-credentials
      mountPath: /var/secrets/google
      readOnly: true
```

> **Note:** Zeebe's GCS backup store uses Application Default Credentials. Mounting the key file and pointing `GOOGLE_APPLICATION_CREDENTIALS` to it is the recommended approach when not using Workload Identity.

---

## Step 5: Register the Elasticsearch GCS Snapshot Repository

Elasticsearch requires the GCS snapshot repository to be registered before backups can be taken. This must be done via the Elasticsearch API.

### 5a. Store GCS credentials in the Elasticsearch keystore (Bitnami subchart)

The Bitnami Elasticsearch chart does not have a native `keystore` values field, so credentials must be injected via an `initScript` that runs `elasticsearch-keystore` before the node starts. The GCS repository plugin uses a service account JSON file stored as a keystore setting.

Add the following to your `values.yaml` under the `elasticsearch` subchart section:

```yaml
elasticsearch:
  master:
    # Mount the GCS service account key into the pod
    extraVolumes:
      - name: gcs-credentials
        secret:
          secretName: camunda-gcs-backup-credentials

    extraVolumeMounts:
      - name: gcs-credentials
        mountPath: /var/secrets/google
        readOnly: true

    # Init script to populate the keystore before Elasticsearch starts
    initScripts:
      keystore-gcs.sh: |
        #!/bin/sh
        set -e
        elasticsearch-keystore create --silent || true
        elasticsearch-keystore add-file --force \
          gcs.client.default.credentials_file \
          /var/secrets/google/service-account-key.json
```

> **Note:** The `|| true` after `keystore create` prevents failure if the keystore already exists on pod restart. The `--force` flag on `add-file` allows overwriting existing keys without interactive confirmation, which is required in a non-TTY context.

After applying this, the keystore will be populated on every pod start. You can then reload secure settings without a restart using:

```bash
kubectl port-forward svc/camunda-elasticsearch 9200:9200 -n camunda

curl -XPOST "http://localhost:9200/_nodes/reload_secure_settings"
```

### 5b. Register the repository

```bash
curl -XPUT "http://localhost:9200/_snapshot/camunda" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "gcs",
    "settings": {
      "bucket": "camunda-backups",
      "base_path": "elasticsearch",
      "client": "default"
    }
  }'
```

Verify the repository is registered correctly:

```bash
curl -XPOST "http://localhost:9200/_snapshot/camunda/_verify"
```

A successful response returns a list of nodes. Any connectivity or permission error will appear here.

---

## Step 6: Configure Backup Repository Name in Helm Values

The web applications (Operate, Tasklist) and Optimize need to know the name of the Elasticsearch snapshot repository. Set this in your `values.yaml`:

```yaml
orchestration:
  env:
    # ... existing backup store env vars ...
    - name: CAMUNDA_DATA_BACKUP_REPOSITORYNAME
      value: camunda   # must match the repository name registered in Step 5b

optimize:
  env:
    - name: CAMUNDA_OPTIMIZE_BACKUP_REPOSITORY_NAME
      value: camunda   # must match the repository name registered in Step 5b
```

---

## Step 7: Apply the Updated Helm Values

```bash
helm upgrade camunda camunda/camunda-platform \
  --version 13.7.0 \
  --namespace camunda \
  -f values-combined-cluster.yaml \
  -f gcs-backups-values.yaml
```

---

## Step 8: Verify the Setup

Check that Zeebe can reach the backup store by triggering a test backup via the management API:

```bash
kubectl port-forward svc/camunda-zeebe-gateway 9600:9600 -n camunda

curl -XPOST "http://localhost:9600/actuator/backupRuntime" \
  -H "Content-Type: application/json" \
  -d '{"backupId": 1}'
```

Check backup status:

```bash
curl "http://localhost:9600/actuator/backupRuntime/1"
```

---

## Reference

- [Camunda 8.8 Backup & Restore docs](https://docs.camunda.io/docs/8.8/self-managed/operational-guides/backup-restore/backup-and-restore/)
- [Camunda 8.8 Create a Backup](https://docs.camunda.io/docs/8.8/self-managed/operational-guides/backup-restore/backup/)
- [Configure Helm chart components](https://docs.camunda.io/docs/8.8/self-managed/deployment/helm/configure/application-configs/)
- [Optimize Backup API](https://docs.camunda.io/docs/8.8/self-managed/operational-guides/backup-restore/optimize-backup/)
- [Elasticsearch GCS Repository Plugin](https://www.elastic.co/guide/en/elasticsearch/plugins/current/repository-gcs.html)
- [GCS Workload Identity for GKE](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)