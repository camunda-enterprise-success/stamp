#!/usr/bin/env bash
# Copies the ECK-generated "elasticsearch-es-elastic-user" secret (created by
# elasticsearch-cluster.yaml in the "elasticsearch" namespace) into the "camunda" namespace, so the
# Camunda platform release (../minimal_setup_elasticsearch.yaml, ../with_optimize.yaml) can read it
# as an existingSecret - Secrets are namespace-scoped, same reasoning as ../camunda-secrets.yaml,
# but this one can't be a static inlined dev value because ECK generates the "elastic" superuser's
# password itself at cluster-creation time.
#
# Idempotent - safe to re-run (e.g. after ECK rotates the password).
set -euo pipefail

PASSWORD=$(kubectl get secret elasticsearch-es-elastic-user -n elasticsearch -o jsonpath='{.data.elastic}' | base64 --decode)

kubectl create secret generic elasticsearch-es-elastic-user -n camunda \
  --from-literal=elastic="$PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
