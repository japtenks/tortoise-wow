#!/usr/bin/env bash
set -euo pipefail

: "${DB_CTID:=501}"
: "${DB_ROOT_PASSWORD:=root}"
: "${DB_ADMIN_USER:=snapjawadmin}"
: "${DB_ADMIN_PASSWORD:=snapjawadmin}"
: "${DB_APP_USER:=torta}"
: "${DB_APP_PASSWORD:=torta}"
: "${LOGIN_DB:=snapjawrealmd}"
: "${DB_PORT:=3306}"
: "${REALM_SLUGS:=stable ptr}"
: "${INCLUDE_LOGS:=1}"

manual_db_sql() {
  printf "CREATE DATABASE IF NOT EXISTS \`%s\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;\n" "${LOGIN_DB}"
  for slug in ${REALM_SLUGS}; do
    printf "CREATE DATABASE IF NOT EXISTS \`%sworld\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;\n" "${slug}"
    printf "CREATE DATABASE IF NOT EXISTS \`%scharacters\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;\n" "${slug}"
    if [[ "${INCLUDE_LOGS}" == "1" ]]; then
      printf "CREATE DATABASE IF NOT EXISTS \`%slogs\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;\n" "${slug}"
    fi
  done

  printf "\n"
  printf "CREATE USER IF NOT EXISTS '%s'@'localhost' IDENTIFIED BY '%s';\n" "${DB_ADMIN_USER}" "${DB_ADMIN_PASSWORD}"
  printf "ALTER USER '%s'@'localhost' IDENTIFIED BY '%s';\n" "${DB_ADMIN_USER}" "${DB_ADMIN_PASSWORD}"
  printf "GRANT ALL PRIVILEGES ON *.* TO '%s'@'localhost';\n" "${DB_ADMIN_USER}"

  printf "\n"
  printf "CREATE USER IF NOT EXISTS '%s'@'%%' IDENTIFIED BY '%s';\n" "${DB_APP_USER}" "${DB_APP_PASSWORD}"
  printf "CREATE USER IF NOT EXISTS '%s'@'localhost' IDENTIFIED BY '%s';\n" "${DB_APP_USER}" "${DB_APP_PASSWORD}"
  printf "ALTER USER '%s'@'%%' IDENTIFIED BY '%s';\n" "${DB_APP_USER}" "${DB_APP_PASSWORD}"
  printf "ALTER USER '%s'@'localhost' IDENTIFIED BY '%s';\n" "${DB_APP_USER}" "${DB_APP_PASSWORD}"
  printf "GRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'%%';\n" "${LOGIN_DB}" "${DB_APP_USER}"
  printf "GRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'localhost';\n" "${LOGIN_DB}" "${DB_APP_USER}"
  for slug in ${REALM_SLUGS}; do
    printf "GRANT ALL PRIVILEGES ON \`%sworld\`.* TO '%s'@'%%';\n" "${slug}" "${DB_APP_USER}"
    printf "GRANT ALL PRIVILEGES ON \`%sworld\`.* TO '%s'@'localhost';\n" "${slug}" "${DB_APP_USER}"
    printf "GRANT ALL PRIVILEGES ON \`%scharacters\`.* TO '%s'@'%%';\n" "${slug}" "${DB_APP_USER}"
    printf "GRANT ALL PRIVILEGES ON \`%scharacters\`.* TO '%s'@'localhost';\n" "${slug}" "${DB_APP_USER}"
    if [[ "${INCLUDE_LOGS}" == "1" ]]; then
      printf "GRANT ALL PRIVILEGES ON \`%slogs\`.* TO '%s'@'%%';\n" "${slug}" "${DB_APP_USER}"
      printf "GRANT ALL PRIVILEGES ON \`%slogs\`.* TO '%s'@'localhost';\n" "${slug}" "${DB_APP_USER}"
    fi
  done

  printf "\nFLUSH PRIVILEGES;\n"
}

print_manual_db_recovery() {
  local manual_sql
  manual_sql="$(manual_db_sql)"

  cat >&2 <<EOF
==> Manual MariaDB recovery required for CT ${DB_CTID}

Enter the DB CT:

pct enter ${DB_CTID}

Verify root access:

mariadb -u root -p'${DB_ROOT_PASSWORD}' -e "SELECT CURRENT_USER(), USER();"

Apply the required databases and users:

mariadb -u root -p'${DB_ROOT_PASSWORD}' <<'SQL'
${manual_sql}SQL

Verify the admin and app users:

mariadb -u ${DB_ADMIN_USER} -p'${DB_ADMIN_PASSWORD}' -e "SELECT CURRENT_USER(), USER(); SHOW DATABASES;"
mariadb -u ${DB_APP_USER} -p'${DB_APP_PASSWORD}' -e "SELECT CURRENT_USER(), USER();"

Then exit the CT and rerun:

cd /opt/tortoise-wow/tools/snapjaw-lxc
./00-install-snapjaw.sh
EOF
}

