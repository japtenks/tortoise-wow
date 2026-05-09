#!/usr/bin/env bash
set -euo pipefail

: "${BUILD_CTID:=503}"
: "${INSTALL_MODE:=bootstrap}"
: "${DATA_SOURCE_MODE:?DATA_SOURCE_MODE is required}"
: "${DATA_PACK_HOST_PATH:=}"
: "${CLIENT_ARCHIVE_HOST_PATH:=}"
: "${FORCE_DATA_REFRESH:=0}"
: "${PACKAGE_BOOTSTRAP_DATA:=1}"
: "${BOOTSTRAP_PACK_HOST_PATH:=/tmp/tortoise-data.tar.gz}"
: "${INSTALL_DIR:=/opt/snapjaw}"

format_duration() {
  local total_seconds="$1"
  local hours=0
  local minutes=0
  local seconds=0

  hours=$(( total_seconds / 3600 ))
  minutes=$(( (total_seconds % 3600) / 60 ))
  seconds=$(( total_seconds % 60 ))

  if [[ "${hours}" -gt 0 ]]; then
    printf '%dh %dm %ds\n' "${hours}" "${minutes}" "${seconds}"
  elif [[ "${minutes}" -gt 0 ]]; then
    printf '%dm %ds\n' "${minutes}" "${seconds}"
  else
    printf '%ds\n' "${seconds}"
  fi
}

