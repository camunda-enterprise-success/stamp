#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BPMN_FILE="${BPMN_FILE:-${SCRIPT_DIR}/test_diagram.bpmn}"

echo "Deploying BPMN file ${BPMN_FILE}"
c8ctl deploy "${BPMN_FILE}" "$@"
