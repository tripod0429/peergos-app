# Peergos runtime dependencies

What Peergos needs at runtime, with upstream sources.

- Upstream: https://github.com/Peergos/Peergos (server), https://github.com/Peergos/web-ui (UI and release builds)
- Upstream image: https://github.com/Peergos/web-ui/blob/master/Containerfile

## Required

| Dependency | Used for | Source |
|---|---|---|
| Java JRE 25+ | Peergos runs on the JVM | https://github.com/Peergos/web-ui/blob/master/Containerfile |
| `libtweetnacl.so` | Native crypto (TweetNaCl), passed with `-native-tweetnacl-path` | Shipped inside `Peergos.jar` (`native-lib/linux/amd64/`), extracted at build time like the upstream Containerfile does |
| `libharfbuzz0b` | The JRE's font library (`libfontmanager.so`) links against it. Ubuntu's JRE only recommends it, and `cloudron/base` turns recommends off | this repo (found with `ldd`) |
| `libsqlitejdbc.so` | Native part of the SQLite JDBC driver, passed with `-native-sqlite-path` | Shipped inside `Peergos.jar` (`org/sqlite/native/Linux/x86_64/`), extracted at build time |

## Runtime versions (soft)

What upstream declares or tests against. Informational: a newer version is not a conflict unless the row says it is enforced.

| Runtime | Upstream says | Source |
|---|---|---|
| Java | 25 (since 1.39 the upstream image builds a trimmed runtime with `jlink` from `eclipse-temurin:25-jdk`, on `debian:trixie-slim`). This package uses Ubuntu's `openjdk-25-jre-headless`. If Peergos ever needs a Java that Ubuntu 26.04 doesn't ship, switch to a Temurin tarball | https://github.com/Peergos/web-ui/blob/master/Containerfile |