db_is_healthy() {
  local sql_file
  sql_file="$(mktemp)"
  trap 'rm -f "${sql_file}"' RETURN

  {
    printf "SELECT 1;\n"
    printf "SHOW DATABASES LIKE '%s';\n" "${LOGIN_DB}"
    for slug in ${REALM_SLUGS}; do
      printf "SHOW DATABASES LIKE '%sworld';\n" "${slug}"
      printf "SHOW DATABASES LIKE '%scharacters';\n" "${slug}"
      if [[ "${INCLUDE_LOGS}" == "1" ]]; then
        printf "SHOW DATABASES LIKE '%slogs';\n" "${slug}"
      fi
    done
  } > "${sql_file}"

  pct push "${DB_CTID}" "${sql_file}" /tmp/snapjaw-db-health.sql >/dev/null
  pct exec "${DB_CTID}" -- bash -lc "
set -euo pipefail
systemctl is-active --quiet mariadb
mariadb -N -B -u '${DB_ADMIN_USER}' -p'${DB_ADMIN_PASSWORD}' < /tmp/snapjaw-db-health.sql >/tmp/snapjaw-db-health.out
mariadb -N -B -u '${DB_APP_USER}' -p'${DB_APP_PASSWORD}' -e 'SELECT CURRENT_USER();' >/dev/null
ss -ltn | awk '\$1 == \"LISTEN\" && \$4 ~ /:${DB_PORT}\$/ { print \$4 }' >/tmp/snapjaw-db-listeners.out
expected_count=1
for slug in ${REALM_SLUGS}; do
  expected_count=\$((expected_count + 2))
  if [[ '${INCLUDE_LOGS}' == '1' ]]; then
    expected_count=\$((expected_count + 1))
  fi
done
actual_count=\$(grep -c '^' /tmp/snapjaw-db-health.out || true)
[[ \"\${actual_count}\" -ge \"\${expected_count}\" ]]
grep -q '^${LOGIN_DB}\$' /tmp/snapjaw-db-health.out
for slug in ${REALM_SLUGS}; do
  grep -q \"^\${slug}world\$\" /tmp/snapjaw-db-health.out
  grep -q \"^\${slug}characters\$\" /tmp/snapjaw-db-health.out
  if [[ '${INCLUDE_LOGS}' == '1' ]]; then
    grep -q \"^\${slug}logs\$\" /tmp/snapjaw-db-health.out
  fi
done
grep -Eq '(^|[^0-9])0\\.0\\.0\\.0:${DB_PORT}\$|^\\[::\\]:${DB_PORT}\$|^:::${DB_PORT}\$' /tmp/snapjaw-db-listeners.out
"
}

configure_mariadb_networking() {
  pct exec "${DB_CTID}" -- bash -lc "
set -euo pipefail
config='/etc/mysql/mariadb.conf.d/50-server.cnf'
if [[ -f \"\${config}\" ]]; then
  sed -i 's/^bind-address[[:space:]]*=.*/bind-address = 0.0.0.0/' \"\${config}\"
  sed -i 's/^[[:space:]]*skip-networking[[:space:]]*=.*/# skip-networking = 0/' \"\${config}\"
  sed -i 's/^[[:space:]]*skip-networking[[:space:]]*\$/# skip-networking/' \"\${config}\"
fi
systemctl restart mariadb
"
}

if db_is_healthy; then
  echo "==> MariaDB already healthy in CT ${DB_CTID}, skipping bootstrap"
  exit 0
fi

echo "==> Installing MariaDB and locale packages in CT ${DB_CTID}"
pct exec "${DB_CTID}" -- bash -lc '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  mariadb-server mariadb-client locales \
  libmariadb-dev libmariadb-dev-compat
sed -i "s/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8
mkdir -p /run/mysqld
chown mysql:mysql /run/mysqld
systemctl start mariadb || true
'

echo "==> Configuring MariaDB for cross-CT access in CT ${DB_CTID}"
configure_mariadb_networking

if db_is_healthy; then
  echo "==> MariaDB became healthy after package install and network setup, skipping manual recovery"
  exit 0
fi

print_manual_db_recovery
exit 1
