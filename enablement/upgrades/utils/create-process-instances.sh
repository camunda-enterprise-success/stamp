#!/usr/bin/env bash
set -euo pipefail

ZEEBE_URL="${ZEEBE_URL:-http://localhost:8080}"
PROCESS_DEFINITION_ID="${PROCESS_DEFINITION_ID:-Test_Diagram}"
INSTANCE_COUNT="${INSTANCE_COUNT:-10}"

AUTH_HEADER=()
[[ -n "${AUTH_TOKEN:-}" ]] && AUTH_HEADER=(-H "Authorization: Bearer ${AUTH_TOKEN}")

for i in $(seq 1 "${INSTANCE_COUNT}"); do
  curl -X POST "${ZEEBE_URL}/v2/process-instances" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    "${AUTH_HEADER[@]}" \
    -d "{\"processDefinitionId\":\"${PROCESS_DEFINITION_ID}\",\"variables\":{\"myId\":\"$i\"}}"
done
