# Cloudron package for Peergos (https://peergos.org)
#
# Pinned inputs. Renovate updates PEERGOS_TAG and PEERGOS_SHA256 (sha256sum of
# the release's Peergos.jar) together with "version" and "upstreamVersion" in
# CloudronManifest.json (see renovate.json and README, "Upgrading Peergos").
FROM cloudron/base:6.0.1@sha256:7b1e729960c3ca312d26e886917ba89483241bba0219ff292858e10d9d5768ee

LABEL org.opencontainers.image.source="https://github.com/tripod0429/peergos-app"

RUN mkdir -p /app/code/native-libs /app/pkg
WORKDIR /app/code

# Peergos needs Java >= 25 (upstream's image uses Azul Zulu 25).
# cloudron/base turns off recommended packages, so libharfbuzz0b, which the
# JRE's font library links against, has to be named.
RUN apt-get update && \
    apt-get install -y openjdk-25-jre-headless libharfbuzz0b unzip && \
    rm -rf /var/cache/apt /var/lib/apt/lists && \
    java -version

# The release's git tag, with its "v": Renovate looks the checksum up by tag
ARG PEERGOS_TAG=v1.43.0
ARG PEERGOS_SHA256=9f322a277fe88ef021e4e275367489a998ab2f47d7036a3b7b3cfbc913dd0700

# The native libraries are extracted at build time so Peergos never has to
# write them to a temp dir at runtime (same approach as upstream's Containerfile).
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    if [ "$arch" != "amd64" ]; then echo "Only amd64 is supported, got $arch"; exit 1; fi; \
    curl -fsSL -o /app/code/Peergos.jar \
        "https://github.com/Peergos/web-ui/releases/download/${PEERGOS_TAG}/Peergos.jar"; \
    echo "${PEERGOS_SHA256}  /app/code/Peergos.jar" | sha256sum -c -; \
    unzip -j -o -q /app/code/Peergos.jar \
        native-lib/linux/amd64/libtweetnacl.so \
        org/sqlite/native/Linux/x86_64/libsqlitejdbc.so \
        -d /app/code/native-libs

# Without a UTF-8 locale Java falls back to ASCII for console output and for
# file name encoding (sun.jnu.encoding).
ENV LANG=C.UTF-8 \
    PEERGOS_PATH=/app/data/peergos

COPY start.sh backup.sh env.sh.template CloudronManifest.json /app/pkg/
RUN chmod +x /app/pkg/start.sh /app/pkg/backup.sh

CMD [ "/app/pkg/start.sh" ]
