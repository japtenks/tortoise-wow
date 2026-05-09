#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${SCRIPT_DIR}/auth-web"
VENV_DIR="${APP_DIR}/.venv"
PYLIB_DIR="${APP_DIR}/.pylibs"
ENV_FILE="${APP_DIR}/.env.local"

cd "${APP_DIR}"

ensure_local_pip() {
  if python3 -m pip --version >/dev/null 2>&1; then
    return
  fi

  local get_pip
  get_pip="$(mktemp)"
  python3 - "${get_pip}" <<'PY'
import sys
import urllib.request

target = sys.argv[1]
urllib.request.urlretrieve("https://bootstrap.pypa.io/get-pip.py", target)
PY
  python3 "${get_pip}" --user --break-system-packages
  rm -f "${get_pip}"
}

if python3 -m venv "${VENV_DIR}" >/dev/null 2>&1; then
  source "${VENV_DIR}/bin/activate"
  python -m pip install --upgrade pip >/dev/null
  python -m pip install -r "${APP_DIR}/requirements-local.txt"
else
  ensure_local_pip
  rm -rf "${PYLIB_DIR}"
  python3 -m pip install --user --upgrade pip --break-system-packages >/dev/null
  python3 -m pip install --break-system-packages --target "${PYLIB_DIR}" -r "${APP_DIR}/requirements-local.txt"
  export PYTHONPATH="${PYLIB_DIR}${PYTHONPATH:+:${PYTHONPATH}}"
fi

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

: "${AUTH_WEB_SECRET:=local-dev-secret}"
: "${AUTH_WEB_DB_HOST:=192.168.1.44}"
: "${AUTH_WEB_DB_PORT:=3306}"
: "${AUTH_WEB_DB_USER:=torta}"
: "${AUTH_WEB_DB_PASSWORD:=torta}"
: "${AUTH_WEB_LOGIN_DB:=snapjawrealmd}"
: "${AUTH_WEB_CHARACTER_DBS:=stablecharacters,ptrcharacters}"
: "${AUTH_WEB_PORT:=8080}"

export AUTH_WEB_SECRET
export AUTH_WEB_DB_HOST
export AUTH_WEB_DB_PORT
export AUTH_WEB_DB_USER
export AUTH_WEB_DB_PASSWORD
export AUTH_WEB_LOGIN_DB
export AUTH_WEB_CHARACTER_DBS
export AUTH_WEB_PORT

echo "Starting SnapJaw auth portal on http://localhost:${AUTH_WEB_PORT}"
echo "Using DB ${AUTH_WEB_DB_HOST}:${AUTH_WEB_DB_PORT}/${AUTH_WEB_LOGIN_DB}"

exec python3 "${APP_DIR}/app.py"
