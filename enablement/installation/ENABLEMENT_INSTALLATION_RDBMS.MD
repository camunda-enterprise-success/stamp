# Installation — RDBMS track (PostgreSQL secondary storage)

Deploys a Camunda 8.9 orchestration cluster with **PostgreSQL (RDBMS) secondary storage**,
Prometheus/Grafana monitoring, OIDC permissions against an in-cluster Keycloak, and scheduled
backup/restore to a local MinIO — all on a local Kubernetes cluster (e.g. kind).

This guide is **self-contained**: every command from an empty cluster to a restored backup is below.
Shared concepts — design intent, the external-dependency model, the cross-namespace wiring, the file
inventory, and the caveats that apply to both tracks — live in [`README.md`](./README.md).

> Targets **Camunda 8.9** via Helm chart `camunda-platform` **14.8.3**.
> Chart 14.x deprecates the bundled Bitnami Elasticsearch/Keycloak subcharts (removed in 8.10)
> — this guide uses the operator-based replacements instead, following Camunda's
> [migration-from-bitnami](https://docs.camunda.io/docs/self-managed/deployment/helm/operational-tasks/migration-from-bitnami/) guidance.

**No Optimize on this track.** Optimize has no RDBMS mode — it only reads Elasticsearch/OpenSearch —
so Optimize, Management Identity, and Web Modeler are not part of this installation. See
[`ENABLEMENT_INSTALLATION_ELASTICSEARCH.MD`](./ENABLEMENT_INSTALLATION_ELASTICSEARCH.MD) for the track
that adds all three. The two storage bases are mutually exclusive: never pass both
`-f minimal_setup.yaml` and `-f minimal_setup_elasticsearch.yaml` in the same command.

## Contents

- [What this track deploys](#what-this-track-deploys)
- [Prerequisites](#prerequisites)
- Install — [1](#1-install-prometheusgrafana) · [2](#2-install-minio) · [3](#3-install-postgresql) · [4](#4-install-keycloak) · [5](#5-create-realm-clients-and-users) · [6](#6-install-camunda) · [7](#7-create-some-data) · [8](#8-enable-scheduled-backups)
- [Accessing the UIs](#accessing-the-uis)
- [Backup & restore (RDBMS model)](#backup--restore-rdbms-model) — [Manual backup](#manual-backup) · [Restore](#restore) · [Coordination](#backup--restore-coordination)
- [Caveats on this track](#caveats-on-this-track)

## What this track deploys

The deployment is built from **layered Helm values files** (composed with multiple `-f` flags — Helm
merges them in order, later files win) plus a few resources applied directly with `kubectl` to
provision dependencies.

`Kind` distinguishes systems the `camunda-platform` chart is merely *configured to talk to*
("External dependency") from the chart's own values-file layers ("Camunda platform"). `Layer` numbers
the four root values files in the order they're additively composed — you can stop after any layer and
have a working cluster (see [Design intent](./README.md#design-intent)); an external dependency's
`Layer` is the first one that needs it.

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

Install the two operators this track needs once per cluster (versions pinned to match the images in
the manifests — check for current versions before production):

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
```

Namespace provenance:

- `camunda` is created from `cluster.create`.
- `minio` and `postgres` are created by their own manifests in steps [2](#2-install-minio) / [3](#3-install-postgresql).
- `keycloak` was created above.

Everything below is idempotent — if you already ran the
[Elasticsearch track](./ENABLEMENT_INSTALLATION_ELASTICSEARCH.MD) on this same cluster, the shared
`kubectl apply`s here are no-ops.

---

# Install

Run every command from `enablement/installation/`.

## 1. Install Prometheus/Grafana

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

## 2. Install MinIO

The local object store all backups are written to (in its own `minio` namespace). The manifest creates the `minio` namespace, a Deployment + Service, a PVC, the `minio-credentials` secret, and a Job that creates the `camunda-backups` bucket.

```bash
kubectl apply -f ./backup/minio.yaml
kubectl rollout status deployment/minio -n minio --timeout=180s
kubectl logs -n minio -l job-name=minio-create-bucket
```

## 3. Install PostgreSQL

One CNPG `Cluster` (`pg-camunda`, single instance) in its own `postgres` namespace, bootstrapped with the `camunda` database, plus a `Database` CR adding Keycloak's `keycloak` database on the same instance. Its `spec.backup` points Barman at MinIO for the PostgreSQL backups. The manifest creates the `postgres` namespace and the credential secrets it needs.

```bash
kubectl apply -f ./postgresql/postgresql-cluster.yaml
kubectl wait --for=condition=Ready --timeout=600s cluster/pg-camunda -n postgres
```

## 4. Install Keycloak

The Keycloak Custom Resource — single instance, no Ingress, backed by the `keycloak` database from
[step 3](#3-install-postgresql). Admin credentials (`admin`/`admin`) are passed in via `bootstrapAdmin`.

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

## 5. Create realm, clients, and users

Scripted via `kcadm.sh` inside the Keycloak pod (`kubectl exec`, no port-forward needed). Creates the `camunda-platform` realm; the `operator`/`task-user` roles; the interactive `orchestration` client (secret written to the K8s secret `camunda-keycloak-client-secrets`); the service-account `benchmark-client` (used by the utility scripts); `camunda-identity`, `optimize`, and `web-modeler` (unused on this track, but harmless to leave in place — they're what the [Elasticsearch track](./ENABLEMENT_INSTALLATION_ELASTICSEARCH.MD) needs); and example users `operator`, `tasklist-user`, `admin` (all `username`=`password`). Idempotent — safe to re-run.

```bash
cd keycloak && ./create-realm-and-clients.sh && cd ..
```

## 6. Install Camunda

First create the credential secrets the Camunda release reads from its **own** namespace
(copies of the RDBMS + MinIO credentials, since Secrets can't be read across namespaces):

```bash
kubectl apply -f ./camunda-secrets.yaml
```

Then compose the full configuration with the four `-f` flags (merged in order — each one is an additive capability layer, see [Design intent](./README.md#design-intent)): `minimal_setup.yaml` (base cluster) → `with_permissions.yaml` (+ OIDC permissions) → `with_monitoring_alerting.yaml` (+ monitoring) → `values_with_backup_restore.yml` (+ backup):

```bash
helm upgrade --install \
  camunda camunda-platform \
  --repo https://helm.camunda.io \
  --version 14.8.3 \
  --namespace camunda \
  -f ./minimal_setup.yaml \
  -f ./with_permissions.yaml \
  -f ./with_monitoring_alerting.yaml \
  -f ./values_with_backup_restore.yml
```

> Each `-f` here is optional and additive — dropping the last one, two, or three flags (and skipping the corresponding external dependency's setup step above) still gives you a fully working cluster, just without that layer's capability. `-f ./minimal_setup.yaml` alone, against nothing but the PostgreSQL from [step 3](#3-install-postgresql), is already a complete, working basic-auth orchestration cluster — everything from here on is opt-in.

Wait for all pods to be `Running` (note: there is **no** Elasticsearch pod in this setup):

```bash
kubectl get pods -n camunda -w
```

## 7. Create some data

Deploy a test BPMN process and create process instances, so you have data to verify survives a backup/restore.
Needs the Keycloak port-forward from [step 4](#4-install-keycloak) running (for OAuth) and a Zeebe Gateway port-forward:

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

## 8. Enable scheduled backups

The Zeebe runtime side is already scheduled hourly by `values_with_backup_restore.yml` (`CAMUNDA_DATA_PRIMARYSTORAGE_BACKUP_SCHEDULE="0 10 * * * *"`, continuous), firing at `:10` past the hour. Add the PostgreSQL side — an hourly CNPG `ScheduledBackup` firing at `:00`, 10 minutes earlier:

```bash
kubectl apply -f ./backup/scheduled-backup.yaml
kubectl get scheduledbackup -n postgres
```

Both `schedule` values are real cron expressions, so the 10-minute stagger is wall-clock anchored and holds every cycle — see [Backup / restore coordination](#backup--restore-coordination) for why the order (and not just an exporter pause) is what matters here.

## Accessing the UIs

```bash
# Grafana (default namespace, from step 1)
kubectl port-forward -n default svc/metrics-grafana 3000:80
# open http://localhost:3000

# Operate (camunda namespace, from step 6)
kubectl port-forward -n camunda svc/camunda-operate 8081:80
# open http://localhost:8081

# MinIO console (to inspect backup objects)
kubectl port-forward -n minio svc/minio 9001:9001
# open http://localhost:9001  (login: minioadmin / minioadmin)
```

Use Operate to confirm the process instances from [step 7](#7-create-some-data) — this is what you check against after a restore.

---

# Backup & restore (RDBMS model)

The two storage layers are backed up **independently, on staggered schedules**, and re-align at
restore time via the **exporter position**. This is deliberately different from the Elasticsearch
track's model (one shared backup ID under a single exporter pause) — see
[Coordination](#backup--restore-coordination) for the mechanism, and read it before your first restore.

## Manual backup

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

## Restore

Recreates the system from the MinIO backups, per the [RDBMS restore guide](https://docs.camunda.io/docs/self-managed/operational-guides/backup-restore/rdbms/rdbms-restore/). The two storage layers are restored independently and re-align via the exporter position.

### R1. Stop Camunda and delete its runtime data

```bash
helm uninstall camunda -n camunda
kubectl delete pvc -n camunda -l app.kubernetes.io/instance=camunda
```

### R2. Delete PostgreSQL and restore it from Barman

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

### R3. Restore the Zeebe runtime

Redeploy in restore mode. `values_to_restore_oc.yml` sets `SPRING_PROFILES_ACTIVE=restore` + `ZEEBE_RESTORE=true` and points at the MinIO primary-storage backup; layering `minimal_setup.yaml` underneath keeps the RDBMS secondary-storage wiring and disables the other components.

```bash
helm upgrade --install \
  camunda camunda-platform \
  --repo https://helm.camunda.io \
  --version 14.8.3 \
  --namespace camunda \
  -f ./minimal_setup.yaml \
  -f ./values_to_restore_oc.yml
```

The restore runs against an **empty** Zeebe data directory (step R1 deleted the PVC; the redeploy creates a fresh one).
It restores the partition data, then the container exits — and because it's a StatefulSet, Kubernetes restarts it,
the restart sees the now-restored (non-empty) directory, and the pod enters `CrashLoopBackOff` logging `data directory ... is not empty`.
**This is the expected success state** — the restore completed on the first run. Confirm by inspecting the restored data and/or the first run's logs.

Catch the success line (it's on the run BEFORE the current crash-looping one):

```bash
kubectl logs -n camunda camunda-zeebe-0 --previous | grep -iE "Restoring RDBMS backups|restored"
```

If instead you see `No backup found` or a range-mismatch failure (`No usable range found for partition N with from=..., exportedPosition=...`,
or the older-style `last log position ... is before the required exported position ...`), the RDBMS was recovered past the newest Zeebe checkpoint
— go back to [step R2](#r2-delete-postgresql-and-restore-it-from-barman), tighten `recoveryTarget` in `postgresql-cluster-restore.yaml` to an earlier bounded point (see above),
delete the cluster+PVC (and clear the WAL-archive prefix per the note above), and redo the recovery. For a bounded Zeebe-side restore,
set `ZEEBE_RESTORE_TO_TIMESTAMP` in `values_to_restore_oc.yml` (must not precede the recovered RDBMS state).

Do **not** proceed to step R4 until the restore has actually completed.

### R4. Return to normal operation

Redeploy with the standard values (Keycloak + realm must be back — re-run steps [4](#4-install-keycloak)/[5](#5-create-realm-clients-and-users) if you also reset those) to disable restore mode:

```bash
helm upgrade --install \
  camunda camunda-platform \
  --repo https://helm.camunda.io \
  --version 14.8.3 \
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
- **Restore point (mandatory, not a fallback)** — when recovering the RDBMS, never leave `recoveryTarget` unset / rely on "latest" WAL replay, even though the backup schedules are staggered correctly. Zeebe's restore resolves each retained backup into a `RangeEntry(start, end)` — a pair of checkpoint timestamps — converts that into a log-position range, and requires the RDBMS's recorded exporter position to fall inside `[firstLogPosition(start), checkpointPosition(end)]` for at least one retained range. Staggering the two backup *schedules* only guarantees the Zeebe backup starts after the Postgres one does; it says nothing about how far WAL replay continues afterwards. On a busy cluster "latest" usually still lands inside a range because a Zeebe checkpoint follows soon after every burst of activity; on an idle/low-traffic cluster (this local teaching setup) "latest" can keep replaying WAL well past the newest Zeebe checkpoint with nothing to stop it, pushing the exporter position outside every retained range. Always pin `recoveryTarget` explicitly in `postgresql-cluster-restore.yaml` — either `targetTime` set a couple of minutes after the Postgres `:00` tick and before the Zeebe `:10` tick (the default), or `backupID` + `targetImmediate: true` pinned to one known-good completed `Backup` object. See [step R2](#r2-delete-postgresql-and-restore-it-from-barman) above.

# Caveats on this track

In addition to the [shared notes / caveats](./README.md#notes--caveats):

- **No Optimize, Management Identity, or Web Modeler.** Optimize only reads Elasticsearch/OpenSearch, so it cannot run on RDBMS secondary storage. The [Elasticsearch track](./ENABLEMENT_INSTALLATION_ELASTICSEARCH.MD) adds all three on an Elasticsearch base.
- **The Grafana alert bundle still carries Elasticsearch rules** (see the note in [step 1](#1-install-prometheusgrafana)) — harmless here, nothing emits those metrics.
