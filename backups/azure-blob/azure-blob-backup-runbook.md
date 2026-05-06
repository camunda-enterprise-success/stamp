# Azure Blob Storage Backup Setup Runbook — Camunda 8.8 (Single Cluster)

## Overview

This runbook covers how to configure Azure Blob Storage as the backup store for a Camunda 8.8 single-cluster deployment managed via Helm. It covers both the Zeebe partition backup store and the Elasticsearch snapshot repository used by the web applications (Operate, Tasklist) and Optimize.

> **Note:** Camunda 8.8 introduced breaking changes to the Operate and Tasklist backup flow. Ensure you are using the 8.8-compatible backup procedure if migrating from an earlier version.

---

## Prerequisites

- A running Camunda 8.8 single-cluster Helm deployment
- `kubectl` and `helm` CLI access to the cluster
- An Azure Storage Account and Blob container for backups
- An Azure account with permissions to create storage accounts and manage access keys
- The `repository-azure` plugin installed on Elasticsearch (included in Elastic's official Docker image by default)

> **Tip:** You can use a single Azure Blob container for both Zeebe and Elasticsearch backups, as long as you configure different `basePath` / `base_path` values for each.

---

## Step 1: Create an Azure Storage Account and Container

```bash
# Create a resource group (if you don't have one)
az group create --name camunda-rg --location westus

# Create a storage account
az storage account create \
  --name camundabackups \
  --resource-group camunda-rg \
  --location westus \
  --sku Standard_LRS

# Create the blob container
az storage container create \
  --name camunda-backups \
  --account-name camundabackups
```

---

## Step 2: Retrieve the Storage Account Key

```bash
az storage account keys list \
  --resource-group camunda-rg \
  --account-name camundabackups \
  --query "[0].value" -o tsv
```

Store the account name and key securely — you will need them in the next step.

> **Production recommendation:** Prefer Azure Managed Identity or a SAS token with limited permissions over static account keys where possible.

---

## Step 3: Store Azure Credentials as a Kubernetes Secret

```bash
kubectl create secret generic camunda-azure-backup-credentials \
  --from-literal=account-name=YOUR_ACCOUNT_NAME \
  --from-literal=account-key=YOUR_ACCOUNT_KEY \
  --namespace camunda
```

---

## Step 4: Configure Zeebe Azure Backup Store

Add the following to your `values.yaml` under the `orchestration` section. In Camunda 8.8, backup config is passed via `orchestration.configuration`:

```yaml
orchestration:
  configuration: |-
    zeebe:
      broker:
        data:
          backup:
            store: AZURE
            azure:
              containerName: camunda-backups
              basePath: zeebe

  env:
    - name: ZEEBE_BROKER_DATA_BACKUP_AZURE_ACCOUNTNAME
      valueFrom:
        secretKeyRef:
          name: camunda-azure-backup-credentials
          key: account-name
    - name: ZEEBE_BROKER_DATA_BACKUP_AZURE_ACCOUNTKEY
      valueFrom:
        secretKeyRef:
          name: camunda-azure-backup-credentials
          key: account-key
```

> **Note:** If migrating from an older chart that used only `env` vars for backup config, see the [Camunda docs on migrating to the configuration file format](https://docs.camunda.io/docs/self-managed/deployment/helm/configure/application-configs/).

---

## Step 5: Register the Elasticsearch Azure Snapshot Repository

Elasticsearch requires the Azure snapshot repository to be registered before backups can be taken. This must be done via the Elasticsearch API.

### 5a. Store Azure credentials in the Elasticsearch keystore (Bitnami subchart)

The Bitnami Elasticsearch chart does not have a native `keystore` values field, so credentials must be injected via an `initScript` that runs `elasticsearch-keystore` before the node starts. Add the following to your `values.yaml` under the `elasticsearch` subchart section:

```yaml
elasticsearch:
  master:
    # Expose the Azure credentials from the Kubernetes secret as env vars
    # so the init script can read them
    extraEnvVars:
      - name: ELASTICSEARCH_AZURE_ACCOUNT_NAME
        valueFrom:
          secretKeyRef:
            name: camunda-azure-backup-credentials
            key: account-name
      - name: ELASTICSEARCH_AZURE_ACCOUNT_KEY
        valueFrom:
          secretKeyRef:
            name: camunda-azure-backup-credentials
            key: account-key

    # Init script to populate the keystore before Elasticsearch starts
    initScripts:
      keystore-azure.sh: |
        #!/bin/sh
        set -e
        elasticsearch-keystore create --silent || true
        echo "${ELASTICSEARCH_AZURE_ACCOUNT_NAME}" \
          | elasticsearch-keystore add --stdin --force azure.client.default.account
        echo "${ELASTICSEARCH_AZURE_ACCOUNT_KEY}" \
          | elasticsearch-keystore add --stdin --force azure.client.default.key
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
    "type": "azure",
    "settings": {
      "container": "camunda-backups",
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
  -f azure-backups-values.yaml
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
- [Optimize Backup API](https://docs.camunda.io/docs/self-managed/8.8/operational-guides/backup-restore/optimize-backup/)
- [Elasticsearch Azure repository plugin](https://www.elastic.co/guide/en/elasticsearch/plugins/current/repository-azure.html)