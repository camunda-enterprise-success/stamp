#!/usr/bin/env bash
set -euo pipefail

ZEEBE_URL="${ZEEBE_URL:-http://localhost:8080}"
BPMN_FILE="${BPMN_FILE:-$(dirname "$0")/test_diagram.bpmn}"

AUTH_HEADER=()
[[ -n "${AUTH_TOKEN:-}" ]] && AUTH_HEADER=(-H "Authorization: Bearer ${AUTH_TOKEN}")

curl -L -X POST "${ZEEBE_URL}/v2/deployments" \
  -H 'Content-Type: multipart/form-data' \
  -H 'Accept: application/json' \
  "${AUTH_HEADER[@]}" \
  -F "resources=@${BPMN_FILE}"
