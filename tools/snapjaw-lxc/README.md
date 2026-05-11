# SnapJaw LXC Minimal Installer

Start by checking out the installer branch of this repo onto that host, then run the entrypoint from `tools/snapjaw-lxc`.

- `00-install-snapjaw.sh`: run the full end-to-end install

- `01-db-host-setup.sh`: install and bootstrap MariaDB in the DB LXC
- `02-build-and-seed.sh`: build `tortoise-wow` and seed the primary realm DBs
- `03-realmd-setup.sh`: install the shared `realmd` runtime in its own LXC
- `03-realmd-setup.sh` also deploys the small auth web portal in the auth CT
- `05-data-setup.sh`: deploy a prepared data pack or extract client data into `${INSTALL_DIR}/data`
- `04-world-setup.sh`: install one `mangosd` realm instance in a world LXC

The intended shape is:

- CT `501`: MariaDB
- CT `502`: shared `realmd`
- CT `503`: `stable` world build/runtime
- CT `504`: `ptr` world runtime

## Naming convention

The scripts assume one shared login DB and per-realm world/character/log DBs:

- login DB: `snapjawrealmd`
- stable DBs: `stableworld`, `stablecharacters`, `stablelogs`
- ptr DBs: `ptrworld`, `ptrcharacters`, `ptrlogs`

Future realms follow the same pattern:

- `betaworld`, `betacharacters`, `betalogs`
- `alphaworld`, `alphacharacters`, `alphalogs`

## Quick start

Run these from the Proxmox host.

```bash
cd /opt
rm -rf /opt/tortoise-wow
git clone --filter=blob:none --no-checkout --branch snapjaw/proxmox-tooling https://github.com/japtenks/tortoise-wow.git
cd /opt/tortoise-wow
git sparse-checkout init --cone
git sparse-checkout set tools/snapjaw-lxc
git checkout
cd /opt/tortoise-wow/tools/snapjaw-lxc
chmod +x *.sh
./00-install-snapjaw.sh
```

This sparse checkout keeps the working tree focused on `tools/snapjaw-lxc` instead of pulling the whole repo contents onto the Proxmox host.

On the first run it will prompt for values, save them to `snapjaw.env`, create any missing LXCs, and then configure them.

If you want the separate content-sync lane that also carries the selected Penqle core/content changes, use the SnapJaw Penqle sync repo/branch instead of this public tooling branch.
On later runs it will reuse `snapjaw.env` automatically.

Use these modes when needed:

To update config:

```bash
./00-install-snapjaw.sh --prompt
```

Re-prompt and overwrite `snapjaw.env`.

```bash
./00-install-snapjaw.sh --write-env-only
```

Prompt and save `snapjaw.env`, but do not run the installer steps yet.

To validate the current config and install plan without making changes:

```bash
./00-install-snapjaw.sh --dry-run
```

To re-prompt values and then validate only:

```bash
./00-install-snapjaw.sh --prompt --dry-run
```

Dry run mode checks the saved config, validates the selected data source path, resolves the template and CT storage that would be used, prints the planned CT layout, and exits before any CT, package, DB, or service changes are made.

## Updating realms

For regular updates, use the dedicated update helpers instead of rerunning `02-build-and-seed.sh`. The build-and-seed step is for provisioning and DB initialization, while the update helpers rebuild and redeploy code without reseeding realm databases.

Stable update:

```bash
cd /opt/tortoise-wow/tools/snapjaw-lxc
chmod +x *.sh
./update-stable.sh
```

PTR update:

```bash
cd /opt/tortoise-wow/tools/snapjaw-lxc
chmod +x *.sh
./update-ptr.sh
```

Defaults:

- `INSTALLER_REPO_BRANCH=snapjaw/proxmox-tooling`
- `STABLE_REPO_BRANCH=codex/proxmox-final`
- `PTR_REPO_BRANCH=proxmox-ptr`

Notes:

- `update-stable.sh` refreshes the shared auth/realmd CT first, then rebuilds and redeploys the `stable` world.
- `update-ptr.sh` keeps the shared auth/realmd tooling branch on the installer branch, but rebuilds the `ptr` world from `PTR_REPO_BRANCH`.
- The intended maintained lanes are `snapjaw/proxmox-tooling` for the installer checkout, `codex/proxmox-final` for the stable realm build, and `proxmox-ptr` for PTR once that branch exists.
- `PTR_REPO_BRANCH` must exist on the Git remote selected by `REPO_URL` or the update will stop with a clear error.
- The provisioning and realm update builds pass `ALLOW_TURTLE_ADDONS=ON`, which is required for the validated Turtle-compatible login flow on the proxmox runtime lane.

