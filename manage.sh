#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
OS_NAME=$(uname -s)
case "${OS_NAME}" in
  Darwin)
    DEFAULT_STATE_DIR="${HOME}/Library/Application Support/TailscaleDERP"
    ;;
  Linux)
    DEFAULT_STATE_DIR=/etc/tailscale-derp-docker
    ;;
  *) echo "Unsupported operating system: ${OS_NAME}" >&2; exit 1 ;;
esac
STATE_DIR=${STATE_DIR:-${DEFAULT_STATE_DIR}}
NODES_DIR=${NODES_DIR:-${STATE_DIR}/nodes}
JOIN_SCRIPT=${JOIN_SCRIPT:-${PROJECT_DIR}/scripts/tailscale-onekey-join-linux.sh}
JOIN_WINDOWS_SCRIPT=${JOIN_WINDOWS_SCRIPT:-${PROJECT_DIR}/scripts/tailscale-onekey-join-windows.ps1}

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
  if [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then
    die "port must be between 1 and 65535"
  fi
}

validate_yes_no() {
  case "$1" in
    yes|no) ;;
    *) die "sudo must be yes or no" ;;
  esac
}

validate_platform() {
  case "$1" in
    linux|debian|ubuntu|alpine|macos|windows) ;;
    *) die "platform must be linux, debian, ubuntu, alpine, macos, or windows" ;;
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
  platform=$9

  validate_id "${id}"
  validate_host "${ssh_host}"
  validate_port "${ssh_port}"
  validate_yes_no "${use_sudo}"
  validate_platform "${platform}"
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
  write_field "${id}" platform "${platform}"
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
  platform=linux

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
      --platform) platform=${2:-}; shift 2 ;;
      *) die "unknown node add option: $1" ;;
    esac
  done

  [ -n "${id}" ] || die "--id is required"
  ensure_state
  node_exists "${id}" && die "node already exists: ${id}"
  save_node "${id}" "${ssh_host}" "${ssh_user}" "${ssh_port}" "${ts_hostname}" "${auth_key}" "${extra_args}" "${use_sudo}" "${platform}"
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
  platform=$(read_field "${id}" platform)
  platform=${platform:-linux}

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ssh-host) ssh_host=${2:-}; shift 2 ;;
      --ssh-user) ssh_user=${2:-}; shift 2 ;;
      --ssh-port) ssh_port=${2:-}; shift 2 ;;
      --hostname) ts_hostname=${2:-}; shift 2 ;;
      --auth-key) auth_key=${2:-}; shift 2 ;;
      --extra-args) extra_args=${2:-}; shift 2 ;;
      --sudo) use_sudo=${2:-}; shift 2 ;;
      --platform) platform=${2:-}; shift 2 ;;
      *) die "unknown node edit option: $1" ;;
    esac
  done

  save_node "${id}" "${ssh_host}" "${ssh_user}" "${ssh_port}" "${ts_hostname}" "${auth_key}" "${extra_args}" "${use_sudo}" "${platform}"
  echo "Node ${id} updated."
}

