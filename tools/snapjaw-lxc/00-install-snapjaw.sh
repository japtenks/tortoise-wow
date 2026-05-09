#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/snapjaw.env}"
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null || true)"

DB_CTID="${DB_CTID:-501}"
REALMD_CTID="${REALMD_CTID:-502}"
BUILD_CTID="${BUILD_CTID:-503}"
LOGIN_DB="${LOGIN_DB:-snapjawrealmd}"
DB_HOST="${DB_HOST:-auto}"
DB_PORT="${DB_PORT:-3306}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-root}"
DB_ADMIN_USER="${DB_ADMIN_USER:-snapjawadmin}"
DB_ADMIN_PASSWORD="${DB_ADMIN_PASSWORD:-snapjawadmin}"
DB_APP_USER="${DB_APP_USER:-torta}"
DB_APP_PASSWORD="${DB_APP_PASSWORD:-torta}"
AUTH_WEB_BOOTSTRAP_ADMIN_KEY="${AUTH_WEB_BOOTSTRAP_ADMIN_KEY:-}"
CT_TEMPLATE_STORAGE="${CT_TEMPLATE_STORAGE:-local}"
CT_TEMPLATE="${CT_TEMPLATE:-auto}"
CT_STORAGE="${CT_STORAGE:-auto}"
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
CT_ONBOOT="${CT_ONBOOT:-1}"
CT_UNPRIVILEGED="${CT_UNPRIVILEGED:-1}"
DB_DISK_GB="${DB_DISK_GB:-16}"
DB_MEMORY_MB="${DB_MEMORY_MB:-4096}"
DB_SWAP_MB="${DB_SWAP_MB:-1024}"
DB_CORES="${DB_CORES:-2}"
REALMD_DISK_GB="${REALMD_DISK_GB:-12}"
REALMD_MEMORY_MB="${REALMD_MEMORY_MB:-2048}"
REALMD_SWAP_MB="${REALMD_SWAP_MB:-512}"
REALMD_CORES="${REALMD_CORES:-2}"
WORLD_DISK_GB="${WORLD_DISK_GB:-32}"
WORLD_MEMORY_MB="${WORLD_MEMORY_MB:-16384}"
WORLD_SWAP_MB="${WORLD_SWAP_MB:-1024}"
WORLD_CORES="${WORLD_CORES:-4}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"
INSTALL_MODE="${INSTALL_MODE:-bootstrap}"
DATA_SOURCE_MODE="${DATA_SOURCE_MODE:-}"
DATA_PACK_HOST_PATH="${DATA_PACK_HOST_PATH:-}"
CLIENT_ARCHIVE_HOST_PATH="${CLIENT_ARCHIVE_HOST_PATH:-}"
FORCE_DATA_REFRESH="${FORCE_DATA_REFRESH:-0}"
PACKAGE_BOOTSTRAP_DATA="${PACKAGE_BOOTSTRAP_DATA:-1}"
BOOTSTRAP_PACK_HOST_PATH="${BOOTSTRAP_PACK_HOST_PATH:-/tmp/tortoise-data.tar.gz}"
PRIMARY_REALM="${PRIMARY_REALM:-stable}"
EXTRA_REALMS="${EXTRA_REALMS:-ptr}"
INCLUDE_LOGS="${INCLUDE_LOGS:-1}"
REALM_MATRIX="${REALM_MATRIX:-stable|503|1|SnapJaw Stable|auto|8085
ptr|504|2|SnapJaw PTR|auto|8086}"
REALM_SLUGS="${REALM_SLUGS:-}"
DRY_RUN="${DRY_RUN:-0}"
ORIGINAL_BUILD_CORES=""
BUILD_CORES_BUMPED="0"

print_repo_version() {
  local branch=""
  local commit=""
  local remote_ref=""
  local remote_commit=""
  local status=""

  [[ -n "${REPO_ROOT}" ]] || return 0

  branch="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  commit="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || true)"
  [[ -n "${branch}" && -n "${commit}" ]] || return 0

  echo "==> Installer source: branch ${branch}, commit ${commit}"

  if git -C "${REPO_ROOT}" rev-parse --verify --quiet "origin/${branch}" >/dev/null 2>&1; then
    remote_ref="origin/${branch}"
  elif git -C "${REPO_ROOT}" rev-parse --verify --quiet "gitea/${branch}" >/dev/null 2>&1; then
    remote_ref="gitea/${branch}"
  else
    return 0
  fi

  remote_commit="$(git -C "${REPO_ROOT}" rev-parse --short "${remote_ref}" 2>/dev/null || true)"
  if [[ -n "${remote_commit}" && "${remote_commit}" == "${commit}" ]]; then
    status="up to date with ${remote_ref}"
  else
    status="local ${commit}, remote ${remote_ref} ${remote_commit}"
  fi

  echo "==> Installer branch status: ${status}"
}

