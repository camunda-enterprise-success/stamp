Collection of skills, TAMs need to be able to do.
...

---

## Utils (`utils/`)

Shared helper scripts for interacting with a running Camunda cluster. All scripts connect to `ZEEBE_URL` (default: `http://localhost:8080`) and support three auth modes controlled by environment variables:

### Scripts

**`utils/get-token.sh`** — Fetch a JWT from an OIDC provider using client credentials.
```bash
export AUTH_TOKEN=$(./utils/get-token.sh)
```

**`utils/check-zeebe-health.sh`** — Check Status
```bash
export AUTH_TOKEN=$(./utils/get-token.sh) && ./utils/check-zeebe-health.sh
```

**`utils/deploy-bpmn.sh`** — Deploy a BPMN file to the cluster.
```bash
export AUTH_TOKEN=$(./utils/get-token.sh) && ./utils/deploy-bpmn.sh
```

**`utils/create-process-instances.sh`** — Create 10 process instances
```bash
export AUTH_TOKEN=$(./utils/get-token.sh) && ./utils/create-process-instances.sh
```