node_list() {
  ensure_state
  printf '%-16s %-10s %-26s %-10s %-20s %s\n' ID PLATFORM SSH USER TAILSCALE_HOSTNAME SUDO
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
    platform=$(read_field "${id}" platform)
    platform=${platform:-linux}
    printf '%-16s %-10s %-26s %-10s %-20s %s\n' "${id}" "${platform}" "${ssh_host}:${ssh_port}" "${ssh_user}" "${ts_hostname}" "${use_sudo}"
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
  platform=$(read_field "${id}" platform)
  echo "Platform: ${platform:-linux}"
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
  platform=$(read_field "${id}" platform)
  platform=${platform:-linux}
  target="${ssh_user}@${ssh_host}"

  echo "Deploying Tailscale ${platform} node ${id} to ${target}:${ssh_port}..."
  case "${platform}" in
    windows)
      [ -f "${JOIN_WINDOWS_SCRIPT}" ] || die "Windows join script not found: ${JOIN_WINDOWS_SCRIPT}"
      command -v base64 >/dev/null 2>&1 || die "base64 is required for Windows deployment"
      auth_b64=$(printf '%s' "${auth_key}" | base64 | tr -d '\r\n')
      hostname_b64=$(printf '%s' "${ts_hostname}" | base64 | tr -d '\r\n')
      extra_b64=$(printf '%s' "${extra_args}" | base64 | tr -d '\r\n')
      {
        printf "\$env:TS_AUTHKEY=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\"%s\"))\n" "${auth_b64}"
        printf "\$env:TS_HOSTNAME=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\"%s\"))\n" "${hostname_b64}"
        printf "\$env:TS_EXTRA_ARGS=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\"%s\"))\n" "${extra_b64}"
        cat "${JOIN_WINDOWS_SCRIPT}"
      } | ssh -p "${ssh_port}" "${target}" "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command -"
      ;;
    linux|debian|ubuntu|alpine|macos)
      if [ "${use_sudo}" = yes ]; then
        remote_shell="sudo -n sh -c 'IFS= read -r TS_AUTHKEY; IFS= read -r TS_HOSTNAME; IFS= read -r TS_EXTRA_ARGS; export TS_AUTHKEY TS_HOSTNAME TS_EXTRA_ARGS; sh'"
      else
        remote_shell="sh -c 'IFS= read -r TS_AUTHKEY; IFS= read -r TS_HOSTNAME; IFS= read -r TS_EXTRA_ARGS; export TS_AUTHKEY TS_HOSTNAME TS_EXTRA_ARGS; sh'"
      fi
      {
        printf '%s\n' "${auth_key}" "${ts_hostname}" "${extra_args}"
        sed '1d' "${JOIN_SCRIPT}"
      } | ssh -p "${ssh_port}" "${target}" "${remote_shell}"
      ;;
  esac
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
  platform=$(prompt "Platform (linux/debian/ubuntu/alpine/macos/windows)" linux)
  ssh_host=$(prompt "SSH host or IP")
  ssh_user=$(prompt "SSH user" root)
  ssh_port=$(prompt "SSH port" 22)
  ts_hostname=$(prompt "Tailscale hostname" "${id}")
  auth_key=$(prompt_secret "Tailscale auth key")
  extra_args=$(prompt "Extra tailscale up arguments" "")
  if [ "${platform}" = windows ] || [ "${ssh_user}" = root ]; then default_sudo=no; else default_sudo=yes; fi
  use_sudo=$(prompt "Use passwordless sudo (yes/no)" "${default_sudo}")
  node_add --id "${id}" --ssh-host "${ssh_host}" --ssh-user "${ssh_user}" \
    --ssh-port "${ssh_port}" --hostname "${ts_hostname}" --auth-key "${auth_key}" \
    --extra-args "${extra_args}" --sudo "${use_sudo}" --platform "${platform}"
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
  current_platform=$(read_field "${id}" platform)
  platform=$(prompt "Platform" "${current_platform:-linux}")
  ssh_user=$(prompt "SSH user" "$(read_field "${id}" ssh_user)")
  ssh_port=$(prompt "SSH port" "$(read_field "${id}" ssh_port)")
  ts_hostname=$(prompt "Tailscale hostname" "$(read_field "${id}" ts_hostname)")
  extra_args=$(prompt "Extra tailscale up arguments (- to clear)" "$(read_field "${id}" extra_args)")
  if [ "${extra_args}" = - ]; then
    extra_args=
  fi
  use_sudo=$(prompt "Use passwordless sudo (yes/no)" "$(read_field "${id}" use_sudo)")
  replace_key=$(prompt "Replace auth key (yes/no)" no)
  if [ "${replace_key}" = yes ]; then auth_key=$(prompt_secret "New auth key"); else auth_key=$(read_field "${id}" auth_key); fi
  node_edit "${id}" --ssh-host "${ssh_host}" --ssh-user "${ssh_user}" \
    --ssh-port "${ssh_port}" --hostname "${ts_hostname}" --auth-key "${auth_key}" \
    --extra-args "${extra_args}" --sudo "${use_sudo}" --platform "${platform}"
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
  if [ ! -f "${PROJECT_DIR}/.env" ]; then
    echo "Main DERP service is not configured."
  elif [ -f "${PROJECT_DIR}/compose.yaml" ] && command -v docker >/dev/null 2>&1; then
    (cd "${PROJECT_DIR}" && docker compose ps)
  else
    echo "Main DERP service is not installed."
  fi
}

