#!/usr/bin/env bash
set -euo pipefail

# Fetches a bearer token from an OIDC provider using client_credentials grant.
# Prints only the raw access token to stdout.

TOKEN_URL="${TOKEN_URL:-https://keycloak.consulting-sandbox.camunda.cloud/realms/jens-keycloak-as-oidc/protocol/openid-connect/token}"
CLIENT_ID="${CLIENT_ID:-benchmark-client}"
CLIENT_SECRET="${CLIENT_SECRET:-benchmark-client}"

if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "Error: curl and jq are required." >&2
  exit 1
fi

RESPONSE="$(curl -sS -X POST "${TOKEN_URL}" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=${CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}")"

TOKEN="$(echo "${RESPONSE}" | jq -r '.access_token // empty')"

if [[ -z "${TOKEN}" ]]; then
  echo "Error: Failed to obtain access token." >&2
  echo "Response: ${RESPONSE}" >&2
  exit 1
fi

echo "${TOKEN}"
