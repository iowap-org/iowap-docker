# syntax=docker/dockerfile:1
# IOWAP — Node base image.
#
# A reusable base image carrying the installed node stack (node-cli,
# node-daemon, relay_client, node_config, handler_runner) installed from
# the iowap-node package on GitHub. Concrete service images (storage/,
# etc.) build ``FROM iowap-node-base`` and only add their capability
# profile + handlers — no Python install step.
#
# The entrypoint translates environment variables (RELAY_URL, NODE_NAME,
# NODE_PROFILE) into ``relay_config.json`` + ``node.yaml`` and registers
# the node on first start; then execs ``node-daemon`` (SSE, event-driven).

ARG IOWAP_NODE_REF=main

FROM python:3.11-slim

# tini as PID 1 so signals (SIGTERM/SIGINT) reach node-daemon cleanly on stop.
RUN apt-get update && apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install the node stack from the iowap-node GitHub package.
# Override IOWAP_NODE_REF to pin a specific tag/branch/commit.
ARG IOWAP_NODE_REF=main
RUN pip install --no-cache-dir \
    "iowap-node @ git+https://github.com/iowap-org/iowap-node.git@${IOWAP_NODE_REF}"

# --- appuser ---------------------------------------------------------------
# Non-root runtime user. PUID/PGID are overridable so a NAS operator can map
# the container's file ownership to their host user for bind-mounted volumes.
ARG PUID=1000
ARG PGID=1000
RUN groupadd -g ${PGID} appuser \
    && useradd -m -u ${PUID} -g appuser appuser \
    && install -d -o appuser -g appuser /app /home/appuser/.relay

# The node resolves ~/.relay via Path.home(); ensure HOME is the appuser's.
ENV HOME=/home/appuser
ENV PATH="/home/appuser/.local/bin:${PATH}"
ENV PYTHONUNBUFFERED=1

USER appuser

# Entrypoint translates env → relay_config.json + node.yaml, registers the
# node on first start, then execs node-daemon.
COPY --chown=appuser:appuser base/docker-entrypoint.sh /app/docker-entrypoint.sh
# Healthcheck script (reads the daemon status file).
COPY --chown=appuser:appuser base/healthcheck.py /app/healthcheck.py

ENTRYPOINT ["/usr/bin/tini", "--", "/app/docker-entrypoint.sh"]

# The base image does not listen on any port — the node only connects to the
# relay via SSE + HTTP. Any bridge-route upstream is served by the concrete
# service image derived from this base (e.g. storage/).
CMD ["node-daemon"]