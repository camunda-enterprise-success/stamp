#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/auth-utils.sh"

ZEEBE_URL="${ZEEBE_URL:-http://localhost:8080}"
BPMN_FILE="${BPMN_FILE:-$(dirname "$0")/test_diagram.bpmn}"

AUTH_ARGS=()
build_auth_header_args
AUTH_MODE="$(describe_auth_mode)"

CURL_ARGS=(
  --silent
  --show-error
  -L
  -X POST
  "${ZEEBE_URL}/v2/deployments"
  -H 'Content-Type: multipart/form-data'
  -H 'Accept: application/json'
  -F "resources=@${BPMN_FILE}"
  --write-out
  $'\nHTTP_STATUS:%{http_code}'
)

if [[ ${#AUTH_ARGS[@]} -gt 0 ]]; then
  CURL_ARGS+=("${AUTH_ARGS[@]}")
fi

echo "Deploying BPMN file ${BPMN_FILE}"
echo "Target endpoint: ${ZEEBE_URL}/v2/deployments"
echo "Auth mode: ${AUTH_MODE}"

RESPONSE="$(curl "${CURL_ARGS[@]}")"
print_response_or_fail "${RESPONSE}"
