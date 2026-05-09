#!/usr/bin/env bash
set -e

# Legacy container bootstrap helper for a minimal single-node MariaDB init flow.
# The entrypoint automatically passes the root password via environment variables.
MYSQL="mariadb -u root -p$MARIADB_ROOT_PASSWORD"
SQL_DIR="/sql_imports"

run_sql() {
  local db="$1"
  local file="$2"
  echo "  -> Applying $file to $db"
  $MYSQL -f "$db" < "$file"
}

echo "=== Step 1: Creating databases ==="
$MYSQL < "$SQL_DIR/create_databases.sql"

echo "=== Step 2: Applying base world tables ==="
for f in "$SQL_DIR"/base/tw_world_*.sql; do
  [ -e "$f" ] || continue
  run_sql "tw_world" "$f"
done

echo "=== Step 3: Adding realm entry ==="
$MYSQL tw_logon -e "
INSERT INTO realmlist (name, address, port, icon, realmflags, timezone, allowedSecurityLevel, population, realmbuilds)
VALUES ('Project Snapjaw', '127.0.0.1', 8085, 0, 0, 1, 0, 0, '5875')
ON DUPLICATE KEY UPDATE address=VALUES(address), port=VALUES(port);
GRANT ALL PRIVILEGES ON tw_world.* TO 'mangos'@'%';
GRANT ALL PRIVILEGES ON tw_char.* TO 'mangos'@'%';
GRANT ALL PRIVILEGES ON tw_logon.* TO 'mangos'@'%';
GRANT ALL PRIVILEGES ON tw_logs.* TO 'mangos'@'%';
FLUSH PRIVILEGES;
"

echo "=== Done! ==="