generate_secret() {
  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(24))
PY
}

load_env_file() {
  if [[ -f "${ENV_FILE}" ]]; then
    echo "==> Loading configuration from ${ENV_FILE}"
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
  fi
}

ensure_generated_defaults() {
  if [[ -f "${ENV_FILE}" ]]; then
    return 0
  fi

  if [[ "${DB_ROOT_PASSWORD}" == "root" ]]; then
    DB_ROOT_PASSWORD="$(generate_secret)"
  fi
  if [[ "${DB_ADMIN_PASSWORD}" == "snapjawadmin" ]]; then
    DB_ADMIN_PASSWORD="$(generate_secret)"
  fi
  if [[ "${DB_APP_PASSWORD}" == "torta" ]]; then
    DB_APP_PASSWORD="$(generate_secret)"
  fi
  if [[ -z "${AUTH_WEB_BOOTSTRAP_ADMIN_KEY}" ]]; then
    AUTH_WEB_BOOTSTRAP_ADMIN_KEY="$(generate_secret)"
  fi
}

prompt_value() {
  local var_name="$1"
  local prompt_label="$2"
  local current_value="$3"
  local secret="${4:-0}"
  local input=""

  if [[ "${secret}" == "1" ]]; then
    read -r -s -p "${prompt_label} [${current_value}]: " input
    echo
  else
    read -r -p "${prompt_label} [${current_value}]: " input
  fi

  if [[ -n "${input}" ]]; then
    printf -v "${var_name}" '%s' "${input}"
  else
    printf -v "${var_name}" '%s' "${current_value}"
  fi
}

prompt_yes_no() {
  local var_name="$1"
  local prompt_label="$2"
  local current_value="$3"
  local default_word="y"
  local input=""

  if [[ "${current_value}" == "1" ]]; then
    default_word="y"
  else
    default_word="n"
  fi

  read -r -p "${prompt_label} [${default_word}]: " input
  input="${input,,}"

  case "${input}" in
    y|yes) printf -v "${var_name}" '%s' "1" ;;
    n|no) printf -v "${var_name}" '%s' "0" ;;
    "") printf -v "${var_name}" '%s' "${current_value}" ;;
    *) echo "Please answer y or n."; prompt_yes_no "${var_name}" "${prompt_label}" "${current_value}" ;;
  esac
}

list_template_storages() {
  pvesm status -content vztmpl 2>/dev/null | awk 'NR > 1 { print $1 }'
}

