#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
STATE_DIR=${STATE_DIR:-/etc/tailscale-derp-docker}
NODES_DIR=${NODES_DIR:-${STATE_DIR}/nodes}
JOIN_SCRIPT=${JOIN_SCRIPT:-${PROJECT_DIR}/scripts/tailscale-onekey-join-linux.sh}

die() {
  echo "Error: $*" >&2
  exit 1
}

ensure_state() {
  umask 077
  mkdir -p "${NODES_DIR}"
  chmod 700 "${STATE_DIR}" "${NODES_DIR}"
}

validate_id() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*|.*) die "node ID may only contain letters, numbers, dot, underscore, and hyphen" ;;
  esac
}

validate_host() {
  case "$1" in
    ''|-*|*[!A-Za-z0-9._:-]*) die "invalid SSH host: $1" ;;
  esac
}

validate_port() {
  case "$1" in
    ''|*[!0-9]*) die "port must be an integer" ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || die "port must be between 1 and 65535"
}

validate_yes_no() {
  case "$1" in
    yes|no) ;;
    *) die "sudo must be yes or no" ;;
  esac
}

node_dir() {
  validate_id "$1"
  printf '%s/%s\n' "${NODES_DIR}" "$1"
}

node_exists() {
  [ -d "$(node_dir "$1")" ]
}

read_field() {
  dir=$(node_dir "$1")
  field=$2
  [ -f "${dir}/${field}" ] || return 0
  sed -n '1p' "${dir}/${field}"
}

write_field() {
  dir=$(node_dir "$1")
  field=$2
  value=$3
  printf '%s\n' "${value}" >"${dir}/${field}"
  chmod 600 "${dir}/${field}"
}

save_node() {
  id=$1
  ssh_host=$2
  ssh_user=$3
  ssh_port=$4
  ts_hostname=$5
  auth_key=$6
  extra_args=$7
  use_sudo=$8

  validate_id "${id}"
  validate_host "${ssh_host}"
  validate_port "${ssh_port}"
  validate_yes_no "${use_sudo}"
  [ -n "${ssh_user}" ] || die "SSH user is required"
  [ -n "${ts_hostname}" ] || die "Tailscale hostname is required"
  [ -n "${auth_key}" ] || die "Tailscale auth key is required"

  ensure_state
  dir=$(node_dir "${id}")
  mkdir -p "${dir}"
  chmod 700 "${dir}"
  write_field "${id}" ssh_host "${ssh_host}"
  write_field "${id}" ssh_user "${ssh_user}"
  write_field "${id}" ssh_port "${ssh_port}"
  write_field "${id}" ts_hostname "${ts_hostname}"
  write_field "${id}" auth_key "${auth_key}"
  write_field "${id}" extra_args "${extra_args}"
  write_field "${id}" use_sudo "${use_sudo}"
}

node_add() {
  id=
  ssh_host=
  ssh_user=root
  ssh_port=22
  ts_hostname=
  auth_key=
  extra_args=
  use_sudo=no

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id) id=${2:-}; shift 2 ;;
      --ssh-host) ssh_host=${2:-}; shift 2 ;;
      --ssh-user) ssh_user=${2:-}; shift 2 ;;
      --ssh-port) ssh_port=${2:-}; shift 2 ;;
      --hostname) ts_hostname=${2:-}; shift 2 ;;
      --auth-key) auth_key=${2:-}; shift 2 ;;
      --extra-args) extra_args=${2:-}; shift 2 ;;
      --sudo) use_sudo=${2:-}; shift 2 ;;
      *) die "unknown node add option: $1" ;;
    esac
  done

  [ -n "${id}" ] || die "--id is required"
  ensure_state
  node_exists "${id}" && die "node already exists: ${id}"
  save_node "${id}" "${ssh_host}" "${ssh_user}" "${ssh_port}" "${ts_hostname}" "${auth_key}" "${extra_args}" "${use_sudo}"
  echo "Node ${id} added."
}

