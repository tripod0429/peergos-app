#!/bin/bash
# Starts the image the way Cloudron runs it (read-only root, writable /tmp, /run
# and /app/data), restarts it once, and fails if:
#   - the container exits, e.g. because Peergos.jar needs a newer Java
#   - Peergos doesn't answer HTTP 200, or the built-in apps don't load
#   - the first start prints no signup token, or the restart counts as a first
#     start or prints another token
#   - a database isn't in localstorage.sqlite.paths (start.sh only sees files
#     created by an earlier start, hence the restart)
#   - anything fails with a read-only filesystem error
#
# Usage: smoke-test.sh <image>    (DOCKER=podman to run it with Podman)
set -euo pipefail

if (( $# != 1 )); then
    echo "Usage: $0 <image>" >&2
    exit 2
fi
image="$1"
docker="${DOCKER:-docker}"
name=peergos-smoke-test
host=peergos.localhost
timeout="${SMOKE_TIMEOUT:-600}"

cleanup() {
    "${docker}" rm -f "${name}" > /dev/null 2>&1 || true
    "${docker}" volume rm -f "${name}" > /dev/null 2>&1 || true
}
trap cleanup EXIT

logs() { "${docker}" logs "${name}" 2>&1; }

fail() {
    echo "::error::$*"
    echo "--- last 200 log lines ---"
    logs | tail -n 200
    exit 1
}

running() { [[ "$("${docker}" inspect -f '{{.State.Running}}' "${name}")" == true ]]; }

status() {
    curl -s -o /dev/null -w '%{http_code}' -H "Host: $1" "http://127.0.0.1:8000$2" || true
}

# Waits until <command...> succeeds, failing early if the container stops.
wait_for() {
    local what="$1"; shift
    local deadline=$(( SECONDS + timeout ))
    until "$@"; do
        running || fail "The container stopped (exit code $("${docker}" inspect -f '{{.State.ExitCode}}' "${name}")) while waiting for ${what}"
        (( SECONDS < deadline )) || fail "Timed out after ${timeout}s waiting for ${what}"
        sleep 5
    done
}

http_ok() { [[ "$(status "${host}" /)" == 200 ]]; }
count() { logs | grep -cF -- "$1" || true; }
# A real token, as test/test.js matches it. start.sh's own notice shows the
# link with a "..." placeholder, which this doesn't match.
tokens() { logs | grep -oE '\?signup=true&token=[0-9a-f]+' | sort -u | wc -l || true; }
has_signup_link() { (( $(tokens) > 0 )); }
started_twice() { (( $(count '==> Starting Peergos') >= 2 )); }

cleanup
"${docker}" volume create "${name}" > /dev/null
# exec: Docker and Podman mount --tmpfs noexec by default, and Cloudron's /tmp
# isn't. sqlite-jdbc extracts its native library to /tmp and loads it from there.
"${docker}" run -d --name "${name}" \
    --read-only --tmpfs /tmp:exec --tmpfs /run:exec \
    -v "${name}:/app/data" \
    -e CLOUDRON_APP_DOMAIN="${host}" \
    -e PEERGOS_PUBLIC_IP=none \
    -e IPFS_TCP_PORT=4001 -e IPFS_UDP_PORT=4001 \
    -p 127.0.0.1:8000:8000 \
    "${image}" > /dev/null

echo "First start"
wait_for "HTTP 200 from /" http_ok
wait_for "the signup link" has_signup_link
pdf="$(status "pdf.${host}" /apps/pdf/index.html)"
[[ "${pdf}" == 200 ]] || fail "The PDF viewer answered ${pdf}, not 200"

echo "Restart"
"${docker}" restart "${name}" > /dev/null
wait_for "the second start" started_twice
wait_for "HTTP 200 from / after the restart" http_ok

# start.sh decides before Peergos starts, so this can't miss a late token
intro="$(count 'A single-use signup link is printed below')"
(( intro == 1 )) || fail "The restart counted as a first start (${intro} signup notices): /app/data/peergos/config didn't persist"
(( $(tokens) == 1 )) || fail "The restart printed a new signup token"

if logs | grep -F 'is not in localstorage.sqlite.paths'; then
    fail "Peergos created a database that backups don't handle. Add it to localstorage.sqlite.paths in CloudronManifest.json"
fi
if logs | grep -iF 'read-only file system'; then
    fail "Something writes outside /app/data, /tmp and /run"
fi

echo "Smoke test passed"
