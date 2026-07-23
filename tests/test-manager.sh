#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT HUP INT TERM
STATE_DIR="${TMP}/state"
MOCK_BIN="${TMP}/bin"
SSH_LOG="${TMP}/ssh.log"
SSH_INPUT="${TMP}/ssh-input"
mkdir -p "${MOCK_BIN}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

manager() {
  STATE_DIR="${STATE_DIR}" sh "${ROOT}/manage.sh" "$@"
}

manager node add \
  --id edge-1 \
  --ssh-host 192.0.2.10 \
  --ssh-user admin \
  --ssh-port 2222 \
  --hostname edge-one \
  --auth-key tskey-auth-secret \
  --extra-args '--ssh --advertise-exit-node' \
  --sudo yes >/dev/null

[ "$(cat "${STATE_DIR}/nodes/edge-1/ssh_port")" = 2222 ] || fail "SSH port was not saved"
[ "$(cat "${STATE_DIR}/nodes/edge-1/ts_hostname")" = edge-one ] || fail "hostname was not saved"
[ "$(stat -c '%a' "${STATE_DIR}/nodes/edge-1/auth_key")" = 600 ] || fail "auth key mode is not 600"

manager node list >"${TMP}/list"
grep -F 'edge-1' "${TMP}/list" >/dev/null || fail "node missing from list"
grep -F '192.0.2.10:2222' "${TMP}/list" >/dev/null || fail "SSH endpoint missing from list"

manager node show edge-1 >"${TMP}/show"
grep -F 'tskey-au...' "${TMP}/show" >/dev/null || fail "auth key was not masked"
if grep -F 'tskey-auth-secret' "${TMP}/show" >/dev/null; then
  fail "full auth key leaked from node show"
fi

manager node edit edge-1 --ssh-port 2200 --hostname edge-renamed --extra-args '' >/dev/null
[ "$(cat "${STATE_DIR}/nodes/edge-1/ssh_port")" = 2200 ] || fail "SSH port was not updated"
[ "$(cat "${STATE_DIR}/nodes/edge-1/ts_hostname")" = edge-renamed ] || fail "hostname was not updated"
[ -z "$(cat "${STATE_DIR}/nodes/edge-1/extra_args")" ] || fail "extra args were not cleared"

cat >"${MOCK_BIN}/ssh" <<'EOF'
#!/bin/sh
printf 'ssh' >"${SSH_LOG}"
printf ' <%s>' "$@" >>"${SSH_LOG}"
printf '\n' >>"${SSH_LOG}"
cat >"${SSH_INPUT}"
EOF
chmod +x "${MOCK_BIN}/ssh"

SSH_LOG="${SSH_LOG}" SSH_INPUT="${SSH_INPUT}" STATE_DIR="${STATE_DIR}" \
  PATH="${MOCK_BIN}:/usr/bin:/bin" sh "${ROOT}/manage.sh" node deploy edge-1 >/dev/null

grep -F 'ssh <-p> <2200> <admin@192.0.2.10>' "${SSH_LOG}" >/dev/null || fail "SSH invocation is incorrect"
sed -n '1p' "${SSH_INPUT}" | grep -Fx 'tskey-auth-secret' >/dev/null || fail "auth key was not streamed"
sed -n '2p' "${SSH_INPUT}" | grep -Fx 'edge-renamed' >/dev/null || fail "hostname was not streamed"
grep -F 'set -eu' "${SSH_INPUT}" >/dev/null || fail "join script was not streamed"

manager node delete edge-1 --yes >/dev/null
[ ! -d "${STATE_DIR}/nodes/edge-1" ] || fail "node directory was not deleted"

echo "manager tests passed"