prompt_template_storage_choice() {
  local current_value="$1"
  local input=""
  local idx=1
  local storage=""
  local -a storages=()

  mapfile -t storages < <(list_template_storages)

  if [[ "${#storages[@]}" -eq 0 ]]; then
    prompt_value CT_TEMPLATE_STORAGE "Template storage" "${current_value}"
    return 0
  fi

  echo "Available template storages:"
  for storage in "${storages[@]}"; do
    echo "  ${idx}) ${storage}"
    idx=$((idx + 1))
  done
  echo "Enter a number or a storage name."

  read -r -p "Template storage [${current_value}]: " input
  if [[ -z "${input}" ]]; then
    CT_TEMPLATE_STORAGE="${current_value}"
    return 0
  fi

  if [[ "${input}" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= ${#storages[@]} )); then
    CT_TEMPLATE_STORAGE="${storages[input-1]}"
    return 0
  fi

  CT_TEMPLATE_STORAGE="${input}"
}

list_available_templates() {
  local storage="$1"

  if command -v pveam >/dev/null 2>&1; then
    pveam list "${storage}" 2>/dev/null | awk '
      NR > 1 && $1 ~ /:vztmpl\/debian-.*-standard_.*_amd64\.tar/ { print $1 }
    '
    return 0
  fi

  if [[ "${storage}" == "local" ]]; then
    find /var/lib/vz/template/cache -maxdepth 1 -type f -name 'debian-*-standard_*_amd64.tar.*' \
      | sort -V \
      | awk '{ print "local:vztmpl/" substr($0, length("/var/lib/vz/template/cache/") + 1) }'
  fi
}

prompt_template_choice() {
  local current_value="$1"
  local input=""
  local idx=1
  local selected=""
  local -a templates=()

  mapfile -t templates < <(list_available_templates "${CT_TEMPLATE_STORAGE}")

  if [[ "${#templates[@]}" -eq 0 ]]; then
    prompt_value CT_TEMPLATE "Template reference or auto" "${current_value}"
    return 0
  fi

  echo "Available Debian templates on ${CT_TEMPLATE_STORAGE}:"
  for selected in "${templates[@]}"; do
    echo "  ${idx}) ${selected}"
    idx=$((idx + 1))
  done
  echo "Enter a number, 'auto', or a full template reference."

  read -r -p "Template reference or auto [${current_value}]: " input
  if [[ -z "${input}" ]]; then
    CT_TEMPLATE="${current_value}"
    return 0
  fi

  if [[ "${input}" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= ${#templates[@]} )); then
    CT_TEMPLATE="${templates[input-1]}"
    return 0
  fi

  CT_TEMPLATE="${input}"
}

prompt_realms() {
  local current_matrix="$1"
  local first_line
  local slug
  local ctid
  local realm_id
  local realm_name
  local realm_address
  local world_port
  local matrix=""
  local more="y"

  echo "Current realms:"
  printf '%s\n' "${current_matrix}"
  echo
  echo "Enter realms one by one as prompted."

  first_line=1
  while [[ "${more}" == "y" ]]; do
    if [[ "${first_line}" == "1" ]]; then
      IFS='|' read -r slug ctid realm_id realm_name realm_address world_port <<< "$(printf '%s\n' "${current_matrix}" | head -n 1)"
    else
      slug=""
      ctid=""
      realm_id=""
      realm_name=""
      realm_address=""
      world_port=""
    fi

    prompt_value slug "Realm slug" "${slug:-stable}"
    prompt_value ctid "World CTID" "${ctid:-503}"
    prompt_value realm_id "Realm ID" "${realm_id:-1}"
    prompt_value realm_name "Realm name" "${realm_name:-SnapJaw ${slug}}"
    prompt_value realm_address "Realm address or auto" "${realm_address:-auto}"
    prompt_value world_port "World port" "${world_port:-8085}"

    if [[ -n "${matrix}" ]]; then
      matrix+=$'\n'
    fi
    matrix+="${slug}|${ctid}|${realm_id}|${realm_name}|${realm_address}|${world_port}"

    if [[ "${first_line}" == "1" ]]; then
      read -r -p "Add another realm? [y]: " more
      more="${more,,}"
      [[ -z "${more}" ]] && more="y"
      first_line=0
    else
      read -r -p "Add another realm? [n]: " more
      more="${more,,}"
      [[ -z "${more}" ]] && more="n"
    fi
  done

  REALM_MATRIX="${matrix}"
}

derive_realm_values() {
  local first_slug=""
  local slug_list=()
  while IFS='|' read -r realm_slug _rest; do
    [[ -n "${realm_slug}" ]] || continue
    slug_list+=("${realm_slug}")
    if [[ -z "${first_slug}" ]]; then
      first_slug="${realm_slug}"
    fi
  done <<< "${REALM_MATRIX}"

  PRIMARY_REALM="${PRIMARY_REALM:-${first_slug}}"
  REALM_SLUGS="${slug_list[*]}"

  if [[ "${#slug_list[@]}" -gt 1 ]]; then
    EXTRA_REALMS="${slug_list[*]:1}"
  else
    EXTRA_REALMS=""
  fi
}

detect_ct_ip() {
  local ctid="$1"
  local ip=""
  local attempt

  for attempt in $(seq 1 30); do
    ip="$(pct exec "${ctid}" -- bash -lc "hostname -I 2>/dev/null | awk '{print \$1}'" 2>/dev/null | tr -d '\r' | head -n 1 || true)"
    if [[ -n "${ip}" ]]; then
      printf '%s\n' "${ip}"
      return 0
    fi
    sleep 2
  done

  if [[ -z "${ip}" ]]; then
    echo "Unable to detect IP for CT ${ctid}. Set it manually." >&2
    return 1
  fi

  printf '%s\n' "${ip}"
}

ct_exists() {
  local ctid="$1"
  pct config "${ctid}" >/dev/null 2>&1
}

ct_name() {
  local ctid="$1"
  pct config "${ctid}" 2>/dev/null | awk -F': ' '/^hostname:/ { print $2; exit }'
}

ct_running() {
  local ctid="$1"
  pct status "${ctid}" 2>/dev/null | grep -q "status: running"
}

detect_template_ref() {
  local template_file=""
  local newest_template=""

  if [[ "${CT_TEMPLATE}" != "auto" && -n "${CT_TEMPLATE}" ]]; then
    printf '%s\n' "${CT_TEMPLATE}"
    return 0
  fi

  if [[ "${CT_TEMPLATE_STORAGE}" == "local" ]]; then
    newest_template="$(find /var/lib/vz/template/cache -maxdepth 1 -type f -name 'debian-*-standard_*_amd64.tar.*' | sort -V | tail -n 1 || true)"
    if [[ -n "${newest_template}" ]]; then
      template_file="${newest_template}"
    fi

    if [[ -n "${template_file}" ]]; then
      printf 'local:vztmpl/%s\n' "$(basename "${template_file}")"
      return 0
    fi
  fi

  echo "Unable to auto-detect a Debian standard LXC template. Set CT_TEMPLATE manually." >&2
  return 1
}

detect_ct_storage() {
  local storages=""

  if [[ "${CT_STORAGE}" != "auto" && -n "${CT_STORAGE}" ]]; then
    printf '%s\n' "${CT_STORAGE}"
    return 0
  fi

  storages="$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1}' || true)"
  if [[ -z "${storages}" ]]; then
    echo "Unable to auto-detect a rootdir-capable CT storage. Set CT_STORAGE manually." >&2
    return 1
  fi

  for preferred in local-zfs zfs rpool-data local-lvm local; do
    if printf '%s\n' "${storages}" | grep -qx "${preferred}"; then
      printf '%s\n' "${preferred}"
      return 0
    fi
  done

  printf '%s\n' "${storages}" | head -n 1
}

create_ct_if_missing() {
  local ctid="$1"
  local hostname="$2"
  local disk_gb="$3"
  local memory_mb="$4"
  local swap_mb="$5"
  local cores="$6"
  local template_ref="$7"
  local rootfs_arg="${CT_STORAGE}:${disk_gb}"

  if ct_exists "${ctid}"; then
    echo "==> CT ${ctid} already exists (${hostname})"
    return 0
  fi

  echo "==> Creating CT ${ctid} (${hostname})"
  pct create "${ctid}" "${template_ref}" \
    --hostname "${hostname}" \
    --ostype debian \
    --rootfs "${rootfs_arg}" \
    --cores "${cores}" \
    --memory "${memory_mb}" \
    --swap "${swap_mb}" \
    --onboot "${CT_ONBOOT}" \
    --unprivileged "${CT_UNPRIVILEGED}" \
    --net0 "name=eth0,bridge=${CT_BRIDGE},ip=dhcp"
}

show_plan_and_confirm() {
  local realm_slug
  local world_ctid
  local realm_id
  local realm_name
  local realm_address
  local world_port
  local existing_name=""
  local response=""

  echo
  echo "==> Planned CT layout"
  for ctid in "${DB_CTID}" "${REALMD_CTID}" "${BUILD_CTID}"; do
    if ct_exists "${ctid}"; then
      existing_name="$(ct_name "${ctid}")"
      echo "CT ${ctid}: existing (${existing_name:-unknown})"
    else
      echo "CT ${ctid}: will be created"
    fi
  done

  while IFS='|' read -r realm_slug world_ctid realm_id realm_name realm_address world_port; do
    [[ -n "${realm_slug}" ]] || continue
    if ct_exists "${world_ctid}"; then
      existing_name="$(ct_name "${world_ctid}")"
      echo "Realm ${realm_slug}: CT ${world_ctid} existing (${existing_name:-unknown}), RealmID ${realm_id}, port ${world_port}, addr ${realm_address}"
    else
      echo "Realm ${realm_slug}: CT ${world_ctid} will be created, RealmID ${realm_id}, port ${world_port}, addr ${realm_address}"
    fi
  done <<< "${REALM_MATRIX}"

  echo "DB host: ${DB_HOST}"
  echo "Login DB: ${LOGIN_DB}"
  echo "Install mode: ${INSTALL_MODE}"
  if [[ "${INSTALL_MODE}" == "reuse" ]]; then
    echo "Data pack path: ${DATA_PACK_HOST_PATH}"
  else
    echo "Client archive path: ${CLIENT_ARCHIVE_HOST_PATH}"
    if [[ "${PACKAGE_BOOTSTRAP_DATA}" == "1" ]]; then
      echo "Bootstrap pack export: ${BOOTSTRAP_PACK_HOST_PATH}"
    else
      echo "Bootstrap pack export: disabled"
    fi
  fi
  echo
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "==> Dry run mode: validation only, no changes will be made"
    return 0
  fi
  read -r -p "Type yes to proceed: " response
  if [[ "${response}" != "yes" ]]; then
    echo "Aborted before provisioning."
    exit 1
  fi
}

perform_dry_run() {
  local template_ref=""
  local ct_storage_ref=""

  echo "==> Dry run checks"
  template_ref="$(detect_template_ref)"
  ct_storage_ref="$(detect_ct_storage)"

  echo "Template: ${template_ref}"
  echo "CT storage: ${ct_storage_ref}"

  if [[ "${DATA_SOURCE_MODE}" == "pack" ]]; then
    echo "Data pack found: ${DATA_PACK_HOST_PATH}"
  else
    echo "Client archive found: ${CLIENT_ARCHIVE_HOST_PATH}"
    if [[ "${PACKAGE_BOOTSTRAP_DATA}" == "1" ]]; then
      echo "Bootstrap pack would be written to: ${BOOTSTRAP_PACK_HOST_PATH}"
    fi
  fi

  echo "==> Dry run completed successfully"
}

prompt_install_mode() {
  local mode="${INSTALL_MODE:-bootstrap}"
  local mode_input=""

  echo
  echo "Choose an install mode."
  echo "Use a Proxmox-host path, for example /fast/Download_Overflow/twmoa_1172.zip"

  while true; do
    read -r -p "Install mode [bootstrap/reuse] [${mode}]: " mode_input
    mode_input="${mode_input:-${mode}}"
    case "${mode_input}" in
      bootstrap|reuse)
        INSTALL_MODE="${mode_input}"
        break
        ;;
      *)
        echo "Please enter bootstrap or reuse."
        ;;
    esac
  done

  if [[ "${INSTALL_MODE}" == "reuse" ]]; then
    DATA_SOURCE_MODE="pack"
    prompt_value DATA_PACK_HOST_PATH "Data pack host path (.tar.gz)" "${DATA_PACK_HOST_PATH}"
    CLIENT_ARCHIVE_HOST_PATH=""
    PACKAGE_BOOTSTRAP_DATA="0"
  else
    DATA_SOURCE_MODE="client"
    prompt_value CLIENT_ARCHIVE_HOST_PATH "Client archive host path (.zip/.7z)" "${CLIENT_ARCHIVE_HOST_PATH}"
    DATA_PACK_HOST_PATH=""
    prompt_yes_no PACKAGE_BOOTSTRAP_DATA "Package extracted data for future reuse?" "${PACKAGE_BOOTSTRAP_DATA}"
    if [[ "${PACKAGE_BOOTSTRAP_DATA}" == "1" ]]; then
      prompt_value BOOTSTRAP_PACK_HOST_PATH "Bootstrap pack output path (.tar.gz)" "${BOOTSTRAP_PACK_HOST_PATH}"
    fi
  fi

  prompt_yes_no FORCE_DATA_REFRESH "Force redeploy/reextract data?" "${FORCE_DATA_REFRESH}"
}

validate_data_source() {
  if [[ "${INSTALL_MODE}" != "bootstrap" && "${INSTALL_MODE}" != "reuse" ]]; then
    echo "ERROR: INSTALL_MODE must be set to 'bootstrap' or 'reuse'." >&2
    exit 1
  fi

  if [[ "${INSTALL_MODE}" == "reuse" ]]; then
    DATA_SOURCE_MODE="pack"
  else
    DATA_SOURCE_MODE="client"
  fi

  if [[ "${INSTALL_MODE}" == "reuse" && -z "${DATA_PACK_HOST_PATH}" ]]; then
    echo "ERROR: DATA_PACK_HOST_PATH is required when INSTALL_MODE=reuse." >&2
    exit 1
  fi

  if [[ "${INSTALL_MODE}" == "bootstrap" && -z "${CLIENT_ARCHIVE_HOST_PATH}" ]]; then
    echo "ERROR: CLIENT_ARCHIVE_HOST_PATH is required when INSTALL_MODE=bootstrap." >&2
    exit 1
  fi
}

ensure_ct_started() {
  local ctid="$1"
  if ct_running "${ctid}"; then
    echo "==> CT ${ctid} already running"
    return 0
  fi

  echo "==> Starting CT ${ctid}"
  pct start "${ctid}"
}

adjust_build_resources_for_bootstrap() {
  local current_cores=""
  local desired_cores=""

  if [[ "${INSTALL_MODE}" != "bootstrap" ]]; then
    return 0
  fi

  desired_cores="$(( WORLD_CORES * 2 ))"
  current_cores="$(pct config "${BUILD_CTID}" 2>/dev/null | awk -F': ' '/^cores:/ { print $2; exit }')"

  if [[ -z "${current_cores}" ]]; then
    return 0
  fi

  if [[ "${current_cores}" -lt "${desired_cores}" ]]; then
    ORIGINAL_BUILD_CORES="${current_cores}"
    BUILD_CORES_BUMPED="1"
    echo "==> Bootstrap mode: increasing build CT ${BUILD_CTID} cores from ${current_cores} to ${desired_cores}"
    pct set "${BUILD_CTID}" --cores "${desired_cores}"
  else
    echo "==> Bootstrap mode: build CT ${BUILD_CTID} already has ${current_cores} cores"
  fi
}

restore_build_resources_after_bootstrap() {
  if [[ "${BUILD_CORES_BUMPED}" != "1" || -z "${ORIGINAL_BUILD_CORES}" ]]; then
    return 0
  fi

  echo "==> Restoring build CT ${BUILD_CTID} cores to ${ORIGINAL_BUILD_CORES}"
  pct set "${BUILD_CTID}" --cores "${ORIGINAL_BUILD_CORES}"
  BUILD_CORES_BUMPED="0"
}

provision_lxcs() {
  local template_ref=""
  local ct_storage_ref=""
  local realm_slug
  local world_ctid
  local builder_matches_world=0

  template_ref="$(detect_template_ref)"
  ct_storage_ref="$(detect_ct_storage)"
  CT_STORAGE="${ct_storage_ref}"

  create_ct_if_missing "${DB_CTID}" "snapjaw-db" "${DB_DISK_GB}" "${DB_MEMORY_MB}" "${DB_SWAP_MB}" "${DB_CORES}" "${template_ref}"
  create_ct_if_missing "${REALMD_CTID}" "snapjaw-realmd" "${REALMD_DISK_GB}" "${REALMD_MEMORY_MB}" "${REALMD_SWAP_MB}" "${REALMD_CORES}" "${template_ref}"

  while IFS='|' read -r realm_slug world_ctid _rest; do
    [[ -n "${realm_slug}" ]] || continue
    create_ct_if_missing "${world_ctid}" "snapjaw-${realm_slug}" "${WORLD_DISK_GB}" "${WORLD_MEMORY_MB}" "${WORLD_SWAP_MB}" "${WORLD_CORES}" "${template_ref}"
    if [[ "${world_ctid}" == "${BUILD_CTID}" ]]; then
      builder_matches_world=1
    fi
  done <<< "${REALM_MATRIX}"

  if [[ "${builder_matches_world}" == "0" && "${BUILD_CTID}" != "${DB_CTID}" && "${BUILD_CTID}" != "${REALMD_CTID}" ]]; then
    create_ct_if_missing "${BUILD_CTID}" "snapjaw-build" "${WORLD_DISK_GB}" "${WORLD_MEMORY_MB}" "${WORLD_SWAP_MB}" "${WORLD_CORES}" "${template_ref}"
  fi

  ensure_ct_started "${DB_CTID}"
  ensure_ct_started "${REALMD_CTID}"

  while IFS='|' read -r _realm_slug world_ctid _rest; do
    [[ -n "${world_ctid}" ]] || continue
    ensure_ct_started "${world_ctid}"
  done <<< "${REALM_MATRIX}"

  if [[ "${builder_matches_world}" == "0" && "${BUILD_CTID}" != "${DB_CTID}" && "${BUILD_CTID}" != "${REALMD_CTID}" ]]; then
    ensure_ct_started "${BUILD_CTID}"
  fi
}

resolve_auto_values() {
  local resolved_matrix=""
  local realm_slug
  local world_ctid
  local realm_id
  local realm_name
  local realm_address
  local world_port

  if [[ -z "${DB_HOST}" || "${DB_HOST}" == "auto" ]]; then
    DB_HOST="$(detect_ct_ip "${DB_CTID}")"
  fi

  while IFS='|' read -r realm_slug world_ctid realm_id realm_name realm_address world_port; do
    [[ -n "${realm_slug}" ]] || continue

    if [[ -z "${realm_address}" || "${realm_address}" == "auto" ]]; then
      realm_address="$(detect_ct_ip "${world_ctid}")"
    fi

    if [[ -n "${resolved_matrix}" ]]; then
      resolved_matrix+=$'\n'
    fi
    resolved_matrix+="${realm_slug}|${world_ctid}|${realm_id}|${realm_name}|${realm_address}|${world_port}"
  done <<< "${REALM_MATRIX}"

  REALM_MATRIX="${resolved_matrix}"
}

save_env_file() {
  cat > "${ENV_FILE}" <<EOF
DB_CTID='${DB_CTID}'
REALMD_CTID='${REALMD_CTID}'
BUILD_CTID='${BUILD_CTID}'
LOGIN_DB='${LOGIN_DB}'
DB_HOST='${DB_HOST}'
DB_PORT='${DB_PORT}'
DB_ROOT_PASSWORD='${DB_ROOT_PASSWORD}'
DB_ADMIN_USER='${DB_ADMIN_USER}'
DB_ADMIN_PASSWORD='${DB_ADMIN_PASSWORD}'
DB_APP_USER='${DB_APP_USER}'
DB_APP_PASSWORD='${DB_APP_PASSWORD}'
AUTH_WEB_BOOTSTRAP_ADMIN_KEY='${AUTH_WEB_BOOTSTRAP_ADMIN_KEY}'
CT_TEMPLATE_STORAGE='${CT_TEMPLATE_STORAGE}'
CT_TEMPLATE='${CT_TEMPLATE}'
CT_STORAGE='${CT_STORAGE}'
CT_BRIDGE='${CT_BRIDGE}'
CT_ONBOOT='${CT_ONBOOT}'
CT_UNPRIVILEGED='${CT_UNPRIVILEGED}'
DB_DISK_GB='${DB_DISK_GB}'
DB_MEMORY_MB='${DB_MEMORY_MB}'
DB_SWAP_MB='${DB_SWAP_MB}'
DB_CORES='${DB_CORES}'
REALMD_DISK_GB='${REALMD_DISK_GB}'
REALMD_MEMORY_MB='${REALMD_MEMORY_MB}'
REALMD_SWAP_MB='${REALMD_SWAP_MB}'
REALMD_CORES='${REALMD_CORES}'
WORLD_DISK_GB='${WORLD_DISK_GB}'
WORLD_MEMORY_MB='${WORLD_MEMORY_MB}'
WORLD_SWAP_MB='${WORLD_SWAP_MB}'
WORLD_CORES='${WORLD_CORES}'
FORCE_REBUILD='${FORCE_REBUILD}'
INSTALL_MODE='${INSTALL_MODE}'
DATA_SOURCE_MODE='${DATA_SOURCE_MODE}'
DATA_PACK_HOST_PATH='${DATA_PACK_HOST_PATH}'
CLIENT_ARCHIVE_HOST_PATH='${CLIENT_ARCHIVE_HOST_PATH}'
FORCE_DATA_REFRESH='${FORCE_DATA_REFRESH}'
PACKAGE_BOOTSTRAP_DATA='${PACKAGE_BOOTSTRAP_DATA}'
BOOTSTRAP_PACK_HOST_PATH='${BOOTSTRAP_PACK_HOST_PATH}'
PRIMARY_REALM='${PRIMARY_REALM}'
EXTRA_REALMS='${EXTRA_REALMS}'
REALM_SLUGS='${REALM_SLUGS}'
INCLUDE_LOGS='${INCLUDE_LOGS}'
REALM_MATRIX=$(cat <<'REALMS'
${REALM_MATRIX}
REALMS
)
EOF
  chmod 600 "${ENV_FILE}"
}

interactive_setup() {
  echo "==> SnapJaw installer setup"
  echo "Press Enter to keep the current value shown in brackets."
  echo

  prompt_value DB_CTID "DB CTID" "${DB_CTID}"
  prompt_value REALMD_CTID "Realmd CTID" "${REALMD_CTID}"
  prompt_value BUILD_CTID "Build CTID" "${BUILD_CTID}"
  prompt_value DB_HOST "DB host address or auto" "${DB_HOST}"
  prompt_value DB_PORT "DB port" "${DB_PORT}"
  prompt_value LOGIN_DB "Login DB name" "${LOGIN_DB}"
  prompt_value DB_ROOT_PASSWORD "DB root password" "${DB_ROOT_PASSWORD}" 1
  prompt_value DB_ADMIN_USER "DB admin user" "${DB_ADMIN_USER}"
  prompt_value DB_ADMIN_PASSWORD "DB admin password" "${DB_ADMIN_PASSWORD}" 1
  prompt_value DB_APP_USER "App DB user" "${DB_APP_USER}"
  prompt_value DB_APP_PASSWORD "App DB password" "${DB_APP_PASSWORD}" 1
  prompt_template_storage_choice "${CT_TEMPLATE_STORAGE}"
  prompt_template_choice "${CT_TEMPLATE}"
  prompt_value CT_STORAGE "Container storage" "${CT_STORAGE}"
  prompt_value CT_BRIDGE "Network bridge" "${CT_BRIDGE}"
  prompt_value DB_DISK_GB "DB disk GB" "${DB_DISK_GB}"
  prompt_value DB_MEMORY_MB "DB memory MB" "${DB_MEMORY_MB}"
  prompt_value DB_CORES "DB CPU cores" "${DB_CORES}"
  prompt_value REALMD_DISK_GB "Realmd disk GB" "${REALMD_DISK_GB}"
  prompt_value REALMD_MEMORY_MB "Realmd memory MB" "${REALMD_MEMORY_MB}"
  prompt_value REALMD_CORES "Realmd CPU cores" "${REALMD_CORES}"
  prompt_value WORLD_DISK_GB "World disk GB" "${WORLD_DISK_GB}"
  prompt_value WORLD_MEMORY_MB "World memory MB" "${WORLD_MEMORY_MB}"
  prompt_value WORLD_CORES "World CPU cores" "${WORLD_CORES}"
  prompt_yes_no FORCE_REBUILD "Force clean rebuild on each run?" "${FORCE_REBUILD}"
  prompt_install_mode
  prompt_yes_no INCLUDE_LOGS "Create and use logs DBs?" "${INCLUDE_LOGS}"
  prompt_realms "${REALM_MATRIX}"
  derive_realm_values
  save_env_file
  echo
  echo "==> Saved configuration to ${ENV_FILE}"
}

REQUEST_PROMPT="0"
WRITE_ENV_ONLY="0"

for arg in "$@"; do
  case "${arg}" in
    --prompt)
      REQUEST_PROMPT="1"
      ;;
    --write-env-only)
      REQUEST_PROMPT="1"
      WRITE_ENV_ONLY="1"
      ;;
    --dry-run)
      DRY_RUN="1"
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      exit 1
      ;;
  esac
done

load_env_file
ensure_generated_defaults
print_repo_version

if [[ "${REQUEST_PROMPT}" == "1" || ! -f "${ENV_FILE}" ]]; then
  interactive_setup
else
  derive_realm_values
fi

if [[ "${WRITE_ENV_ONLY}" == "1" ]]; then
  exit 0
fi

validate_data_source

if [[ "${DRY_RUN}" != "1" ]]; then
  trap restore_build_resources_after_bootstrap EXIT
fi

echo "==> Step 1/6: Provision LXCs"
show_plan_and_confirm
if [[ "${DRY_RUN}" == "1" ]]; then
  perform_dry_run
  exit 0
fi
provision_lxcs
adjust_build_resources_for_bootstrap
resolve_auto_values

echo "==> Step 2/6: DB host setup"
env \
  DB_CTID="${DB_CTID}" \
  DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD}" \
  DB_ADMIN_USER="${DB_ADMIN_USER}" \
  DB_ADMIN_PASSWORD="${DB_ADMIN_PASSWORD}" \
  DB_APP_USER="${DB_APP_USER}" \
  DB_APP_PASSWORD="${DB_APP_PASSWORD}" \
  LOGIN_DB="${LOGIN_DB}" \
  REALM_SLUGS="${REALM_SLUGS}" \
  INCLUDE_LOGS="${INCLUDE_LOGS}" \
  "${SCRIPT_DIR}/01-db-host-setup.sh"

