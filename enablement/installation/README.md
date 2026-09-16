# Full Camunda 8.9 Installation — Enablement Guides

Two hands-on walkthroughs for deploying a full Camunda 8 stack — Prometheus/Grafana monitoring,
OIDC-based permissions, and scheduled backup/restore — on a local Kubernetes cluster (e.g. kind).
They exist to give hands-on experience with the platform capabilities you need to set up or
troubleshoot a real environment.

Everything is deployed **into the same local cluster** for convenience, but nothing here is **bundled
with the Camunda platform**: secondary storage, the OIDC provider, the backup object store and the
monitoring stack are all external dependencies (see [Design intent](#design-intent)).

> Targets **Camunda 8.9** via Helm chart `camunda-platform` **14.8.3**.
> Chart 14.x deprecates the bundled Bitnami Elasticsearch/Keycloak subcharts and disables them by
> default; they are removed in 8.10 (chart `15.x`, which also requires the Helm v4 CLI). These guides
> use operator-based replacements instead, per Camunda's
> [operator-based infrastructure](https://docs.camunda.io/docs/self-managed/deployment/helm/configure/operator-based-infrastructure/)
> guidance — see [Why operators](#why-operators--and-what-else-you-could-use) for the reasoning and
> for the alternatives you can use instead.

## Contents

- [Choose your track](#choose-your-track)
- [Design intent](#design-intent)
- [Why operators — and what else you could use](#why-operators--and-what-else-you-could-use)
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

## Why operators — and what else you could use

[Design intent](#design-intent) point 2 covers *what* PostgreSQL, the OIDC provider, the backup object
store and the monitoring stack are: external dependencies the `camunda-platform` chart only ever
points at. This section covers the other half of that decision — *how* they get deployed. The chart
has no opinion there, so the choice is yours, and the choice these guides make (Kubernetes operators)
is one of several Camunda supports.

### Camunda's order of preference

1. **Managed or already-existing external services, first.** Camunda's production guidance is to build
   on "primarily managed PostgreSQL and Elasticsearch services, along with external OIDC providers"
   ([operator-based infrastructure](https://docs.camunda.io/docs/self-managed/deployment/helm/configure/operator-based-infrastructure/)).
2. **Vendor-supported operators**, when managed services aren't in your organization's service catalog
   — explicitly the fallback, not the first choice. A local kind cluster has no managed service to
   point at, which is precisely why these guides use operators.
3. **The bundled Bitnami subcharts** — development and testing only. Deprecated *and disabled by
   default* in 8.9, and **removed in 8.10** (chart `15.x`, which also requires the Helm v4 CLI). See
   [Bitnami subcharts](https://docs.camunda.io/docs/self-managed/deployment/helm/chart-parameters/#bitnami-subcharts).

Operators here are therefore not a recommendation *over* managed services — they're what you reach for
when there's no managed service to point at. What they buy over hand-rolled StatefulSets: each is
maintained by the project that owns the technology, with its own support channel and CVE cadence; they
automate failover, backup, and credential/certificate rotation; and they drop the Bitnami/Broadcom
image supply chain entirely.

| Operator                                                                                            | Provides                  | Namespace       | Pinned here | Track   |
|-----------------------------------------------------------------------------------------------------|---------------------------|-----------------|-------------|---------|
| [CloudNativePG](https://cloudnative-pg.io/) (CNPG)                                                  | PostgreSQL (`pg-camunda`) | `postgres`      | 1.30.0      | both    |
| [Keycloak operator](https://www.keycloak.org/operator/installation)                                  | Keycloak (OIDC provider)  | `keycloak`      | 26.3.2      | both    |
| [ECK](https://www.elastic.co/guide/en/cloud-on-k8s/current/index.html)                               | Elasticsearch             | `elasticsearch` | 3.3.2       | ES only |

All three are cluster-scoped (hence the cluster-admin prerequisite); install commands live in each
track's Prerequisites ([RDBMS](./ENABLEMENT_INSTALLATION_RDBMS.MD#prerequisites) ·
[Elasticsearch](./ENABLEMENT_INSTALLATION_ELASTICSEARCH.MD#prerequisites)). This directory follows the
shape of Camunda's own
[operator-based reference manifests](https://github.com/camunda/camunda-deployment-references/tree/stable/8.9/generic/kubernetes/operator-based).

> **Support boundary.** PostgreSQL, Elasticsearch and Keycloak are external dependencies — not Camunda
> products — *regardless of how they're deployed*. Camunda supports their **integration and
> configuration** with the Helm chart; it does not provide operational support for the infrastructure
> itself. That comes from the CNPG/Elastic/Keycloak projects or your managed-service vendor. Choosing
> an operator doesn't move that line.

### Operators are not the only option

If your organization already runs any of these — or is simply better at running them another way — use
what you have. Every row below is a path Camunda documents
([managed services](https://docs.camunda.io/docs/self-managed/deployment/helm/operational-tasks/migration-from-bitnami/bitnami-to-managed-services/)
· [advanced alternatives](https://docs.camunda.io/docs/self-managed/deployment/helm/operational-tasks/migration-from-bitnami/alternatives/)),
and each changes only endpoints and credentials here — never the shape of a values file:

| Instead of              | You could use                                                                                           | What changes in this repo                                                                                                   |
|-------------------------|---------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------|
| CNPG PostgreSQL         | RDS, Aurora PostgreSQL, Cloud SQL, Azure Database for PostgreSQL, a DBA-managed shared cluster          | the JDBC URL in `minimal_setup.yaml` (+ the `identity`/`webmodeler` hosts in `with_identity_webmodeler.yaml`) and the Secret |
| ECK Elasticsearch       | Elastic Cloud, Amazon OpenSearch, self-run OpenSearch, an existing ES cluster                           | the ES URL in `minimal_setup_elasticsearch.yaml` / `with_optimize.yaml` and the Secret                                      |
| the in-cluster Keycloak | Entra ID, Okta, Auth0, Cognito, an existing corporate Keycloak, or Keycloak brokering a SAML/LDAP IdP    | the OIDC endpoint keys in `with_permissions.yaml` / `with_optimize.yaml` and the client secrets                              |
| MinIO                   | S3, GCS, Azure Blob                                                                                     | the `CAMUNDA_DATA_PRIMARYSTORAGE_BACKUP_S3_*` block (and the CNPG/ES snapshot targets)                                       |
| in-cluster anything     | VMs, bare metal, Docker Compose — or Camunda itself outside Kubernetes                                  | endpoints and credentials only                                                                                              |

Reusing existing expertise is reason enough on its own, and it isn't the only one Camunda recognizes:
a policy forbidding operator installs (security or compliance), bare metal without managed-service
access, and consolidating onto a DBA-managed cluster are all called out explicitly.

### What actually has to be true

"Reachable from the cluster" is the main requirement, but not the only one:

- **Network reachability from the Camunda pods.** For secondary storage and the object store this
  really is all the chart needs — a URL plus credentials. Nothing has to run *inside* Kubernetes; it
  only has to be routable from the pods (and for in-cluster services that means a fully-qualified
  Service DNS name — see [Shared architecture](#shared-architecture)).
- **Credentials as a Secret in the Camunda release's own namespace.** Secrets are namespace-scoped and
  the chart reads `existingSecret` only from its own namespace — the entire reason the
  `camunda-secrets*.yaml` copies exist here.
- **A supported version, not merely a reachable one.** Elasticsearch 8.19+ or 9.2+, OpenSearch 2.19+
  or 3.4+, Keycloak 26.x for Management Identity (25.x dropped in 8.9), and for RDBMS secondary
  storage the [RDBMS support policy](https://docs.camunda.io/docs/self-managed/concepts/databases/relational-db/rdbms-support-policy/)
  (PostgreSQL 15–18, 14 deprecated; also MariaDB, MySQL, SQL Server, Oracle, Aurora PostgreSQL, H2).
  Managed PostgreSQL is supported as an *engine*, not per provider. Full matrix:
  [supported environments](https://docs.camunda.io/docs/reference/supported-environments/#component-requirements).
  Bringing your own Elasticsearch also means granting the
  [required ES privileges](https://docs.camunda.io/docs/self-managed/concepts/databases/elasticsearch/elasticsearch-privileges/).
- **The IdP is the exception to "reachable from the cluster."** An OIDC issuer must be reachable by the
  in-cluster pods *and* by your browser, at a URL that resolves to the same string for both —
  otherwise the `iss` claim and the redirect URIs don't line up. Hence the Keycloak here fixes its
  hostname to the cluster-DNS name and both guides ask for an `/etc/hosts` entry. It's also why a
  port-forward-only setup generally needs Keycloak rather than a corporate IdP: Entra ID and Okta
  reject `localhost` redirect URIs.
- **Optimize needs a document store.** It has no RDBMS mode, so no choice of relational database makes
  Optimize work — which is why the two tracks split the way they do.

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
