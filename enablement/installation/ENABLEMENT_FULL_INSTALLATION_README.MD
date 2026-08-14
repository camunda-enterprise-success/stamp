# Full Camunda Installation with Monitoring and Backup

This guide walks through deploying a full Camunda 8 stack — Prometheus/Grafana monitoring, OIDC-based permissions, and scheduled backup/restore 
— on a local Kubernetes cluster (e.g. kind). 
It provides hands-on experience with the platform capabilities to set up or troubleshoot an environment.

Everything here is deployed **into the same local cluster** for convenience, but nothing is **bundled with the Camunda platform**:

- **Secondary storage is PostgreSQL (RDBMS)**, provisioned in-cluster via the **CloudNativePG (CNPG) operator** — This first version does **not** include Optimize (the one component that still needs Elasticsearch).
- **Authentication is an in-cluster Keycloak**, deployed via the official **Keycloak operator**.
- **Backups go to a local MinIO** object store. Both backup halves land in one bucket: the Zeebe runtime (primary storage) and the PostgreSQL secondary storage (via CNPG Barman).

> Targets **Camunda 8.9** via Helm chart `camunda-platform` **14.7.0**. 
> Chart 14.x deprecates the bundled Bitnami Elasticsearch/Keycloak subcharts (removed in 8.10) 
> — this guide uses the operator-based replacements instead, following Camunda's [migration-from-bitnami](https://docs.camunda.io/docs/self-managed/deployment/helm/operational-tasks/migration-from-bitnami/) guidance.

## Design Intent

This directory demonstrates two things about a Camunda 8.9 installation, on top of the walkthrough itself:

