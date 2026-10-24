# Cloudron package for Peergos (https://peergos.org)
#
# Pinned inputs. To upgrade Peergos, change PEERGOS_VERSION and PEERGOS_SHA256
# (sha256sum of the release's Peergos.jar), and bump "version" and
# "upstreamVersion" in CloudronManifest.json (see README, "Upgrading Peergos").
FROM cloudron/base:6.0.0@sha256:9bed4c8fa880645f8e669041ee28febe941481d00e9445e3e5a5483cb541d09b

LABEL org.opencontainers.image.source="https://github.com/tripod0429/peergos-app"

RUN mkdir -p /app/code/native-libs /app/pkg
WORKDIR /app/code

# Peergos needs Java >= 25 (upstream's image uses eclipse-temurin:25-jre).
# cloudron/base turns off recommended packages, so libharfbuzz0b, which the
# JRE's font library links against, has to be named.
RUN apt-get update && \
    apt-get install -y openjdk-25-jre-headless libharfbuzz0b unzip && \
    rm -rf /var/cache/apt /var/lib/apt/lists && \
    java -version

ARG PEERGOS_VERSION=1.40.0
ARG PEERGOS_SHA256=eed1a5dc2bb14f69edd9c6bef41b5d9fe3b9a5e4938e5cee32e4f8d2bfb8e0cb

# The native libraries are extracted at build time so Peergos never has to
# write them to a temp dir at runtime (same approach as upstream's Containerfile).
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    if [ "$arch" != "amd64" ]; then echo "Only amd64 is supported, got $arch"; exit 1; fi; \
    curl -fsSL -o /app/code/Peergos.jar \
        "https://github.com/Peergos/web-ui/releases/download/v${PEERGOS_VERSION}/Peergos.jar"; \
    echo "${PEERGOS_SHA256}  /app/code/Peergos.jar" | sha256sum -c -; \
    unzip -j -o -q /app/code/Peergos.jar \
        native-lib/linux/amd64/libtweetnacl.so \
        org/sqlite/native/Linux/x86_64/libsqlitejdbc.so \
        -d /app/code/native-libs

# Without a UTF-8 locale Java falls back to ASCII for console output and for
# file name encoding (sun.jnu.encoding).
ENV LANG=C.UTF-8 \
    PEERGOS_PATH=/app/data/peergos

COPY start.sh env.sh.template CloudronManifest.json /app/pkg/
RUN chmod +x /app/pkg/start.sh

CMD [ "/app/pkg/start.sh" ]
