---
name: cloudron-app-packaging
description: Package web apps for Cloudron. Covers Dockerfile patterns, CloudronManifest.json, addons, cloudron builder build (registry), cloudron install/update, and debugging. Use when creating, updating, or troubleshooting a Cloudron app package, or when the user mentions Cloudron packaging, Dockerfile.cloudron, CloudronManifest.json, Cloudron addons, or cloudron builder.
---

# Cloudron App Packaging

A Cloudron app is a Docker image with a `CloudronManifest.json`. The platform provides a readonly filesystem, addon services, and a managed backup/restore lifecycle.

## Quick start

```bash
npm install -g cloudron
cloudron login my.example.com
cloudron init                    # creates CloudronManifest.json and Dockerfile
cloudron install                 # on-server build, or last cloudron builder image
cloudron update                  # same as install for an existing app
```

## Key constraints

- Filesystem is **readonly** at runtime. Writable dirs: `/tmp`, `/run`, `/app/data`.
- Databases, caching, email, and auth are **addons** — env vars injected at runtime.
- `CloudronManifest.json` declares metadata, ports, and addon requirements.
- App listens on HTTP (not HTTPS). The platform handles TLS termination.
- Default memory limit is 256 MB (RAM + swap). Set `memoryLimit` in manifest to change.

## Dockerfile patterns

Name the file `Dockerfile`, `Dockerfile.cloudron`, or `cloudron/Dockerfile`.

### Base images

Pin the dated tag **and** digest. Child images (`php-base` / `node-base` / `python-base`) use `series-YYYYMMDD` tags, not floating `:8.5` / `:24` / `:3.14`.

| App type | Image | Notes |
|----------|-------|-------|
| No Node / PHP / pip | `cloudron/base:6.0.0@sha256:9bed4c8fa880645f8e669041ee28febe941481d00e9445e3e5a5483cb541d09b` | Ubuntu 26.04. No PHP, Node, pip/venv, Apache, or mongo tools. `nginx-full`, supervisor, and ImageMagick stay. |
| Node 24 | `cloudron/node-base:24-20260920@sha256:d984683ec59bf2379130bf41cf3c2b6bc0453f327297d7183525cb05424e7b34` | Latest Node 24.x at `/usr/local/node`, **on** `PATH`. |
| Python 3.14 | `cloudron/python-base:3.14-20260920@sha256:f61b3964a044414c8dcdcd897aea39629e3d73a21e48c01492e4c4a82753f891` | Distro Python, venv, pip. Prefer when the app supports it. |
| Python 3.13 | `cloudron/python-base:3.13-20260920@sha256:32e0d51808c692ab7fe6dd51c98238d6b15b1102462e5d7ade954cf48f5acbf2` | When upstream pins 3.13. |
| Python 3.12 | `cloudron/python-base:3.12-20260920@sha256:49c5a00c1110ec76cb5122e48c26dbc26a1c04e020c9ee230be95272c66eb86b` | When upstream pins 3.12. |
| Python 3.11 | `cloudron/python-base:3.11-20260920@sha256:b667f60283768162b46c84f69619e13edbf6c1e1a4ccde3c1d828d7d631f5f0b` | When upstream pins 3.11. |
| PHP 8.5 | `cloudron/php-base:8.5-20260920@sha256:a59a4334fbf50ebfdf8f6cc5527e099e4586349a1aefc546e85f7401ea366d65` | Prefer when the app supports PHP 8.5. Apache, Composer, and ghostscript (for Imagick PDF) are here. |
| PHP 8.4 | `cloudron/php-base:8.4-20260920@sha256:e9352b5fba7ad0a231b8a9e454034400a3a34a7fe1800425f634d32ffcae4a52` | Use when the app is not ready for 8.5. |

Do **not** put PHP, Node, or pip/venv back into `cloudron/base`. Apps that need a Node major other than 24 stay on `cloudron/base` and install their own tarball. uv / conda apps stay on `cloudron/base` and install their own interpreter. Node/PHP apps that need a Python sidecar stay on `node-base` / `php-base` and `apt-get install python3-venv` (use **install**, not `reinstall`).

### Typical structure (Node)