1. **It's built up iteratively, one capability at a time.** `minimal_setup.yaml` on its own is already a complete, working orchestration cluster — single node, RDBMS secondary storage, basic auth. Each further values file (`with_permissions.yaml`, `with_monitoring_alerting.yaml`, `values_with_backup_restore.yml`) is an *additive layer* on top of it, composed via extra `-f` flags. You can stop after any layer and have a working cluster; you don't need permissions to get monitoring, or monitoring to get backups. The [Installation](#installation) walkthrough below applies all of them together for convenience, but each layer is independently understandable — see the `Layer` column in the [Architecture Overview](#architecture-overview) table, and that values file's own header comment, for what each one adds on its own.
2. **PostgreSQL, the OIDC provider, backup storage, and monitoring are external dependencies — not part of the core Camunda platform.** The `camunda-platform` Helm chart never deploys or owns any of them; it is only ever *configured to talk to* them (a JDBC URL, an issuer URL, an S3 endpoint, a scrape target). This guide happens to run all four in-cluster via operators/plain manifests, which is a local/dev convenience — in a real deployment they'd typically be a managed database (RDS/CloudSQL), a corporate IdP (Entra ID, Okta, Auth0, ...), cloud object storage (S3/GCS), and a hosted observability stack instead. Swapping any of them out only ever changes endpoints and credentials, never the shape of the Camunda values files.

## Contents

- [Design Intent](#design-intent)
- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
- [Installation](#installation) — [01](#01-install-prometheusgrafana) [02](#02-install-minio) [03](#03-install-postgresql) [04](#04-install-keycloak) [05](#05-create-realm-clients-and-users) [06](#06-install-camunda) [07](#07-create-some-data) [08](#08-enable-scheduled-backups)
- [Accessing the UIs](#accessing-the-uis)
- [Manual Backup](#manual-backup)
- [Restore](#restore)
- [Reset](#reset)
- [Other files in this directory](#other-files-in-this-directory)
- [Variant: Elasticsearch + Optimize + Identity + Web Modeler](#variant-elasticsearch--optimize--identity--web-modeler) — [V1](#v1-create-a-local-cluster-and-install-operators) [V2](#v2-install-postgresql) [V3](#v3-install-keycloak) [V4](#v4-create-realm-clients-and-users) [V5](#v5-install-elasticsearch) [V6](#v6-add-identity--web-modeler-databases) [V7](#v7-copy-secrets) [V8](#v8-install-camunda) [V9](#v9-create-some-data) [V10](#v10-accessing-the-new-uis) [V11](#v11-enable-backups-elasticsearch-variant) [Manual backup](#manual-backup-elasticsearch-variant) [Restore](#restore-elasticsearch-variant)
- [Notes / caveats](#notes--caveats)

## Architecture Overview

The deployment is built from **layered Helm values files** (composed with multiple `-f` flags — Helm merges them in order, later files win) 
plus a few resources applied directly with `kubectl` to provision dependencies. 
The Helm values-file slices for the `camunda-platform` chart itself stay flat at the top of this directory 
(they're all composed together in one `-f ... -f ...` command anyway).

"External" components manifests/scripts live in their own subdirectory: `postgresql/`, `keycloak/`, `monitoring/`, `backup/` (+ `backup/restore/`). The Elasticsearch + Optimize variant adds `elasticsearch/` and its own backup track `backup_elasticsearch/` (+ `backup_elasticsearch/restore/`) — see the [Variant](#variant-elasticsearch--optimize--identity--web-modeler) section.

`Kind` distinguishes systems the `camunda-platform` chart is merely *configured to talk to* ("External dependency") from the chart's own values-file layers ("Camunda platform"). `Layer` numbers the four root `-f` values files in the order they're additively composed (see [Design Intent](#design-intent)); an external dependency's `Layer` is the first one that needs it.

| Concern                      | Kind                 | Layer            | How                                                                                         | Namespace             | File(s)                                                                   |
|------------------------------|----------------------|------------------|---------------------------------------------------------------------------------------------|-----------------------|----------------------------------------------------------------------------|
| Secondary storage            | External dependency  | 1 (base)         | PostgreSQL via CNPG operator (shared by Camunda + Keycloak)                                 | `postgres`            | `postgresql/postgresql-cluster.yaml`                                      |
| Base orchestration           | Camunda platform     | 1 (base)         | Single node, RDBMS secondary storage, basic auth                                            | `camunda`             | `minimal_setup.yaml`                                                      |
| Authentication               | External dependency  | 2 (+permissions) | Keycloak via Keycloak operator; realm/clients/users scripted                                | `keycloak`            | `keycloak/keycloak-instance.yaml`, `keycloak/create-realm-and-clients.sh` |
| OIDC permissions             | Camunda platform     | 2 (+permissions) | Switches auth to OIDC against the in-cluster Keycloak; roles, mapping rules, authorizations | `camunda`             | `with_permissions.yaml`                                                   |
| Monitoring                   | Camunda platform     | 3 (+monitoring)  | Prometheus scraping on Zeebe                                                                | `camunda` / `default` | `with_monitoring_alerting.yaml`                                           |
| Object store (backups)       | External dependency  | 4 (+backup)      | Local MinIO, bucket `camunda-backups`                                                       | `minio`               | `backup/minio.yaml`                                                       |
| Backup (Zeebe runtime)       | Camunda platform     | 4 (+backup)      | Primary-storage backup → MinIO, continuous + hourly cron at `:10`                           | `camunda`             | `values_with_backup_restore.yml`                                          |
| Backup (PostgreSQL)          | External dependency  | 4 (+backup)      | CNPG ScheduledBackup (Barman) → MinIO, hourly cron at `:00` (10 min before the Zeebe side)  | `postgres`            | `backup/scheduled-backup.yaml`                                            |
| Chart-consumed secret copies | Camunda platform     | 1–4 (all)        | RDBMS + MinIO credentials for the Camunda release                                           | `camunda`             | `camunda-secrets.yaml`                                                    |

**Each external dependency runs in its own namespace** (`minio`, `postgres`, `keycloak`). 
The Camunda platform release is alone in `camunda`. Cross-namespace wiring uses fully-qualified Service DNS:

- Camunda + Keycloak → Postgres: `pg-camunda-rw.postgres.svc.cluster.local:5432`
- Camunda + Postgres(Barman) → MinIO: `http://minio.minio.svc.cluster.local:9000`
- Camunda → Keycloak (OIDC): `keycloak-service.keycloak.svc.cluster.local:18080`

Two databases live on the one shared CNPG instance `pg-camunda`: `camunda` (orchestration secondary storage) and `keycloak`. 
Because Kubernetes Secrets are namespace-scoped, shared credentials are duplicated into each consuming namespace 
(e.g. `minio-credentials` exists in `minio`, `postgres`, and `camunda`).

## Prerequisites

Tools required locally:

- `helm`, `kubectl` (aliased as `k`), `kubens` (from `kubectx`)
- `c8ctl` — used by the utility scripts under `../utils/` to deploy BPMN and create process instances
- Cluster-admin rights (the CNPG and Keycloak operators are cluster-scoped)
- Ability to add an `/etc/hosts` entry on the machine you browse from (for Keycloak login, since port-forwarding is used)

A running Kubernetes cluster. Locally, create one via:

```bash
make cluster.create   # from deployment-references-repo/local/kubernetes/kind-single-region/
```

Install the two operators once per cluster (versions pinned to match the images in the manifests — check for current versions before production):

```bash
# CloudNativePG operator
CNPG_VERSION=1.30.0
kubectl apply --server-side -f \
  "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-${CNPG_VERSION%.*}/releases/cnpg-${CNPG_VERSION}.yaml"
kubectl rollout status deployment/cnpg-controller-manager -n cnpg-system --timeout=300s

# Keycloak operator (CRDs + controller). Runs in the "keycloak" namespace.
KEYCLOAK_VERSION=26.3.2
kubectl create namespace keycloak
kubectl apply --server-side -f \
  "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KEYCLOAK_VERSION}/kubernetes/keycloaks.k8s.keycloak.org-v1.yml"
kubectl apply --server-side -f \
  "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KEYCLOAK_VERSION}/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml"
kubectl apply -n keycloak --server-side -f \
  "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KEYCLOAK_VERSION}/kubernetes/kubernetes.yml"
kubectl wait --for=condition=available --timeout=300s deployment/keycloak-operator -n keycloak

# Elastic Cloud on Kubernetes (ECK) operator - only needed for the Elasticsearch + Optimize +
# Identity + Web Modeler variant (see below), skip this if you're only following the RDBMS
# installation. Versions pinned to match Camunda's own 8.9 operator-based reference.
ECK_VERSION=3.3.2
kubectl create namespace elastic-system
kubectl apply --server-side -f \
  "https://download.elastic.co/downloads/eck/${ECK_VERSION}/crds.yaml"
kubectl apply -n elastic-system --server-side -f \
  "https://download.elastic.co/downloads/eck/${ECK_VERSION}/operator.yaml"
kubectl wait --for=jsonpath='{.status.readyReplicas}'=1 --timeout=300s statefulset/elastic-operator -n elastic-system
```

- `camunda` namespace is created from `cluster.create`.
- `minio` and `postgres` namespaces are created by their own manifests in steps 02/03.
- `keycloak` was created above.
- `elastic-system` was created above (ECK operator only; the `elasticsearch` namespace for the actual cluster is created by [V5](#v5-install-elasticsearch)).

---

# Installation

Run every command from `enablement/installation/`.

## 01 Install Prometheus/Grafana

Monitoring first, so Prometheus is ready to scrape as soon as Camunda starts. 
The `kube-prometheus-stack` chart installs Prometheus, Grafana, AlertManager, and the Prometheus Operator into the `default` namespace.

**Before running:** create `monitoring/grafana-secret.yaml.secret` by copying `grafana-secret.yaml.template` and filling in your admin credentials (Gmail credentials only needed for alert emails).

```bash
kubectl create configmap grafana-alerts \
  --from-file=./monitoring/camunda-alerts-grafana-managed.yaml \
  -n default

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community

kubectl apply -f ./monitoring/grafana-secret.yaml.secret -n default

helm install metrics prometheus-community/kube-prometheus-stack \
  --wait --atomic \
  -f ./monitoring/prometheus-operator-values.yaml \
  --set prometheusOperator.tlsProxy.enabled=false \
  --namespace default
```

> The alert bundle still includes some Elasticsearch-specific rules that no longer apply to this RDBMS-based setup — they're harmless (nothing emits those metrics) and can be ignored or trimmed.

## 02 Install MinIO

The local object store all backups are written to (in its own `minio` namespace). The manifest creates the `minio` namespace, a Deployment + Service, a PVC, the `minio-credentials` secret, and a Job that creates the `camunda-backups` bucket.

```bash
kubectl apply -f ./backup/minio.yaml
kubectl rollout status deployment/minio -n minio --timeout=180s
kubectl logs -n minio -l job-name=minio-create-bucket
```

## 03 Install PostgreSQL

One CNPG `Cluster` (`pg-camunda`, single instance) in its own `postgres` namespace, bootstrapped with the `camunda` database, plus a `Database` CR adding Keycloak's `keycloak` database on the same instance. Its `spec.backup` points Barman at MinIO for the PostgreSQL backups. The manifest creates the `postgres` namespace and the credential secrets it needs.

```bash
kubectl apply -f ./postgresql/postgresql-cluster.yaml
kubectl wait --for=condition=Ready --timeout=600s cluster/pg-camunda -n postgres
```

## 04 Install Keycloak

The Keycloak Custom Resource — single instance, no Ingress, backed by the `keycloak` database from step 03. Admin credentials (`admin`/`admin`) are passed in via `bootstrapAdmin`.

```bash
kubectl apply -f ./keycloak/keycloak-instance.yaml
kubectl wait --for=condition=Ready --timeout=600s keycloak/keycloak -n keycloak
```

**Accessing Keycloak locally.** The instance fixes its hostname to the cluster-DNS name so the token `iss` claim is identical for in-cluster pods and your browser. Add a loopback entry once, then port-forward when you need it:

```bash
echo "127.0.0.1 keycloak-service.keycloak.svc.cluster.local" | sudo tee -a /etc/hosts
kubectl port-forward svc/keycloak-service 18080:18080 -n keycloak
```

Admin console: http://keycloak-service.keycloak.svc.cluster.local:18080/auth/

## 05 Create Realm, Clients, and Users

Scripted via `kcadm.sh` inside the Keycloak pod (`kubectl exec`, no port-forward needed). Creates the `camunda-platform` realm; the `operator`/`task-user` roles; the interactive `orchestration` client (secret written to the K8s secret `camunda-keycloak-client-secrets`); the service-account `benchmark-client` (used by the utility scripts); `camunda-identity`, `optimize`, and `web-modeler` (unused on this track, but harmless to leave in place — see the Variant section below); and example users `operator`, `tasklist-user`, `admin` (all `username`=`password`). Idempotent — safe to re-run.

```bash
cd keycloak && ./create-realm-and-clients.sh && cd ..
```

## 06 Install Camunda

First create the credential secrets the Camunda release reads from its **own** namespace 
(copies of the RDBMS + MinIO credentials, since Secrets can't be read across namespaces):

```bash
kubectl apply -f ./camunda-secrets.yaml
```

Then compose the full configuration with the four `-f` flags (merged in order — each one is an additive capability layer, see [Design Intent](#design-intent)): `minimal_setup.yaml` (base cluster) → `with_permissions.yaml` (+ OIDC permissions) → `with_monitoring_alerting.yaml` (+ monitoring) → `values_with_backup_restore.yml` (+ backup):

### With auth
```bash
helm upgrade --install \
  camunda camunda-platform \
  --repo https://helm.camunda.io \
  --version 14.7.0 \
  --namespace camunda \
  -f ./minimal_setup.yaml \
  -f ./with_permissions.yaml \
  -f ./with_monitoring_alerting.yaml \
  -f ./values_with_backup_restore.yml
```

> Each `-f` here is optional and additive — dropping the last one, two, or three flags (and skipping the corresponding external dependency's setup step above) still gives you a fully working cluster, just without that layer's capability. `-f ./minimal_setup.yaml` alone, against nothing but the PostgreSQL from [03](#03-install-postgresql), is already a complete, working basic-auth orchestration cluster — everything from here on is opt-in.

Wait for all pods to be `Running` (note: there is **no** Elasticsearch pod in this setup):

```bash
kubectl get pods -n camunda -w
```

## 07 Create some data

Deploy a test BPMN process and create process instances, so you have data to verify survives a backup/restore. 
Needs the Keycloak port-forward from step 04 running (for OAuth) and a Zeebe Gateway port-forward:

```bash
kubectl port-forward -n camunda svc/camunda-zeebe-gateway 8080:8080 &

c8ctl add profile enablement --baseUrl=http://localhost:8080/v2 \
  --clientId=benchmark-client --clientSecret=benchmark-client \
  --oAuthUrl=http://localhost:18080/auth/realms/camunda-platform/protocol/openid-connect/token \
  --audience=orchestration

../utils/deploy-bpmn.sh --profile=enablement
../utils/create-process-instances.sh --profile=enablement
```

`c8ctl add profile` registers the `benchmark-client` service-account credentials once, resolving OAuth against the in-cluster Keycloak on every subsequent call. 
Each script reads its remaining defaults from env vars (`PROCESS_DEFINITION_ID`, `INSTANCE_COUNT`) and forwards any extra flags (like `--profile`) straight through to `c8ctl`.

## 08 Enable scheduled backups

The Zeebe runtime side is already scheduled hourly by `values_with_backup_restore.yml` (`CAMUNDA_DATA_PRIMARYSTORAGE_BACKUP_SCHEDULE="0 10 * * * *"`, continuous), firing at `:10` past the hour. Add the PostgreSQL side — an hourly CNPG `ScheduledBackup` firing at `:00`, 10 minutes earlier:

```bash
kubectl apply -f ./backup/scheduled-backup.yaml
kubectl get scheduledbackup -n postgres
```

Both `schedule` values are real cron expressions, so the 10-minute stagger is wall-clock anchored and holds every cycle — see [Backup / restore coordination](#backup--restore-coordination) for why the order (and not just an exporter pause) is what matters here.

## Accessing the UIs

```bash
# Grafana (default namespace, from step 01)
kubectl port-forward -n default svc/metrics-grafana 3000:80
# open http://localhost:3000

# Operate (camunda namespace, from step 06)
kubectl port-forward -n camunda svc/camunda-operate 8081:80
# open http://localhost:8081

# MinIO console (to inspect backup objects)
kubectl port-forward -n minio svc/minio 9001:9001
# open http://localhost:9001  (login: minioadmin / minioadmin)
```

Use Operate to confirm the process instances from [07](#07-create-some-data) — this is what you check against after a restore.

---

# Manual Backup

For an on-demand backup outside the hourly schedules, `backup/manual-backup.sh` takes both halves in one go — the PostgreSQL backup first (a CNPG `Backup`), then the Zeebe runtime backup (`POST /actuator/backupRuntime`), following the docs' recommended order:

```bash
./backup/manual-backup.sh
```

Verify:

```bash
kubectl get backups -n postgres                # PostgreSQL (CNPG) backups
kubectl port-forward -n minio svc/minio 9001:9001   # then browse the bucket in the console
```

This follows the [RDBMS backup guide](https://docs.camunda.io/docs/self-managed/operational-guides/backup-restore/rdbms/rdbms-backup/).

# Restore

Recreates the system from the MinIO backups, per the [RDBMS restore guide](https://docs.camunda.io/docs/self-managed/operational-guides/backup-restore/rdbms/rdbms-restore/). The two storage layers are restored independently and re-align via the exporter position.

## 01 Stop Camunda and delete its runtime data

```bash
helm uninstall camunda -n camunda
kubectl delete pvc -n camunda -l app.kubernetes.io/instance=camunda
```

## 02 Delete postgresql and Restore PostgreSQL from Barman

 Delete the old cluster **and its PVC** so recovery provisions fresh storage from the backup:
```bash
kubectl delete cluster pg-camunda -n postgres --ignore-not-found
kubectl delete pvc -n postgres -l cnpg.io/cluster=pg-camunda --ignore-not-found
```

Recreate the CNPG cluster in **recovery** mode (restores the whole instance — both databases — from MinIO). This replaces the normal `postgresql/postgresql-cluster.yaml`.
```bash
kubectl apply -f ./backup/restore/postgresql-cluster-restore.yaml
kubectl wait --for=condition=Ready --timeout=600s cluster/pg-camunda -n postgres
```

`postgresql-cluster-restore.yaml`'s `recoveryTarget` **must be set to a bounded point before you apply it** — it is not a reactive fallback for if something goes wrong. Recovering to "latest" WAL is unsafe here even though the two backup schedules are correctly staggered: Zeebe's restore validates the RDBMS's recorded exporter position against a set of checkpoint ranges (`RangeEntry[start, end]`, each a pair of checkpoint timestamps) recovered from its own backups, and requires the exporter position to fall inside one of them. "Latest" keeps replaying WAL however far the archive happens to have been flushed, independent of any Zeebe checkpoint — on an idle/low-traffic cluster (typical here) that easily runs past the newest Zeebe checkpoint. The symptom is a restore failure like:

```
No usable range found for partition 1 with from=null, exportedPosition=370.
Available ranges: [RangeEntry[start=1785239136694, end=1785240600406]]
```

Before applying, fill in the `recoveryTarget` block in `postgresql-cluster-restore.yaml` with ONE of:
- **`targetTime` (default, recommended)** — a wall-clock timestamp a couple of minutes after the Postgres backup's `:00` tick and safely before Zeebe's `:10` checkpoint tick, e.g. `2026-07-28 12:02:00.00000+00` for a 12:00 UTC cycle. No cluster lookup needed.
- **`backupID` + `targetImmediate: true`** — pins to one specific, already-completed Postgres `Backup` object. `backupID` is the **Barman** backup ID (`status.backupId`, format `YYYYMMDDTHHMMSS`) — not the Kubernetes object's `metadata.name`, which is a different, operator-assigned string. Find the object with `kubectl get backup -n postgres` (use one created at/after a `:00` tick and before the `:10` Zeebe checkpoint you're restoring against), then get its real ID with `kubectl get backup <name> -n postgres -o jsonpath='{.status.backupId}'`.

See [Backup / restore coordination](#backup--restore-coordination) below for the full mechanism.

> If you re-run recovery after a failed attempt, also clear the recovered cluster's own WAL-archive prefix first, or CNPG aborts with "Expected empty archive". This uses the [MinIO Client](https://min.io/docs/minio/linux/reference/minio-mc.html) (`mc`, install once via `brew install minio-mc`), which runs on your machine and talks to MinIO over its S3 API port (9000 — distinct from the 9001 console port-forward used elsewhere in this guide):
> ```bash
> kubectl port-forward -n minio svc/minio 9000:9000 &
> mc alias set local http://localhost:9000 minioadmin minioadmin 
> mc rm --recursive --force local/camunda-backups/rdbms/pg-camunda-restored/
> ```

## 03 Restore the Zeebe runtime

Redeploy in restore mode. `values_to_restore_oc.yml` sets `SPRING_PROFILES_ACTIVE=restore` + `ZEEBE_RESTORE=true` and points at the MinIO primary-storage backup; layering `minimal_setup.yaml` underneath keeps the RDBMS secondary-storage wiring and disables the other components.

```bash
helm upgrade --install \
  camunda camunda-platform \
  --repo https://helm.camunda.io \
  --version 14.7.0 \
  --namespace camunda \
  -f ./minimal_setup.yaml \
  -f ./values_to_restore_oc.yml
```

The restore runs against an **empty** Zeebe data directory (step 01 deleted the PVC; the redeploy creates a fresh one). 
It restores the partition data, then the container exits — and because it's a StatefulSet, Kubernetes restarts it, 
the restart sees the now-restored (non-empty) directory, and the pod enters `CrashLoopBackOff` logging `data directory ... is not empty`. 
**This is the expected success state** — the restore completed on the first run. Confirm by inspecting the restored data and/or the first run's logs:

Catch the success line (it's on the run BEFORE the current crash-looping one):
```bash
kubectl logs -n camunda camunda-zeebe-0 --previous | grep -iE "Restoring RDBMS backups|restored"
```

If instead you see `No backup found` or a range-mismatch failure (`No usable range found for partition N with from=..., exportedPosition=...`, 
or the older-style `last log position ... is before the required exported position ...`), the RDBMS was recovered past the newest Zeebe checkpoint 
— go back to step 02, tighten `recoveryTarget` in `postgresql-cluster-restore.yaml` to an earlier bounded point (see above),
delete the cluster+PVC (and clear the WAL-archive prefix per the note above), and redo the recovery. For a bounded Zeebe-side restore, 
set `ZEEBE_RESTORE_TO_TIMESTAMP` in `values_to_restore_oc.yml` (must not precede the recovered RDBMS state). 

Do **not** proceed to step 04 until the restore has actually completed.

## 04 Return to normal operation

Redeploy with the standard values (Keycloak + realm must be back — re-run steps 04/05 if you also reset those) to disable restore mode:

```bash
helm upgrade --install \
  camunda camunda-platform \
  --repo https://helm.camunda.io \
  --version 14.7.0 \
  --namespace camunda \
  -f ./minimal_setup.yaml \
  -f ./with_permissions.yaml \
  -f ./with_monitoring_alerting.yaml \
  -f ./values_with_backup_restore.yml
```

Verify in Operate that the process instances from before the backup are visible and no data was lost. 
(Directly: `kubectl exec -n postgres pg-camunda-1 -- psql -U postgres -d camunda -tAc "SELECT count(*) FROM process_instance;"`.)

## Backup / restore coordination

The two storage layers re-align at restore time through the **exporter position**: 
Zeebe restores its runtime from a primary-storage backup, then continues exporting into the RDBMS from where the RDBMS left off. 
For this to work, the restored state must satisfy:

> the Zeebe primary-storage backup position **≥** the RDBMS exporter position.

Otherwise the restore aborts — older versions with `last log position X is before the required exported position Y`, 
current versions with `No usable range found for partition N with from=..., exportedPosition=...`— both meaning the same thing:
no retained Zeebe checkpoint range covers the RDBMS's recorded exporter position (Zeebe would otherwise re-export records the RDBMS already has).
Three rules keep them consistent:

- **Backup order** — take the RDBMS backup first, then the Zeebe backup (the order `manual-backup.sh` uses, and the docs recommend). With continuous Zeebe backups enabled the primary side keeps pace with the exporter automatically. For the *scheduled* backups, this repo stagger the two cron schedules by 10 minutes — Postgres (`scheduled-backup.yaml`) at `:00`, Zeebe (`CAMUNDA_DATA_PRIMARYSTORAGE_BACKUP_SCHEDULE` in `values_with_backup_restore.yml`) at `:10`. This only works because `CAMUNDA_DATA_PRIMARYSTORAGE_BACKUP_SCHEDULE` accepts a genuine [CRON expression](https://docs.camunda.io/docs/self-managed/components/orchestration-cluster/core-settings/configuration/properties/#camundadataprimary-storagebackup) (6-field, seconds-leading — same style CNPG's `schedule` field uses). The 10-minute gap needs to comfortably exceed how long the Postgres backup actually takes to run — fine on a small/low-data cluster, but widen it (or drop back to an explicit wait-then-trigger pipeline) if backup duration ever grows closer to that margin.
- **Backup order, but causal instead of timed** — if you'd rather not depend on a fixed gap at all (e.g. backup duration is unpredictable), replace both schedules with a single external trigger (cron job, CI pipeline, etc.) that runs the RDBMS backup, waits for it to reach `completed`, and only then calls `POST /actuator/backupRuntime` for the Zeebe side — same order, guaranteed by completion rather than elapsed time. `backup/manual-backup.sh` already implements exactly that sequence for on-demand use; wrapping it in a Kubernetes `CronJob` gets you the same guarantee on a schedule.
- **Restore point (mandatory, not a fallback)** — when recovering the RDBMS, never leave `recoveryTarget` unset / rely on "latest" WAL replay, even though the backup schedules are staggered correctly. Zeebe's restore resolves each retained backup into a `RangeEntry(start, end)` — a pair of checkpoint timestamps — converts that into a log-position range, and requires the RDBMS's recorded exporter position to fall inside `[firstLogPosition(start), checkpointPosition(end)]` for at least one retained range. Staggering the two backup *schedules* only guarantees the Zeebe backup starts after the Postgres one does; it says nothing about how far WAL replay continues afterwards. On a busy cluster "latest" usually still lands inside a range because a Zeebe checkpoint follows soon after every burst of activity; on an idle/low-traffic cluster (this local teaching setup) "latest" can keep replaying WAL well past the newest Zeebe checkpoint with nothing to stop it, pushing the exporter position outside every retained range. Always pin `recoveryTarget` explicitly in `postgresql-cluster-restore.yaml` — either `targetTime` set a couple of minutes after the Postgres `:00` tick and before the Zeebe `:10` tick (the default), or `backupID` + `targetImmediate: true` pinned to one known-good completed `Backup` object. See [step 02](#02-delete-postgresql-and-restore-postgresql-from-barman) above.


# Variant: Elasticsearch + Optimize + Identity + Web Modeler

An alternative to the main Installation walkthrough above that swaps the orchestration cluster's
secondary storage from RDBMS to **Elasticsearch** (via the **ECK operator**, replacing the
deprecated bundled Bitnami subchart per Camunda's
[migration-from-bitnami](https://docs.camunda.io/docs/self-managed/deployment/helm/operational-tasks/migration-from-bitnami/bitnami-to-operators/)
guidance) and adds **Optimize**, **Management Identity**, and **Web Modeler** on top. Optimize has
no RDBMS mode — it only reads Elasticsearch/OpenSearch — so this is a genuinely alternate base,
**mutually exclusive with `minimal_setup.yaml`** at the storage layer: never apply both
`minimal_setup.yaml` and `minimal_setup_elasticsearch.yaml` in the same `-f ... -f ...` line.

**This section is fully self-contained** — every command needed for this track, [V1](#v1-create-a-local-cluster-and-install-operators)
through [V10](#v10-accessing-the-new-uis) (plus the optional backup/restore track,
[V11](#v11-enable-backups-elasticsearch-variant) onward), is below; you don't need to jump back into
the main Installation walkthrough above. It does duplicate some of the same shared building blocks the
RDBMS track uses (the local cluster, the CNPG/Keycloak operators, the `pg-camunda` Postgres
instance, Keycloak + its realm — Identity requires OIDC) plus the ECK operator/Elasticsearch this
track alone needs. If you already ran the main walkthrough on this same cluster, the early `kubectl
apply`s below are no-ops (everything here is idempotent); otherwise this is a complete path from an
empty cluster. `with_permissions.yaml` composes unchanged on top of either storage base. Monitoring
([01](#01-install-prometheusgrafana)) is an independent layer this variant doesn't add — see the main
guide above if you also want it on top. **Backup/restore for this Elasticsearch variant** — which
covers Optimize too — is its own self-contained track at the end of this section:
[V11](#v11-enable-backups-elasticsearch-variant), [Manual backup](#manual-backup-elasticsearch-variant),
[Restore](#restore-elasticsearch-variant). It follows Camunda's Elasticsearch/OpenSearch backup model
(one shared backup ID across all components under an exporter pause), which is deliberately different
from the RDBMS track's model above.

| Concern                        | Kind                 | How                                                                          | Namespace       | File(s)                                                                    |
|---------------------------------|----------------------|-------------------------------------------------------------------------------|-----------------|------------------------------------------------------------------------------|
| App database                   | External dependency  | PostgreSQL via CNPG operator (Keycloak + Identity + Web Modeler)             | `postgres`      | `postgresql/postgresql-cluster.yaml`                                       |
| Authentication                 | External dependency  | Keycloak via Keycloak operator; realm/clients/users scripted                 | `keycloak`      | `keycloak/keycloak-instance.yaml`, `keycloak/create-realm-and-clients.sh`   |
| OIDC permissions                | Camunda platform     | Switches auth to OIDC against the in-cluster Keycloak                        | `camunda`       | `with_permissions.yaml`                                                    |
| Secondary storage (base)       | External dependency  | Elasticsearch via ECK operator                                               | `elasticsearch` | `elasticsearch/elasticsearch-cluster.yaml`                                 |
| Base orchestration (alt.)      | Camunda platform     | Single node, Elasticsearch secondary storage, basic auth                     | `camunda`       | `minimal_setup_elasticsearch.yaml`                                         |
| Optimize                       | Camunda platform     | Imports from the same Elasticsearch the orchestration cluster exports into   | `camunda`       | `with_optimize.yaml`                                                       |
| Identity + Web Modeler app DBs | External dependency  | Two more databases on the shared CNPG instance                              | `postgres`      | `postgresql/postgresql-databases-identity-webmodeler.yaml` (+ roles in `postgresql/postgresql-cluster.yaml`) |
| Management Identity            | Camunda platform     | Own OIDC client, prepared explicitly (see below)                             | `camunda`       | `with_identity_webmodeler.yaml`                                            |
| Web Modeler                    | Camunda platform     | Requires Identity; own (public) OIDC client + CNPG-backed project storage   | `camunda`       | `with_identity_webmodeler.yaml`                                            |
| Chart-consumed secret copies   | Camunda platform     | Elasticsearch/Web Modeler+Identity DB credentials, plus one consolidated `camunda-credentials` Secret for everything Keycloak-facing | `camunda`       | `elasticsearch/copy-elastic-secret.sh`, `camunda-secrets-identity-webmodeler.yaml`, `keycloak/create-realm-and-clients.sh` |
| Object store (backups)         | External dependency  | Local MinIO, bucket `camunda-backups` (reused from the main guide)          | `minio`         | `backup/minio.yaml`                                                       |
| Backup — ES snapshot repos     | External dependency  | Elasticsearch S3 snapshot repos → MinIO (Operate/Tasklist history + Optimize); ES keystore creds baked into the ES cluster | `elasticsearch` | `elasticsearch/elasticsearch-cluster.yaml` (secureSettings), `backup_elasticsearch/register-snapshot-job.yaml` |
| Backup — coordinated + restore | Camunda platform     | One shared backup ID across Zeebe runtime + history + Optimize under an exporter pause; restore overlays | `camunda`       | `values_with_backup_restore_elasticsearch.yml`, `values_to_restore_oc_elasticsearch.yml`, `backup_elasticsearch/` |

Unlike orchestration's own OIDC client (`with_permissions.yaml`'s
`orchestration.security.authentication.oidc`), Optimize/Identity/Web Modeler share one "External
Keycloak" connection block (`global.identity.keycloak.*`, set in `with_optimize.yaml`) plus
per-component client config under `global.identity.auth.*`.

**Every OIDC client any track needs is always created, up front**, by
`keycloak/create-realm-and-clients.sh` (V4) — following Camunda's own
documented ["Option 1: prepare an existing realm"](https://docs.camunda.io/docs/self-managed/deployment/helm/configure/authentication-and-authorization/external-keycloak/#configure-components-using-oidc)
pattern for external Keycloak, rather than relying on Management Identity's own startup-time
self-provisioning for anything beyond its own client lookup. That self-provisioning path (Camunda's
alternative "Option 2: let Management Identity create a realm") was tried first while building this
guide and found to be non-idempotent in practice: Identity's `KeycloakPresetInitializer` always
attempts to *create* its resource-server clients unconditionally (no existence check), so it
409-crashes on every restart after the first success — and even a from-scratch attempt
intermittently produced a client with `authorizationServicesEnabled: true` that a later
initialization step then refused to manage, crash-looping regardless. Explicit, scripted client
creation (this section's approach) sidesteps that fragility entirely: every client already exists
with the right settings before Camunda's `helm upgrade --install` ever runs, and every credential —
the Keycloak admin password, Identity's/Optimize's client secrets — is consolidated into one
Secret, `camunda-credentials`, using the exact key names from Camunda's own external-Keycloak
example, written by the same script that creates the matching Keycloak clients so the two can never
drift out of sync.

## V1 Create a Local Cluster and Install Operators

Tools required locally: `helm`, `kubectl` (aliased as `k`), `kubens` (from `kubectx`), `c8ctl`
(used by the utility scripts under `../utils/`), cluster-admin rights (the CNPG/Keycloak/ECK
operators are cluster-scoped), and the ability to add an `/etc/hosts` entry on the machine you
browse from (for Keycloak login, since port-forwarding is used).

A running Kubernetes cluster. Locally, create one via:

```bash
make cluster.create   # from deployment-references-repo/local/kubernetes/kind-single-region/
```

Install the three operators this track needs once per cluster (versions pinned to match the images
in the manifests — check for current versions before production):

```bash
# CloudNativePG operator (Postgres for Keycloak + Identity + Web Modeler)
CNPG_VERSION=1.30.0
kubectl apply --server-side -f \
  "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-${CNPG_VERSION%.*}/releases/cnpg-${CNPG_VERSION}.yaml"
kubectl rollout status deployment/cnpg-controller-manager -n cnpg-system --timeout=300s

# Keycloak operator (CRDs + controller). Runs in the "keycloak" namespace.
KEYCLOAK_VERSION=26.3.2
kubectl create namespace keycloak
kubectl apply --server-side -f \
  "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KEYCLOAK_VERSION}/kubernetes/keycloaks.k8s.keycloak.org-v1.yml"
kubectl apply --server-side -f \
  "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KEYCLOAK_VERSION}/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml"
kubectl apply -n keycloak --server-side -f \
  "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KEYCLOAK_VERSION}/kubernetes/kubernetes.yml"
kubectl wait --for=condition=available --timeout=300s deployment/keycloak-operator -n keycloak

# Elastic Cloud on Kubernetes (ECK) operator - this track's secondary storage.
# Versions pinned to match Camunda's own 8.9 operator-based reference.
ECK_VERSION=3.3.2
kubectl create namespace elastic-system
kubectl apply --server-side -f \
  "https://download.elastic.co/downloads/eck/${ECK_VERSION}/crds.yaml"
kubectl apply -n elastic-system --server-side -f \
  "https://download.elastic.co/downloads/eck/${ECK_VERSION}/operator.yaml"
kubectl wait --for=jsonpath='{.status.readyReplicas}'=1 --timeout=300s statefulset/elastic-operator -n elastic-system
```

- `camunda` namespace is created from `cluster.create`.
- `keycloak` and `elastic-system` were created above.
- `postgres` is created by its own manifest in [V2](#v2-install-postgresql); `elasticsearch` (the
  actual ES cluster's namespace) is created by [V5](#v5-install-elasticsearch).

Run every remaining command in this section from `enablement/installation/`.

## V2 Install PostgreSQL

One CNPG `Cluster` (`pg-camunda`, single instance) in its own `postgres` namespace, bootstrapped
with the `camunda` database (unused on this Elasticsearch-backed track, but harmless — it's the
same shared manifest as the RDBMS track) plus login roles/databases for Keycloak, Identity, and Web
Modeler. The manifest creates the `postgres` namespace and the credential secrets it needs.

```bash
kubectl apply -f ./postgresql/postgresql-cluster.yaml
kubectl wait --for=condition=Ready --timeout=600s cluster/pg-camunda -n postgres
```

## V3 Install Keycloak

The Keycloak Custom Resource — single instance, no Ingress, backed by the `keycloak` database from
V2. Admin credentials (`admin`/`admin`) are passed in via `bootstrapAdmin`.

```bash
kubectl apply -f ./keycloak/keycloak-instance.yaml
kubectl wait --for=condition=Ready --timeout=600s keycloak/keycloak -n keycloak
```

**Accessing Keycloak locally.** The instance fixes its hostname to the cluster-DNS name so the
token `iss` claim is identical for in-cluster pods and your browser. Add a loopback entry once, then
port-forward when you need it:

```bash
echo "127.0.0.1 keycloak-service.keycloak.svc.cluster.local" | sudo tee -a /etc/hosts
kubectl port-forward svc/keycloak-service 18080:18080 -n keycloak
```

Admin console: http://keycloak-service.keycloak.svc.cluster.local:18080/auth/

## V4 Create Realm, Clients, and Users

Scripted via `kcadm.sh` inside the Keycloak pod (`kubectl exec`, no port-forward needed). Creates
the `camunda-platform` realm; the `operator`/`task-user` roles; the interactive `orchestration`
client (secret written to the K8s secret `camunda-keycloak-client-secrets`); the service-account
`benchmark-client` (used by the utility scripts, audience `orchestration`); `camunda-identity`
(Management Identity's own client — confidential, service account roles on, Authorization
explicitly off, per
[Camunda's own guidance for this client](https://docs.camunda.io/docs/next/self-managed/components/management-identity/configuration/connect-to-an-existing-keycloak/)),
`optimize`, and `web-modeler` (public, no secret) — following Camunda's own
["Option 1: prepare an existing realm"](https://docs.camunda.io/docs/self-managed/deployment/helm/configure/authentication-and-authorization/external-keycloak/#configure-components-using-oidc)
pattern (see the Variant section's intro above for why); the consolidated `camunda-credentials`
Secret (Keycloak admin password, the `admin` first-user's password, Identity's/Optimize's client
secrets); an `admin`/`admin` first user for Management Identity's own login; and example users
`operator`, `tasklist-user`, `admin` (all `username`=`password`). Idempotent — safe to re-run. This
is the exact same script and command as [step 05](#05-create-realm-clients-and-users) in the main
guide — every client is always created, on both tracks:

```bash
cd keycloak && ./create-realm-and-clients.sh && cd ..
```

## V5 Install Elasticsearch

Single-node ECK-managed Elasticsearch, in its own `elasticsearch` namespace (same "external
dependency gets its own namespace" convention as `postgres`/`keycloak`). Requires the ECK operator
from [V1](#v1-create-a-local-cluster-and-install-operators).

```bash
kubectl apply -f ./elasticsearch/elasticsearch-cluster.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Ready --timeout=600s elasticsearch/elasticsearch -n elasticsearch
```

ECK generates the `elastic` superuser's password itself (unlike every other credential in this
repo) and stores it in a Secret in the `elasticsearch` namespace — copy it into `camunda` so the
Camunda release can read it:

```bash
./elasticsearch/copy-elastic-secret.sh
```

## V6 Add Identity + Web Modeler Databases

Adds the `identity` and `webmodeler` databases to the **same** shared CNPG instance from
[V2](#v2-install-postgresql) (`pg-camunda`) — no new Postgres instance needed; the login roles
themselves were already created by V2's cluster manifest. Just the two new `Database` CRs:

```bash
kubectl apply -f ./postgresql/postgresql-databases-identity-webmodeler.yaml
```

## V7 Copy Secrets

Same reasoning as `camunda-secrets.yaml` in the main guide — the Camunda release can only read
`existingSecret`s from its own (`camunda`) namespace:

```bash
kubectl apply -f ./camunda-secrets-identity-webmodeler.yaml
```

## V8 Install Camunda

Compose the Elasticsearch base with the two new layers (order matters — `with_identity_webmodeler.yaml`
depends on the `global.identity.auth.*` block `with_optimize.yaml` establishes):

```bash
helm upgrade --install \
  camunda camunda-platform \
  --repo https://helm.camunda.io \
  --version 14.7.0 \
  --namespace camunda \
  -f ./minimal_setup_elasticsearch.yaml \
  -f ./with_permissions.yaml \
  -f ./with_optimize.yaml \
  -f ./with_identity_webmodeler.yaml
```

```bash
kubectl get pods -n camunda -w
```

> **If Identity doesn't reach `Ready`**, check first whether [V4](#v4-create-realm-clients-and-users)
> actually ran — every client Identity needs (`camunda-identity`,
> `orchestration`, `optimize`, `web-modeler`), the `realm-management` service-account roles on
> `camunda-identity` (`manage-clients`/`manage-realm`/`manage-users` — needed even under GENERIC
> auth, for Identity's own runtime user/role management calls), and the `camunda-credentials` Secret
> must already exist in Keycloak *before* this step.
>
> Also confirm `with_optimize.yaml`'s `global.identity.auth.type` is `"GENERIC"`, not `"KEYCLOAK"`.
> KEYCLOAK type activates Identity's own `keycloak` Spring profile, which runs
> `KeycloakPresetInitializer` — it unconditionally tries to *create* every resource-server client via
> Keycloak's admin API on every startup, so it 409-crashes (`Client ... already exists`) the moment
> those clients already exist, which V4 guarantees from the very first apply. Pre-creating the
> clients (V4) alone does **not** avoid this — only `type: "GENERIC"` does, by skipping that
> initializer entirely and talking to Keycloak as a plain OIDC provider via the explicit
> `publicIssuerUrl`/`issuerBackendUrl`/`authUrl`/`tokenUrl`/`jwksUrl` in `with_optimize.yaml`. This
> was discovered the hard way while building this guide: pre-creating clients alone still 409-crashed
> Identity until `auth.type` was switched to `GENERIC`. If you still see the 409 (or a
> `NotFoundException ... not managed by Identity because it has authorization services enabled`),
> recovery: delete the conflicting client(s) from the realm (`kcadm.sh delete clients/<id> -r
> camunda-platform`) and delete the Identity pod to retry from a clean slate.

## V9 Create Some Data

Deploy a test BPMN process and create process instances, so Optimize has data to import. Needs the
Keycloak port-forward from [V3](#v3-install-keycloak) running (for OAuth) and a Zeebe Gateway
port-forward:

```bash
kubectl port-forward -n camunda svc/camunda-zeebe-gateway 8080:8080 &

c8ctl add profile enablement --baseUrl=http://localhost:8080/v2 \
  --clientId=benchmark-client --clientSecret=benchmark-client \
  --oAuthUrl=http://localhost:18080/auth/realms/camunda-platform/protocol/openid-connect/token \
  --audience=orchestration

../utils/deploy-bpmn.sh --profile=enablement
../utils/create-process-instances.sh --profile=enablement
```

`--audience=orchestration` — the orchestration cluster validates tokens against the `orchestration`
client V4 prepared, per `with_permissions.yaml`'s `orchestration.security.authentication.oidc`.
`c8ctl add profile` registers the `benchmark-client` service-account
credentials once, resolving OAuth against the in-cluster Keycloak on every subsequent call. Allow a
minute or two for Optimize's own import cycle to pick up the new instances — it doesn't appear
immediately, unlike Operate/Tasklist.

## V10 Accessing the New UIs

```bash
# Operate
kubectl port-forward -n camunda svc/camunda-operate 8081:80
# open http://localhost:8081

# Optimize
kubectl port-forward -n camunda svc/camunda-optimize 8083:80
# open http://localhost:8083/optimize

# Web Modeler (the restapi service also serves the web frontend - there's no separate webapp Service)
kubectl port-forward -n camunda svc/camunda-web-modeler-restapi 8070:80
# open http://localhost:8070/modeler

# Management Identity
kubectl port-forward -n camunda svc/camunda-identity 8084:80
# open http://localhost:8084/identity
```

Log in to Management Identity, Optimize, and Web Modeler with `admin`/`admin` — the same Keycloak
user V4 creates for every other login in this guide. Management Identity recognizes it as an admin
via `global.identity.auth.identity.initialClaimName`/`initialClaimValue` (`with_optimize.yaml`)
matching that user's `preferred_username` claim, not the chart's `identity.firstUser` mechanism
(that requires KEYCLOAK-type admin-API access, which this guide's `type: "GENERIC"` deliberately
does not use — see V8's note). Operate/Tasklist (via Orchestration's own login) use
the separate `operator`/`tasklist-user`/`admin` realm users V4 always creates.

**Variant-specific caveats**, in addition to the [Notes / caveats](#notes--caveats) below:
- **Single-node Elasticsearch, no HA** — same posture as the rest of this guide; not appropriate
  beyond local/enablement use.
- **Optimize's import runs on its own schedule** — new process instances don't appear in Optimize
  immediately, unlike Operate/Tasklist.
- **Identity's own database is not strictly required.** In "External Keycloak" mode, Keycloak can
  store Identity's data itself unless multitenancy is enabled — `identity.externalDatabase` is
  wired up anyway here to demonstrate the CNPG pattern end-to-end, per this guide's design intent
  of showing every component backed by an explicit, operator-managed dependency.
- **Web Modeler's Pusher secret is auto-generated and changes on every `helm upgrade`**, which the
  chart itself warns about (`kubectl logs` on the restapi pod, or the Helm install output) — it
  breaks WebSocket-based live-collaboration until affected browser tabs reconnect. Set
  `webModeler.restapi.pusher.secret.existingSecret` / `.pusher.client.secret.existingSecret` to a
  stable Secret if that matters for your use of this guide; left as chart defaults here since it's
  cosmetic for a local/dev cluster.
- **Don't let Management Identity self-provision its OIDC clients on this track.** V4
  prepares every client up front instead, and `with_optimize.yaml`
  sets `global.identity.auth.type: "GENERIC"` — both matter. Self-provisioning
  (`KeycloakPresetInitializer`) is gated behind `type: "KEYCLOAK"`'s `keycloak` Spring profile: it
  always attempts to *create* its resource-server clients, never checks if they already exist, so it
  409-crashes on every restart after its first success even with V4's clients already prepared.
  `type: "GENERIC"` is what actually disables that initializer; V4's client prep alone does not.
  If you switch back to `type: "KEYCLOAK"` and let Identity self-provision, expect the same
  fragility; see the note under [V8](#v8-install-camunda) for the recovery procedure if it happens.


## V11 Enable backups (Elasticsearch variant)

Backup/restore for this variant follows Camunda's [Elasticsearch/OpenSearch backup model](https://docs.camunda.io/docs/self-managed/operational-guides/backup-restore/),
which is deliberately **different from the RDBMS track's model** in the main guide above. There, the
two storage halves are backed up on independent staggered schedules and re-aligned at restore via the
exporter position. Here, **all components share ONE backup ID** and are snapshotted together under a
single **exporter pause**, because Elasticsearch is the secondary storage for Operate/Tasklist history
**and** for Optimize. One coordinated backup covers three snapshot streams, all landing in the local
MinIO bucket `camunda-backups`:

| Stream                          | Trigger                                                  | Lands in                                                                     |
|---------------------------------|----------------------------------------------------------|------------------------------------------------------------------------------|
| Zeebe runtime (primary storage) | `POST camunda-zeebe-gateway:9600/actuator/backupRuntime` | `s3://camunda-backups/oc-runtime` (Camunda-managed)                          |
| Operate/Tasklist history        | `POST camunda-zeebe-gateway:9600/actuator/backupHistory` | ES repo `camunda-backups-webapps` → `s3://camunda-backups/web-apps-indices`  |
| **Optimize**                    | `POST camunda-optimize:8092/actuator/backups`            | ES repo `camunda-backups-optimize` → `s3://camunda-backups/optimize-indices` |

**1. Install the object store** (same MinIO manifest as the main guide — a no-op if you already have it):

```bash
kubectl apply -f ./backup/minio.yaml
```

**2. Give Elasticsearch its S3 credentials.** `elasticsearch/elasticsearch-cluster.yaml` already carries
the `secureSettings` block and the `elasticsearch-s3-backup-credentials` Secret that load the MinIO
access/secret keys into the Elasticsearch keystore (needed for any s3-type snapshot repository). If you
installed Elasticsearch at [V5](#v5-install-elasticsearch) **before** this backup wiring existed,
re-apply the manifest so ECK picks up the keystore change (it reloads secure settings automatically):

```bash
kubectl apply -f ./elasticsearch/elasticsearch-cluster.yaml
```

**3. Copy the MinIO credentials into the `camunda` namespace** (the orchestration release reads them for
the runtime backup; Secrets are namespace-scoped — same reasoning as `camunda-secrets.yaml`, which this
variant doesn't apply):

```bash
kubectl apply -f ./backup_elasticsearch/minio-credentials-camunda.yaml
```

**4. Add the backup values layer** by re-running the [V8](#v8-install-camunda) install with one extra
`-f` (`values_with_backup_restore_elasticsearch.yml` — the Elasticsearch counterpart of the RDBMS
track's `values_with_backup_restore.yml`; it configures the runtime backup store, the history repo
name `CAMUNDA_DATA_BACKUP_REPOSITORY_NAME`, and Optimize's repo name `CAMUNDA_OPTIMIZE_BACKUP_REPOSITORY_NAME`):

```bash
helm upgrade --install \
  camunda camunda-platform \
  --repo https://helm.camunda.io \
  --version 14.7.0 \
  --namespace camunda \
  -f ./minimal_setup_elasticsearch.yaml \
  -f ./with_permissions.yaml \
  -f ./with_optimize.yaml \
  -f ./with_identity_webmodeler.yaml \
  -f ./values_with_backup_restore_elasticsearch.yml
kubectl rollout status statefulset/camunda-zeebe -n camunda --timeout=300s
```

**5. Register the two Elasticsearch snapshot repositories** (points them at MinIO):

```bash
kubectl apply -f ./backup_elasticsearch/register-snapshot-job.yaml
kubectl wait --for=condition=complete --timeout=120s job/register-snapshot-job -n camunda
```

> **Why no scheduled cron here (unlike the RDBMS track's `:00`/`:10` schedules)?** The coordinated
> single-backup-ID model needs one pause spanning all three snapshots, which the engine's independent
> runtime-backup cron can't coordinate with the history/Optimize snapshots. So backups on this variant
> are taken on demand by the Job below. (You can schedule them by wrapping that Job in a Kubernetes
> `CronJob` that bumps the backup ID each run.)

## Manual backup (Elasticsearch variant)

Pick a backup ID — an **integer greater than any previous** backup ID; a Unix timestamp works well —
and put it in the shared `camunda-backup-config` ConfigMap (the take-backup and restore Jobs both read
it, keeping all streams tied to the same ID):

```bash
kubectl create configmap camunda-backup-config -n camunda \
  --from-literal=BACKUP_ID=9999 \
  --dry-run=client -o yaml | kubectl apply -f -
```

Run the coordinated backup (pause exporting → history → Optimize → runtime → resume, all one ID):

```bash
kubectl apply -f ./backup_elasticsearch/take-backup-job.yaml
kubectl wait --for=condition=complete --timeout=1800s job/camunda-backup-combined -n camunda
kubectl logs -f job/camunda-backup-combined -n camunda
```

Verify the objects landed in MinIO (console on port 9001, or `mc`):

```bash
kubectl port-forward -n minio svc/minio 9000:9000 &
mc alias set local http://localhost:9000 minioadmin minioadmin
mc ls --recursive local/camunda-backups/       # oc-runtime/, web-apps-indices/, optimize-indices/
```

> To take **another** backup later, a completed Job can't be re-run in place — bump the ConfigMap to a
> new larger ID (the `kubectl create ... | kubectl apply` above) and re-create the Job
> (`kubectl delete job camunda-backup-combined -n camunda` first, then re-apply).
>
> **A backup ID can only ever be used once, even for a retry.** If the Job fails partway through
> (e.g. one step errored but history/Optimize already completed), you can't re-apply it with the
> *same* ID to pick up where it left off — `backupHistory`/Optimize's backup API reject a reused ID
> with HTTP 400, since a backup ID must be strictly greater than every ID used before, including
> partially-completed ones. Bump to a fresh ID and re-run the whole Job from scratch; the exporter
> pause guarantees the retry gets a consistent snapshot regardless of what the failed attempt did.

## Restore (Elasticsearch variant)

Recreates the system from a given backup ID. The Elasticsearch snapshots (history + Optimize) and the
Zeebe runtime backup are restored in that order, tied together by the shared backup ID. Set
`camunda-backup-config`'s `BACKUP_ID` to the one you're restoring first:

```bash
kubectl create configmap camunda-backup-config -n camunda \
  --from-literal=BACKUP_ID=<the-backup-id> \
  --dry-run=client -o yaml | kubectl apply -f -
```

**01 Stop everything that writes to Elasticsearch.** A snapshot can't restore over an open index, and
nothing may re-create the indices mid-restore — so scale the orchestration cluster (the exporter) and
Optimize (its importer) to zero:

```bash
kubectl scale statefulset camunda-zeebe -n camunda --replicas=0
kubectl scale deployment camunda-optimize -n camunda --replicas=0
```

**02 Delete the Camunda indices.** Preview first, then delete (`camunda-*`, `operate-*`, `tasklist-*`,
and `optimize-*`):

```bash
kubectl apply -f ./backup_elasticsearch/delete-camunda-indices-dryrun-job.yaml
kubectl logs -f job/delete-camunda-indices-dryrun -n camunda
kubectl apply -f ./backup_elasticsearch/delete-camunda-indices-job.yaml
kubectl wait --for=condition=complete --timeout=300s job/delete-camunda-indices -n camunda
```

**03 Restore the Elasticsearch snapshots** (history + Optimize) for the backup ID. The repositories are
still registered from install, but re-applying the register Job is harmless and required if the ES
cluster itself was ever reset:

```bash
kubectl apply -f ./backup_elasticsearch/register-snapshot-job.yaml   # idempotent; safe to re-run
kubectl wait --for=condition=complete --timeout=120s job/register-snapshot-job -n camunda
kubectl apply -f ./backup_elasticsearch/restore/es-snapshot-restore-job.yaml
kubectl wait --for=condition=complete --timeout=1800s job/camunda-es-snapshot-restore -n camunda
kubectl logs -f job/camunda-es-snapshot-restore -n camunda
```

**04 Restore the Zeebe runtime.** Delete the broker's PVC so the restore runs against an empty data
directory, then redeploy in restore mode. `values_to_restore_oc_elasticsearch.yml` sets
`SPRING_PROFILES_ACTIVE=restore` + `ZEEBE_RESTORE=true` and passes the backup ID explicitly via
`ZEEBE_RESTORE_FROM_BACKUP_ID` (Elasticsearch, unlike the RDBMS, doesn't record the exporter position
for the engine to auto-discover it); layering `minimal_setup_elasticsearch.yaml` underneath keeps the
ES wiring and disables Optimize/Identity/Web Modeler for the restore run:

```bash
kubectl delete pvc data-camunda-zeebe-0 -n camunda
helm upgrade --install \
  camunda camunda-platform \
  --repo https://helm.camunda.io \
  --version 14.7.0 \
  --namespace camunda \
  -f ./minimal_setup_elasticsearch.yaml \
  -f ./values_to_restore_oc_elasticsearch.yml
```

The restore container restores the partition data, then exits — Kubernetes restarts the StatefulSet
pod, the restart sees the now-restored (non-empty) directory, and the pod enters `CrashLoopBackOff`
logging `data directory ... is not empty`. **This is the expected success state.** Confirm on the run
*before* the current crash-looping one:

```bash
kubectl logs -n camunda camunda-zeebe-0 --previous | grep -iE "restored|restore"
```

Do **not** proceed until the restore has actually completed.

**05 Return to normal operation.** Redeploy the full Variant stack (with the backup layer, so backups
keep working) to leave restore mode and bring Optimize/Identity/Web Modeler back — Optimize re-reads the
restored `optimize-*` indices:

```bash
helm upgrade --install \
  camunda camunda-platform \
  --repo https://helm.camunda.io \
  --version 14.7.0 \
  --namespace camunda \
  -f ./minimal_setup_elasticsearch.yaml \
  -f ./with_permissions.yaml \
  -f ./with_optimize.yaml \
  -f ./with_identity_webmodeler.yaml \
  -f ./values_with_backup_restore_elasticsearch.yml
```

Verify in **Operate** that the process instances from before the backup are visible, and in **Optimize**
(after its next import cycle) that its reports/data survived.


# Notes / caveats

- **Local/dev credentials.** Every credential here is a simple hardcoded `username=password` (or `clientId=secret`) pair — DB creds, Keycloak admin, MinIO root, OIDC client secrets. Each manifest's header keeps the "real" imperative secret-creation command commented out. Replace them (and `defaultRoles.admin.users`) before this is anything but a local/dev cluster.
- **CNPG Barman on 1.30.** In-tree `barmanObjectStore` is deprecated (v1.26+) in favour of the Barman Cloud Plugin, but remains the default and works on 1.30. If your operator image no longer bundles `barman-cloud`, install the Barman Cloud Plugin and switch `postgresql-cluster.yaml`/`scheduled-backup.yaml` to an `ObjectStore` CR + `method: plugin`.
- **Single instance, no HA.** `pg-camunda` runs one instance; the orchestration cluster is single-node. Appropriate for local/enablement, not production.
- **No Ingress/TLS.** Everything is reached via `kubectl port-forward`. Exposing this beyond local access requires re-introducing Ingress (and adjusting the Keycloak hostname/`iss` handling).
- **No Optimize / Elasticsearch on the RDBMS track.** The installation above omits Optimize, Management Identity, and Web Modeler. See [Variant: Elasticsearch + Optimize + Identity + Web Modeler](#variant-elasticsearch--optimize--identity--web-modeler) for a parallel track that adds all three, backed by Elasticsearch (via the ECK operator) instead of RDBMS.
