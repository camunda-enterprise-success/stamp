#!/usr/bin/env bash
set -euo pipefail

ZEEBE_URL="${ZEEBE_URL:-http://localhost:8080}"

AUTH_HEADER=()
[[ -n "${AUTH_TOKEN:-}" ]] && AUTH_HEADER=(-H "Authorization: Bearer ${AUTH_TOKEN}")

curl -X GET \
  "${ZEEBE_URL}/v1/topology" \
  -H "Content-Type: application/json" \
  "${AUTH_HEADER[@]}"
