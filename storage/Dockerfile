# syntax=docker/dockerfile:1
# IOWAP — Storage service node image.
#
# Builds ``FROM iowap-node-base`` and adds the storage node's node.yaml
# (capability declarations) + handlers/ directory. The whole node stack
# is already installed in the base image, so this Dockerfile has no
# Python install step — it is a thin layer on top of the base.
#
# Build context is the repo root, Dockerfile path is storage/Dockerfile:
#
#   docker build -t iowap-node-base -f base/Dockerfile .
#   docker build -t iowap-storage   -f storage/Dockerfile .

ARG NODE_BASE_IMAGE=iowap-node-base:latest
FROM ${NODE_BASE_IMAGE}

ENV NODE_PORT=8791 \
    STORAGE_PATH=/storage

WORKDIR /app

# Copy the storage node's capability profile + handlers.
COPY --chown=appuser:appuser storage/node.yaml /app/profiles/storage.yaml
COPY --chown=appuser:appuser storage/handlers/ /app/handlers/
# The bridge server relays upload/download channel requests.
COPY --chown=appuser:appuser storage/bridge_server.py /app/bridge_server.py
# The retention watchdog applies retention policies periodically.
COPY --chown=appuser:appuser storage/retention_watchdog.py /app/retention_watchdog.py
# Storage entrypoint launches bridge server + watchdog, then execs node-daemon.
COPY --chown=appuser:appuser storage/docker-entrypoint-storage.sh /app/docker-entrypoint-storage.sh

ENV NODE_NAME=storage-node \
    NODE_PROFILE=storage \
    NODE_ROLE=service \
    BRIDGE_PORT=8791

USER root
RUN mkdir -p "${STORAGE_PATH}" && chown -R appuser:appuser "${STORAGE_PATH}"
USER appuser

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD ["python3", "/app/healthcheck.py"]

ENTRYPOINT ["/usr/bin/tini", "--", "/app/docker-entrypoint-storage.sh"]
CMD ["node-daemon"]