```dockerfile
FROM cloudron/node-base:24-20260920@sha256:d984683ec59bf2379130bf41cf3c2b6bc0453f327297d7183525cb05424e7b34

RUN mkdir -p /app/code
WORKDIR /app/code

COPY . /app/code/

RUN ln -sf /run/app/config.json /app/code/config.json

RUN chmod +x /app/code/start.sh

CMD [ "/app/code/start.sh" ]
```

Do **not** set `ENV PATH=/usr/local/node-…/bin:$PATH` on `node-base`. Node is already on `PATH`.

### Typical structure (non-PHP, no Node)

```dockerfile
FROM cloudron/base:6.0.0@sha256:9bed4c8fa880645f8e669041ee28febe941481d00e9445e3e5a5483cb541d09b

RUN mkdir -p /app/code
WORKDIR /app/code

COPY . /app/code/

RUN ln -sf /run/app/config.json /app/code/config.json

RUN chmod +x /app/code/start.sh

CMD [ "/app/code/start.sh" ]
```

### Typical structure (Python)

```dockerfile
FROM cloudron/python-base:3.14-20260920@sha256:f61b3964a044414c8dcdcd897aea39629e3d73a21e48c01492e4c4a82753f891

RUN mkdir -p /app/code
WORKDIR /app/code

COPY . /app/code/

RUN python3 -m venv /app/code/venv
RUN /app/code/venv/bin/pip install -r /app/code/requirements.txt

RUN chmod +x /app/code/start.sh

CMD [ "/app/code/start.sh" ]
```

Use `:3.13-20260920` / `:3.12-20260920` / `:3.11-20260920` (same date, matching digest from the table) when upstream pins that series.

### Typical structure (PHP)

```dockerfile
FROM cloudron/php-base:8.5-20260920@sha256:a59a4334fbf50ebfdf8f6cc5527e099e4586349a1aefc546e85f7401ea366d65

RUN mkdir -p /app/code
WORKDIR /app/code

# configure apache / php paths under /etc/php/8.5/...
RUN a2enmod rewrite php8.5

CMD [ "/app/code/start.sh" ]
```

`libapache2-mod-php` is enabled by the package. Apps that use php-fpm should `a2dismod php8.5` and `a2enconf php8.5-fpm`. Multi-PHP apps (e.g. LAMP) stay on `cloudron/base` and install `apache2` themselves. A static Apache site (no PHP) also `apt-get install apache2` — Apache is not in `cloudron/base`.

### mongosh

`mongosh` is not in any base image. Apps that declare the `mongodb` addon and need it (Web terminal, or `start.sh`) install the official tarball:

```dockerfile
FROM cloudron/base:6.0.0@sha256:9bed4c8fa880645f8e669041ee28febe941481d00e9445e3e5a5483cb541d09b
ARG MONGOSH_VERSION=2.9.2
RUN curl -fsSL "https://downloads.mongodb.com/compass/mongosh-${MONGOSH_VERSION}-linux-x64.tgz" \
        | tar -zx -C /tmp && \
    cp /tmp/mongosh-${MONGOSH_VERSION}-linux-x64/bin/mongosh /usr/local/bin/ && \
    rm -rf /tmp/mongosh-${MONGOSH_VERSION}-linux-x64
```

Do **not** `COPY --from=cloudron/mongotools`.

### Multi-stage builds

Multi-stage builds are acceptable for compilation, asset bundling, or any other build-time work. The **final stage** must use `cloudron/base`, `cloudron/node-base`, `cloudron/python-base`, or `cloudron/php-base`. Platform tooling such as the file manager, web terminal, and log viewer depends on utilities provided by these images.

```dockerfile
FROM cloudron/node-base:24-20260920@sha256:d984683ec59bf2379130bf41cf3c2b6bc0453f327297d7183525cb05424e7b34 AS build
WORKDIR /build
COPY . .
RUN npm ci && npm run build

FROM cloudron/node-base:24-20260920@sha256:d984683ec59bf2379130bf41cf3c2b6bc0453f327297d7183525cb05424e7b34

RUN mkdir -p /app/code
WORKDIR /app/code

COPY --from=build /build/dist /app/code/dist
COPY start.sh /app/code/

RUN chmod +x /app/code/start.sh
CMD [ "/app/code/start.sh" ]
```

