# Camunda Upgrade Enablement

Upgrading Camunda installations falls under the TAM responsibilities and is something a TAM will encounter multiple times with their customers. Therefore it's a skill to have.

Three difficulty levels are available:

- **Easy**: Single Zeebe Broker, Gateway and Operate with Basic Auth — from 8.6 to 8.9
- **Medium**: 3 Zeebe Brokers, Gateway, Operate, Tasklist, Optimize with existing Keycloak — from 8.6 to 8.9
- **Hard**: All components with external IDP, with Multi-tenancy — from 8.6 to 8.9

---

## How Helm Upgrades Work

Camunda is installed and upgraded via `helm upgrade --install`. This command is **idempotent**: it installs the chart if it doesn't exist, or upgrades it in-place if it does. You should think of it as "apply this desired state".

Helm performs a rolling update — Kubernetes gradually replaces old pods with new ones. Stateless components (Operate, Tasklist, Connectors) restart quickly.
Helm handles the ordering via the StatefulSet update strategy, but you need to wait for all pods to reach `Running` before assuming the upgrade is done.

> Always upgrade **one minor version at a time** (8.6 → 8.7 → 8.8 → 8.9). Skipping versions is not supported and can corrupt Zeebe's data migration.

TODO: Add docs link


## FAQ

**Q: Why start from 8.6?**
A: Understanding the upgrade procedure is a core skill that needs hands-on practice. Extra minor versions = extra training. It also provides context on how the platform evolved — which is beneficial to understand. (Earlier versions only had gRPC which is cumbersome, so didn't go further back)


---

## Easy

**Scenario**: Single Zeebe Broker, Gateway, and Operate with Basic Auth. No OIDC, 1 partition, 1 replica. This is the simplest possible upgrade path.

### Deploy Camunda 8.6

```bash
helm upgrade --install camunda camunda/camunda-platform \
  -f ./easy/11.12.3-values-easy.yml \
  --version 11.12.3 \
  --create-namespace -n camunda
```

### Create some test data

Important: port-forward port 8080

Deploy a BPMN process and create process instances so you have real data to verify after each upgrade.

```bash
../utils/deploy-bpmn.sh
../utils/create-process-instances.sh
```

`deploy-bpmn.sh` uploads `test_diagram.bpmn` via the Zeebe REST API. `create-process-instances.sh` starts 10 instances of that process. Both scripts read `ZEEBE_URL` from the environment (defaults to `http://localhost:8080`).

### Verify in Operate

Open Operate and log in with `demo`/`demo`. Confirm process instances are visible before proceeding. This is your baseline to compare against after each upgrade step.

### Upgrade to Camunda 8.7

The 8.7 values file is structurally identical to 8.6.

```bash
helm upgrade --install camunda camunda/camunda-platform \
  -f ./easy/solution/12.8.4-values-easy.yml \
  --version 12.8.4 \
  --create-namespace -n camunda
```

Wait for all pods to be `Running`, then verify in Operate that the previously created instances are still visible.

### Upgrade to Camunda 8.8

This is the structurally most significant upgrade. The values file switches from `zeebe:` to `orchestration:`. The chart version jumps from 12.x to 13.x.

```bash
helm upgrade --install camunda camunda/camunda-platform \
  -f ./easy/solution/13.7.0-values-easy.yml \
  --version 13.7.0 \
  --create-namespace -n camunda
```

After the rollout, check that the orchestration pod starts cleanly. Then verify in Operate that historical instances survived the migration.

### Upgrade to Camunda 8.9

8.9 adds the `secondaryStorage` field, which tells the orchestration engine that historical data (completed instances, decisions) lives in Elasticsearch rather than in Zeebe's local storage. This enables horizontal scaling of history queries independently from processing.

```bash
helm upgrade --install camunda camunda/camunda-platform \
  -f ./easy/solution/14.0.0-values-easy.yml \
  --version 14.0.0 \
  --create-namespace -n camunda
```

---

## Medium

**Scenario**: 3 Zeebe Brokers with 3 partitions and 3 replicas, plus Operate, Tasklist, and Optimize, backed by an external Keycloak for OIDC.

This scenario adds complexity in two dimensions:

1. **Multi-broker Zeebe**: The StatefulSet upgrade takes longer because each broker migrates independently and must finish before the next starts. With 3 brokers, expect the rollout to take 3× as long as the easy scenario.
2. **External Keycloak**: You must ensure the OIDC client configurations (client IDs, secrets, redirect URIs) in the values file match what is registered in Keycloak. A mismatch means components will fail authentication silently or with cryptic errors.

> TODO: Replace the consulting Keycloak with a locally deployed one so this works independently of the sandbox environment.

### Deploy Camunda 8.7

```bash
helm upgrade --install camunda camunda/camunda-platform \
  -f ./medium/11.12.3-values-medium.yml \
  --version 11.2.3 \
  --create-namespace -n camunda
```

### Create some test data

With an external Keycloak you need an access token to authenticate against the Zeebe REST API.

```bash
export AUTH_TOKEN=$(../utils/get-token.sh)
../utils/deploy-bpmn.sh
../utils/create-process-instances.sh
```

`get-token.sh` fetches a bearer token via OAuth2 client credentials grant from the configured Keycloak instance. The token is passed to the deployment and instance-creation scripts via the `AUTH_TOKEN` environment variable.

### Upgrade to Camunda 8.8

```bash
# TODO: add 13.x values file for the medium scenario
```

### Upgrade to Camunda 8.9

```bash
# TODO: add 14.x values file for the medium scenario
```

---

## Hard

**Scenario**: Full component stack with external Keycloak and multi-tenancy enabled.

Multi-tenancy adds a further constraint on top of the medium scenario: all data (process definitions, instances, decisions) is scoped to a tenant ID. When upgrading, the Zeebe migration must correctly associate tenants with all existing records. If multi-tenancy is enabled mid-upgrade without the right migration flags, historical data can become inaccessible.

Key things to understand before attempting:
- The default tenant (`<default>`) is automatically created; custom tenants must be pre-provisioned in Identity before instances are created.
- In Camunda <8.8 tenant information was stored in identity's postgresql. Since Camunda 8.8, for the orchestration cluster, tenants are stored in the orchestration cluster (and elasticsearch).

> This scenario is not yet fully documented. Contributions welcome.
