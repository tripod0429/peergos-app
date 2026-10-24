#!/bin/bash
set -euo pipefail

export PEERGOS_PATH=/app/data/peergos
config="${PEERGOS_PATH}/config"

log() { echo "==> $*"; }

mkdir -p "${PEERGOS_PATH}/.ipfs/datastore"

# --- Copied data ---------------------------------------------------------------
# The node's peer ID and private key are in ${config}, so a clone of this app,
# or a backup imported into a new app, would come up as a second copy of the
# same Peergos node and split its users' data. Remember which app the data
# belongs to and hold if that changes. Restores, location changes, updates and
# a full Cloudron restore keep the app id. CLOUDRON_APP_HOSTNAME is the app id
# (undocumented); it's unset outside Cloudron, and then there's nothing to check.
app_id="${CLOUDRON_APP_HOSTNAME:-}"
id_file=/app/data/cloudron-app-id
if [[ -n "${app_id}" ]]; then
    if [[ -f "${id_file}" && "$(<"${id_file}")" != "${app_id}" ]]; then
        log "This app's data comes from another Cloudron app ($(<"${id_file}")), not this one (${app_id})."
        log "Peergos was not started: the peer ID is part of the data, so this copy would run as a second instance of the same Peergos node."
        log "If this is a clone, uninstall it. If you moved Peergos here and the old app is gone, delete ${id_file} (File Manager or Web Terminal) and restart the app."
        # Keep the container up for the File Manager and Web Terminal. A bare
        # sleep as PID 1 would ignore SIGTERM and delay every stop.
        trap 'exit 0' TERM INT
        sleep infinity &
        wait
        exit 1
    fi
    echo "${app_id}" > "${id_file}"
fi

# --- User settings -------------------------------------------------------------
# /app/data/env.sh is where admins change settings (File Manager, then restart).
# It's created from a commented template on first start and never overwritten.
# Values from `cloudron env set` still work; the file wins if both set one.
if [[ ! -f /app/data/env.sh ]]; then
    cp /app/pkg/env.sh.template /app/data/env.sh
fi
set -a
# shellcheck source=/dev/null
source /app/data/env.sh
set +a

first_run=false
[[ -f "${config}" ]] || first_run=true

# --- SQLite backups ------------------------------------------------------------
# Every file listed under localstorage.sqlite.paths in the manifest must exist,
# or Cloudron backups fail. A zero-byte file is a valid empty SQLite database,
# so Peergos initialises these normally on first start.
sqlite_list="$(jq -r '.addons.localstorage.sqlite.paths[]' /app/pkg/CloudronManifest.json)"
declare -A listed=()
while IFS= read -r f; do
    listed["${f}"]=1
    [[ -e "${f}" ]] || touch "${f}"
done <<< "${sqlite_list}"

# A database added by a newer Peergos that isn't listed gets backed up as a copy
# of a live file. reachability/*.sqlite are skipped on purpose: they are per-user
# garbage collection indexes that Peergos rebuilds, so they can't be listed.
while IFS= read -r -d '' f; do
    [[ -n "${listed[${f}]:-}" ]] || log "WARNING: ${f} is not in localstorage.sqlite.paths in CloudronManifest.json"
done < <(find "${PEERGOS_PATH}" "${PEERGOS_PATH}/.ipfs/datastore" -maxdepth 1 -type f \( -name '*.sql' -o -name '*.sqlite' \) -print0)

# Peergos writes every argument into $PEERGOS_PATH/config on first run and
# reads that file on later runs. Command-line flags override it, but a flag we
# stop passing would linger, so drop the keys this script manages.
if [[ -f "${config}" ]]; then
    sed -i -E '/^(generate-token|ipfs-swarm-addrs|ipfs-announce-addresses|admin-usernames|default-quota)[[:space:]]*=/d' "${config}"
fi

# --- Signup token ------------------------------------------------------------
generate_token=false
if [[ "${first_run}" == true || "${PEERGOS_GENERATE_TOKEN:-false}" == true ]]; then
    generate_token=true
fi

# --- P2P listeners -----------------------------------------------------------
# Peergos' default listeners are [::]:4001 over TCP and QUIC (dual stack). That
# fails if the container has no IPv6 stack, so fall back to the same listeners
# on IPv4 (Peergos accepts quic-v1 in -ipfs-swarm-addrs since 1.38.0).
swarm_args=()
if [[ ! -e /proc/net/if_inet6 ]]; then
    swarm_args=(-ipfs-swarm-addrs "/ip4/0.0.0.0/tcp/4001,/ip4/0.0.0.0/udp/4001/quic-v1")
    log "No IPv6 stack in the container: P2P listens on IPv4 only"
