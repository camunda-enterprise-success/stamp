#!/bin/bash
# Manual, on-demand backup - takes ONE backup of both halves right now, independent of the
# hourly schedules (scheduled-backup.yaml for Postgres at :00, CAMUNDA_DATA_PRIMARYSTORAGE_
# BACKUP_SCHEDULE at :10 for Zeebe). Both land in the same MinIO bucket "camunda-backups".
#
# Order follows the RDBMS backup guide's recommendation: take the secondary storage (Postgres)
# backup first, then the primary storage (Zeebe runtime) backup. No exporter pause is needed -
# Zeebe records the exporter position in the RDBMS and aligns the two at restore time.
#   https://docs.camunda.io/docs/self-managed/operational-guides/backup-restore/rdbms/rdbms-backup/
#
# Prerequisites: the platform is installed and running (pg-camunda Ready, Zeebe running,
# MinIO up). Run from anywhere with kubectl access to the cluster.

set -euo pipefail

CAMUNDA_NAMESPACE=${CAMUNDA_NAMESPACE:-camunda}
POSTGRES_NAMESPACE=${POSTGRES_NAMESPACE:-postgres}
CLUSTER=${CLUSTER:-pg-camunda}
GATEWAY_MGMT=${GATEWAY_MGMT:-http://camunda-zeebe-gateway:9600}
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="${CLUSTER}-manual-${STAMP}"

echo "==========================================================="
echo "1/2  Postgres (secondary storage) backup via CNPG Barman"
echo "==========================================================="
echo "Creating Backup '$BACKUP_NAME' ..."
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: ${BACKUP_NAME}
  namespace: ${POSTGRES_NAMESPACE}
spec:
  cluster:
    name: ${CLUSTER}
  method: barmanObjectStore
EOF

echo "Waiting for the Postgres backup to complete (up to 20 min) ..."
for i in $(seq 1 120); do
  PHASE=$(kubectl get backup "$BACKUP_NAME" -n "$POSTGRES_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  echo "  [postgres] phase: ${PHASE:-<pending>}"
  case "$PHASE" in
    completed) echo "  -> Postgres backup completed."; break ;;
    failed)    echo "  -> Postgres backup FAILED."; kubectl describe backup "$BACKUP_NAME" -n "$POSTGRES_NAMESPACE"; exit 1 ;;
  esac
  [ "$i" = "120" ] && { echo "  -> timed out"; exit 1; }
  sleep 10
done

echo ""
echo "==========================================================="
echo "2/2  Zeebe (primary storage) runtime backup"
echo "==========================================================="
echo "Triggering POST ${GATEWAY_MGMT}/actuator/backupRuntime (backupId auto-generated) ..."
# The gateway management API (:9600) isn't exposed by default, so run curl from an ephemeral
# in-cluster pod that can resolve the Service.
kubectl run camunda-manual-backup-"$STAMP" \
  -n "$CAMUNDA_NAMESPACE" \
  --rm -i --restart=Never \
  --image=curlimages/curl:latest \
  --command -- /bin/sh -c "
    set -e
    echo 'Requesting runtime backup ...'
    # POST with NO body and NO Content-Type header: with continuous/scheduled backups enabled
    # the backupId must NOT be supplied (the engine generates it and returns 202). Adding a
    # JSON content-type with an empty body, or supplying a backupId, both yield HTTP 400.
    curl -sS --fail -X POST '${GATEWAY_MGMT}/actuator/backupRuntime'
    echo
    echo 'Current backup state:'
    curl -sS '${GATEWAY_MGMT}/actuator/backupRuntime/state'
    echo
  "

echo ""
echo "==========================================================="
echo "Done. Verify:"
echo "  kubectl get backups -n $POSTGRES_NAMESPACE"
echo "  # Zeebe runtime backup state (from an in-cluster pod or port-forward):"
echo "  curl $GATEWAY_MGMT/actuator/backupRuntime/state"
echo "  # Objects in MinIO (mc alias set + mc ls local/camunda-backups --recursive)"
echo "==========================================================="
