# Peergos for Cloudron

> [!NOTE]
> This is an unofficial community package. It is not affiliated with or endorsed by Peergos or Cloudron.
> The packaging (Dockerfile, scripts, manifest, tests and docs) was written with the help of Claude, an AI model by Anthropic, and tested on a real Cloudron server.

Cloudron package for [Peergos](https://peergos.org) 1.43.0, built on `cloudron/base:6.0.0` with Ubuntu's OpenJDK 25 JRE.

To install it, add this URL under Community apps in your Cloudron dashboard settings:

```
https://raw.githubusercontent.com/tripod0429/peergos-app/main/CloudronVersions.json
```

| File | Purpose |
| --- | --- |
| `Dockerfile` | Installs the JRE, downloads and checksum-verifies `Peergos.jar`, extracts the native libraries |
| `start.sh` | Builds the Peergos command line from Cloudron's environment and runs it as `cloudron` |
| `backup.sh` | Cloudron's `backupCommand`: collects garbage in the running server just before each backup |
| `env.sh.template` | Commented settings file, copied to `/app/data/env.sh` on first start |
| `CloudronManifest.json` | Port 8000 for HTTP, 4001 TCP and UDP for P2P, 2 GiB memory, SQLite-aware backups, publishing metadata |
| `POSTINSTALL.md`, `DESCRIPTION.md`, `CHANGELOG` | Text shown in the Cloudron dashboard |
| `logo.png`, `screenshots/` | Icon and screenshots for the dashboard (from [Peergos/web-ui](https://github.com/Peergos/web-ui), GPL-3.0) |
| `test/` | Browser test of the app's life cycle on a real Cloudron |
| `AGENTS.md` | Runtime dependencies, with upstream sources |
| `.github/workflows/build.yml` | Builds and smoke-tests the image on each push and pull request; publishes a new version when it reaches `main` |
| `.github/actions/build/` | The build and smoke test that both of the workflow's jobs run |
| `.github/scripts/` | The workflow's smoke test, CHANGELOG generator and signed commit helper |
| `renovate.json` | Renovate config: a PR for each Peergos release, plus the base image, GitHub Actions and test dependencies |

## Local test with Podman (secureblue)

One-time setup. Both are security trade-offs that secureblue makes opt-in:

```bash
ujust set-container-userns on                                   # rootless containers
run0 podman image trust set -t accept docker.io/cloudron/base   # allow the unsigned base image
```

Build and run with the same read-only filesystem Cloudron uses:

```bash
# --format docker keeps the base image's bash SHELL, like Cloudron's docker builds
podman build --format docker -t peergos-cloudron .
podman volume create peergos-test

# exec, as on Cloudron: sqlite-jdbc extracts its native library to /tmp and loads it from there
podman run --rm --name peergos \
  --read-only --tmpfs /tmp:exec --tmpfs /run:exec \
  -v peergos-test:/app/data \
  -e CLOUDRON_APP_DOMAIN=peergos.localhost \
  -e PEERGOS_PUBLIC_IP=none \
  -e IPFS_TCP_PORT=4001 -e IPFS_UDP_PORT=4001 \
  -e PEERGOS_LOG_LEVEL=INFO \
  -p 127.0.0.1:8000:8000 \
  peergos-cloudron
```

In a second terminal:

```bash
# Should print 200. Peergos answers 404 to any Host it doesn't recognise.
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: peergos.localhost' http://127.0.0.1:8000/

# Built-in apps live on subdomains, under /apps/<name>/
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: pdf.peergos.localhost' http://127.0.0.1:8000/apps/pdf/index.html
```

Things to check:

* The first start prints a `signup=true&token=...` line. Stop and start the container again: there should be no new token, and the `Starting Nabu ... peerid:` line (logged at INFO) should show the same peer ID.
* Nothing should fail with a read-only filesystem error. If something does, it is writing outside `/app/data`, `/tmp` or `/run`.
* No `==> WARNING: ... is not in localstorage.sqlite.paths` line (see Backups below).

`DOCKER=podman .github/scripts/smoke-test.sh peergos-cloudron` runs these checks automatically, the same way CI does.

The local test can't exercise signup in a browser. Peergos builds its origin as `https://<public-domain>`, so the web UI only works properly behind Cloudron's TLS.

## Install on Cloudron

```bash
cloudron install --location peergos.example.com --alias-domains '*.peergos.example.com'
cloudron logs -f --app peergos.example.com      # look for "signup=true"
```

* **Wildcard alias.** Required. Peergos serves its built-in apps (PDF viewer, calendar, editor, …), the HTML viewer and sandboxed third-party apps from subdomains of the app domain. The HTML viewer and third-party apps get hashed subdomains, so individual aliases can't cover them. Cloudron doesn't add the alias by itself: pass `--alias-domains` as above, or add it under the app's Location settings in the dashboard. The wildcard certificate needs a DNS provider Cloudron can control through an API.
* **Signup link.** Peergos prints it with `:8000` appended. Remove that before opening it.
* **Firewall.** Port 4001 TCP and UDP must be reachable from the internet.

### Settings

Settings live in `/app/data/env.sh`, which `start.sh` creates from `env.sh.template` on first start and never overwrites. Edit it with the dashboard's File Manager (or `cloudron exec`), then restart the app. Uncomment a line to use it:

```bash
export PEERGOS_ADMIN_USERNAMES=alice
```

`cloudron env set --app <app> NAME=value` still works too. If both set the same variable, `env.sh` wins.

| Variable | Effect |
| --- | --- |
| `PEERGOS_ADMIN_USERNAMES` | Comma-separated admins, who can manage signup tokens and space requests in the UI |
| `PEERGOS_DEFAULT_QUOTA` | Storage per new user in bytes. Peergos' default is 1 GiB |
| `PEERGOS_GENERATE_TOKEN=true` | Print one more signup link on the next start. Unset it afterwards, or every restart makes a token |
| `PEERGOS_PUBLIC_IP` | Public IP to announce. Defaults to the app domain's A record, which is wrong behind Cloudflare's proxy or NAT. `none` disables announcing |
| `PEERGOS_EXTRA_ARGS` | Extra Peergos flags, split on spaces, e.g. the `-use-s3 true -s3.bucket …` set for S3 storage |
| `PEERGOS_MAX_RAM_PERCENTAGE` | JVM heap as a share of the container's memory limit (default 60) |
| `PEERGOS_LOG_LEVEL` | `SEVERE`, `WARNING` (default) or `INFO`. See Logging below |
| `PEERGOS_AUTO_GC=true` | Let Peergos collect garbage on its own every 12 hours. Only for an app you don't back up, see Backup and restore |

## Backup and restore

* **What's covered.** All of `/app/data`: the databases, the blockstore with every user's encrypted files, and the node's identity (peer ID and private key, in `/app/data/peergos/config`). A restore brings the server back as the same Peergos node, so other servers and the global PKI keep finding it.
* **Before you restore.** Stop Peergos sync on every device and copy each synced folder somewhere safe. Files uploaded since the backup are missing on the restored server, which looks like a deletion to the sync client, and by default it deletes the local copies too.
* **What a restore can't undo.** The rest of the network keeps going. Accounts created since the backup stay registered in the global PKI, but the server no longer has them, and usernames can't be reused. Friendships with users on other servers made since the backup may be one-sided.
* **Garbage collection.** Space from deleted files is freed by a garbage collection that `backup.sh` (the manifest's `backupCommand`) runs just before each backup. Peergos' own 12-hour timer is off, because a collection while a backup is being copied could delete blocks that backup still needs. If you don't back up this app, set `PEERGOS_AUTO_GC=true` in `env.sh` so space is still freed. Don't combine it with backups.
* **Cloudron 10.1.6 or later.** The package requires it. Earlier versions had [a restore bug](https://forum.cloudron.io/topic/16125/sqlite-backups-restore-never-applies-the-dump-docker-run-without-i): a restore kept the database files as the upload copied them while the app ran, not the snapshots Cloudron takes first. Backups made before your Cloudron reached 10.1.6 still restore that way. With the rsync backup format, a file written during such a backup can leave that user's account unusable after a restore.
* **If a restore looks incomplete.** Keep several backups. If a user's files won't load after a restore, restore an older one.
* **Clones and moves.** `start.sh` writes the app's Cloudron id to `/app/data/cloudron-app-id`. If the data turns up in a different app (a clone, or a backup imported into a new app), Peergos isn't started and the logs say why: two copies would run as the same Peergos node and split its users' data. If you moved Peergos and the old app is gone, delete that file with the File Manager and restart the app. Restores, location changes, updates and a full Cloudron restore keep the app id and aren't affected. Backups made before version 1.2.0 have no id file, so a clone of one isn't caught.

## Design notes

* **Data.** Everything lives in `/app/data/peergos` (`PEERGOS_PATH`). Peergos writes its full command line to `config` there on first run and reuses it. `start.sh` passes the important flags on every start and removes the keys it manages from `config`, so a setting you remove doesn't linger.
* **Backups.** The SQLite databases are listed under `localstorage.sqlite.paths`, so Cloudron snapshots each one before it uploads the rest, and restores the snapshots. That list is the only one: `start.sh` reads it from the manifest (copied into the image) and creates any listed file that is missing, because a listed file that doesn't exist breaks backups. It also logs a warning for any `*.sql`/`*.sqlite` file in `/app/data/peergos` or `.ipfs/datastore` that isn't listed, which is how a database added by a new Peergos release shows up.
* **Backup hook.** `backup.sh` runs in a separate container that shares the app's network and mounts `/app/data`. It asks the running server to collect garbage with `Peergos.jar gc`, which authenticates with the token the server writes to `gc.token` and waits until the collection has finished. It skips the collection when the server doesn't answer, because `gc` would then collect in its own process next to a server that may be starting. A failed collection is retried once: a second request waits for a collection that is still running, so a success means none is. Peergos also refuses to collect while it sorts a blockstore into per-user folders, but only blockstores from Peergos versions over a year old need that. A new server's blockstore is sorted from the start, so the hook treats that refusal like any other failure. If that fails too, the backup goes ahead anyway, since Cloudron aborts a backup whose hook fails. It runs `gc` as `cloudron`, so nothing under `/app/data` ends up owned by root.
* **`env.sh` runs as root.** `start.sh` sources `/app/data/env.sh` before it drops to `cloudron`, and `/app/data` is writable by `cloudron`. So anything that could already write files as the Peergos process could get root inside the container on the next restart. That's still confined to an unprivileged, read-only container, and it's the same pattern as official Cloudron packages such as Directus. A possible future fix: evaluate `env.sh` as `cloudron` and import only `PEERGOS_*` variables (other than `PEERGOS_PATH`) into the root script.
* **Not in the list on purpose.** `reachability/reachability-<username>.sqlite` are per-user indexes for Peergos' garbage collector. Their names depend on the users, so they can't be listed, and they are backed up as plain files. Peergos rebuilds them from the blockstore, so the worst case after a restore is a stale index. If garbage collection logs SQLite errors after a restore, stop the app, delete `/app/data/peergos/reachability`, and start it again.
* **`thumbnailer.log`.** Peergos runs thumbnail generation in a separate JVM and appends that process's stderr to `/app/data/peergos/thumbnailer.log`. It grows a few hundred bytes per worker start, so it can safely be deleted at any time.
* **P2P listeners.** By default Peergos listens on `[::]:4001` (TCP and QUIC), which fails without an IPv6 stack. In that case `start.sh` passes the same two listeners on IPv4 with `-ipfs-swarm-addrs`. That needs Peergos 1.38.0 or later: older parsers rejected `quic-v1`, so the fallback used to be TCP only.
* **Announce flag.** The self-hosting docs show `-announce-ipfs-addresses`, but the code reads `-ipfs-announce-addresses`. Peergos ignores unknown flags silently, so the documented spelling has no effect.
* **Logging.** Peergos and its IPFS library log through one `java.util.logging` logger. At INFO that includes two lines for every request relayed to another Peergos node: about 5,000 lines in the first minute after install. `start.sh` writes `/run/peergos-logging.properties` on each start, with the level from `PEERGOS_LOG_LEVEL` (default WARNING) and one line per record. The startup, version and signup-link lines are printed directly, so they show at every level.
* **Health check.** Peergos rejects requests whose `Host` header isn't its domain. The health check relies on Cloudron sending the app's domain as `Host`. If the dashboard shows the app as not responding while it works in the browser, start investigating here.

## Upgrading Peergos

Renovate (Mend's hosted app, configured in `renovate.json`) opens a pull request a few hours after each Peergos release. It updates:

* `PEERGOS_TAG` and `PEERGOS_SHA256` in the `Dockerfile`. Renovate downloads the release's `Peergos.jar` to compute the checksum.
* `upstreamVersion` and `version` in `CloudronManifest.json`. A minor Peergos release bumps the minor package version, a patch release the patch version.
* The Peergos version at the top of this README.

The PR's build job builds the image and runs the smoke test, which also fails on a `not in localstorage.sqlite.paths` warning. Its summary shows the CHANGELOG section that merging will publish.

Before merging:

1. Check that upstream's [Containerfile](https://github.com/Peergos/web-ui/blob/master/Containerfile) still uses Java 25 (see `AGENTS.md`). The smoke test fails if `Peergos.jar` needs a newer Java than the image has, but not if upstream merely moved to one.
2. Run the test suite against the PR's branch (`renovate/peergos`, see Running tests). Without `IMAGE` it builds on the server from your checkout. Set `VERSIONS_URL` to also test the update from the published version.
3. If the smoke test named a new database, add it to `localstorage.sqlite.paths` in the manifest on the PR's branch. Renovate leaves a PR alone once someone else has pushed to it.

Merging publishes the version (see Publishing).

Renovate's other PRs (the `cloudron/base` image, GitHub Actions, test dependencies) don't change `version`, so merging them publishes nothing: a base image update ships with the next release. To ship one sooner, bump `version` and add a `[version]` section to `CHANGELOG` in its PR.

## Publishing

Images go to GitHub's container registry (`ghcr.io/tripod0429/peergos-app`). `cloudron builder` isn't used: it only works with Cloudron's own registry app.

`.github/workflows/build.yml` builds the image and runs `.github/scripts/smoke-test.sh` on every pull request and every push to `main`. When `main` gets a `version` that `CloudronVersions.json` doesn't have yet, the same run publishes it:

1. If `CHANGELOG` has no `[version]` section, `.github/scripts/changelog.sh` adds one. It has a line that links the release notes, then upstream's notes for every Peergos release since the last published version. The notes are verbatim except that blank lines are dropped and lines that aren't list items become one, because a line that starts with `[` ends a section for Cloudron's parser. If Peergos didn't change, there's nothing to copy and the run fails: write the section yourself.
2. Builds the image, smoke-tests it, pushes it, and checks that it can be pulled without credentials, as Cloudron servers do.
3. Runs `cloudron versions add --image …` and `cloudron versions verify`.
4. Tags the commit the image was built from as `v<version>`, then commits `CHANGELOG` and `CloudronVersions.json` as "Publish \<version\>" through GitHub's API, which signs the commit. The version only counts as published once that commit is on `main`.

Only a run that publishes from `main` gets a token that can push images, tags and commits. A first job decides that from `CloudronManifest.json` and `CloudronVersions.json` alone. Pull requests, dry runs, runs on other branches and pushes that don't change the version run the branch's scripts with a read-only token.

So a release is any PR that bumps `version`: Renovate's, or one of yours with a `[version]` section in `CHANGELOG`. Don't push a version bump straight to `main` without running the tests first.

Only versions that aren't in `CloudronVersions.json` yet are ever pushed, so an image someone was offered never changes, and a fix always needs a new version. A run that fails before the publish commit leaves the version unpublished, so a rerun starts over. It pushes the image again and accepts a `v<version>` tag that's already on the commit it built. A tag on any other commit, which could be anything, stops the run before it pushes anything: delete the tag if it's left from a failed release, or bump the version. To retry, rerun the failed job, or use Run workflow under Actions with "dry run" unticked. With it ticked (the default), Run workflow only shows the CHANGELOG section it would publish.

The workflow commits to `main` and creates the tag directly with its own token. So a rule on `main` that requires pull requests or status checks rejects the publish commit, and a rule that restricts creating tags rejects the tag. A rule that requires signed commits is fine, because GitHub signs the commit. Leave those rules off: nothing merges by itself, and a PR shows whether its build passed either way.

Run `cloudron versions init` once to create `CloudronVersions.json`; it should add no manifest fields.

Without the workflow: `podman login ghcr.io` (with a classic token that has `write:packages`), `podman build --format docker -t ghcr.io/tripod0429/peergos-app:$version .`, `podman push …`, then `cloudron versions add --image ghcr.io/tripod0429/peergos-app:$version`, `cloudron versions verify`, and commit and tag.

Don't put `dockerImage` in `CloudronManifest.json`: `cloudron versions add` records it in `CloudronVersions.json`. To pull a bad release, use `cloudron versions revoke`, then publish a fixed version.

## Running tests

`test/test.js` follows the official Cloudron app tests. It installs the app, signs up through the browser with the token from the logs, creates a folder, then checks the folder survives a restart, a backup and restore, and a location change. It also checks that no new signup link appears after the first start, and that Peergos holds when `/app/data/cloudron-app-id` names another app and starts again once the file is deleted, then uninstalls. It needs the `cloudron` CLI logged in to the server to test on.

The browser runs in the official Selenium container, so nothing browser-related is installed on the host. A local Chrome also can't start on hosts that preload `hardened_malloc`, such as secureblue. On secureblue, allow the image once with `run0 podman image trust set -t accept docker.io/selenium/standalone-chromium`.

The browser opens before the install and sits idle during it and during backups and restores. Selenium ends a session after 300 idle seconds by default, so `SE_NODE_SESSION_TIMEOUT` raises that.

```bash
podman run -d --rm --name selenium -p 127.0.0.1:4444:4444 --shm-size=2g -e SE_NODE_SESSION_TIMEOUT=3600 docker.io/selenium/standalone-chromium:4.49.0
cd test && npm install
export SELENIUM_REMOTE_URL=http://127.0.0.1:4444
LOCATION=peergos-test.example.com npm test                                   # builds on the server from this directory
LOCATION=peergos-test.example.com IMAGE=ghcr.io/tripod0429/peergos-app:1.0.0 npm test
podman stop selenium
```

Without `SELENIUM_REMOTE_URL`, Selenium uses a local Chrome, downloading chromedriver (and Chrome for Testing, if none is installed) to `~/.cache/selenium`.

* `LOCATION` is the full domain to install at. The location-change step also uses `<first label>2.<rest>`, e.g. `peergos-test2.example.com`.
* `IMAGE` installs and updates a pushed image instead of building on the server.
* `P2P_PORT` sets the host port for P2P (TCP and UDP). Use it when another Peergos on the server already has 4001.
* `VERSIONS_URL` (the hosted `CloudronVersions.json`) adds an update test: install the published version, create data, update to this build, check the data.
* `SHOW_BROWSER=1` shows the browser instead of running headless (local Chrome only). Screenshots of failed steps land in `test/screenshots/`.

Each run signs up one or two accounts named `cloudrontest…`. Peergos usernames are global across the Peergos network, so these stay registered in its public PKI after the app is uninstalled.