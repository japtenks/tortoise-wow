#!/usr/bin/env bash
set -euo pipefail

: "${WORLD_CTID:?WORLD_CTID is required}"
: "${REALM_SLUG:?REALM_SLUG is required}"
: "${REALM_ID:?REALM_ID is required}"
: "${REALM_NAME:?REALM_NAME is required}"
: "${REALM_ADDRESS:?REALM_ADDRESS is required}"
: "${WORLD_PORT:?WORLD_PORT is required}"
: "${REPO_URL:=https://github.com/japtenks/tortoise-wow.git}"
: "${REPO_BRANCH:?REPO_BRANCH is required}"
: "${DB_HOST:=127.0.0.1}"
: "${DB_PORT:=3306}"
: "${DB_APP_USER:=torta}"
: "${DB_APP_PASSWORD:=torta}"
: "${LOGIN_DB:=snapjawrealmd}"
: "${INSTALL_DIR:=/opt/snapjaw}"
: "${SOURCE_DIR:=/opt/tortoise-wow}"
: "${BUILD_DIR:=/opt/tortoise-wow-build}"
: "${WITH_LOG_DB:=1}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Updating realm '${REALM_SLUG}' in CT ${WORLD_CTID} from branch '${REPO_BRANCH}'"

echo "==> Installing build prerequisites in CT ${WORLD_CTID}"
pct exec "${WORLD_CTID}" -- bash -lc '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  ca-certificates locales \
  build-essential git cmake ninja-build pkg-config rsync \
  mariadb-client libmariadb3 libmariadb-dev libmariadb-dev-compat \
  libace-dev libssl-dev zlib1g-dev libbz2-dev \
  libreadline-dev libncurses-dev libtbb-dev libboost-all-dev
sed -i "s/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8
'

echo "==> Fetching source in CT ${WORLD_CTID}"
pct exec "${WORLD_CTID}" -- bash -lc "
set -euo pipefail
if [[ ! -d '${SOURCE_DIR}/.git' ]]; then
  git clone '${REPO_URL}' '${SOURCE_DIR}'
fi
git -C '${SOURCE_DIR}' fetch --all --prune
if ! git -C '${SOURCE_DIR}' rev-parse --verify --quiet 'origin/${REPO_BRANCH}' >/dev/null; then
  echo 'Remote branch origin/${REPO_BRANCH} does not exist.' >&2
  exit 1
fi
git -C '${SOURCE_DIR}' checkout '${REPO_BRANCH}'
git -C '${SOURCE_DIR}' reset --hard 'origin/${REPO_BRANCH}'
"

echo "==> Building realm '${REALM_SLUG}' in CT ${WORLD_CTID}"
pct exec "${WORLD_CTID}" -- bash -lc "
set -euo pipefail
cmake -S '${SOURCE_DIR}' -B '${BUILD_DIR}' -G Ninja \
  -DCMAKE_INSTALL_PREFIX='${INSTALL_DIR}' \
  -DCMAKE_BUILD_TYPE='Release' \
  -DALLOW_TURTLE_ADDONS='ON' \
  -DUSE_EXTRACTORS='OFF'
cmake --build '${BUILD_DIR}' --target install
"

echo "==> Rewriting config and restarting realm '${REALM_SLUG}'"
env \
  WORLD_CTID="${WORLD_CTID}" \
  BUILD_CTID="${WORLD_CTID}" \
  DB_HOST="${DB_HOST}" \
  DB_PORT="${DB_PORT}" \
  DB_APP_USER="${DB_APP_USER}" \
  DB_APP_PASSWORD="${DB_APP_PASSWORD}" \
  LOGIN_DB="${LOGIN_DB}" \
  REALM_SLUG="${REALM_SLUG}" \
  REALM_ID="${REALM_ID}" \
  REALM_NAME="${REALM_NAME}" \
  REALM_ADDRESS="${REALM_ADDRESS}" \
  WORLD_PORT="${WORLD_PORT}" \
  WITH_LOG_DB="${WITH_LOG_DB}" \
  "${SCRIPT_DIR}/04-world-setup.sh"
