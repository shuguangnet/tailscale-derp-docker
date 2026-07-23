#!/bin/sh
set -eu

AUTH_KEY="${TS_AUTHKEY:-${1:-}}"
HOST_NAME="${TS_HOSTNAME:-$(hostname)}"
EXTRA_ARGS="${TS_EXTRA_ARGS:-}"
OS_NAME=$(uname -s)

run_privileged() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "sudo or root privileges are required." >&2
    exit 1
  fi
}

if [ -z "${AUTH_KEY}" ]; then
  echo "Usage:" >&2
  echo "  TS_AUTHKEY=tskey-auth-xxx sh $0" >&2
  echo "  sh $0 tskey-auth-xxx" >&2
  exit 1
fi

if ! command -v tailscale >/dev/null 2>&1; then
  case "${OS_NAME}" in
    Darwin)
      command -v curl >/dev/null 2>&1 || {
        echo "curl is required to install Tailscale on macOS." >&2
        exit 1
      }
      package_file=$(mktemp "${TMPDIR:-/tmp}/tailscale.pkg.XXXXXX")
      trap 'rm -f "${package_file}"' EXIT HUP INT TERM
      curl -fL --retry 3 -o "${package_file}" \
        https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg
      run_privileged installer -pkg "${package_file}" -target /
      open -a Tailscale >/dev/null 2>&1 || true
      ;;
    Linux)
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://tailscale.com/install.sh | sh
      elif command -v wget >/dev/null 2>&1; then
        wget -qO- https://tailscale.com/install.sh | sh
      else
        echo "curl or wget is required to install Tailscale." >&2
        exit 1
      fi
      ;;
    *)
      echo "Unsupported operating system: ${OS_NAME}" >&2
      exit 1
      ;;
  esac
fi

case "${OS_NAME}" in
  Darwin)
    open -a Tailscale >/dev/null 2>&1 || true
    ;;
  Linux)
    if command -v systemctl >/dev/null 2>&1; then
      run_privileged systemctl enable --now tailscaled
    elif command -v rc-service >/dev/null 2>&1; then
      run_privileged rc-update add tailscale default >/dev/null 2>&1 || true
      run_privileged rc-service tailscale start
    else
      run_privileged service tailscaled start >/dev/null 2>&1 || true
    fi
    ;;
esac

if ! command -v tailscale >/dev/null 2>&1; then
  for candidate in \
    /Applications/Tailscale.app/Contents/MacOS/tailscale \
    /Applications/Tailscale.app/Contents/MacOS/Tailscale \
    /usr/local/bin/tailscale \
    /opt/homebrew/bin/tailscale
  do
    if [ -x "${candidate}" ]; then
      TAILSCALE_BIN=${candidate}
      break
    fi
  done
else
  TAILSCALE_BIN=$(command -v tailscale)
fi

: "${TAILSCALE_BIN:?tailscale CLI was not found after installation}"

set -- "${TAILSCALE_BIN}" up \
  "--auth-key=${AUTH_KEY}" \
  "--hostname=${HOST_NAME}" \
  --accept-dns=false

if [ -n "${EXTRA_ARGS}" ]; then
  # TS_EXTRA_ARGS is intentionally shell-split so multiple flags can be supplied.
  # shellcheck disable=SC2086
  set -- "$@" ${EXTRA_ARGS}
fi

"$@"
"${TAILSCALE_BIN}" status
"${TAILSCALE_BIN}" netcheck
