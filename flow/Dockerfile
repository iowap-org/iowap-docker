# syntax=docker/dockerfile:1
# IOWAP — Flow runner service image (dedizierter Flow-Node, T-172).
#
# Builds the iowap-flow package from GitHub and adds its capability
# profile + handlers + entrypoint. Unlike storage/ this is NOT a thin
# layer on iowap-node-base: flow pins its own iowap-node dependency in
# pyproject.toml, so the package install is self-contained (same model
# as server/). The profile/handlers/entrypoint files are NOT in this
# repo — they are cloned from iowap-org/iowap-flow at build time.
#
# Build context is the repo root, Dockerfile path is flow/Dockerfile:
#
#   docker build -t iowap-flow -f flow/Dockerfile .

ARG IOWAP_FLOW_REF=main

FROM python:3.11-slim

# tini as PID 1 + git for the git+ pip installs (setpriv comes from
# util-linux, which is already in the base image).
RUN apt-get update && apt-get install -y --no-install-recommends tini git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install iowap-flow from GitHub. The package's pyproject.toml pins its
# iowap-node dependency, so the whole node stack comes with it.
# Override IOWAP_FLOW_REF to pin a specific tag/branch/commit.
ARG IOWAP_FLOW_REF=main
RUN pip install --no-cache-dir \
    "iowap-flow @ git+https://github.com/iowap-org/iowap-flow.git@${IOWAP_FLOW_REF}"

# Clone the flow repo's runtime assets (profile, handlers, entrypoint) —
# pip's git+ checkout does not leave them in a usable location. Profile
# goes to /app/profiles/, handlers to /app/handlers/ (paths the profile's
# handler: reference expects), entrypoint to /entrypoint.sh as upstream.
RUN git clone --depth 1 --branch ${IOWAP_FLOW_REF} \
        https://github.com/iowap-org/iowap-flow.git /tmp/iowap-flow \
    && mkdir -p /app/profiles /app/handlers \
    && cp /tmp/iowap-flow/profiles/node.yaml /app/profiles/ \
    && cp -r /tmp/iowap-flow/handlers/. /app/handlers/ \
    && cp /tmp/iowap-flow/entrypoint.sh /entrypoint.sh \
    && chmod +x /entrypoint.sh /app/handlers/*.py \
    && rm -rf /tmp/iowap-flow /app/handlers/__pycache__

# --- appuser ---------------------------------------------------------------
# Non-root runtime user. PUID/PGID are overridable so a NAS operator can map
# the container's file ownership to their host user for bind-mounted volumes.
ARG PUID=1000
ARG PGID=1000
RUN groupadd -g ${PGID} appuser \
    && useradd -m -u ${PUID} -g appuser appuser \
    && install -d -o appuser -g appuser /app /home/appuser/.relay

ENV HOME=/home/appuser
ENV PATH="/home/appuser/.local/bin:${PATH}"
ENV PYTHONUNBUFFERED=1

# Entrypoint runs as root (chown of the state volume on first start) and
# drops to appuser itself via setpriv — flow's deploy contract (Plan Task 6,
# Pitfall #21). Do NOT switch to USER appuser here; the entrypoint handles it.
USER root

ENTRYPOINT ["/entrypoint.sh"]
CMD ["node-daemon"]