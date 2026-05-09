#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

: "${REALMD_CTID:=502}"
: "${BUILD_CTID:=503}"
: "${DB_HOST:=192.168.1.44}"
: "${DB_PORT:=3306}"
: "${DB_APP_USER:=torta}"
: "${DB_APP_PASSWORD:=torta}"
: "${LOGIN_DB:=snapjawrealmd}"
: "${INSTALL_DIR:=/opt/snapjaw}"
: "${AUTH_WEB_PORT:=8080}"
: "${AUTH_WEB_CHARACTER_DBS:=stablecharacters,ptrcharacters}"
: "${AUTH_WEB_BOOTSTRAP_ADMIN_KEY:=}"
: "${FORCE_PIN_ACCOUNT_RANK:=99}"

auth_web_secret="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"

realmd_is_healthy() {
  pct exec "${REALMD_CTID}" -- bash -lc "
set -euo pipefail
test -x '${INSTALL_DIR}/bin/realmd'
test -f '${INSTALL_DIR}/etc/realmd.conf'
grep -Fq 'LoginDatabaseInfo = \"${DB_HOST};${DB_PORT};${DB_APP_USER};${DB_APP_PASSWORD};${LOGIN_DB}\"' '${INSTALL_DIR}/etc/realmd.conf'
grep -Fq 'BindIP = \"0.0.0.0\"' '${INSTALL_DIR}/etc/realmd.conf'
grep -Fq 'ForcePinAccountRank = ${FORCE_PIN_ACCOUNT_RANK}' '${INSTALL_DIR}/etc/realmd.conf'
test -f '${INSTALL_DIR}/auth-web/app.py'
test -f '${INSTALL_DIR}/auth-web/auth-web.env'
grep -Fq 'AUTH_WEB_PORT=${AUTH_WEB_PORT}' '${INSTALL_DIR}/auth-web/auth-web.env'
mariadb --skip-ssl --host='${DB_HOST}' --port='${DB_PORT}' --user='${DB_APP_USER}' --password='${DB_APP_PASSWORD}' '${LOGIN_DB}' -N -B -e 'SELECT 1;' >/dev/null
systemctl is-active --quiet realmd
systemctl is-active --quiet snapjaw-auth-web
"
}

if realmd_is_healthy; then
  echo "==> realmd already healthy in CT ${REALMD_CTID}, skipping setup"
  exit 0
fi

echo "==> Installing realmd runtime dependencies in CT ${REALMD_CTID}"
pct exec "${REALMD_CTID}" -- bash -lc '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  ca-certificates locales \
  mariadb-client libmariadb3 libmariadb-dev \
  libace-dev libssl-dev libtbb-dev \
  zlib1g libbz2-1.0 libreadline-dev libncurses-dev \
  python3 python3-flask python3-pymysql
sed -i "s/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8
mkdir -p /opt/snapjaw/bin /opt/snapjaw/etc /opt/snapjaw/logs /opt/snapjaw/auth-web
id -u snapjaw-auth-web >/dev/null 2>&1 || useradd --system --home-dir /opt/snapjaw/auth-web --shell /usr/sbin/nologin snapjaw-auth-web
'

echo "==> Copying realmd binary and sample config from CT ${BUILD_CTID} to CT ${REALMD_CTID}"
pct exec "${BUILD_CTID}" -- tar -C "${INSTALL_DIR}" -cf - bin/realmd etc/realmd.conf.dist | pct exec "${REALMD_CTID}" -- tar -C "${INSTALL_DIR}" -xf -

echo "==> Copying auth web app to CT ${REALMD_CTID}"
tar -C "${SCRIPT_DIR}" -cf - auth-web | pct exec "${REALMD_CTID}" -- tar -C "${INSTALL_DIR}" -xf -

echo "==> Writing realmd.conf and service unit"
pct exec "${REALMD_CTID}" -- bash -lc "
set -e
cp -f '${INSTALL_DIR}/etc/realmd.conf.dist' '${INSTALL_DIR}/etc/realmd.conf'
sed -i \
  -e 's|^LoginDatabaseInfo *=.*|LoginDatabaseInfo = \"${DB_HOST};${DB_PORT};${DB_APP_USER};${DB_APP_PASSWORD};${LOGIN_DB}\"|' \
  -e 's|^BindIP *=.*|BindIP = \"0.0.0.0\"|' \
  '${INSTALL_DIR}/etc/realmd.conf'
if grep -q '^ForcePinAccountRank' '${INSTALL_DIR}/etc/realmd.conf'; then
  sed -i 's|^ForcePinAccountRank *=.*|ForcePinAccountRank = ${FORCE_PIN_ACCOUNT_RANK}|' '${INSTALL_DIR}/etc/realmd.conf'
else
  printf '\nForcePinAccountRank = ${FORCE_PIN_ACCOUNT_RANK}\n' >> '${INSTALL_DIR}/etc/realmd.conf'
fi
python3 - <<'PY'
from pathlib import Path
env_path = Path('${INSTALL_DIR}/auth-web/auth-web.env')
secret = '${auth_web_secret}'
if env_path.exists():
    for line in env_path.read_text(encoding='utf-8').splitlines():
        if line.startswith('AUTH_WEB_SECRET='):
            _, _, current = line.partition('=')
            if current:
                secret = current
                break
env_path.write_text(
    '\\n'.join([
        'AUTH_WEB_SECRET=' + secret,
        'AUTH_WEB_DB_HOST=${DB_HOST}',
        'AUTH_WEB_DB_PORT=${DB_PORT}',
        'AUTH_WEB_DB_USER=${DB_APP_USER}',
        'AUTH_WEB_DB_PASSWORD=${DB_APP_PASSWORD}',
        'AUTH_WEB_LOGIN_DB=${LOGIN_DB}',
        'AUTH_WEB_CHARACTER_DBS=${AUTH_WEB_CHARACTER_DBS}',
        'AUTH_WEB_PORT=${AUTH_WEB_PORT}',
        'AUTH_WEB_BOOTSTRAP_ADMIN_KEY=${AUTH_WEB_BOOTSTRAP_ADMIN_KEY}',
    ]) + '\\n',
    encoding='utf-8',
)
PY
chown -R snapjaw-auth-web:snapjaw-auth-web '${INSTALL_DIR}/auth-web'
chown root:snapjaw-auth-web '${INSTALL_DIR}/auth-web/auth-web.env'
chmod 750 '${INSTALL_DIR}/auth-web'
chmod 640 '${INSTALL_DIR}/auth-web/auth-web.env'
cat > /etc/systemd/system/realmd.service <<'EOF'
[Unit]
Description=SnapJaw realmd
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}/bin
ExecStart=${INSTALL_DIR}/bin/realmd -c ${INSTALL_DIR}/etc/realmd.conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/snapjaw-auth-web.service <<'EOF'
[Unit]
Description=SnapJaw auth web
After=network-online.target mariadb.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}/auth-web
User=snapjaw-auth-web
Group=snapjaw-auth-web
EnvironmentFile=${INSTALL_DIR}/auth-web/auth-web.env
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/auth-web/app.py
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable realmd
systemctl enable snapjaw-auth-web
systemctl restart realmd
systemctl restart snapjaw-auth-web
systemctl status realmd --no-pager
systemctl status snapjaw-auth-web --no-pager
"
