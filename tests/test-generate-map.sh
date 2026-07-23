#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT HUP INT TERM
OUTPUT="${TMP}/derp-map.json"

DERP_HOSTNAME=derp.example.com \
DERP_PORT=8443 \
STUN_PORT=3478 \
DERP_REGION_ID=901 \
DERP_REGION_CODE=test \
DERP_REGION_NAME='Test Region' \
sh "${ROOT}/scripts/generate-derp-map.sh" "${OUTPUT}" >/dev/null

grep -F '"HostName": "derp.example.com"' "${OUTPUT}" >/dev/null
grep -F '"DERPPort": 8443' "${OUTPUT}" >/dev/null
grep -F '"STUNPort": 3478' "${OUTPUT}" >/dev/null
grep -F '"901"' "${OUTPUT}" >/dev/null

if command -v jq >/dev/null 2>&1; then
  jq -e '.derpMap.Regions["901"].Nodes[0].DERPPort == 8443' "${OUTPUT}" >/dev/null
fi

if DERP_HOSTNAME=derp.example.com DERP_PORT=bad \
  sh "${ROOT}/scripts/generate-derp-map.sh" "${OUTPUT}" >/dev/null 2>&1; then
  echo "FAIL: invalid port should fail" >&2
  exit 1
fi

echo "DERP map tests passed"
