#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BPMN_FILE="${BPMN_FILE:-${SCRIPT_DIR}/test_diagram.bpmn}"

# Connection handling:
#  - If the caller passes --profile / --baseUrl (e.g. --profile=enablement, as in
#    ENABLEMENT_FULL_INSTALLATION_README.MD), it is forwarded untouched and nothing
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

echo "Deploying BPMN file ${BPMN_FILE}"
c8ctl deploy "${BPMN_FILE}" ${CONNECTION_ARGS[@]+"${CONNECTION_ARGS[@]}"} "$@"