PHP apps that need Node at build time (e.g. Lychee) `COPY --from=cloudron/node-base:24-20260920` into a builder stage, with `php-base` as the final stage.

### start.sh conventions

- Runs as root. Use `gosu cloudron:cloudron <cmd>` to drop privileges.
- Fix ownership on every start (backups/restores can reset it):
  ```bash
  chown -R cloudron:cloudron /app/data
  ```
- Use `exec` as the last command to forward SIGTERM:
  ```bash
  exec gosu cloudron:cloudron node /app/code/server.js
  ```
- Track first-run with a marker file:
  ```bash
  if [[ ! -f /app/data/.initialized ]]; then
    # first-time setup
    touch /app/data/.initialized
  fi
  ```

### Writable directories

| Path | Persists across restarts | Backed up |
|------|--------------------------|-----------|
| `/tmp` | No | No |
| `/run` | No | No |
| `/app/data` | Yes | Yes (requires `localstorage` addon) |

Put runtime config (generated files) in `/run`. Put persistent data in `/app/data`.

### Logging

Log to stdout/stderr. The platform manages rotation and streaming.

If the app cannot log to stdout, write to `/run/<subdir>/*.log` (two levels deep). These files are autorotated.

### Multiple processes

Use `supervisor` or `pm2` when the app has multiple components. Single-process apps do not need a process manager. Configure supervisor to send output to stdout:

```ini
[program:app]
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
```

### Memory-aware worker count

```bash
if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    memory_limit=$(cat /sys/fs/cgroup/memory.max)
    [[ "${memory_limit}" == "max" ]] && memory_limit=$((2 * 1024 * 1024 * 1024))
else
    memory_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
fi
worker_count=$((memory_limit / 1024 / 1024 / 150))
worker_count=$((worker_count > 8 ? 8 : worker_count))
worker_count=$((worker_count < 1 ? 1 : worker_count))
```

## Manifest essentials

Minimal `CloudronManifest.json`:

```json
{
  "id": "com.example.myapp",
  "title": "My App",
  "author": "Jane Developer <jane@example.com>",
  "version": "1.0.0",
  "healthCheckPath": "/",
  "httpPort": 8000,
  "addons": {
    "localstorage": {}
  },
  "manifestVersion": 2
}
```

Common fields:

| Field | Purpose |
|-------|---------|
| `httpPort` | TCP port the app listens on (HTTP only) |
| `healthCheckPath` | Path returning 2xx when app is healthy |
| `addons` | Addon requirements (see below) |
| `version` | Semver package version |
| `memoryLimit` | Max memory in bytes (default 256 MB) |
| `tcpPorts` / `udpPorts` | Non-HTTP port bindings exposed to the user |
| `httpPorts` | Additional HTTP services on secondary domains |
| `multiDomain` | Enable alias domains |
| `optionalSso` | Allow install without user management |
| `configurePath` | Admin panel path shown in dashboard |
| `postInstallMessage` | Markdown shown after install (supports `<sso>`/`<nosso>` tags) |
| `minBoxVersion` | Minimum platform version required |

For the full field reference, see [manifest-ref.md](manifest-ref.md).

## Addons overview

Declare addons in the manifest `addons` object. Env vars are injected at runtime.

| Addon | Provides | Key env var |
|-------|----------|-------------|
| `localstorage` | Writable `/app/data`, backup support, optional FTP/SQLite | — |
| `mysql` | MySQL 8.0 database | `CLOUDRON_MYSQL_URL` |
| `postgresql` | PostgreSQL 14.9 database | `CLOUDRON_POSTGRESQL_URL` |
| `mongodb` | MongoDB 8.0 database | `CLOUDRON_MONGODB_URL` |
| `redis` | Redis 8.4 cache (persistent) | `CLOUDRON_REDIS_URL` |
| `ldap` | LDAP v3 authentication | `CLOUDRON_LDAP_URL` |
| `oidc` | OpenID Connect authentication | `CLOUDRON_OIDC_DISCOVERY_URL` |
| `sendmail` | Outgoing email (SMTP relay) | `CLOUDRON_MAIL_SMTP_SERVER` |
| `recvmail` | Incoming email (IMAP) | `CLOUDRON_MAIL_IMAP_SERVER` |
| `email` | Full email (SMTP + IMAP + Sieve) | multiple |
| `proxyauth` | Authentication wall in front of app | — |
| `scheduler` | Cron-like periodic tasks | — |
| `tls` | App certificate files | `/etc/certs/tls_cert.pem` |
| `turn` | STUN/TURN service | `CLOUDRON_TURN_SERVER` |
| `docker` | Create containers (restricted) | `CLOUDRON_DOCKER_HOST` |

