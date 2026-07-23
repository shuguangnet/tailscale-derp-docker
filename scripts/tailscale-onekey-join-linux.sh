#!/bin/sh
set -eu

AUTH_KEY="${TS_AUTHKEY:-${1:-}}"
HOST_NAME="${TS_HOSTNAME:-$(hostname)}"
EXTRA_ARGS="${TS_EXTRA_ARGS:-}"

if [ -z "${AUTH_KEY}" ]; then
  echo "Usage:" >&2
  echo "  TS_AUTHKEY=tskey-auth-xxx sh $0" >&2
  echo "  sh $0 tskey-auth-xxx" >&2
  exit 1
fi

if ! command -v tailscale >/dev/null 2>&1; then
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- https://tailscale.com/install.sh | sh
  else
    echo "curl or wget is required to install Tailscale." >&2
    exit 1
  fi
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl enable --now tailscaled
else
  service tailscaled start >/dev/null 2>&1 || true
fi

set -- tailscale up \
  "--auth-key=${AUTH_KEY}" \
  "--hostname=${HOST_NAME}" \
  --accept-dns=false

if [ -n "${EXTRA_ARGS}" ]; then
  # TS_EXTRA_ARGS is intentionally shell-split so multiple flags can be supplied.
  # shellcheck disable=SC2086
  set -- "$@" ${EXTRA_ARGS}
fi

"$@"
tailscale status
tailscale netcheck
