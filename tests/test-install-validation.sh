#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT HUP INT TERM

if DERP_HOSTNAME='bad host' sh "${ROOT}/install.sh" >"${TMP}/out" 2>"${TMP}/err"; then
  echo "FAIL: invalid hostname should fail" >&2
  exit 1
fi
grep -F 'must be a DNS hostname' "${TMP}/err" >/dev/null

if DERP_HOSTNAME=derp.example.com DERP_PORT=70000 \
  sh "${ROOT}/install.sh" >"${TMP}/out" 2>"${TMP}/err"; then
  echo "FAIL: invalid port should fail" >&2
  exit 1
fi
grep -F 'must be between 1 and 65535' "${TMP}/err" >/dev/null

echo "installer validation tests passed"
