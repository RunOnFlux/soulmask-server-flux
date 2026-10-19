# Soulmask dedicated server image for Flux.
#
# Written from scratch. The game's native Linux server (Steam app 3017300, anonymous), installed
# and updated with SteamCMD on every start, run as uid 1000 under a supervisor that saves on stop,
# writes the gameplay settings (GameXishu.json) from the hub's panel, follows game updates,
# restarts daily if asked, keeps backups, and gives the hub a JSON status, the game's own
# maintenance console, bans, presets and restores. See README.md.
#
# The base. CI builds it pinned to the digest it resolved and records that digest in the
# org.opencontainers.image.base.digest label, which the scheduled check compares against
# (.github/ci/needs-rebuild.sh).
ARG BASE_IMAGE=steamcmd/steamcmd:ubuntu-24
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive
ARG FLUX_IMAGE_VERSION=dev

# python3 (not -minimal): fluxsm.py needs json, sqlite3 (consistent copies of the world
# database), tarfile and socket. util-linux brings setpriv (the server must not run as root).
RUN apt-get update -y && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl procps tzdata python3 util-linux && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY scripts/flux-lib.sh scripts/flux-entrypoint.sh scripts/fluxsm.py /opt/flux/
RUN chmod 0755 /opt/flux/*.sh /opt/flux/fluxsm.py && \
    ln -s /opt/flux/fluxsm.py /usr/local/bin/flux-soulmask

# SteamCMD's self-update, done once here instead of on every container start; the scheduled
# rebuild keeps it current.
RUN steamcmd +quit >/dev/null 2>&1; test -d /root/.local/share/Steam

ENV FLUX_IMAGE_VERSION=${FLUX_IMAGE_VERSION}

VOLUME ["/mnt/soulmask/server", "/mnt/soulmask/data"]

# The game port and the Steam query port (both UDP). The maintenance console (18888/tcp) is bound
# on 127.0.0.1 by the game itself and is never published.
EXPOSE 8777/udp 27015/udp

# The first start downloads about 2.2 GB. FluxOS does not act on health; this is for anyone
# running the image by hand.
HEALTHCHECK --interval=60s --timeout=10s --start-period=20m --retries=3 \
    CMD pgrep -f "/WSServer-Linux-Shipping " >/dev/null || exit 1

ENTRYPOINT []
CMD ["/opt/flux/flux-entrypoint.sh"]