## Env file

The saved env file lives at `tools/snapjaw-lxc/snapjaw.env` by default.
You can point to a different one with:

```bash
ENV_FILE=/path/to/my-snapjaw.env ./00-install-snapjaw.sh
```

## Realm format

Realms are stored in `REALM_MATRIX` using this format:

```text
slug|ctid|realm_id|realm_name|realm_address|world_port
```

Use `auto` for `DB_HOST` or any `realm_address` to detect the current DHCP address of that container at runtime.

## Install modes

The installer now has two intended modes:

- `INSTALL_MODE=bootstrap`
  - first run
  - requires `CLIENT_ARCHIVE_HOST_PATH`
  - builds extractors
  - temporarily raises the build CT to `WORLD_CORES * 2` if it is lower, then restores the original core count at the end of the run
  - extracts `dbc`, `maps`, `vmaps`, and `mmaps` from a client archive
  - can optionally export a host-side `tortoise-data.tar.gz` for later reuse runs
- `INSTALL_MODE=reuse`
  - later reruns
  - requires `DATA_PACK_HOST_PATH`
  - skips extractor builds
  - deploys a prepared `tortoise-data.tar.gz`

These paths must be available on the Proxmox host itself. A mounted network share path such as `/mnt/example/location_here/...` is fine.

Useful bootstrap options:

- `PACKAGE_BOOTSTRAP_DATA=1` exports a data pack after a successful bootstrap extraction
- `BOOTSTRAP_PACK_HOST_PATH=/path/to/tortoise-data.tar.gz` controls where that pack is written on the Proxmox host
- reuse mode assumes you already have a prepared pack available on the host

## DB users

- `DB_ROOT_PASSWORD`: used only for the one-time bootstrap/reset path
- `DB_ADMIN_USER` / `DB_ADMIN_PASSWORD`: persistent admin account for verification and maintenance
- `DB_APP_USER` / `DB_APP_PASSWORD`: normal app connection user used by the realm services
- on a fresh interactive install, passwords and the auth portal bootstrap admin key are generated automatically and saved to `snapjaw.env`

## Auth web portal

Step 3 now deploys a lightweight Flask portal in CT `502` alongside `realmd`.

Default endpoint:

```text
http://<auth-ct-ip>:8080
```

Defaults and knobs:

- `AUTH_WEB_PORT=8080`
- `AUTH_WEB_CHARACTER_DBS=stablecharacters,ptrcharacters`
- `AUTH_WEB_BOOTSTRAP_ADMIN_KEY` must be set before the portal can create its first portal admin
- `FORCE_PIN_ACCOUNT_RANK=99` disables automatic PIN prompting for normal GM/staff ranks in this LXC setup unless you lower it
- once `AUTH_WEB_BOOTSTRAP_ADMIN_KEY` is configured, the first account created with that key becomes a portal admin without changing in-game account rank

Current v1 features:

- public account registration using the same normalized `SHA1(USERNAME:PASSWORD)` hash format as the core
- admin login using auth accounts marked as portal admins
- browse recent accounts or search by username
- reset account passwords with the same server hash format
- delete empty offline accounts that have no characters
- set `shop_coins` balance per account
- offline-only character testing helpers:
  - set level
  - set money
- one-click preset boost to level `60` plus test gold
- offline loadout presets that replace equipped gear and bag slots
- queued Tier 1 mail preset for quick GM-side checks

Current v1 limits:

- account usernames and passwords are restricted to `3-16` characters using letters, numbers, or underscore
- character actions only run when the character is offline
- the queued Tier 1 mail helper only works for names that fit the pending-command-safe character set

## Provisioning

Missing CTs are created with:

- newest available Debian standard LXC template
- auto-detected CT storage, preferring common ZFS-backed names when available
- DHCP on the selected bridge
- unprivileged containers by default
- separate resource defaults for DB, `realmd`, and world/build CTs

If template or storage auto-detection fails, set `CT_TEMPLATE` or `CT_STORAGE` manually in the prompt or in `snapjaw.env`.
Example:

```text
CT_TEMPLATE='local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst'
CT_STORAGE='local-zfs'
```

## Retry behavior

