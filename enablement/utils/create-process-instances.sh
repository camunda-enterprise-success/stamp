#!/usr/bin/env bash
set -euo pipefail

PROCESS_DEFINITION_ID="${PROCESS_DEFINITION_ID:-Test_Diagram}"
INSTANCE_COUNT="${INSTANCE_COUNT:-10}"

# Connection handling:
#  - If the caller passes --profile / --baseUrl (e.g. --profile=enablement, as in
#    installation/README.md), it is forwarded untouched and nothing
#    is injected — that path is unchanged.
#  - Otherwise fall back to the unprotected local API. The Speedrun install
#    (real_minimal_setup.yaml sets orchestration.security.authentication.unprotectedApi:
#    true) needs no OAuth at all, just the zeebe-gateway port-forward on 8080.
#    Passing --baseUrl explicitly also bypasses whatever profile happens to be active.
C8_BASE_URL="${C8_BASE_URL:-http://localhost:8080/v2}"
CONNECTION_ARGS=(--baseUrl="${C8_BASE_URL}")
for arg in "$@"; do
  case "${arg}" in
    --profile|--profile=*|--baseUrl|--baseUrl=*) CONNECTION_ARGS=(); break ;;
  esac
done

echo "Creating ${INSTANCE_COUNT} process instance(s) for ${PROCESS_DEFINITION_ID}"
for i in $(seq 1 "${INSTANCE_COUNT}"); do
  echo "Submitting instance ${i}/${INSTANCE_COUNT}"
  c8ctl create pi --id="${PROCESS_DEFINITION_ID}" --variables="{\"myId\":\"$i\"}" \
    ${CONNECTION_ARGS[@]+"${CONNECTION_ARGS[@]}"} "$@"
done
