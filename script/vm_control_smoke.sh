#!/usr/bin/env bash
set -euo pipefail

PORT="${TARMAC_VM_CONTROL_PORT:-9473}"
TOKEN="${TARMAC_VM_CONTROL_TOKEN:?Set TARMAC_VM_CONTROL_TOKEN to the token shown in Cache & Diagnostics settings}"
BASE_URL="http://127.0.0.1:${PORT}"

auth_header() {
  printf 'Authorization: Bearer %s' "$TOKEN"
}

echo "GET ${BASE_URL}/health"
curl --fail --silent --show-error "${BASE_URL}/health" | tee /dev/stderr
echo

echo "GET ${BASE_URL}/vm"
curl --fail --silent --show-error "${BASE_URL}/vm" | tee /dev/stderr
echo

echo "POST ${BASE_URL}/vm/boot"
curl --fail --silent --show-error \
  -X POST \
  -H "$(auth_header)" \
  "${BASE_URL}/vm/boot" | tee /dev/stderr
echo

echo "POST ${BASE_URL}/vm/stop"
curl --fail --silent --show-error \
  -X POST \
  -H "$(auth_header)" \
  "${BASE_URL}/vm/stop" | tee /dev/stderr
echo

echo "POST ${BASE_URL}/vm/teardown"
curl --fail --silent --show-error \
  -X POST \
  -H "$(auth_header)" \
  "${BASE_URL}/vm/teardown" | tee /dev/stderr
echo

echo "VM control REST smoke completed."