node_edit() {
  id=${1:-}
  [ -n "${id}" ] || die "node ID is required"
  shift
  ensure_state
  node_exists "${id}" || die "node not found: ${id}"

  ssh_host=$(read_field "${id}" ssh_host)
  ssh_user=$(read_field "${id}" ssh_user)
  ssh_port=$(read_field "${id}" ssh_port)
  ts_hostname=$(read_field "${id}" ts_hostname)
  auth_key=$(read_field "${id}" auth_key)
  extra_args=$(read_field "${id}" extra_args)
  use_sudo=$(read_field "${id}" use_sudo)

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ssh-host) ssh_host=${2:-}; shift 2 ;;
      --ssh-user) ssh_user=${2:-}; shift 2 ;;
      --ssh-port) ssh_port=${2:-}; shift 2 ;;
      --hostname) ts_hostname=${2:-}; shift 2 ;;
      --auth-key) auth_key=${2:-}; shift 2 ;;
      --extra-args) extra_args=${2:-}; shift 2 ;;
      --sudo) use_sudo=${2:-}; shift 2 ;;
      *) die "unknown node edit option: $1" ;;
    esac
  done

  save_node "${id}" "${ssh_host}" "${ssh_user}" "${ssh_port}" "${ts_hostname}" "${auth_key}" "${extra_args}" "${use_sudo}"
  echo "Node ${id} updated."
}

