#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/snapjaw.env}"

: "${INSTALLER_REPO_BRANCH:=snapjaw/proxmox-final}"
: "${STABLE_REPO_BRANCH:=codex/proxmox-final}"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

find_realm_line() {
  local wanted_slug="$1"
  while IFS='|' read -r realm_slug world_ctid realm_id realm_name realm_address world_port; do
    [[ -n "${realm_slug}" ]] || continue
    if [[ "${realm_slug}" == "${wanted_slug}" ]]; then
      printf '%s|%s|%s|%s|%s|%s\n' "${realm_slug}" "${world_ctid}" "${realm_id}" "${realm_name}" "${realm_address}" "${world_port}"
      return 0
    fi
  done <<< "${REALM_MATRIX:-}"

  return 1
}

echo "==> Updating host checkout on branch '${INSTALLER_REPO_BRANCH}'"
git -C "${REPO_ROOT}" fetch origin
git -C "${REPO_ROOT}" checkout "${INSTALLER_REPO_BRANCH}"
git -C "${REPO_ROOT}" pull --ff-only origin "${INSTALLER_REPO_BRANCH}"

realm_line="$(find_realm_line stable)" || {
  echo "Stable realm not found in REALM_MATRIX." >&2
  exit 1
}
IFS='|' read -r realm_slug world_ctid realm_id realm_name realm_address world_port <<< "${realm_line}"

echo "==> Refreshing shared auth/realmd CT"
"${SCRIPT_DIR}/03-realmd-setup.sh"

echo "==> Updating stable realm from branch '${STABLE_REPO_BRANCH}'"
env \
  WORLD_CTID="${world_ctid}" \
  REALM_SLUG="${realm_slug}" \
  REALM_ID="${realm_id}" \
  REALM_NAME="${realm_name}" \
  REALM_ADDRESS="${realm_address}" \
  WORLD_PORT="${world_port}" \
  REPO_BRANCH="${STABLE_REPO_BRANCH}" \
  DB_HOST="${DB_HOST}" \
  DB_PORT="${DB_PORT}" \
  DB_APP_USER="${DB_APP_USER}" \
  DB_APP_PASSWORD="${DB_APP_PASSWORD}" \
  LOGIN_DB="${LOGIN_DB}" \
  WITH_LOG_DB="${INCLUDE_LOGS:-1}" \
  "${SCRIPT_DIR}/10-update-realm.sh"
