#!/bin/sh
set -eu

REPO_SLUG=${REPO_SLUG:-shuguangnet/tailscale-derp-docker}
INSTALL_DIR=${INSTALL_DIR:-/opt/tailscale-derp-docker}
DERP_HOSTNAME=${DERP_HOSTNAME:-${1:-}}
DERP_PORT=${DERP_PORT:-8443}
DERP_BACKEND_PORT=${DERP_BACKEND_PORT:-8080}
STUN_PORT=${STUN_PORT:-3478}
DERP_REGION_ID=${DERP_REGION_ID:-901}
DERP_REGION_CODE=${DERP_REGION_CODE:-custom}
DERP_REGION_NAME=${DERP_REGION_NAME:-Custom DERP}
TAILSCALE_VERSION=${TAILSCALE_VERSION:-v1.98.9}

validate_port() {
  name=$1
  value=$2
  case "${value}" in
    ''|*[!0-9]*) echo "${name} must be an integer." >&2; exit 1 ;;
  esac
  if [ "${value}" -lt 1 ] || [ "${value}" -gt 65535 ]; then
    echo "${name} must be between 1 and 65535." >&2
    exit 1
  fi
}

if [ -n "${DERP_HOSTNAME}" ]; then
  case "${DERP_HOSTNAME}" in
    *[!A-Za-z0-9.-]*|.*|*.)
      echo "DERP_HOSTNAME must be a DNS hostname." >&2
      exit 1
      ;;
  esac

  validate_port DERP_PORT "${DERP_PORT}"
  validate_port DERP_BACKEND_PORT "${DERP_BACKEND_PORT}"
  validate_port STUN_PORT "${STUN_PORT}"
  case "${DERP_REGION_ID}" in
    ''|*[!0-9]*) echo "DERP_REGION_ID must be a positive integer." >&2; exit 1 ;;
  esac
  if [ "${DERP_REGION_ID}" -lt 1 ]; then
    echo "DERP_REGION_ID must be a positive integer." >&2
    exit 1
  fi
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this installer as root." >&2
  exit 1
fi

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required to install Docker." >&2
    exit 1
  fi
  curl -fsSL https://get.docker.com | sh
}

download_repo() {
  if [ -f "./compose.yaml" ] && [ -f "./Dockerfile" ]; then
    INSTALL_DIR=$(pwd)
    return
  fi
  command -v curl >/dev/null 2>&1 || {
    echo "curl is required to download the repository." >&2
    exit 1
  }
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "${tmp_dir}"' EXIT HUP INT TERM
  curl -fsSL "https://github.com/${REPO_SLUG}/archive/refs/heads/main.tar.gz" \
    | tar -xz -C "${tmp_dir}" --strip-components=1
  mkdir -p "${INSTALL_DIR}"
  cp -R "${tmp_dir}/." "${INSTALL_DIR}/"
}

download_repo

if [ -z "${DERP_HOSTNAME}" ]; then
  sh "${INSTALL_DIR}/manage.sh" menu
  exit 0
fi

install_docker

write_env() {
  escaped=$(printf '%s' "$2" | sed "s/'/'\\\\''/g")
  printf "%s='%s'\n" "$1" "${escaped}"
}

{
  write_env DERP_HOSTNAME "${DERP_HOSTNAME}"
  write_env DERP_PORT "${DERP_PORT}"
  write_env DERP_BACKEND_PORT "${DERP_BACKEND_PORT}"
  write_env DERP_BIND_ADDRESS 127.0.0.1
  write_env STUN_PORT "${STUN_PORT}"
  write_env DERP_REGION_ID "${DERP_REGION_ID}"
  write_env DERP_REGION_CODE "${DERP_REGION_CODE}"
  write_env DERP_REGION_NAME "${DERP_REGION_NAME}"
  write_env TAILSCALE_VERSION "${TAILSCALE_VERSION}"
} >"${INSTALL_DIR}/.env"

cat >"${INSTALL_DIR}/Caddyfile.snippet" <<EOF
https://${DERP_HOSTNAME}:${DERP_PORT} {
    reverse_proxy 127.0.0.1:${DERP_BACKEND_PORT}
}
EOF

cd "${INSTALL_DIR}"
docker compose up -d --build
sh scripts/generate-derp-map.sh

echo
echo "DERP is running behind 127.0.0.1:${DERP_BACKEND_PORT}."
echo "Add ${INSTALL_DIR}/Caddyfile.snippet to the host edge-caddy configuration, then reload Caddy."
echo "Merge ${INSTALL_DIR}/derp-map.json into the Tailscale access-control policy."
echo "Make sure TCP ${DERP_PORT} and UDP ${STUN_PORT} are open, then run: tailscale netcheck"
