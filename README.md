# Peergos for Cloudron

> [!NOTE]
> This is an unofficial community package. It is not affiliated with or endorsed by Peergos or Cloudron.
> The packaging (Dockerfile, scripts, manifest, tests and docs) was written with the help of Claude, an AI model by Anthropic, and tested on a real Cloudron server.

Cloudron package for [Peergos](https://peergos.org) 1.38.0, built on `cloudron/base:6.0.0` with Ubuntu's OpenJDK 25 JRE.

To install it, add this URL under Community apps in your Cloudron dashboard settings:

```
https://raw.githubusercontent.com/tripod0429/peergos-app/main/CloudronVersions.json
```

| File | Purpose |
| --- | --- |
| `Dockerfile` | Installs the JRE, downloads and checksum-verifies `Peergos.jar`, extracts the native libraries |
| `start.sh` | Builds the Peergos command line from Cloudron's environment and runs it as `cloudron` |
| `env.sh.template` | Commented settings file, copied to `/app/data/env.sh` on first start |
| `CloudronManifest.json` | Port 8000 for HTTP, 4001 TCP and UDP for P2P, 2 GiB memory, SQLite-aware backups, publishing metadata |
| `POSTINSTALL.md`, `DESCRIPTION.md`, `CHANGELOG` | Text shown in the Cloudron dashboard |
| `logo.png`, `screenshots/` | Icon and screenshots for the dashboard (from [Peergos/web-ui](https://github.com/Peergos/web-ui), GPL-3.0) |
| `test/` | Browser test of the app's life cycle on a real Cloudron |
| `AGENTS.md` | Runtime dependencies, with upstream sources |
| `.github/workflows/build.yml` | Builds the image on each push; pushes it to ghcr.io on a `v<version>` tag |

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

podman run --rm --name peergos \
  --read-only --tmpfs /tmp --tmpfs /run \
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

The local test can't exercise signup in a browser. Peergos builds its origin as `https://<public-domain>`, so the web UI only works properly behind Cloudron's TLS.

## Install on Cloudron

```bash
cloudron install --location peergos.example.com --alias-domains '*.peergos.example.com'
cloudron logs -f --app peergos.example.com      # look for "signup=true"
```

* **Wildcard alias.** Peergos serves its built-in apps (PDF viewer, calendar, editor, …) and sandboxed third-party apps from subdomains of the app domain. Cloudron doesn't add the alias by itself: pass `--alias-domains` as above, or add it under the app's Location settings in the dashboard. The wildcard certificate needs a DNS provider Cloudron can control through an API. If you can't use one, add `pdf`, `calendar`, `code-editor`, `markup-viewer`, `email` and `address-book` as individual aliases instead. Third-party apps won't work in that case.
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

## Design notes

* **Data.** Everything lives in `/app/data/peergos` (`PEERGOS_PATH`). Peergos writes its full command line to `config` there on first run and reuses it. `start.sh` passes the important flags on every start and removes the keys it manages from `config`, so a setting you remove doesn't linger.
* **Backups.** The SQLite databases are listed under `localstorage.sqlite.paths`, so Cloudron backs them up consistently instead of copying live files. That list is the only one: `start.sh` reads it from the manifest (copied into the image) and creates any listed file that is missing, because a listed file that doesn't exist breaks backups. It also logs a warning for any `*.sql`/`*.sqlite` file in `/app/data/peergos` or `.ipfs/datastore` that isn't listed, which is how a database added by a new Peergos release shows up.
* **Not in the list on purpose.** `reachability/reachability-<username>.sqlite` are per-user indexes for Peergos' garbage collector. Their names depend on the users, so they can't be listed, and they are backed up as plain files. Peergos rebuilds them from the blockstore, so the worst case after a restore is a stale index. If garbage collection logs SQLite errors after a restore, stop the app, delete `/app/data/peergos/reachability`, and start it again.
* **`thumbnailer.log`.** Peergos runs thumbnail generation in a separate JVM and appends that process's stderr to `/app/data/peergos/thumbnailer.log`. It grows a few hundred bytes per worker start, so it can safely be deleted at any time.
* **P2P listeners.** By default Peergos listens on `[::]:4001` (TCP and QUIC), which fails without an IPv6 stack. In that case `start.sh` passes the same two listeners on IPv4 with `-ipfs-swarm-addrs`. That needs Peergos 1.38.0 or later: older parsers rejected `quic-v1`, so the fallback used to be TCP only.
* **Announce flag.** The self-hosting docs show `-announce-ipfs-addresses`, but the code reads `-ipfs-announce-addresses`. Peergos ignores unknown flags silently, so the documented spelling has no effect.
* **Logging.** Peergos and its IPFS library log through one `java.util.logging` logger. At INFO that includes two lines for every request relayed to another Peergos node: about 5,000 lines in the first minute after install. `start.sh` writes `/run/peergos-logging.properties` on each start, with the level from `PEERGOS_LOG_LEVEL` (default WARNING) and one line per record. The startup, version and signup-link lines are printed directly, so they show at every level.
* **Health check.** Peergos rejects requests whose `Host` header isn't its domain. The health check relies on Cloudron sending the app's domain as `Host`. If the dashboard shows the app as not responding while it works in the browser, start investigating here.

## Upgrading Peergos

1. Download the new `Peergos.jar` from <https://github.com/Peergos/web-ui/releases> and run `sha256sum` on it.
2. Update `PEERGOS_VERSION` and `PEERGOS_SHA256` in the `Dockerfile`.
3. Bump `version` and `upstreamVersion` in `CloudronManifest.json` and add a `[version]` section to `CHANGELOG`.
4. Check that upstream's [Containerfile](https://github.com/Peergos/web-ui/blob/master/Containerfile) still uses Java 25 (see `AGENTS.md`).
5. Run the local Podman test or `cloudron update`, then check the logs for the `not in localstorage.sqlite.paths` warning. Add any file it names to the manifest.
6. Run the test suite, then publish.

## Publishing

Images go to GitHub's container registry (`ghcr.io/tripod0429/peergos-app`). `cloudron builder` isn't used: it only works with Cloudron's own registry app.

`.github/workflows/build.yml` builds the image on every push to `main` and every pull request. A `v<version>` tag also pushes it, after checking that the tag matches `version` in `CloudronManifest.json` and that the image tag doesn't exist yet. A published image never changes, so a fix always needs a new version.

Run `cloudron versions init` once to create `CloudronVersions.json`; it should add no manifest fields.

Each release:

1. Bump `version` (and `upstreamVersion` for a Peergos update) in `CloudronManifest.json`, add a `[version]` section to `CHANGELOG`, then commit and push.
2. Tag the release:

   ```bash
   version=$(jq -r .version CloudronManifest.json)
   git tag "v$version" && git push origin "v$version"
   ```

3. Cloudron servers pull the image without credentials. When the workflow publishes it from this public repo, the package is public too; that was the case for 1.0.0. If a pull fails with "unauthorized", check the package's visibility in its GitHub settings.
4. Run the tests against the pushed image (`IMAGE=ghcr.io/tripod0429/peergos-app:$version`, see below).
5. Publish:

   ```bash
   cloudron versions add --image ghcr.io/tripod0429/peergos-app:$version
   cloudron versions verify
   git add CloudronVersions.json && git commit -m "Release $version" && git push
   ```

Without the workflow, `podman login ghcr.io` (with a classic token that has `write:packages`), `podman build --format docker -t ghcr.io/tripod0429/peergos-app:$version .` and `podman push …` do the same as step 2.

Don't put `dockerImage` in `CloudronManifest.json`: `cloudron versions add` records it in `CloudronVersions.json`. To pull a bad release, use `cloudron versions revoke`, then publish a fixed version.

## Running tests

`test/test.js` follows the official Cloudron app tests. It installs the app, signs up through the browser with the token from the logs, creates a folder, then checks the folder survives a restart, a backup and restore, and a location change. It also checks that no new signup link appears after the first start, then uninstalls. It needs the `cloudron` CLI logged in to the server to test on.

The browser runs in the official Selenium container, so nothing browser-related is installed on the host. A local Chrome also can't start on hosts that preload `hardened_malloc`, such as secureblue. On secureblue, allow the image once with `run0 podman image trust set -t accept docker.io/selenium/standalone-chromium`.

```bash
podman run -d --rm --name selenium -p 127.0.0.1:4444:4444 --shm-size=2g docker.io/selenium/standalone-chromium:4.49.0
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