echo "==> Step 3/6: Build and seed"
build_extractors="0"
if [[ "${INSTALL_MODE}" == "bootstrap" ]]; then
  build_extractors="1"
fi
env \
  BUILD_CTID="${BUILD_CTID}" \
  DB_HOST="${DB_HOST}" \
  DB_PORT="${DB_PORT}" \
  DB_APP_USER="${DB_APP_USER}" \
  DB_APP_PASSWORD="${DB_APP_PASSWORD}" \
  LOGIN_DB="${LOGIN_DB}" \
  PRIMARY_REALM="${PRIMARY_REALM}" \
  EXTRA_REALMS="${EXTRA_REALMS}" \
  FORCE_REBUILD="${FORCE_REBUILD}" \
  BUILD_EXTRACTORS="${build_extractors}" \
  "${SCRIPT_DIR}/02-build-and-seed.sh"

echo "==> Step 4/6: Shared realmd setup"
env \
  REALMD_CTID="${REALMD_CTID}" \
  BUILD_CTID="${BUILD_CTID}" \
  DB_HOST="${DB_HOST}" \
  DB_PORT="${DB_PORT}" \
  DB_APP_USER="${DB_APP_USER}" \
  DB_APP_PASSWORD="${DB_APP_PASSWORD}" \
  LOGIN_DB="${LOGIN_DB}" \
  AUTH_WEB_BOOTSTRAP_ADMIN_KEY="${AUTH_WEB_BOOTSTRAP_ADMIN_KEY}" \
  "${SCRIPT_DIR}/03-realmd-setup.sh"

