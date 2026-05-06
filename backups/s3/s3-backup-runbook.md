# S3 Backup Setup Runbook — Camunda 8.8 (Single Cluster, AWS S3)

## Overview

This runbook covers how to configure AWS S3 as the backup store for a Camunda 8.8 single-cluster deployment managed via Helm. It covers both the Zeebe partition backup store and the Elasticsearch snapshot repository used by the web applications (Operate, Tasklist) and Optimize.

> **Note:** Camunda 8.8 introduced breaking changes to the Operate and Tasklist backup flow. Ensure you are using the 8.8-compatible backup procedure if migrating from an earlier version.

---

## Prerequisites

- A running Camunda 8.8 single-cluster Helm deployment
- `kubectl` and `helm` CLI access to the cluster
- An AWS S3 bucket for backups (or two separate buckets — see note below)
- An IAM user or role with read/write access to the S3 bucket(s)
- The `repository-s3` plugin installed on Elasticsearch (included in Elastic's official Docker image by default)

> **Tip:** You can use a single S3 bucket for both Zeebe and Elasticsearch backups, as long as you configure different `basePath` / `base_path` values for each.

---

## Step 1: Create the S3 Bucket

Create your S3 bucket in your target AWS region. Example:

```bash
aws s3api create-bucket \
  --bucket camunda-backups \
  --region eu-west-1 \
  --create-bucket-configuration LocationConstraint=eu-west-1
```

---

## Step 2: Create an IAM Policy and User

Create an IAM policy with the minimum required permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads",
        "s3:ListBucketVersions"
      ],
      "Resource": "arn:aws:s3:::camunda-backups"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::camunda-backups/*"
    }
  ]
}
```

Create an IAM user, attach the policy, and generate an access key/secret key pair. Store these credentials securely — you will need them in the next step.

> **Production recommendation:** Prefer an IAM role with IRSA (IAM Roles for Service Accounts) over static credentials where possible.

---

## Step 3: Store S3 Credentials as a Kubernetes Secret

```bash
kubectl create secret generic camunda-s3-backup-credentials \
  --from-literal=access-key=YOUR_ACCESS_KEY \
  --from-literal=secret-key=YOUR_SECRET_KEY \
  --namespace camunda
```

---

## Step 4: Configure Zeebe S3 Backup Store

Add the following to your `values.yaml` under the `orchestration` section. In Camunda 8.8, backup config is passed via `orchestration.configuration`:

```yaml
orchestration:
  configuration: |-
    zeebe:
      broker:
        data:
          backup:
            store: S3
            s3:
              bucketName: camunda-backups
              region: eu-west-1
              basePath: zeebe

  env:
    - name: ZEEBE_BROKER_DATA_BACKUP_S3_ACCESSKEY
      valueFrom:
        secretKeyRef:
          name: camunda-s3-backup-credentials
          key: access-key
    - name: ZEEBE_BROKER_DATA_BACKUP_S3_SECRETKEY
      valueFrom:
        secretKeyRef:
          name: camunda-s3-backup-credentials
          key: secret-key
```

> **Note:** If migrating from an older chart that used only `env` vars for backup config, see the [Camunda docs on migrating to the configuration file format](https://docs.camunda.io/docs/self-managed/deployment/helm/configure/application-configs/).

---

## Step 5: Register the Elasticsearch S3 Snapshot Repository

Elasticsearch requires the S3 snapshot repository to be registered before backups can be taken. This must be done via the Elasticsearch API.

### 5a. Store S3 credentials in the Elasticsearch keystore (Bitnami subchart)

The Bitnami Elasticsearch chart does not have a native `keystore` values field, so credentials must be injected via an `initScript` that runs `elasticsearch-keystore` before the node starts. Add the following to your `values.yaml` under the `elasticsearch` subchart section:

```yaml
elasticsearch:
  master:
    # Expose the S3 credentials from the Kubernetes secret as env vars
    # so the init script can read them
    extraEnvVars:
      - name: ELASTICSEARCH_S3_CLIENT_ACCESS_KEY
        valueFrom:
          secretKeyRef:
            name: camunda-s3-backup-credentials
            key: access-key
      - name: ELASTICSEARCH_S3_CLIENT_SECRET_KEY
        valueFrom:
          secretKeyRef:
            name: camunda-s3-backup-credentials
            key: secret-key

    # Init script to populate the keystore before Elasticsearch starts
    initScripts:
      keystore-s3.sh: |
        #!/bin/sh
        set -e
        elasticsearch-keystore create --silent || true
        echo "${ELASTICSEARCH_S3_CLIENT_ACCESS_KEY}" \
          | elasticsearch-keystore add --stdin --force s3.client.default.access_key
        echo "${ELASTICSEARCH_S3_CLIENT_SECRET_KEY}" \
          | elasticsearch-keystore add --stdin --force s3.client.default.secret_key
```


> **Note:** The `|| true` after `keystore create` prevents failure if the keystore already exists on pod restart. The `--force` flag on `add` allows overwriting existing keys without interactive confirmation, which is required in a non-TTY context.

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
    "type": "s3",
    "settings": {
      "bucket": "camunda-backups",
      "region": "eu-west-1",
      "base_path": "elasticsearch",
      "access_key": "YOUR_ACCESS_KEY",
      "secret_key": "YOUR_SECRET_KEY"
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
  -f s3-backups-values.yaml
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