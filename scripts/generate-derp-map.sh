#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "${SCRIPT_DIR}")

if [ -f "${PROJECT_DIR}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${PROJECT_DIR}/.env"
  set +a
fi

: "${DERP_HOSTNAME:?DERP_HOSTNAME is required}"
DERP_PORT=${DERP_PORT:-8443}
STUN_PORT=${STUN_PORT:-3478}
DERP_REGION_ID=${DERP_REGION_ID:-901}
DERP_REGION_CODE=${DERP_REGION_CODE:-custom}
DERP_REGION_NAME=${DERP_REGION_NAME:-Custom DERP}
OUTPUT=${1:-${PROJECT_DIR}/derp-map.json}

case "${DERP_PORT}:${STUN_PORT}:${DERP_REGION_ID}" in
  *[!0-9:]*) echo "Ports and region ID must be integers." >&2; exit 1 ;;
esac

escape_json() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

HOST_JSON=$(escape_json "${DERP_HOSTNAME}")
CODE_JSON=$(escape_json "${DERP_REGION_CODE}")
NAME_JSON=$(escape_json "${DERP_REGION_NAME}")

cat >"${OUTPUT}" <<EOF
{
  "derpMap": {
    "OmitDefaultRegions": false,
    "Regions": {
      "${DERP_REGION_ID}": {
        "RegionID": ${DERP_REGION_ID},
        "RegionCode": "${CODE_JSON}",
        "RegionName": "${NAME_JSON}",
        "Nodes": [
          {
            "Name": "${DERP_REGION_ID}a",
            "RegionID": ${DERP_REGION_ID},
            "HostName": "${HOST_JSON}",
            "DERPPort": ${DERP_PORT},
            "STUNPort": ${STUN_PORT}
          }
        ]
      }
    }
  }
}
EOF

echo "Wrote ${OUTPUT}"
