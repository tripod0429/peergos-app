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
if ! curl -s -o /dev/null --max-time 10 http://127.0.0.1:8000/; then
    log "Peergos isn't answering on port 8000, skipping garbage collection"
    exit 0
fi

# gc reads its token from $PEERGOS_PATH/gc.token, which the server writes owner
# only, and waits until the collection has finished. Run it as the server's user
# so nothing it writes under /app/data ends up owned by root.
# Cloudron aborts a backup whose backupCommand fails, and a failed collection
# shouldn't cost a backup, so report it and carry on.
if ! gosu cloudron:cloudron java -Djava.io.tmpdir=/tmp --enable-native-access=ALL-UNNAMED \
        -jar /app/code/Peergos.jar gc -port 8000 -log-to-console true -log-to-file false; then
    log "Garbage collection failed, backing up anyway"
fi
exit 0