fi

# --- Announce addresses ------------------------------------------------------
# Tell other Peergos nodes how to reach us: the server's public IP plus the
# *host* ports Cloudron mapped (IPFS_TCP_PORT / IPFS_UDP_PORT). The IP defaults
# to the app domain's A record; override with PEERGOS_PUBLIC_IP (or "none").
public_ip="${PEERGOS_PUBLIC_IP:-}"
if [[ -z "${public_ip}" ]]; then
    public_ip="$(getent ahostsv4 "${CLOUDRON_APP_DOMAIN}" | awk 'NR==1 { print $1 }' || true)"
    if [[ "${public_ip}" =~ ^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]]; then
        log "WARNING: ${CLOUDRON_APP_DOMAIN} resolves to private address ${public_ip}; set PEERGOS_PUBLIC_IP to your public IP"
    fi
fi

announce=()
if [[ -n "${public_ip}" && "${public_ip}" != none ]]; then
    [[ -n "${IPFS_TCP_PORT:-}" ]] && announce+=("/ip4/${public_ip}/tcp/${IPFS_TCP_PORT}")
    [[ -n "${IPFS_UDP_PORT:-}" ]] && announce+=("/ip4/${public_ip}/udp/${IPFS_UDP_PORT}/quic-v1")
fi
announce_args=()
if (( ${#announce[@]} > 0 )); then
    announce_args=(-ipfs-announce-addresses "$(IFS=,; echo "${announce[*]}")")
    log "Announcing P2P addresses: ${announce[*]}"
else
    log "Not announcing any P2P address (no public IP or no port bindings)"
fi

# --- Optional settings (set with: cloudron env set --app <app> NAME=value) ---
optional_args=()
[[ -n "${PEERGOS_ADMIN_USERNAMES:-}" ]] && optional_args+=(-admin-usernames "${PEERGOS_ADMIN_USERNAMES}")
[[ -n "${PEERGOS_DEFAULT_QUOTA:-}" ]] && optional_args+=(-default-quota "${PEERGOS_DEFAULT_QUOTA}")
extra_args=()
read -r -a extra_args <<< "${PEERGOS_EXTRA_ARGS:-}"

# --- Ownership -----------------------------------------------------------------
# Only touch files that need it; a recursive chown of a large blockstore on
# every start would be slow.
find /app/data \( ! -user cloudron -o ! -group cloudron \) -exec chown -h cloudron:cloudron {} +

# --- Logging -------------------------------------------------------------------
# Peergos and its IPFS library log through one java.util.logging logger. At INFO
# that includes two lines for every request relayed to another Peergos node,
# thousands on the first start, so the default is WARNING. The signup link and
# version lines are printed directly and show at any level. One line per record:
# Cloudron adds its own timestamps.
cat > /run/peergos-logging.properties <<EOF
handlers = java.util.logging.ConsoleHandler
.level = ${PEERGOS_LOG_LEVEL:-WARNING}
java.util.logging.ConsoleHandler.level = ALL
java.util.logging.ConsoleHandler.formatter = java.util.logging.SimpleFormatter
java.util.logging.SimpleFormatter.format = %4\$s %2\$s: %5\$s%6\$s%n
EOF

java_opts=(
    -Djava.util.logging.config.file=/run/peergos-logging.properties
    --enable-native-access=ALL-UNNAMED
    -XX:MaxRAMPercentage="${PEERGOS_MAX_RAM_PERCENTAGE:-60}"
    -XX:+ExitOnOutOfMemoryError
    -Djava.io.tmpdir=/tmp
)

peergos_args=(
    daemon
    -listen-host 0.0.0.0
    -port 8000
    -public-server true
    -public-domain "${CLOUDRON_APP_DOMAIN}"
    -quota-upload-limit-seconds "${PEERGOS_QUOTA_UPLOAD_LIMIT_SECONDS:-600}"
    -generate-token "${generate_token}"
    -log-to-console true
    -log-to-file false
    -native-tweetnacl-path /app/code/native-libs/libtweetnacl.so
    -native-sqlite-path /app/code/native-libs/libsqlitejdbc.so
    "${swarm_args[@]}"
    "${announce_args[@]}"
    "${optional_args[@]}"
    "${extra_args[@]}"
)

if [[ "${generate_token}" == true ]]; then
    log "A single-use signup link is printed below once Peergos is up."
    log "Open it as https://${CLOUDRON_APP_DOMAIN}/?signup=true&token=... (drop the ':8000' Peergos adds)."
fi

log "Starting Peergos"
exec gosu cloudron:cloudron java "${java_opts[@]}" -jar /app/code/Peergos.jar "${peergos_args[@]}"