Retries now reuse the existing source tree, build directory, and install directory by default.
That means a failure after the build step should come back much faster on the next run.

If you really want a clean rebuild, set `FORCE_REBUILD=1` in `snapjaw.env` or answer `yes` to the rebuild prompt.

## Day-to-day operations

Once the stack exists, most day-to-day work happens through `pct enter`, `systemctl`, and a few fixed install paths.

Common CTs:

- `501`: MariaDB
- `502`: shared `realmd` plus the auth web portal
- `503`: `stable` build/runtime by default
- `504`: `ptr` runtime by default

Enter a container:

```bash
pct enter 501
pct enter 502
pct enter 503
pct enter 504
```

Useful paths inside the containers:

- `/opt/snapjaw/bin`: installed binaries such as `realmd` and `mangosd`
- `/opt/snapjaw/etc`: generated runtime configs such as `realmd.conf` and `mangosd.conf`
- `/opt/snapjaw/data`: extracted or deployed `dbc`, `maps`, `vmaps`, and `mmaps`
- `/opt/snapjaw/auth-web`: Flask auth portal files and `auth-web.env`
- `/opt/tortoise-wow/sql/database_updates`: world DB auto-update files copied into world CTs

Useful services:

- in CT `502`: `realmd`, `snapjaw-auth-web`
- in world CTs such as `503` and `504`: `mangosd`

Check service state:

```bash
pct exec 502 -- systemctl status realmd --no-pager
pct exec 502 -- systemctl status snapjaw-auth-web --no-pager
pct exec 503 -- systemctl status mangosd --no-pager
pct exec 504 -- systemctl status mangosd --no-pager
```

Restart services:

```bash
pct exec 502 -- systemctl restart realmd
pct exec 502 -- systemctl restart snapjaw-auth-web
pct exec 503 -- systemctl restart mangosd
pct exec 504 -- systemctl restart mangosd
```

Read recent logs:

```bash
pct exec 502 -- journalctl -u realmd -n 100 --no-pager
pct exec 502 -- journalctl -u snapjaw-auth-web -n 100 --no-pager
pct exec 503 -- journalctl -u mangosd -n 100 --no-pager
pct exec 504 -- journalctl -u mangosd -n 100 --no-pager
```

Inspect generated configs:

```bash
pct exec 502 -- sed -n '1,160p' /opt/snapjaw/etc/realmd.conf
pct exec 502 -- sed -n '1,160p' /opt/snapjaw/auth-web/auth-web.env
pct exec 503 -- sed -n '1,220p' /opt/snapjaw/etc/mangosd.conf
pct exec 504 -- sed -n '1,220p' /opt/snapjaw/etc/mangosd.conf
```

Check that data files are present:

```bash
pct exec 503 -- find /opt/snapjaw/data -maxdepth 2 -type d \( -name dbc -o -name maps -o -name vmaps -o -name mmaps \)
pct exec 504 -- find /opt/snapjaw/data -maxdepth 2 -type d \( -name dbc -o -name maps -o -name vmaps -o -name mmaps \)
```

Quick MariaDB checks from the DB CT:

```bash
pct enter 501
mariadb -u <db_admin_user> -p'<db_admin_password>' -e "SHOW DATABASES;"
mariadb -u <db_app_user> -p'<db_app_password>' -e "SELECT CURRENT_USER(), USER();"
```

Quick auth portal checks from the auth CT:

```bash
pct exec 502 -- ss -ltnp | grep 8080
pct exec 502 -- curl -I http://127.0.0.1:8080/ || true
```

Typical rerun patterns:

- full guided installer rerun: `./00-install-snapjaw.sh`
- validate saved config only: `./00-install-snapjaw.sh --dry-run`
- rebuild and redeploy stable realm code: `./update-stable.sh`
- rebuild and redeploy PTR realm code: `./update-ptr.sh`
- rerun only shared auth/realmd setup: `./03-realmd-setup.sh`
- rerun only data deployment/extraction: `./05-data-setup.sh`

## Cleanup

Run these from the Proxmox host if you want to inspect or tear down the SnapJaw LXCs.

List the containers:

```bash
pct list
```

Stop the world and realmd CTs you want to remove:

```bash
for ctid in 502 503 504; do
  pct stop "${ctid}" 2>/dev/null || true
done
```

Destroy them:

```bash
for ctid in 502 503 504; do
  pct destroy "${ctid}" 2>/dev/null || true
done
```

