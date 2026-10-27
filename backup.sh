#!/bin/bash
set -uo pipefail

# Cloudron runs this (backupCommand in the manifest) before every backup, in a
# separate container from this image that shares the app's network and mounts
# /app/data. It runs before Cloudron snapshots the databases and uploads the
# blockstore, so collecting garbage here, with the server's own GC timer off,
# means no blocks are deleted while the backup is copied. See README, "Backup
# and restore".

log() { echo "==> backup: $*"; }

# With no server answering, `gc` collects in its own process instead, which
# would race a server that is just starting. Only ask a server that is up.
# 127.0.0.1 rather than localhost: Peergos logs any other Host as an error.
server_up() { curl -s -o /dev/null --max-time 10 http://127.0.0.1:8000/; }

# gc reads its token from $PEERGOS_PATH/gc.token, which the server writes owner
# only, and waits until the collection has finished. Run it as the server's user
# so nothing it writes under /app/data ends up owned by root.
collect() {
    gosu cloudron:cloudron java -Djava.io.tmpdir=/tmp --enable-native-access=ALL-UNNAMED \
        -jar /app/code/Peergos.jar gc -port 8000 -log-to-console true -log-to-file false
}

# Every way out exits 0: Cloudron aborts a backup whose backupCommand fails,
# and a missed collection shouldn't cost a backup.
# Peergos also refuses to collect ("still being partitioned") while it sorts a
# blockstore into per-user folders. Only blockstores from Peergos versions over
# a year old need that; a new one is sorted from the start. So it's treated
# like any other failure.
for attempt in 1 2; do
    if ! server_up; then
        log "Peergos isn't answering on port 8000, skipping garbage collection"
        exit 0
    fi
    if output="$(collect 2>&1)"; then
        printf '%s\n' "${output}"
        exit 0
    fi
    printf '%s\n' "${output}"
    # If the request failed while a collection was still running in the
    # server, a second request waits for it, so a success means none is.
    if (( attempt == 1 )); then
        log "Garbage collection failed, trying once more"
    fi
done
log "Garbage collection failed again, backing up anyway"
exit 0