echo "==> Step 5/6: Data setup"
env \
  BUILD_CTID="${BUILD_CTID}" \
  INSTALL_MODE="${INSTALL_MODE}" \
  DATA_SOURCE_MODE="${DATA_SOURCE_MODE}" \
  DATA_PACK_HOST_PATH="${DATA_PACK_HOST_PATH}" \
  CLIENT_ARCHIVE_HOST_PATH="${CLIENT_ARCHIVE_HOST_PATH}" \
  FORCE_DATA_REFRESH="${FORCE_DATA_REFRESH}" \
  PACKAGE_BOOTSTRAP_DATA="${PACKAGE_BOOTSTRAP_DATA}" \
  BOOTSTRAP_PACK_HOST_PATH="${BOOTSTRAP_PACK_HOST_PATH}" \
  REALM_MATRIX="${REALM_MATRIX}" \
  "${SCRIPT_DIR}/05-data-setup.sh"

echo "==> Step 6/6: World realm setup"
while IFS='|' read -r realm_slug world_ctid realm_id realm_name realm_address world_port; do
  [[ -n "${realm_slug}" ]] || continue
  env \
    WORLD_CTID="${world_ctid}" \
    BUILD_CTID="${BUILD_CTID}" \
    DB_HOST="${DB_HOST}" \
    DB_PORT="${DB_PORT}" \
    DB_APP_USER="${DB_APP_USER}" \
    DB_APP_PASSWORD="${DB_APP_PASSWORD}" \
    LOGIN_DB="${LOGIN_DB}" \
    REALM_SLUG="${realm_slug}" \
    REALM_ID="${realm_id}" \
    REALM_NAME="${realm_name}" \
    REALM_ADDRESS="${realm_address}" \
    WORLD_PORT="${world_port}" \
    WITH_LOG_DB="${INCLUDE_LOGS}" \
    "${SCRIPT_DIR}/04-world-setup.sh"
done <<< "${REALM_MATRIX}"

echo "==> SnapJaw install flow completed"