## Notes

- `00-install-snapjaw.sh` is the single entry point. It calls the five sub-scripts in order.
- `00-install-snapjaw.sh` now supports interactive prompting and env-file persistence.
- `01-db-host-setup.sh` now skips bootstrap if MariaDB is already healthy and the expected DBs and users are present.
- if Step 2 cannot verify a healthy MariaDB admin/app setup after package install, it now stops and prints an explicit manual recovery block for the DB CT instead of attempting an opaque in-place reset
- `02-build-and-seed.sh` imports the full SQL set once into the primary realm, then clones that world DB into any extra realms listed in `EXTRA_REALMS`.
- Extra realm character and logs DBs are cloned as schema-only, so they start empty.
- `03-realmd-setup.sh` now skips setup if the binary, config, DB connectivity, and service are already healthy.
- `03-realmd-setup.sh` also installs `snapjaw-auth-web.service`, writes `${INSTALL_DIR}/auth-web/auth-web.env`, starts the auth portal on `AUTH_WEB_PORT`, and sets `ForcePinAccountRank = ${FORCE_PIN_ACCOUNT_RANK}` in `realmd.conf`.
- `05-data-setup.sh` now owns the client extraction flow directly instead of relying on the repo copy of `run-local-extractors.sh` inside the build CT.
- `04-world-setup.sh` registers the realm row in `snapjawrealmd.realmlist` using `REALM_ID`, `REALM_NAME`, `REALM_ADDRESS`, and `WORLD_PORT`.
- `05-data-setup.sh` runs before world setup, so bootstrap and reuse data handling are now part of the main installer flow.
- Each world CT still needs `${INSTALL_DIR}/data` populated with `dbc`, `maps`, `vmaps`, and `mmaps`, but the installer now handles that during Step 5 when configured with a valid client archive or data pack.
- `04-world-setup.sh` now also copies `sql/database_updates` into each world CT and sets `Database.AutoUpdate.Path = "/opt/tortoise-wow/sql/"`, so world SQL migrations can auto-apply on startup.

## DB manual recovery

If Step 2 stops with a MariaDB manual recovery message, enter the DB CT and run the printed commands there. The recovery flow is:

```bash
pct enter 501
mariadb -u root -proot -e "SELECT CURRENT_USER(), USER();"
```

Then apply the login/world/character/log databases plus the `snapjawadmin` and `torta` users, for example:

```sql
CREATE DATABASE IF NOT EXISTS snapjawrealmd CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE IF NOT EXISTS stableworld CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE IF NOT EXISTS stablecharacters CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE IF NOT EXISTS stablelogs CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE IF NOT EXISTS ptrworld CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE IF NOT EXISTS ptrcharacters CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE IF NOT EXISTS ptrlogs CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

CREATE USER IF NOT EXISTS 'snapjawadmin'@'%' IDENTIFIED BY 'snapjawadmin';
CREATE USER IF NOT EXISTS 'snapjawadmin'@'localhost' IDENTIFIED BY 'snapjawadmin';
ALTER USER 'snapjawadmin'@'%' IDENTIFIED BY 'snapjawadmin';
ALTER USER 'snapjawadmin'@'localhost' IDENTIFIED BY 'snapjawadmin';
GRANT ALL PRIVILEGES ON *.* TO 'snapjawadmin'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'snapjawadmin'@'localhost' WITH GRANT OPTION;

CREATE USER IF NOT EXISTS 'torta'@'%' IDENTIFIED BY 'torta';
CREATE USER IF NOT EXISTS 'torta'@'localhost' IDENTIFIED BY 'torta';
ALTER USER 'torta'@'%' IDENTIFIED BY 'torta';
ALTER USER 'torta'@'localhost' IDENTIFIED BY 'torta';
GRANT ALL PRIVILEGES ON *.* TO 'torta'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'torta'@'localhost' WITH GRANT OPTION;

FLUSH PRIVILEGES;
```

Verify:

```bash
mariadb -u <db_admin_user> -p'<db_admin_password>' -e "SELECT CURRENT_USER(), USER(); SHOW DATABASES;"
mariadb -u <db_app_user> -p'<db_app_password>' -e "SELECT CURRENT_USER(), USER();"
```

Then exit the DB CT and rerun:

```bash
cd /opt/tortoise-wow/tools/snapjaw-lxc
./00-install-snapjaw.sh
```