node_list() {
  ensure_state
  printf '%-18s %-28s %-10s %-22s %s\n' ID SSH USER TAILSCALE_HOSTNAME SUDO
  found=false
  for dir in "${NODES_DIR}"/*; do
    [ -d "${dir}" ] || continue
    found=true
    id=$(basename "${dir}")
    ssh_host=$(read_field "${id}" ssh_host)
    ssh_user=$(read_field "${id}" ssh_user)
    ssh_port=$(read_field "${id}" ssh_port)
    ts_hostname=$(read_field "${id}" ts_hostname)
    use_sudo=$(read_field "${id}" use_sudo)
    printf '%-18s %-28s %-10s %-22s %s\n' "${id}" "${ssh_host}:${ssh_port}" "${ssh_user}" "${ts_hostname}" "${use_sudo}"
  done
  ${found} || echo "No child nodes configured."
}

node_show() {
  id=${1:-}
  ensure_state
  node_exists "${id}" || die "node not found: ${id}"
  auth_key=$(read_field "${id}" auth_key)
  case "${auth_key}" in
    ????????*) masked_key=$(printf '%s' "${auth_key}" | cut -c1-8); masked_key="${masked_key}..." ;;
    *) masked_key='***' ;;
  esac
  echo "ID: ${id}"
  echo "SSH: $(read_field "${id}" ssh_user)@$(read_field "${id}" ssh_host):$(read_field "${id}" ssh_port)"
  echo "Tailscale hostname: $(read_field "${id}" ts_hostname)"
  echo "Auth key: ${masked_key}"
  echo "Extra args: $(read_field "${id}" extra_args)"
  echo "Use sudo: $(read_field "${id}" use_sudo)"
}

node_delete() {
  id=${1:-}
  confirmation=${2:-}
  ensure_state
  dir=$(node_dir "${id}")
  [ -d "${dir}" ] || die "node not found: ${id}"
  [ "${confirmation}" = "--yes" ] || die "pass --yes to confirm deletion"
  find "${dir}" -maxdepth 1 -type f -delete
  rmdir "${dir}"
  echo "Node ${id} configuration deleted. The remote Tailscale node was not removed from the admin console."
}

node_deploy() {
  id=${1:-}
  ensure_state
  node_exists "${id}" || die "node not found: ${id}"
  command -v ssh >/dev/null 2>&1 || die "ssh is required"
  [ -f "${JOIN_SCRIPT}" ] || die "join script not found: ${JOIN_SCRIPT}"

  ssh_host=$(read_field "${id}" ssh_host)
  ssh_user=$(read_field "${id}" ssh_user)
  ssh_port=$(read_field "${id}" ssh_port)
  ts_hostname=$(read_field "${id}" ts_hostname)
  auth_key=$(read_field "${id}" auth_key)
  extra_args=$(read_field "${id}" extra_args)
  use_sudo=$(read_field "${id}" use_sudo)
  target="${ssh_user}@${ssh_host}"

  if [ "${use_sudo}" = yes ]; then
    remote_shell="sudo -n sh -c 'IFS= read -r TS_AUTHKEY; IFS= read -r TS_HOSTNAME; IFS= read -r TS_EXTRA_ARGS; export TS_AUTHKEY TS_HOSTNAME TS_EXTRA_ARGS; sh'"
  else
    remote_shell="sh -c 'IFS= read -r TS_AUTHKEY; IFS= read -r TS_HOSTNAME; IFS= read -r TS_EXTRA_ARGS; export TS_AUTHKEY TS_HOSTNAME TS_EXTRA_ARGS; sh'"
  fi

  echo "Deploying Tailscale node ${id} to ${target}:${ssh_port}..."
  {
    printf '%s\n' "${auth_key}" "${ts_hostname}" "${extra_args}"
    sed '1d' "${JOIN_SCRIPT}"
  } | ssh -p "${ssh_port}" "${target}" "${remote_shell}"
}

prompt() {
  label=$1
  default=${2:-}
  if [ -n "${default}" ]; then
    printf '%s [%s]: ' "${label}" "${default}" >/dev/tty
  else
    printf '%s: ' "${label}" >/dev/tty
  fi
  IFS= read -r answer </dev/tty || exit 1
  printf '%s\n' "${answer:-${default}}"
}

prompt_secret() {
  label=$1
  printf '%s: ' "${label}" >/dev/tty
  old_stty=$(stty -g </dev/tty)
  stty -echo </dev/tty
  IFS= read -r answer </dev/tty || {
    stty "${old_stty}" </dev/tty
    exit 1
  }
  stty "${old_stty}" </dev/tty
  printf '\n' >/dev/tty
  printf '%s\n' "${answer}"
}

interactive_add() {
  id=$(prompt "Node ID")
  ssh_host=$(prompt "SSH host or IP")
  ssh_user=$(prompt "SSH user" root)
  ssh_port=$(prompt "SSH port" 22)
  ts_hostname=$(prompt "Tailscale hostname" "${id}")
  auth_key=$(prompt_secret "Tailscale auth key")
  extra_args=$(prompt "Extra tailscale up arguments" "")
  if [ "${ssh_user}" = root ]; then default_sudo=no; else default_sudo=yes; fi
  use_sudo=$(prompt "Use passwordless sudo (yes/no)" "${default_sudo}")
  node_add --id "${id}" --ssh-host "${ssh_host}" --ssh-user "${ssh_user}" \
    --ssh-port "${ssh_port}" --hostname "${ts_hostname}" --auth-key "${auth_key}" \
    --extra-args "${extra_args}" --sudo "${use_sudo}"
  deploy_now=$(prompt "立即通过 SSH 部署此节点 (yes/no)" yes)
  if [ "${deploy_now}" = yes ]; then
    node_deploy "${id}"
  fi
}

interactive_edit() {
  id=$(prompt "Node ID")
  ensure_state
  node_exists "${id}" || die "node not found: ${id}"
  ssh_host=$(prompt "SSH host or IP" "$(read_field "${id}" ssh_host)")
  ssh_user=$(prompt "SSH user" "$(read_field "${id}" ssh_user)")
  ssh_port=$(prompt "SSH port" "$(read_field "${id}" ssh_port)")
  ts_hostname=$(prompt "Tailscale hostname" "$(read_field "${id}" ts_hostname)")
  extra_args=$(prompt "Extra tailscale up arguments (- to clear)" "$(read_field "${id}" extra_args)")
  [ "${extra_args}" = - ] && extra_args=
  use_sudo=$(prompt "Use passwordless sudo (yes/no)" "$(read_field "${id}" use_sudo)")
  replace_key=$(prompt "Replace auth key (yes/no)" no)
  if [ "${replace_key}" = yes ]; then auth_key=$(prompt_secret "New auth key"); else auth_key=$(read_field "${id}" auth_key); fi
  node_edit "${id}" --ssh-host "${ssh_host}" --ssh-user "${ssh_user}" \
    --ssh-port "${ssh_port}" --hostname "${ts_hostname}" --auth-key "${auth_key}" \
    --extra-args "${extra_args}" --sudo "${use_sudo}"
  deploy_now=$(prompt "立即重新部署此节点 (yes/no)" no)
  if [ "${deploy_now}" = yes ]; then
    node_deploy "${id}"
  fi
}

interactive_delete() {
  id=$(prompt "Node ID")
  answer=$(prompt "Delete ${id} configuration (yes/no)" no)
  [ "${answer}" = yes ] && node_delete "${id}" --yes || echo "Cancelled."
}

interactive_deploy_main() {
  hostname=$(prompt "DERP hostname" "bs.de.933999.xyz")
  derp_port=$(prompt "Public DERP TCP port" 8443)
  backend_port=$(prompt "Local DERP backend port" 8080)
  stun_port=$(prompt "STUN UDP port" 3478)
  region_id=$(prompt "DERP region ID" 901)
  region_code=$(prompt "DERP region code" de-bs)
  region_name=$(prompt "DERP region name" "Germany BS")
  DERP_HOSTNAME="${hostname}" DERP_PORT="${derp_port}" DERP_BACKEND_PORT="${backend_port}" \
    STUN_PORT="${stun_port}" DERP_REGION_ID="${region_id}" DERP_REGION_CODE="${region_code}" \
    DERP_REGION_NAME="${region_name}" sh "${PROJECT_DIR}/install.sh"
}

show_main_status() {
  if [ -f "${PROJECT_DIR}/compose.yaml" ] && command -v docker >/dev/null 2>&1; then
    (cd "${PROJECT_DIR}" && docker compose ps)
  else
    echo "Main DERP service is not installed."
  fi
}

menu() {
  [ -r /dev/tty ] || die "interactive menu requires a terminal"
  while :; do
    cat >/dev/tty <<'EOF'

Tailscale DERP 管理菜单
1. 部署或更新主 DERP 服务
2. 添加子节点配置
3. 查看子节点列表
4. 查看子节点配置
5. 修改子节点配置
6. 通过 SSH 部署子节点
7. 删除子节点配置
8. 查看主 DERP 服务状态
0. 退出
EOF
    choice=$(prompt "请选择")
    case "${choice}" in
      1) interactive_deploy_main ;;
      2) interactive_add ;;
      3) node_list ;;
      4) node_show "$(prompt "Node ID")" ;;
      5) interactive_edit ;;
      6) node_deploy "$(prompt "Node ID")" ;;
      7) interactive_delete ;;
      8) show_main_status ;;
      0) exit 0 ;;
      *) echo "Invalid selection." ;;
    esac
  done
}

usage() {
  cat <<'EOF'
Usage:
  manage.sh menu
  manage.sh deploy-main
  manage.sh node list
  manage.sh node show ID
  manage.sh node add --id ID --ssh-host HOST --hostname NAME --auth-key KEY [options]
  manage.sh node edit ID [options]
  manage.sh node deploy ID
  manage.sh node delete ID --yes
EOF
}

command=${1:-menu}
case "${command}" in
  menu) menu ;;
  deploy-main) interactive_deploy_main ;;
  status) show_main_status ;;
  node)
    action=${2:-}
    [ "$#" -ge 2 ] && shift 2 || true
    case "${action}" in
      list) node_list "$@" ;;
      show) node_show "$@" ;;
      add) node_add "$@" ;;
      edit) node_edit "$@" ;;
      deploy) node_deploy "$@" ;;
      delete) node_delete "$@" ;;
      *) usage; exit 1 ;;
    esac
    ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
