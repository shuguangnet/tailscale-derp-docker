#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

for script in \
  "${ROOT}/install.sh" \
  "${ROOT}/manage.sh" \
  "${ROOT}/docker-entrypoint.sh" \
  "${ROOT}/scripts/generate-derp-map.sh" \
  "${ROOT}/scripts/tailscale-onekey-join-linux.sh" \
  "${ROOT}/tests/test-join.sh" \
  "${ROOT}/tests/test-generate-map.sh" \
  "${ROOT}/tests/test-install-validation.sh" \
  "${ROOT}/tests/test-manager.sh"
do
  sh -n "${script}"
done

sh "${ROOT}/tests/test-join.sh"
sh "${ROOT}/tests/test-generate-map.sh"
sh "${ROOT}/tests/test-install-validation.sh"
sh "${ROOT}/tests/test-manager.sh"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${ROOT}/install.sh" "${ROOT}/manage.sh" "${ROOT}"/scripts/*.sh "${ROOT}"/tests/*.sh
fi

echo "all tests passed"
