# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

**STAMP** (Structured Technical Account Manager Platform Setup) is a modular Helm values overlay library for deploying **Camunda 8.8** in customer environments. It is not a standalone application — it produces no build artifacts. All content is YAML values files, Markdown runbooks, and shell scripts.

Companion repo: [camunda/camunda-deployment-references](https://github.com/camunda/camunda-deployment-references) provides reference IaC; STAMP provides TAM-focused overlays on top of those foundations.

## Local Development Commands

All local Kubernetes setup is in `local/kubernetes/kind-single-region/`, driven by a Makefile:

Creaet/Delete cluster via make (more functions available via `make help`):
```bash
make cluster.create
make cluster.delete
```

## Architecture: Layered Helm Overlays

STAMP's core pattern is composable `-f` flags to `helm upgrade --install`. Overlays are always layered on top of a base values file — never used standalone:

```bash
helm upgrade --install camunda camunda/camunda-platform \
  --version 8.8 \
  --namespace camunda --create-namespace \
  -f base-values/values-orchestration-cluster.yaml \   # always first
  -f base-values/values-local-tls.yaml \               # optional local TLS
  -f backups/s3/s3-backup-values.yaml                  # optional overlay
```

### Conventions

- **`!!!-` prefix** on a directory = planned placeholder, intentionally empty. Do not populate without understanding the full feature scope.
- Resource sizing throughout STAMP is intentionally minimal (demo/POC). Flag this to users before production use.
- The `enablement/` directory contains TAM-facing installation guides and upgrade examples — structured documentation used for unboarding new TAMs, not deployment configs.
- Each backup destination has a paired `*-values.yaml` + `*-runbook.md`; keep them in sync when editing.

### Updating `base-values/values-orchestration-cluster.yaml`

Before deploying to a real cluster, the following must be changed from their defaults:
- `global.ingress.host` (default: `camunda.example.com`)
- Orchestration `ingress.grpc.host`
- `grafana.adminPassword` in the observability values (default: `changeme`)
