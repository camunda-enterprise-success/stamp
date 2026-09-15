# Full Camunda 8.9 Installation — Enablement Guides

Two hands-on walkthroughs for deploying a full Camunda 8 stack — Prometheus/Grafana monitoring,
OIDC-based permissions, and scheduled backup/restore — on a local Kubernetes cluster (e.g. kind).
They exist to give hands-on experience with the platform capabilities you need to set up or
troubleshoot a real environment.

Everything is deployed **into the same local cluster** for convenience, but nothing here is **bundled
with the Camunda platform**: secondary storage, the OIDC provider, the backup object store and the
monitoring stack are all external dependencies (see [Design intent](#design-intent)).

> Targets **Camunda 8.9** via Helm chart `camunda-platform` **14.8.3**.
> Chart 14.x deprecates the bundled Bitnami Elasticsearch/Keycloak subcharts (removed in 8.10)
> — these guides use the operator-based replacements instead, following Camunda's
> [migration-from-bitnami](https://docs.camunda.io/docs/self-managed/deployment/helm/operational-tasks/migration-from-bitnami/) guidance.

## Contents

- [Choose your track](#choose-your-track)
- [Design intent](#design-intent)
- [Shared architecture](#shared-architecture)
- [Repository map](#repository-map)
- [Notes / caveats](#notes--caveats)

## Choose your track

|                      | RDBMS track                                                    | Elasticsearch track                                                        |
|----------------------|----------------------------------------------------------------|----------------------------------------------------------------------------|
| **Secondary storage**| PostgreSQL via the CNPG operator                               | Elasticsearch via the ECK operator                                         |
| **Components**       | Orchestration cluster (Zeebe / Operate / Tasklist)             | + Optimize, Management Identity, Web Modeler                               |
| **Operators needed** | CNPG, Keycloak                                                 | CNPG, Keycloak, **ECK**                                                    |
| **Authentication**   | In-cluster Keycloak (OIDC), realm scripted                     | In-cluster Keycloak (OIDC), realm scripted                                 |
| **Monitoring**       | Prometheus/Grafana layer                                       | Prometheus/Grafana layer (optional here)                                   |
| **Backup model**     | Two independent staggered schedules, re-aligned at restore via the exporter position | One shared backup ID, all three snapshot streams under a single exporter pause |
| **Steps**            | 8 install steps + backup/restore                               | 10 install steps + backup/restore                                          |
| **Guide**            | **[ENABLEMENT_INSTALLATION_RDBMS.MD](./ENABLEMENT_INSTALLATION_RDBMS.MD)** | **[ENABLEMENT_INSTALLATION_ELASTICSEARCH.MD](./ENABLEMENT_INSTALLATION_ELASTICSEARCH.MD)** |

Each guide is **self-contained** — from an empty cluster to a restored backup, without jumping back
here. Both are idempotent, so you can run the second one on the same cluster afterwards; the shared
`kubectl apply`s simply become no-ops.

> **The two storage bases are mutually exclusive.** Never pass both `-f minimal_setup.yaml` and
> `-f minimal_setup_elasticsearch.yaml` in the same `helm upgrade` command. Pick RDBMS *or*
> Elasticsearch. If you want Optimize, you need the Elasticsearch track: Optimize has no RDBMS mode —
> it only reads Elasticsearch/OpenSearch.

## Design intent

Beyond the walkthroughs themselves, this directory demonstrates two things about a Camunda 8.9
installation:

**1. It's built up iteratively, one capability at a time.**
`minimal_setup.yaml` on its own is already a complete, working orchestration cluster — single node,
RDBMS secondary storage, basic auth. Each further values file (`with_permissions.yaml`,
`with_monitoring_alerting.yaml`, `values_with_backup_restore.yml`) is an *additive layer* on top of it,
composed via extra `-f` flags (Helm merges them in order, later files win).

- You can stop after any layer and have a working cluster.
- You don't need permissions to get monitoring, or monitoring to get backups.
- The walkthroughs apply all layers together for convenience, but each layer is independently
  understandable — see the `Layer` column in each guide's component table, and each values file's own
  header comment, for what it adds on its own.
- The same holds on the Elasticsearch track, with `minimal_setup_elasticsearch.yaml` as the base and
  `with_optimize.yaml` / `with_identity_webmodeler.yaml` as further layers.

**2. PostgreSQL, the OIDC provider, backup storage, and monitoring are external dependencies — not
part of the core Camunda platform.**
The `camunda-platform` Helm chart never deploys or owns any of them; it is only ever *configured to
talk to* them (a JDBC URL, an issuer URL, an S3 endpoint, a scrape target).

- These guides happen to run all four in-cluster via operators/plain manifests — a local/dev
  convenience.
- In a real deployment they'd typically be a managed database (RDS/CloudSQL), a corporate IdP
  (Entra ID, Okta, Auth0, …), cloud object storage (S3/GCS), and a hosted observability stack.
- Swapping any of them out only ever changes endpoints and credentials, never the shape of the Camunda
  values files.

The component tables in each guide make this explicit with a `Kind` column: "External dependency" vs.
"Camunda platform" (the chart's own values-file layers).

## Shared architecture

The Helm values-file slices for the `camunda-platform` chart itself stay flat at the top of this
directory (they're all composed together in one `-f ... -f ...` command anyway). "External" components'
manifests and scripts live in their own subdirectory: `postgresql/`, `keycloak/`, `elasticsearch/`,
`monitoring/`, `backup/` (+ `backup/restore/`), `backup_elasticsearch/` (+ `backup_elasticsearch/restore/`).

**Each external dependency runs in its own namespace** (`minio`, `postgres`, `keycloak`,
`elasticsearch`). The Camunda platform release is alone in `camunda`. Cross-namespace wiring uses
fully-qualified Service DNS:

- Camunda + Keycloak → Postgres: `pg-camunda-rw.postgres.svc.cluster.local:5432`
- Camunda + Postgres(Barman) → MinIO: `http://minio.minio.svc.cluster.local:9000`
- Camunda → Keycloak (OIDC): `keycloak-service.keycloak.svc.cluster.local:18080`
- Camunda → Elasticsearch (ES track): `elasticsearch-es-http.elasticsearch.svc.cluster.local:9200`

**One shared PostgreSQL instance.** `postgresql/postgresql-cluster.yaml` provisions a single CNPG
`Cluster` named `pg-camunda` carrying every database any track needs: `camunda` (orchestration
secondary storage, used only on the RDBMS track), `keycloak`, and — added by
`postgresql/postgresql-databases-identity-webmodeler.yaml` on the Elasticsearch track — `identity` and
`webmodeler`.

**Secrets are duplicated per namespace.** Kubernetes Secrets are namespace-scoped and the Camunda
chart can only read an `existingSecret` from its own namespace, so shared credentials are copied into
each consuming namespace (e.g. `minio-credentials` exists in `minio`, `postgres`, and `camunda`). The
`camunda-secrets*.yaml` files at the top of this directory are exactly those copies.

## Repository map

Helm values files for the `camunda-platform` chart (composed with `-f`):

| File                                          | Track | What it is                                                                        |
|-----------------------------------------------|-------|-----------------------------------------------------------------------------------|
| `minimal_setup.yaml`                          | RDBMS | Base: single node, RDBMS secondary storage, basic auth                            |
| `minimal_setup_elasticsearch.yaml`            | ES    | Base: single node, Elasticsearch secondary storage, basic auth                    |
| `with_permissions.yaml`                       | both  | Switches auth to OIDC; roles, mapping rules, authorizations                        |
| `with_monitoring_alerting.yaml`               | both  | Prometheus scraping on Zeebe                                                      |
| `with_optimize.yaml`                          | ES    | Optimize + the shared "External Keycloak" connection block for Optimize/Identity/Web Modeler |
| `with_identity_webmodeler.yaml`               | ES    | Management Identity + Web Modeler                                                 |
| `values_with_backup_restore.yml`              | RDBMS | Zeebe runtime backup → MinIO, continuous + hourly cron                            |
| `values_to_restore_oc.yml`                    | RDBMS | Restore-mode overlay for the Zeebe runtime                                        |
| `values_with_backup_restore_elasticsearch.yml`| ES    | Runtime backup store + history/Optimize snapshot repo names                        |
| `values_to_restore_oc_elasticsearch.yml`      | ES    | Restore-mode overlay, backup ID passed explicitly                                 |
| `camunda-secrets.yaml`                        | RDBMS | RDBMS + MinIO credential copies in the `camunda` namespace                         |
| `camunda-secrets-identity-webmodeler.yaml`    | ES    | Identity + Web Modeler DB credential copies (Elasticsearch's own is copied by script) |

Dependency manifests and scripts:

| Path                                                        | Track | What it is                                                              |
|-------------------------------------------------------------|-------|-------------------------------------------------------------------------|
| `postgresql/postgresql-cluster.yaml`                        | both  | CNPG `Cluster` `pg-camunda` + `camunda`/`keycloak` DBs + Barman→MinIO    |
| `postgresql/postgresql-databases-identity-webmodeler.yaml`  | ES    | `identity` + `webmodeler` DBs on the same instance                      |
| `keycloak/keycloak-instance.yaml`                           | both  | Keycloak CR (single instance, no Ingress)                               |
| `keycloak/create-realm-and-clients.sh`                      | both  | Realm, all OIDC clients, roles, users, `camunda-credentials` Secret     |
| `elasticsearch/elasticsearch-cluster.yaml`                  | ES    | ECK `Elasticsearch` CR + S3 keystore `secureSettings` for snapshots     |
| `elasticsearch/copy-elastic-secret.sh`                      | ES    | Copies ECK's generated `elastic` password into `camunda`                |
| `monitoring/`                                               | both  | `kube-prometheus-stack` values, Grafana secret template, alert bundle   |
| `backup/minio.yaml`                                         | both  | MinIO Deployment/Service/PVC/credentials + bucket-creation Job          |
| `backup/scheduled-backup.yaml`                              | RDBMS | CNPG `ScheduledBackup` (hourly at `:00`)                                |
| `backup/manual-backup.sh`                                   | RDBMS | On-demand: Postgres backup, then Zeebe runtime backup                   |
| `backup/restore/postgresql-cluster-restore.yaml`            | RDBMS | CNPG `Cluster` in recovery mode — **set `recoveryTarget` before applying** |
| `backup_elasticsearch/minio-credentials-camunda.yaml`       | ES    | MinIO credential copy in `camunda`                                      |
| `backup_elasticsearch/register-snapshot-job.yaml`           | ES    | Registers the two ES S3 snapshot repositories                           |
| `backup_elasticsearch/take-backup-job.yaml`                 | ES    | Coordinated backup: pause → history → Optimize → runtime → resume       |
| `backup_elasticsearch/delete-camunda-indices*-job.yaml`     | ES    | Index deletion before a restore (dry-run + real)                        |
| `backup_elasticsearch/restore/es-snapshot-restore-job.yaml` | ES    | Restores the history + Optimize snapshots for a backup ID               |
| `../utils/deploy-bpmn.sh`, `../utils/create-process-instances.sh` | both | `c8ctl` wrappers used by the "create some data" step               |

## Notes / caveats

These apply to both tracks; each guide adds its own track-specific list.

- **Local/dev credentials.** Every credential here is a simple hardcoded `username=password` (or `clientId=secret`) pair — DB creds, Keycloak admin, MinIO root, OIDC client secrets. Each manifest's header keeps the "real" imperative secret-creation command commented out. Replace them (and `defaultRoles.admin.users`) before this is anything but a local/dev cluster.
- **CNPG Barman on 1.30.** In-tree `barmanObjectStore` is deprecated (v1.26+) in favour of the Barman Cloud Plugin, but remains the default and works on 1.30. If your operator image no longer bundles `barman-cloud`, install the Barman Cloud Plugin and switch `postgresql-cluster.yaml`/`scheduled-backup.yaml` to an `ObjectStore` CR + `method: plugin`.
- **Single instance, no HA.** `pg-camunda` runs one instance; the orchestration cluster is single-node; Elasticsearch (ES track) is single-node. Appropriate for local/enablement, not production.
- **No Ingress/TLS.** Everything is reached via `kubectl port-forward`. Exposing this beyond local access requires re-introducing Ingress (and adjusting the Keycloak hostname/`iss` handling).