Read env vars at runtime on every start — values can change across restarts. Run DB migrations on each start.

For full env var lists and addon options, see [addons-ref.md](addons-ref.md).

## Build and install

There are two ways to get an image onto the Cloudron.

### On-server build (default)

`cloudron install` and `cloudron update` upload the source and build on the server. No local Docker and no registry are needed. These images cannot be published (`cloudron versions add` / appstore upload).

```bash
cloudron install
cloudron update
```

Do **not** use `cloudron build`. That command no longer exists.

### Registry (`cloudron builder`)

If a [Container registry](https://docs.cloudron.io/packages/container-registry/) is in use, build with `cloudron builder`, then install from that image. This is the workflow for offloading builds and for anything that must produce a registry-hosted image (publishing, repeating installs without rebuilding on the box).

```bash
cloudron builder login           # registry URL, username, app password
cloudron builder build           # from the package directory (Dockerfile + manifest)
cloudron install                 # uses the last builder image (prompts on a TTY)
cloudron update
```

The CLI remembers the repository name for later `cloudron builder build` runs. `cloudron builder reset` clears it. `cloudron versions add` and `cloudron appstore upload` use the same last builder image (`--last-build` skips the prompt; `--image` records a specific image).

Private registry repos are not pullable until the repo is public or the registry is added under the Cloudron private-registry settings.

## Debugging

```bash
cloudron logs                # view app logs
cloudron logs -f             # follow logs in real time
cloudron exec                # shell into running app
cloudron debug               # pause app (read-write filesystem)
cloudron debug --disable     # exit debug mode
```

## Stack-specific notes

**Apache** — In `php-base` already. On `cloudron/base`, `apt-get install apache2`. Disable default sites, set `Listen 8000`, log errors to stderr, start with `exec /usr/sbin/apache2 -DFOREGROUND`.

**Nginx** — `nginx-full` is in `cloudron/base`. Use `/run/` for temp paths (`client_body_temp_path`, `proxy_temp_path`, etc.). Run with supervisor alongside the app.

**PHP** — Move sessions from `/var/lib/php/sessions` to `/run/php/sessions` via symlink. Paths are `/etc/php/8.5` (or `8.4`); php-fpm is `/usr/sbin/php-fpm8.5` and `unix:/run/php/php8.5-fpm.sock`. Ghostscript is in `php-base` for Imagick PDF; other apps that need it `apt-get install ghostscript`.

**Java** — Read cgroup memory limit and set `-XX:MaxRAM` accordingly.

## Examples

All published Cloudron apps are open source: https://git.cloudron.io/packages

Browse by framework:
[PHP](https://git.cloudron.io/explore/projects?tag=php) ·
[Node](https://git.cloudron.io/explore/projects?tag=node) ·
[Python](https://git.cloudron.io/explore/projects?tag=python) ·
[Ruby/Rails](https://git.cloudron.io/explore/projects?tag=rails) ·
[Java](https://git.cloudron.io/explore/projects?tag=java) ·
[Go](https://git.cloudron.io/explore/projects?tag=go) ·
[Rust](https://git.cloudron.io/explore/projects?tag=rust)

## Additional resources

- For the full manifest field reference, see [manifest-ref.md](manifest-ref.md).
- For addon env vars and options, see [addons-ref.md](addons-ref.md).
- Ask questions: [App Packaging & Development forum](https://forum.cloudron.io/category/96/app-packaging-development)
