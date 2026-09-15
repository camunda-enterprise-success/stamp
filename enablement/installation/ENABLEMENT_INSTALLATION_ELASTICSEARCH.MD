# Installation — Elasticsearch track (+ Optimize, Identity, Web Modeler)

Deploys a Camunda 8.9 orchestration cluster with **Elasticsearch secondary storage** (via the **ECK
operator**, replacing the deprecated bundled Bitnami subchart) and adds **Optimize**, **Management
Identity**, and **Web Modeler** on top, plus Prometheus/Grafana monitoring, OIDC permissions against
an in-cluster Keycloak, and coordinated backup/restore to a local MinIO — all on a local Kubernetes
cluster (e.g. kind).

This guide is **self-contained**: every command from an empty cluster to a restored backup is below.
Shared concepts — design intent, the external-dependency model, the cross-namespace wiring, the file
inventory, and the caveats that apply to both tracks — live in [`README.md`](./README.md).

> Targets **Camunda 8.9** via Helm chart `camunda-platform` **14.8.3**.
> Chart 14.x deprecates the bundled Bitnami Elasticsearch/Keycloak subcharts (removed in 8.10)
> — this guide uses the operator-based replacements instead, following Camunda's
> [migration-from-bitnami](https://docs.camunda.io/docs/self-managed/deployment/helm/operational-tasks/migration-from-bitnami/bitnami-to-operators/) guidance.

Optimize has no RDBMS mode — it only reads Elasticsearch/OpenSearch — so this is a genuinely alternate
storage base, **mutually exclusive with `minimal_setup.yaml`**: never pass both `minimal_setup.yaml`
and `minimal_setup_elasticsearch.yaml` in the same `-f ... -f ...` line. See
[`ENABLEMENT_INSTALLATION_RDBMS.MD`](./ENABLEMENT_INSTALLATION_RDBMS.MD) for the RDBMS-backed track.

## Contents

- [What this track deploys](#what-this-track-deploys)
- [Design decisions on this track](#design-decisions-on-this-track)
- [Prerequisites](#prerequisites)
- Install — [1](#1-install-prometheusgrafana) · [2](#2-install-postgresql) · [3](#3-install-keycloak) · [4](#4-create-realm-clients-and-users) · [5](#5-install-elasticsearch) · [6](#6-add-identity--web-modeler-databases) · [7](#7-copy-secrets) · [8](#8-install-camunda) · [9](#9-create-some-data) · [10](#10-accessing-the-uis)
- [Backup & restore (Elasticsearch model)](#backup--restore-elasticsearch-model) — [Enable backups](#enable-backups) · [Manual backup](#manual-backup) · [Restore](#restore)
- [Caveats on this track](#caveats-on-this-track)

## What this track deploys

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
| Object store (backups)         | External dependency  | Local MinIO, bucket `camunda-backups`                                        | `minio`         | `backup/minio.yaml`                                                       |
| Backup — ES snapshot repos     | External dependency  | Elasticsearch S3 snapshot repos → MinIO (Operate/Tasklist history + Optimize); ES keystore creds baked into the ES cluster | `elasticsearch` | `elasticsearch/elasticsearch-cluster.yaml` (secureSettings), `backup_elasticsearch/register-snapshot-job.yaml` |
| Backup — coordinated + restore | Camunda platform     | One shared backup ID across Zeebe runtime + history + Optimize under an exporter pause; restore overlays | `camunda`       | `values_with_backup_restore_elasticsearch.yml`, `values_to_restore_oc_elasticsearch.yml`, `backup_elasticsearch/` |

Unlike orchestration's own OIDC client (`with_permissions.yaml`'s
`orchestration.security.authentication.oidc`), Optimize/Identity/Web Modeler share one "External
Keycloak" connection block (`global.identity.keycloak.*`, set in `with_optimize.yaml`) plus
per-component client config under `global.identity.auth.*`.

## Design decisions on this track

Read this once — it explains two settings that are easy to get wrong and that cause crash-loops rather
than clean errors. [Step 4](#4-create-realm-clients-and-users) and [step 8](#8-install-camunda) link
back here instead of repeating it.

**1. Every OIDC client any component needs is created explicitly, up front** by
`keycloak/create-realm-and-clients.sh` — following Camunda's own documented
["Option 1: prepare an existing realm"](https://docs.camunda.io/docs/self-managed/deployment/helm/configure/authentication-and-authorization/external-keycloak/#configure-components-using-oidc)
pattern for external Keycloak, rather than relying on Management Identity's startup-time
self-provisioning for anything beyond its own client lookup. That self-provisioning path (Camunda's
alternative "Option 2: let Management Identity create a realm") was tried first while building this
guide and found to be non-idempotent in practice: Identity's `KeycloakPresetInitializer` always
attempts to *create* its resource-server clients unconditionally (no existence check), so it
409-crashes on every restart after the first success — and even a from-scratch attempt intermittently
produced a client with `authorizationServicesEnabled: true` that a later initialization step then
refused to manage, crash-looping regardless.

Explicit, scripted client creation sidesteps that entirely: every client already exists with the right
settings before `helm upgrade --install` ever runs, and every credential — the Keycloak admin
password, Identity's/Optimize's client secrets — is consolidated into one Secret,
`camunda-credentials`, using the exact key names from Camunda's own external-Keycloak example, written
by the same script that creates the matching Keycloak clients so the two can never drift out of sync.

**2. `global.identity.auth.type` must be `"GENERIC"`, not `"KEYCLOAK"`** (set in
`with_optimize.yaml`). Pre-creating the clients alone does **not** avoid the 409 crash-loop — only
`GENERIC` does. `KEYCLOAK` activates Identity's own `keycloak` Spring profile, which runs
`KeycloakPresetInitializer` on every startup; `GENERIC` skips that initializer entirely and talks to
Keycloak as a plain OIDC provider via the explicit
`publicIssuerUrl`/`issuerBackendUrl`/`authUrl`/`tokenUrl`/`jwksUrl` in `with_optimize.yaml`. This was
discovered the hard way: pre-created clients still 409-crashed Identity until `auth.type` was switched
to `GENERIC`. If you switch back to `KEYCLOAK` and let Identity self-provision, expect the same
fragility — see the [troubleshooting callout in step 8](#8-install-camunda) for the recovery procedure.

As a consequence, Management Identity recognizes its admin user via
`global.identity.auth.identity.initialClaimName`/`initialClaimValue` rather than the chart's
`identity.firstUser` mechanism (which requires KEYCLOAK-type admin-API access).

## Prerequisites

Tools required locally:

- `helm`, `kubectl` (aliased as `k`), `kubens` (from `kubectx`)
- `c8ctl` — used by the utility scripts under `../utils/` to deploy BPMN and create process instances
- Cluster-admin rights (the CNPG, Keycloak and ECK operators are cluster-scoped)
- Ability to add an `/etc/hosts` entry on the machine you browse from (for Keycloak login, since port-forwarding is used)

A running Kubernetes cluster. Locally, create one via:

```bash
make cluster.create   # from deployment-references-repo/local/kubernetes/kind-single-region/
```

Install the three operators this track needs once per cluster (versions pinned to match the images in
the manifests — check for current versions before production):

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

Namespace provenance:

- `camunda` is created from `cluster.create`.
- `keycloak` and `elastic-system` were created above.
- `postgres` is created by its own manifest in [step 2](#2-install-postgresql); `elasticsearch` (the actual ES cluster's namespace) is created by [step 5](#5-install-elasticsearch).

Everything below is idempotent — if you already ran the
[RDBMS track](./ENABLEMENT_INSTALLATION_RDBMS.MD) on this same cluster, the shared `kubectl apply`s
here are no-ops.

---

# Install

Run every command from `enablement/installation/`.

## 1. Install Prometheus/Grafana

Optional, and independent of everything else on this track — skip it if you don't want monitoring.
Monitoring first, so Prometheus is ready to scrape as soon as Camunda starts. The
`kube-prometheus-stack` chart installs Prometheus, Grafana, AlertManager, and the Prometheus Operator
into the `default` namespace.

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

> To also wire Zeebe's own Prometheus scraping, add `-f ./with_monitoring_alerting.yaml` to the Camunda
> install in [step 8](#8-install-camunda) — it composes on top of this track's storage base unchanged.

## 2. Install PostgreSQL

One CNPG `Cluster` (`pg-camunda`, single instance) in its own `postgres` namespace, bootstrapped
with the `camunda` database (unused on this Elasticsearch-backed track, but harmless — it's the
same shared manifest as the RDBMS track) plus login roles/databases for Keycloak, Identity, and Web
Modeler. The manifest creates the `postgres` namespace and the credential secrets it needs.

```bash
kubectl apply -f ./postgresql/postgresql-cluster.yaml
kubectl wait --for=condition=Ready --timeout=600s cluster/pg-camunda -n postgres
```

## 3. Install Keycloak

The Keycloak Custom Resource — single instance, no Ingress, backed by the `keycloak` database from
[step 2](#2-install-postgresql). Admin credentials (`admin`/`admin`) are passed in via `bootstrapAdmin`.

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

## 4. Create realm, clients, and users

Scripted via `kcadm.sh` inside the Keycloak pod (`kubectl exec`, no port-forward needed). Creates:

- the `camunda-platform` realm and the `operator`/`task-user` roles;
- the interactive `orchestration` client (secret written to the K8s secret `camunda-keycloak-client-secrets`);
- the service-account `benchmark-client` (used by the utility scripts, audience `orchestration`);
- `camunda-identity` — Management Identity's own client: confidential, service account roles on,
  Authorization explicitly off, plus the `realm-management` service-account roles
  (`manage-clients`/`manage-realm`/`manage-users`, needed even under GENERIC auth for Identity's own
  runtime user/role management calls), per
  [Camunda's guidance for this client](https://docs.camunda.io/docs/next/self-managed/components/management-identity/configuration/connect-to-an-existing-keycloak/);
- `optimize`, and `web-modeler` (public, no secret);
- the consolidated `camunda-credentials` Secret (Keycloak admin password, the `admin` first-user's
  password, Identity's/Optimize's client secrets);
- an `admin`/`admin` first user for Management Identity's own login, and example users `operator`,
  `tasklist-user`, `admin` (all `username`=`password`).

Idempotent — safe to re-run. This is the same script the RDBMS track runs; every client is always
created on both tracks. See [Design decisions](#design-decisions-on-this-track) for why clients are
prepared here rather than self-provisioned by Identity.

```bash
cd keycloak && ./create-realm-and-clients.sh && cd ..
```

## 5. Install Elasticsearch

Single-node ECK-managed Elasticsearch, in its own `elasticsearch` namespace (same "external
dependency gets its own namespace" convention as `postgres`/`keycloak`). Requires the ECK operator
from [Prerequisites](#prerequisites).

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

## 6. Add Identity + Web Modeler databases

Adds the `identity` and `webmodeler` databases to the **same** shared CNPG instance from
[step 2](#2-install-postgresql) (`pg-camunda`) — no new Postgres instance needed; the login roles
themselves were already created by that step's cluster manifest. Just the two new `Database` CRs:

```bash
kubectl apply -f ./postgresql/postgresql-databases-identity-webmodeler.yaml
```

## 7. Copy secrets

The Camunda release can only read `existingSecret`s from its own (`camunda`) namespace, so the
Identity and Web Modeler database credentials are duplicated into it (Elasticsearch's own credential
was already copied by the script in [step 5](#5-install-elasticsearch)):

```bash
kubectl apply -f ./camunda-secrets-identity-webmodeler.yaml
```

## 8. Install Camunda

Compose the Elasticsearch base with the three layers (order matters — `with_identity_webmodeler.yaml`
depends on the `global.identity.auth.*` block `with_optimize.yaml` establishes):

```bash
helm upgrade --install \
  camunda camunda-platform \
  --repo https://helm.camunda.io \
  --version 14.8.3 \
  --namespace camunda \
  -f ./minimal_setup_elasticsearch.yaml \
  -f ./with_permissions.yaml \
  -f ./with_optimize.yaml \
  -f ./with_identity_webmodeler.yaml
```

```bash
kubectl get pods -n camunda -w
```

> **If Identity doesn't reach `Ready`**, check in this order:
> 1. Did [step 4](#4-create-realm-clients-and-users) actually run? Every client Identity needs
>    (`camunda-identity`, `orchestration`, `optimize`, `web-modeler`), the `realm-management`
>    service-account roles on `camunda-identity`, and the `camunda-credentials` Secret must already
>    exist in Keycloak *before* this step.
> 2. Is `with_optimize.yaml`'s `global.identity.auth.type` still `"GENERIC"`? `"KEYCLOAK"` makes
>    Identity 409-crash on `Client ... already exists` — see
>    [Design decisions](#design-decisions-on-this-track).
> 3. **Recovery** from a 409 (or a `NotFoundException ... not managed by Identity because it has
>    authorization services enabled`): delete the conflicting client(s) from the realm
>    (`kcadm.sh delete clients/<id> -r camunda-platform`) and delete the Identity pod to retry from a
>    clean slate.

## 9. Create some data

Deploy a test BPMN process and create process instances, so Optimize has data to import. Needs the
Keycloak port-forward from [step 3](#3-install-keycloak) running (for OAuth) and a Zeebe Gateway
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
client [step 4](#4-create-realm-clients-and-users) prepared, per `with_permissions.yaml`'s
`orchestration.security.authentication.oidc`. `c8ctl add profile` registers the `benchmark-client`
service-account credentials once, resolving OAuth against the in-cluster Keycloak on every subsequent
call. Allow a minute or two for Optimize's own import cycle to pick up the new instances — it doesn't
appear immediately, unlike Operate/Tasklist.

## 10. Accessing the UIs

```bash
# Operate
kubectl port-forward -n camunda svc/camunda-operate 8081:80
# open http://localhost:8081

# Optimize
kubectl port-forward -n camunda svc/camunda-optimize 8090:80
# open http://localhost:8090/optimize

# Web Modeler (the restapi service also serves the web frontend - there's no separate webapp Service)
kubectl port-forward -n camunda svc/camunda-web-modeler-restapi 8070:80
# open http://localhost:8070/modeler

# Management Identity
kubectl port-forward -n camunda svc/camunda-identity 8084:80
# open http://localhost:8084/identity

# Grafana (only if you did step 1)
kubectl port-forward -n default svc/metrics-grafana 3000:80
# open http://localhost:3000
```

Log in to Management Identity, Optimize, and Web Modeler with `admin`/`admin` — the same Keycloak
user [step 4](#4-create-realm-clients-and-users) creates for every other login in this guide.
Management Identity recognizes it as an admin via
`global.identity.auth.identity.initialClaimName`/`initialClaimValue` (`with_optimize.yaml`) matching
that user's `preferred_username` claim, not the chart's `identity.firstUser` mechanism — see
[Design decisions](#design-decisions-on-this-track). Operate/Tasklist (via Orchestration's own login)
use the separate `operator`/`tasklist-user`/`admin` realm users step 4 always creates.

---

# Backup & restore (Elasticsearch model)

Backup/restore for this track follows Camunda's [Elasticsearch/OpenSearch backup model](https://docs.camunda.io/docs/self-managed/operational-guides/backup-restore/),
which is deliberately **different from the [RDBMS track's model](./ENABLEMENT_INSTALLATION_RDBMS.MD#backup--restore-rdbms-model)**.
There, the two storage halves are backed up on independent staggered schedules and re-aligned at
restore via the exporter position. Here, **all components share ONE backup ID** and are snapshotted
together under a single **exporter pause**, because Elasticsearch is the secondary storage for
Operate/Tasklist history **and** for Optimize. One coordinated backup covers three snapshot streams,
all landing in the local MinIO bucket `camunda-backups`:

| Stream                          | Trigger                                                  | Lands in                                                                     |
|---------------------------------|----------------------------------------------------------|------------------------------------------------------------------------------|
| Zeebe runtime (primary storage) | `POST camunda-zeebe-gateway:9600/actuator/backupRuntime` | `s3://camunda-backups/oc-runtime` (Camunda-managed)                          |
| Operate/Tasklist history        | `POST camunda-zeebe-gateway:9600/actuator/backupHistory` | ES repo `camunda-backups-webapps` → `s3://camunda-backups/web-apps-indices`  |
| **Optimize**                    | `POST camunda-optimize:8092/actuator/backups`            | ES repo `camunda-backups-optimize` → `s3://camunda-backups/optimize-indices` |

## Enable backups

**1. Install the object store** (same MinIO manifest as the RDBMS track — a no-op if you already have it):

```bash
kubectl apply -f ./backup/minio.yaml
```

**2. Give Elasticsearch its S3 credentials.** `elasticsearch/elasticsearch-cluster.yaml` already carries
the `secureSettings` block and the `elasticsearch-s3-backup-credentials` Secret that load the MinIO
access/secret keys into the Elasticsearch keystore (needed for any s3-type snapshot repository). If you
installed Elasticsearch at [step 5](#5-install-elasticsearch) **before** this backup wiring existed,
re-apply the manifest so ECK picks up the keystore change (it reloads secure settings automatically):

```bash
kubectl apply -f ./elasticsearch/elasticsearch-cluster.yaml
```

**3. Copy the MinIO credentials into the `camunda` namespace** (the orchestration release reads them for
the runtime backup; Secrets are namespace-scoped — same reasoning as [step 7](#7-copy-secrets)):

```bash
kubectl apply -f ./backup_elasticsearch/minio-credentials-camunda.yaml
```

**4. Add the backup values layer** by re-running the [step 8](#8-install-camunda) install with one extra
`-f` (`values_with_backup_restore_elasticsearch.yml` — the Elasticsearch counterpart of the RDBMS
track's `values_with_backup_restore.yml`; it configures the runtime backup store, the history repo
name `CAMUNDA_DATA_BACKUP_REPOSITORY_NAME`, and Optimize's repo name `CAMUNDA_OPTIMIZE_BACKUP_REPOSITORY_NAME`):

```bash
helm upgrade --install \
  camunda camunda-platform \
  --repo https://helm.camunda.io \
  --version 14.8.3 \
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
> runtime-backup cron can't coordinate with the history/Optimize snapshots. So backups on this track
> are taken on demand by the Job below. (You can schedule them by wrapping that Job in a Kubernetes
> `CronJob` that bumps the backup ID each run.)

## Manual backup

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

## Restore

Recreates the system from a given backup ID. The Elasticsearch snapshots (history + Optimize) and the
Zeebe runtime backup are restored in that order, tied together by the shared backup ID. Set
`camunda-backup-config`'s `BACKUP_ID` to the one you're restoring first:

```bash
kubectl create configmap camunda-backup-config -n camunda \
  --from-literal=BACKUP_ID=<the-backup-id> \
  --dry-run=client -o yaml | kubectl apply -f -
```

### R1. Stop everything that writes to Elasticsearch

A snapshot can't restore over an open index, and nothing may re-create the indices mid-restore — so
scale the orchestration cluster (the exporter) and Optimize (its importer) to zero:

```bash
kubectl scale statefulset camunda-zeebe -n camunda --replicas=0
kubectl scale deployment camunda-optimize -n camunda --replicas=0
```

### R2. Delete the Camunda indices

Preview first, then delete (`camunda-*`, `operate-*`, `tasklist-*`, and `optimize-*`):

```bash
kubectl apply -f ./backup_elasticsearch/delete-camunda-indices-dryrun-job.yaml
kubectl logs -f job/delete-camunda-indices-dryrun -n camunda
kubectl apply -f ./backup_elasticsearch/delete-camunda-indices-job.yaml
kubectl wait --for=condition=complete --timeout=300s job/delete-camunda-indices -n camunda
```

### R3. Restore the Elasticsearch snapshots

History + Optimize, for the backup ID. The repositories are still registered from install, but
re-applying the register Job is harmless and required if the ES cluster itself was ever reset:

```bash
kubectl apply -f ./backup_elasticsearch/register-snapshot-job.yaml   # idempotent; safe to re-run
kubectl wait --for=condition=complete --timeout=120s job/register-snapshot-job -n camunda
kubectl apply -f ./backup_elasticsearch/restore/es-snapshot-restore-job.yaml
kubectl wait --for=condition=complete --timeout=1800s job/camunda-es-snapshot-restore -n camunda
kubectl logs -f job/camunda-es-snapshot-restore -n camunda
```

### R4. Restore the Zeebe runtime

Delete the broker's PVC so the restore runs against an empty data directory, then redeploy in restore
mode. `values_to_restore_oc_elasticsearch.yml` sets `SPRING_PROFILES_ACTIVE=restore` +
`ZEEBE_RESTORE=true` and passes the backup ID explicitly via `ZEEBE_RESTORE_FROM_BACKUP_ID`
(Elasticsearch, unlike the RDBMS, doesn't record the exporter position for the engine to auto-discover
it); layering `minimal_setup_elasticsearch.yaml` underneath keeps the ES wiring and disables
Optimize/Identity/Web Modeler for the restore run:

```bash
kubectl delete pvc data-camunda-zeebe-0 -n camunda
helm upgrade --install \
  camunda camunda-platform \
  --repo https://helm.camunda.io \
  --version 14.8.3 \
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

### R5. Return to normal operation

Redeploy the full stack (with the backup layer, so backups keep working) to leave restore mode and
bring Optimize/Identity/Web Modeler back — Optimize re-reads the restored `optimize-*` indices:

```bash
helm upgrade --install \
  camunda camunda-platform \
  --repo https://helm.camunda.io \
  --version 14.8.3 \
  --namespace camunda \
  -f ./minimal_setup_elasticsearch.yaml \
  -f ./with_permissions.yaml \
  -f ./with_optimize.yaml \
  -f ./with_identity_webmodeler.yaml \
  -f ./values_with_backup_restore_elasticsearch.yml
```

Verify in **Operate** that the process instances from before the backup are visible, and in **Optimize**
(after its next import cycle) that its reports/data survived.

# Caveats on this track

In addition to the [shared notes / caveats](./README.md#notes--caveats):

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
- **Don't let Management Identity self-provision its OIDC clients** — see
  [Design decisions](#design-decisions-on-this-track) for why, and the callout in
  [step 8](#8-install-camunda) for recovery if it happens.