has_world_data() {
  local ctid="$1"
  pct exec "${ctid}" -- bash -lc "
set -e
for dir in dbc maps vmaps mmaps; do
  if [[ ! -d '${INSTALL_DIR}/data/'\"\$dir\" ]] || [[ -z \$(ls -A '${INSTALL_DIR}/data/'\"\$dir\" 2>/dev/null) ]]; then
    exit 1
  fi
done
"
}

deploy_pack_to_world() {
  local ctid="$1"
  local host_path="$2"

  echo "==> Deploying data pack to CT ${ctid}"
  pct push "${ctid}" "${host_path}" /tmp/snapjaw-data.tar.gz >/dev/null
  pct exec "${ctid}" -- bash -lc "
set -e
rm -rf '${INSTALL_DIR}/data'
mkdir -p '${INSTALL_DIR}/data'
tar -xzf /tmp/snapjaw-data.tar.gz -C '${INSTALL_DIR}/data'
find '${INSTALL_DIR}/data' -maxdepth 2 -type d \( -name dbc -o -name maps -o -name vmaps -o -name mmaps \)
"
}

extract_client_on_build() {
  local host_path="$1"
  local extraction_started_at=0
  local extraction_finished_at=0
  local extraction_started_label=""
  local extraction_finished_label=""

  echo "==> Installing client extraction tools in CT ${BUILD_CTID}"
  pct exec "${BUILD_CTID}" -- bash -lc '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y p7zip-full unzip tar
'

  echo "==> Copying client archive to CT ${BUILD_CTID}"
  pct push "${BUILD_CTID}" "${host_path}" /tmp/snapjaw-client-archive >/dev/null

  extraction_started_at="$(date +%s)"
  extraction_started_label="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "==> Data extraction started at ${extraction_started_label}"
  echo "==> Extracting client archive in CT ${BUILD_CTID}"
  pct exec "${BUILD_CTID}" -- bash -lc "
set -e
rm -rf /tmp/snapjaw-wow-client
mkdir -p /tmp/snapjaw-wow-client \
  '${INSTALL_DIR}/data/dbc' \
  '${INSTALL_DIR}/data/maps' \
  '${INSTALL_DIR}/data/vmaps' \
  '${INSTALL_DIR}/data/mmaps'
7z x -y /tmp/snapjaw-client-archive -o/tmp/snapjaw-wow-client >/tmp/snapjaw-client-extract.log
WOW_CLIENT_ROOT=\$(find /tmp/snapjaw-wow-client -maxdepth 4 -type d -name Data | head -n 1 | xargs -r dirname)
if [[ -z \"\${WOW_CLIENT_ROOT}\" ]]; then
  echo 'ERROR: Could not find WoW client Data directory after extraction.'
  exit 1
fi
export PATH='${INSTALL_DIR}/bin':\"\${PATH}\"
for extractor in mapextractor vmapextractor vmap_assembler MoveMapGen; do
  if ! command -v \"\${extractor}\" >/dev/null 2>&1; then
    echo \"ERROR: Missing extractor binary: \${extractor}. Re-run build with extractors enabled.\"
    exit 1
  fi
done
rm -rf '${INSTALL_DIR}/data/vmaps'/* '${INSTALL_DIR}/data/mmaps'/* \"\${WOW_CLIENT_ROOT}/Buildings\"
echo '[1/4] Extracting maps and dbc...'
mapextractor -i \"\${WOW_CLIENT_ROOT}\" -o '${INSTALL_DIR}/data'
echo '[2/4] Extracting vmap buildings...'
cd \"\${WOW_CLIENT_ROOT}\"
vmapextractor -d \"\${WOW_CLIENT_ROOT}/Data\"
echo '[3/4] Assembling vmaps...'
vmap_assembler \"\${WOW_CLIENT_ROOT}/Buildings\" '${INSTALL_DIR}/data/vmaps'
echo '[4/4] Generating mmaps (this will take a long time)...'
cd '${INSTALL_DIR}/data'
MoveMapGen --silent
"
  extraction_finished_at="$(date +%s)"
  extraction_finished_label="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "==> Data extraction finished at ${extraction_finished_label}"
  echo "==> Data extraction took $(format_duration "$(( extraction_finished_at - extraction_started_at ))")"
}

sync_build_data_to_world() {
  local ctid="$1"

  if [[ "${ctid}" == "${BUILD_CTID}" ]]; then
    return 0
  fi

  echo "==> Syncing extracted data from CT ${BUILD_CTID} to CT ${ctid}"
  pct exec "${BUILD_CTID}" -- tar -C "${INSTALL_DIR}" -cf - data | pct exec "${ctid}" -- bash -lc "
set -e
rm -rf '${INSTALL_DIR}/data'
mkdir -p '${INSTALL_DIR}'
tar -C '${INSTALL_DIR}' -xf -
find '${INSTALL_DIR}/data' -maxdepth 2 -type d \( -name dbc -o -name maps -o -name vmaps -o -name mmaps \)
"
}

package_build_data_to_host() {
  local host_path="$1"
  local host_dir=""

  host_dir="$(dirname "${host_path}")"
  mkdir -p "${host_dir}"

  echo "==> Packaging extracted data from CT ${BUILD_CTID} to host path ${host_path}"
  pct exec "${BUILD_CTID}" -- tar -C "${INSTALL_DIR}" -czf - data > "${host_path}"
}

if [[ "${INSTALL_MODE}" == "reuse" ]]; then
  DATA_SOURCE_MODE="pack"
elif [[ "${INSTALL_MODE}" == "bootstrap" ]]; then
  DATA_SOURCE_MODE="client"
fi

if [[ "${DATA_SOURCE_MODE}" == "pack" ]]; then
  if [[ -z "${DATA_PACK_HOST_PATH}" || ! -f "${DATA_PACK_HOST_PATH}" ]]; then
    echo "ERROR: DATA_PACK_HOST_PATH does not exist on the Proxmox host: ${DATA_PACK_HOST_PATH}" >&2
    exit 1
  fi
elif [[ "${DATA_SOURCE_MODE}" == "client" ]]; then
  if [[ -z "${CLIENT_ARCHIVE_HOST_PATH}" || ! -f "${CLIENT_ARCHIVE_HOST_PATH}" ]]; then
    echo "ERROR: CLIENT_ARCHIVE_HOST_PATH does not exist on the Proxmox host: ${CLIENT_ARCHIVE_HOST_PATH}" >&2
    exit 1
  fi
else
  echo "ERROR: DATA_SOURCE_MODE must be 'pack' or 'client'" >&2
  exit 1
fi

world_ctids=()
while IFS='|' read -r _realm_slug world_ctid _rest; do
  [[ -n "${world_ctid}" ]] || continue
  world_ctids+=("${world_ctid}")
done <<< "${REALM_MATRIX}"

if [[ "${DATA_SOURCE_MODE}" == "pack" ]]; then
  for ctid in "${world_ctids[@]}"; do
    if [[ "${FORCE_DATA_REFRESH}" == "1" ]] || ! has_world_data "${ctid}"; then
      deploy_pack_to_world "${ctid}" "${DATA_PACK_HOST_PATH}"
    else
      echo "==> Data already present in CT ${ctid}, skipping pack deploy"
    fi
  done
else
  if [[ "${FORCE_DATA_REFRESH}" == "1" ]] || ! has_world_data "${BUILD_CTID}"; then
    extract_client_on_build "${CLIENT_ARCHIVE_HOST_PATH}"
  else
    echo "==> Data already present in build CT ${BUILD_CTID}, skipping extraction"
  fi

  for ctid in "${world_ctids[@]}"; do
    if [[ "${FORCE_DATA_REFRESH}" == "1" ]] || ! has_world_data "${ctid}"; then
      sync_build_data_to_world "${ctid}"
    else
      echo "==> Data already present in CT ${ctid}, skipping sync"
    fi
  done

  if [[ "${PACKAGE_BOOTSTRAP_DATA}" == "1" ]]; then
    package_build_data_to_host "${BOOTSTRAP_PACK_HOST_PATH}"
  fi
fi
