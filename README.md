# STAMP
### Structured Technical Account Manager Platform Setup

[![Camunda](https://img.shields.io/badge/Camunda-FC5D0D)](https://www.camunda.com/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](./LICENSE)

STAMP is a companion repository to [camunda/camunda-deployment-references](https://github.com/camunda/camunda-deployment-references). Where that repo provides reference architectures using Terraform and infrastructure-as-code, STAMP provides:

- **`values.yaml` overlays** for quickly enabling common integrations on top of a running Camunda Helm deployment
- **Runbooks** for deploying and configuring supporting tools (observability, secret managers, CI/CD)

> ⚠️ STAMP is intended for TAM-assisted deployments and proof-of-concept engagements. It is not a production-hardened reference. Always review and adapt configs to your customer's requirements.

---

## Structure

```
STAMP/
├── aws/
│   ├── configs/          # values.yaml overlays for AWS-native scenarios
│   └── runbooks/         # Step-by-step operational guides for AWS
├── azure/
│   ├── configs/
│   └── runbooks/
├── gcp/
│   ├── configs/
│   └── runbooks/
└── generic/              # Cloud-agnostic configs and runbooks
    ├── configs/
    └── runbooks/
```

Config directories follow the naming pattern `{category}-{provider-or-tool}/` to mirror the convention used in `camunda-deployment-references`.

---

## Quick Reference

### Backup

| Provider | Config | Runbook |
|---|---|---|
| AWS S3 | [aws/configs/backup-s3](./aws/configs/backup-s3/values.yaml) | [aws/runbooks/backup-s3.md](./aws/runbooks/backup-s3.md) |
| Azure Blob | [azure/configs/backup-blob](./azure/configs/backup-blob/values.yaml) | [azure/runbooks/backup-blob.md](./azure/runbooks/backup-blob.md) |
| GCS | [gcp/configs/backup-gcs](./gcp/configs/backup-gcs/values.yaml) | [gcp/runbooks/backup-gcs.md](./gcp/runbooks/backup-gcs.md) |
| MinIO | [generic/configs/backup-minio](./generic/configs/backup-minio/values.yaml) | [generic/runbooks/backup-minio.md](./generic/runbooks/backup-minio.md) |

### Secret Managers

| Provider | Config | Runbook |
|---|---|---|
| AWS Secrets Manager | [aws/configs/secrets-aws-secrets-manager](./aws/configs/secrets-aws-secrets-manager/values.yaml) | [aws/runbooks/secrets-aws-secrets-manager.md](./aws/runbooks/secrets-aws-secrets-manager.md) |
| Azure Key Vault | [azure/configs/secrets-key-vault](./azure/configs/secrets-key-vault/values.yaml) | [azure/runbooks/secrets-key-vault.md](./azure/runbooks/secrets-key-vault.md) |
| GCP Secret Manager | [gcp/configs/secrets-gcp-secret-manager](./gcp/configs/secrets-gcp-secret-manager/values.yaml) | [gcp/runbooks/secrets-gcp-secret-manager.md](./gcp/runbooks/secrets-gcp-secret-manager.md) |
| HashiCorp Vault | [generic/configs/secrets-hashicorp-vault](./generic/configs/secrets-hashicorp-vault/values.yaml) | [generic/runbooks/secrets-hashicorp-vault.md](./generic/runbooks/secrets-hashicorp-vault.md) |

### Authentication

| Provider | Config | Runbook |
|---|---|---|
| Microsoft Entra ID | [generic/configs/auth-entra-id](./generic/configs/auth-entra-id/values.yaml) | [generic/runbooks/auth-entra-id.md](./generic/runbooks/auth-entra-id.md) |

### Observability

| Scenario | Runbook |
|---|---|
| Prometheus + Grafana | [generic/runbooks/observability-prometheus-grafana.md](./generic/runbooks/observability-prometheus-grafana.md) |

### CI/CD

| Tool | Runbook |
|---|---|
| GitHub Actions | [generic/runbooks/cicd-github-actions.md](./generic/runbooks/cicd-github-actions.md) |
| ArgoCD | [generic/runbooks/cicd-argocd.md](./generic/runbooks/cicd-argocd.md) |

---

## Usage

STAMP configs are designed to be layered on top of your base `values.yaml` using Helm's `-f` flag:

```bash
helm upgrade --install camunda camunda/camunda-platform \
  -f values.yaml \
  -f stamp/aws/configs/backup-s3/values.yaml \
  -f stamp/generic/configs/auth-entra-id/values.yaml
```

Later files take precedence over earlier ones. Start with your base values, then layer in STAMP configs for each integration.

---

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). Stub runbooks marked with 🚧 are priority targets for new contributions.

## Related

- [camunda/camunda-deployment-references](https://github.com/camunda/camunda-deployment-references) — reference architectures
- [Camunda Helm Chart docs](https://docs.camunda.io/docs/self-managed/setup/install/)
- [Camunda Self-Managed docs](https://docs.camunda.io/docs/self-managed/about-self-managed/)

## License

Apache-2.0