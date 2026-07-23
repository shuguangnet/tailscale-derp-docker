#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT HUP INT TERM
MOCK_BIN="${TMP}/bin"
LOG="${TMP}/calls.log"
mkdir -p "${MOCK_BIN}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  grep -F -- "$1" "${LOG}" >/dev/null || fail "missing log entry: $1"
}

cat >"${MOCK_BIN}/tailscale" <<'EOF'
#!/bin/sh
printf 'tailscale' >>"${TEST_LOG}"
printf ' <%s>' "$@" >>"${TEST_LOG}"
printf '\n' >>"${TEST_LOG}"
EOF

cat >"${MOCK_BIN}/systemctl" <<'EOF'
#!/bin/sh
printf 'systemctl' >>"${TEST_LOG}"
printf ' <%s>' "$@" >>"${TEST_LOG}"
printf '\n' >>"${TEST_LOG}"
EOF

cat >"${MOCK_BIN}/hostname" <<'EOF'
#!/bin/sh
printf 'mock-host\n'
EOF
cat >"${MOCK_BIN}/id" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -u ]; then
  printf '0\n'
else
  /usr/bin/id "$@"
fi
EOF
chmod +x "${MOCK_BIN}"/*

if PATH="${MOCK_BIN}:/usr/bin:/bin" sh "${ROOT}/scripts/tailscale-onekey-join-linux.sh" \
  >"${TMP}/missing.out" 2>"${TMP}/missing.err"; then
  fail "missing auth key should fail"
fi
grep -F "Usage:" "${TMP}/missing.err" >/dev/null || fail "usage was not printed"

: >"${LOG}"
TEST_LOG="${LOG}" PATH="${MOCK_BIN}:/usr/bin:/bin" \
  TS_AUTHKEY=tskey-test TS_HOSTNAME=node-one TS_EXTRA_ARGS='--advertise-exit-node --ssh' \
  sh "${ROOT}/scripts/tailscale-onekey-join-linux.sh" >/dev/null

assert_contains 'systemctl <enable> <--now> <tailscaled>'
assert_contains 'tailscale <up> <--auth-key=tskey-test> <--hostname=node-one> <--accept-dns=false> <--advertise-exit-node> <--ssh>'
assert_contains 'tailscale <status>'
assert_contains 'tailscale <netcheck>'

cat >"${MOCK_BIN}/uname" <<'EOF'
#!/bin/sh
printf 'Darwin\n'
EOF
cat >"${MOCK_BIN}/open" <<'EOF'
#!/bin/sh
printf 'open' >>"${TEST_LOG}"
printf ' <%s>' "$@" >>"${TEST_LOG}"
printf '\n' >>"${TEST_LOG}"
EOF
chmod +x "${MOCK_BIN}/uname" "${MOCK_BIN}/open"

: >"${LOG}"
TEST_LOG="${LOG}" PATH="${MOCK_BIN}:/usr/bin:/bin" \
  TS_AUTHKEY=tskey-mac TS_HOSTNAME=mac-one \
  sh "${ROOT}/scripts/tailscale-onekey-join-linux.sh" >/dev/null
assert_contains 'open <-a> <Tailscale>'
assert_contains 'tailscale <up> <--auth-key=tskey-mac> <--hostname=mac-one> <--accept-dns=false>'

echo "join script tests passed"
