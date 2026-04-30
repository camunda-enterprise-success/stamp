#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/auth-utils.sh"

ZEEBE_URL="${ZEEBE_URL:-http://localhost:8080}"
PROCESS_DEFINITION_ID="${PROCESS_DEFINITION_ID:-Test_Diagram}"
INSTANCE_COUNT="${INSTANCE_COUNT:-10}"

AUTH_ARGS=()
build_auth_header_args
AUTH_MODE="$(describe_auth_mode)"

echo "Creating ${INSTANCE_COUNT} process instance(s) for ${PROCESS_DEFINITION_ID}"
echo "Target endpoint: ${ZEEBE_URL}/v2/process-instances"
echo "Auth mode: ${AUTH_MODE}"

for i in $(seq 1 "${INSTANCE_COUNT}"); do
  CURL_ARGS=(
    --silent
    --show-error
    -X POST
    "${ZEEBE_URL}/v2/process-instances"
    -H 'Content-Type: application/json'
    -H 'Accept: application/json'
    -d "{\"processDefinitionId\":\"${PROCESS_DEFINITION_ID}\",\"variables\":{\"myId\":\"$i\"}}"
    --write-out
    $'\nHTTP_STATUS:%{http_code}'
  )

  if [[ ${#AUTH_ARGS[@]} -gt 0 ]]; then
    CURL_ARGS+=("${AUTH_ARGS[@]}")
  fi

  echo "Submitting instance ${i}/${INSTANCE_COUNT}"
  RESPONSE="$(curl "${CURL_ARGS[@]}")"
  print_response_or_fail "${RESPONSE}"
done
