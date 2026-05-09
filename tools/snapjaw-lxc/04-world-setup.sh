#!/usr/bin/env bash
set -euo pipefail

: "${WORLD_CTID:?WORLD_CTID is required}"
: "${BUILD_CTID:=503}"
: "${DB_HOST:=192.168.1.44}"
: "${DB_PORT:=3306}"
: "${DB_APP_USER:=torta}"
: "${DB_APP_PASSWORD:=torta}"
: "${LOGIN_DB:=snapjawrealmd}"
: "${REALM_SLUG:?REALM_SLUG is required}"
: "${REALM_ID:?REALM_ID is required}"
: "${REALM_NAME:=Project Snapjaw ${REALM_SLUG}}"
: "${REALM_ADDRESS:?REALM_ADDRESS is required}"
: "${WORLD_PORT:?WORLD_PORT is required}"
: "${TIMEZONE_ID:=1}"
: "${REALM_BUILDS:=5875}"
: "${INSTALL_DIR:=/opt/snapjaw}"
: "${SOURCE_DIR:=/opt/tortoise-wow}"
: "${WITH_LOG_DB:=1}"

realm_world_db="${REALM_SLUG}world"
realm_char_db="${REALM_SLUG}characters"
realm_logs_db="${REALM_SLUG}logs"
realm_name_sql="${REALM_NAME//\'/\'\'}"
realm_address_sql="${REALM_ADDRESS//\'/\'\'}"

echo "==> Installing world runtime dependencies in CT ${WORLD_CTID}"
pct exec "${WORLD_CTID}" -- bash -lc '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  ca-certificates locales \
  mariadb-client libmariadb3 libmariadb-dev \
  libace-dev libssl-dev libtbb-dev \
  zlib1g libbz2-1.0 libreadline-dev libncurses-dev
sed -i "s/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8
mkdir -p /opt/snapjaw/bin /opt/snapjaw/etc /opt/snapjaw/logs /opt/snapjaw/data /opt/tortoise-wow/sql/database_updates
'

echo "==> Copying mangosd binary, sample config, and world SQL updates from CT ${BUILD_CTID} to CT ${WORLD_CTID}"
if [[ "${WORLD_CTID}" == "${BUILD_CTID}" ]]; then
  pct exec "${WORLD_CTID}" -- bash -lc "
set -e
test -x '${INSTALL_DIR}/bin/mangosd'
test -f '${INSTALL_DIR}/etc/mangosd.conf.dist'
test -d '${SOURCE_DIR}/sql/database_updates'
"
else
  pct exec "${BUILD_CTID}" -- tar -C / -cf - "${INSTALL_DIR#/}/bin/mangosd" "${INSTALL_DIR#/}/etc/mangosd.conf.dist" "${SOURCE_DIR#/}/sql/database_updates" | pct exec "${WORLD_CTID}" -- tar -C / -xf -
fi

echo "==> Writing mangosd.conf for realm '${REALM_SLUG}'"
pct exec "${WORLD_CTID}" -- bash -lc "
set -e
cp -f '${INSTALL_DIR}/etc/mangosd.conf.dist' '${INSTALL_DIR}/etc/mangosd.conf'
sed -i \
  -e 's|^DataDir *=.*|DataDir = \"${INSTALL_DIR}/data\"|' \
  -e 's|^Database.AutoUpdate.Enabled *=.*|Database.AutoUpdate.Enabled = 1|' \
  -e 's|^Database.AutoUpdate.Path *=.*|Database.AutoUpdate.Path = \"${SOURCE_DIR}/sql/\"|' \
  -e 's|^Database.AutoUpdate.WorldUpdateName *=.*|Database.AutoUpdate.WorldUpdateName = \"database_updates\"|' \
  -e 's|^RealmID *=.*|RealmID = ${REALM_ID}|' \
  -e 's|^WorldServerPort *=.*|WorldServerPort = ${WORLD_PORT}|' \
  -e 's|^Console.Enable *=.*|Console.Enable = 0|' \
  -e 's|^BindIP *=.*|BindIP = \"0.0.0.0\"|' \
  -e 's|^LoginDatabase.Info *=.*|LoginDatabase.Info = \"${DB_HOST};${DB_PORT};${DB_APP_USER};${DB_APP_PASSWORD};${LOGIN_DB}\"|' \
  -e 's|^WorldDatabase.Info *=.*|WorldDatabase.Info = \"${DB_HOST};${DB_PORT};${DB_APP_USER};${DB_APP_PASSWORD};${realm_world_db}\"|' \
  -e 's|^CharacterDatabase.Info *=.*|CharacterDatabase.Info = \"${DB_HOST};${DB_PORT};${DB_APP_USER};${DB_APP_PASSWORD};${realm_char_db}\"|' \
  '${INSTALL_DIR}/etc/mangosd.conf'
if [[ '${WITH_LOG_DB}' == '1' ]]; then
  sed -i \
    -e 's|^LogsDatabase.Info *=.*|LogsDatabase.Info = \"${DB_HOST};${DB_PORT};${DB_APP_USER};${DB_APP_PASSWORD};${realm_logs_db}\"|' \
    '${INSTALL_DIR}/etc/mangosd.conf'
fi
grep -q '^Database.AutoUpdate.Enabled' '${INSTALL_DIR}/etc/mangosd.conf' || echo 'Database.AutoUpdate.Enabled = 1' >> '${INSTALL_DIR}/etc/mangosd.conf'
grep -q '^Database.AutoUpdate.Path' '${INSTALL_DIR}/etc/mangosd.conf' || echo 'Database.AutoUpdate.Path = \"${SOURCE_DIR}/sql/\"' >> '${INSTALL_DIR}/etc/mangosd.conf'
grep -q '^Database.AutoUpdate.WorldUpdateName' '${INSTALL_DIR}/etc/mangosd.conf' || echo 'Database.AutoUpdate.WorldUpdateName = \"database_updates\"' >> '${INSTALL_DIR}/etc/mangosd.conf'
cat > /etc/systemd/system/mangosd.service <<'EOF'
[Unit]
Description=SnapJaw ${REALM_SLUG} mangosd
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}/bin
ExecStart=${INSTALL_DIR}/bin/mangosd -c ${INSTALL_DIR}/etc/mangosd.conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mangosd
"

echo "==> Registering realm '${REALM_NAME}' in ${LOGIN_DB}.realmlist"
pct exec "${BUILD_CTID}" -- bash -lc "
set -e
export MYSQL_PWD='${DB_APP_PASSWORD}'
mariadb --skip-ssl --host='${DB_HOST}' --port='${DB_PORT}' --user='${DB_APP_USER}' '${LOGIN_DB}' -e \"
DELETE FROM realmlist WHERE id=${REALM_ID};
INSERT INTO realmlist
  (id, name, address, port, icon, realmflags, timezone, allowedSecurityLevel, population, realmbuilds)
VALUES
  (${REALM_ID}, '${realm_name_sql}', '${realm_address_sql}', ${WORLD_PORT}, 0, 0, ${TIMEZONE_ID}, 0, 0, '${REALM_BUILDS}');
\"
"

echo "==> Restarting mangosd in CT ${WORLD_CTID}"
pct exec "${WORLD_CTID}" -- bash -lc "
systemctl restart mangosd
systemctl status mangosd --no-pager
"