main_control() {
  action=${1:-status}
  [ -f "${PROJECT_DIR}/.env" ] || die "main DERP service is not configured"
  command -v docker >/dev/null 2>&1 || die "docker is required"
  case "${action}" in
    start) (cd "${PROJECT_DIR}" && docker compose up -d) ;;
    stop) (cd "${PROJECT_DIR}" && docker compose stop) ;;
    restart) (cd "${PROJECT_DIR}" && docker compose restart) ;;
    status) show_main_status ;;
    logs) (cd "${PROJECT_DIR}" && docker compose logs --tail 100 -f derper) ;;
    uninstall)
      answer=$(prompt "停止并删除 DERP 容器和持久化密钥 (yes/no)" no)
      if [ "${answer}" = yes ]; then
        (cd "${PROJECT_DIR}" && docker compose down -v)
        echo "DERP containers and persistent key volume removed. Configuration files were kept."
      fi
      ;;
    *) die "unknown main service action: ${action}" ;;
  esac
}

main_service_menu() {
  cat >/dev/tty <<'EOF'

主 DERP 服务管理
1. 启动
2. 停止
3. 重启
4. 查看状态
5. 查看实时日志
6. 卸载容器和数据卷
0. 返回
EOF
  action=$(prompt "请选择")
  case "${action}" in
    1) main_control start ;;
    2) main_control stop ;;
    3) main_control restart ;;
    4) main_control status ;;
    5) main_control logs ;;
    6) main_control uninstall ;;
    0) return ;;
    *) echo "Invalid selection." ;;
  esac
}

join_local_device() {
  auth_key=$(prompt_secret "Tailscale auth key")
  hostname=$(prompt "Tailscale hostname" "$(hostname)")
  extra_args=$(prompt "Extra tailscale up arguments" "")
  TS_AUTHKEY="${auth_key}" TS_HOSTNAME="${hostname}" TS_EXTRA_ARGS="${extra_args}" \
    sh "${JOIN_SCRIPT}"
}

menu() {
  [ -r /dev/tty ] || die "interactive menu requires a terminal"
  while :; do
    cat >/dev/tty <<'EOF'

Tailscale DERP 管理菜单
1. 部署或更新主 DERP 服务
2. 管理主 DERP 服务
3. 安装 Tailscale 并让当前设备加入网络
------------------------------------------------
4. 添加子节点配置
5. 查看子节点列表
6. 查看子节点配置
7. 修改子节点配置
8. 通过 SSH 部署子节点
9. 删除子节点配置
0. 退出
EOF
    choice=$(prompt "请选择")
    case "${choice}" in
      1) interactive_deploy_main ;;
      2) main_service_menu ;;
      3) join_local_device ;;
      4) interactive_add ;;
      5) node_list ;;
      6) node_show "$(prompt "Node ID")" ;;
      7) interactive_edit ;;
      8) node_deploy "$(prompt "Node ID")" ;;
      9) interactive_delete ;;
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
  manage.sh local-join
  manage.sh main start|stop|restart|status|logs|uninstall
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
  local-join) join_local_device ;;
  main) main_control "${2:-status}" ;;
  status) show_main_status ;;
  node)
    if [ "$#" -lt 2 ]; then
      usage
      exit 1
    fi
    action=$2
    shift 2
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
