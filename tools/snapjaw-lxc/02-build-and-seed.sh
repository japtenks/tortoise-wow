#!/usr/bin/env bash
set -euo pipefail

: "${BUILD_CTID:=503}"
: "${DB_HOST:=127.0.0.1}"
: "${DB_PORT:=3306}"
: "${DB_APP_USER:=torta}"
: "${DB_APP_PASSWORD:=torta}"
: "${LOGIN_DB:=snapjawrealmd}"
: "${PRIMARY_REALM:=stable}"
: "${EXTRA_REALMS:=ptr}"
: "${REPO_URL:=https://github.com/japtenks/tortoise-wow.git}"
: "${REPO_BRANCH:=main}"
: "${SOURCE_DIR:=/opt/tortoise-wow}"
: "${BUILD_DIR:=/opt/tortoise-wow-build}"
: "${INSTALL_DIR:=/opt/snapjaw}"
: "${BUILD_TYPE:=Release}"
: "${FORCE_REBUILD:=0}"
: "${BUILD_EXTRACTORS:=0}"

echo "==> Installing build prerequisites in CT ${BUILD_CTID}"
pct exec "${BUILD_CTID}" -- bash -lc '
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

echo "==> Cloning and building tortoise-wow in CT ${BUILD_CTID}"
pct exec "${BUILD_CTID}" -- bash -lc "
set -e
if [[ '${BUILD_EXTRACTORS}' == '1' ]]; then
  use_extractors='ON'
else
  use_extractors='OFF'
fi

if [[ '${FORCE_REBUILD}' == '1' ]]; then
  echo '==> FORCE_REBUILD=1, removing existing source/build/install directories'
  rm -rf '${SOURCE_DIR}' '${BUILD_DIR}' '${INSTALL_DIR}'
fi

if [[ ! -d '${SOURCE_DIR}/.git' ]]; then
  git clone --branch '${REPO_BRANCH}' '${REPO_URL}' '${SOURCE_DIR}'
else
  git -C '${SOURCE_DIR}' fetch --all --prune
  git -C '${SOURCE_DIR}' checkout '${REPO_BRANCH}'
  git -C '${SOURCE_DIR}' reset --hard 'origin/${REPO_BRANCH}'
fi

cmake -S '${SOURCE_DIR}' -B '${BUILD_DIR}' -G Ninja \
  -DCMAKE_INSTALL_PREFIX='${INSTALL_DIR}' \
  -DCMAKE_BUILD_TYPE='${BUILD_TYPE}' \
  -DALLOW_TURTLE_ADDONS='ON' \
  -DUSE_EXTRACTORS=\"\${use_extractors}\"
cmake --build '${BUILD_DIR}' --target install
"

echo "==> Seeding primary realm '${PRIMARY_REALM}' into MariaDB"
pct exec "${BUILD_CTID}" -- bash -lc "
set -euo pipefail
export MYSQL_PWD='${DB_APP_PASSWORD}'
MYSQL_ARGS=(--skip-ssl --host='${DB_HOST}' --port='${DB_PORT}' --user='${DB_APP_USER}')
mariadb \"\${MYSQL_ARGS[@]}\" -e 'SELECT CURRENT_USER(), @@hostname;'
perl -pe \"s#/\\\\*![0-9]{5} DEFINER=\\\\x60[^\\\\x60]*\\\\x60@\\\\x60[^\\\\x60]*\\\\x60\\\\*/##g; s/\\\\btw_world\\\\b/${PRIMARY_REALM}world/g; s/\\\\btw_char\\\\b/${PRIMARY_REALM}characters/g; s/\\\\btw_logs\\\\b/${PRIMARY_REALM}logs/g; s/\\\\btw_logon\\\\b/${LOGIN_DB}/g\" \
  '${SOURCE_DIR}/sql/create_databases.sql' | mariadb \"\${MYSQL_ARGS[@]}\"
for f in '${SOURCE_DIR}'/sql/base/tw_world_*.sql; do
  [ -e \"\$f\" ] || continue
  perl -pe 's/\\btw_world\\b/${PRIMARY_REALM}world/g' \"\$f\" | mariadb \"\${MYSQL_ARGS[@]}\" '${PRIMARY_REALM}world'
done
"

for realm in ${EXTRA_REALMS}; do
  echo "==> Cloning primary realm data into '${realm}'"
  pct exec "${BUILD_CTID}" -- bash -lc "
set -euo pipefail
export MYSQL_PWD='${DB_APP_PASSWORD}'
mysqldump --skip-ssl --host='${DB_HOST}' --port='${DB_PORT}' --user='${DB_APP_USER}' '${PRIMARY_REALM}world' \
  | mariadb --skip-ssl --host='${DB_HOST}' --port='${DB_PORT}' --user='${DB_APP_USER}' '${realm}world'
mysqldump --skip-ssl --no-data --host='${DB_HOST}' --port='${DB_PORT}' --user='${DB_APP_USER}' '${PRIMARY_REALM}characters' \
  | mariadb --skip-ssl --host='${DB_HOST}' --port='${DB_PORT}' --user='${DB_APP_USER}' '${realm}characters'
if mariadb --skip-ssl --host='${DB_HOST}' --port='${DB_PORT}' --user='${DB_APP_USER}' -Nse \"SHOW DATABASES LIKE '${PRIMARY_REALM}logs'\" | grep -q .; then
  mysqldump --skip-ssl --no-data --host='${DB_HOST}' --port='${DB_PORT}' --user='${DB_APP_USER}' '${PRIMARY_REALM}logs' \
    | mariadb --skip-ssl --host='${DB_HOST}' --port='${DB_PORT}' --user='${DB_APP_USER}' '${realm}logs'
fi
"
done

echo "==> Done. Binaries are installed in ${INSTALL_DIR} on CT ${BUILD_CTID}"
