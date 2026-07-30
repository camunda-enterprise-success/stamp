#!/usr/bin/env bash
set -euo pipefail

PROCESS_DEFINITION_ID="${PROCESS_DEFINITION_ID:-Test_Diagram}"
INSTANCE_COUNT="${INSTANCE_COUNT:-10}"

echo "Creating ${INSTANCE_COUNT} process instance(s) for ${PROCESS_DEFINITION_ID}"
for i in $(seq 1 "${INSTANCE_COUNT}"); do
  echo "Submitting instance ${i}/${INSTANCE_COUNT}"
  c8ctl create pi --id="${PROCESS_DEFINITION_ID}" --variables="{\"myId\":\"$i\"}" "$@"
done
