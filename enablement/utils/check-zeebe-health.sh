#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/auth-utils.sh"

ZEEBE_URL="${ZEEBE_URL:-http://localhost:8080}"

AUTH_ARGS=()
build_auth_header_args
AUTH_MODE="$(describe_auth_mode)"

CURL_ARGS=(
  --silent
  --show-error
  -X GET
  "${ZEEBE_URL}/v1/topology"
  -H "Content-Type: application/json"
  --write-out
  $'\nHTTP_STATUS:%{http_code}'
)

if [[ ${#AUTH_ARGS[@]} -gt 0 ]]; then
  CURL_ARGS+=("${AUTH_ARGS[@]}")
fi

echo "Checking Zeebe topology at ${ZEEBE_URL}/v1/topology"
echo "Auth mode: ${AUTH_MODE}"

RESPONSE="$(curl "${CURL_ARGS[@]}")"
print_response_or_fail "${RESPONSE}"
