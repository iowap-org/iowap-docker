# syntax=docker/dockerfile:1
# IOWAP — Universal node image (T-020/T-037).
#
# Builds ``FROM iowap-node-base`` and adds the universal-node flavour layer:
# the container-HTTP MCP surface (iowap-node-mcp — Streamable HTTP /mcp +
# Bearer, T-037) on top of the plain node stack. The base image keeps
# serving the other service images (storage/, etc.) unchanged; the universal
# node is the operator-facing flavour for agents on the same host.
#
# The mcp package code is baked from the SOURCE REPO, not PyPI (owner call
# 2026-11-25): `universal-node/mcp/` is a GITLINK (submodule) onto
# iowap-org/iowap-universal-node — the authoritative source, no plain
# copies. The submodule holds the repo root, so the package directory inside
# it is `mcp/` (→ universal-node/mcp/mcp/), which is what gets COPY'd to
# /app/mcp and pip-installed. The version stays maintained in that
# pyproject.toml (0.1.0 / T-037); only the PyPI release is dropped.
# Requires the submodule to be checked out before the build:
#
#   git submodule update --init universal-node/mcp    # local
#   (CI: actions/checkout with submodules: recursive)
#
# iowap-node-mcp declares iowap-client-mcp (>= 0.2.0, stdio-only since the
# T-037 split) as its dependency, so pip still pulls/upgrades that wheel
# (plus the mcp SDK and uvicorn) from PyPI as part of this install. Since
# the T-040 slim-down the base image no longer starts or ships any MCP —
# the universal entrypoint (docker-entrypoint-universal.sh) starts
# `iowap-node-mcp --http` on 7781 and is the only MCP surface in this image.
#
# Build context is the repo root, Dockerfile path is universal-node/Dockerfile:
#
#   docker build -t iowap-universal-node -f universal-node/Dockerfile .

ARG NODE_BASE_IMAGE=iowap-node-base:latest
FROM ${NODE_BASE_IMAGE}

# The universal-node flavour keeps the base's node stack untouched and adds
# the streaming-HTTP MCP package from the universal-node repo (gitlink, no
# PyPI for this package). system-wide as root, like the base image's own
# install — pip upgrades the base's iowap-client-mcp[mcp] 0.1.x to 0.2.0 in
# the same site-packages while wiring the just-copied iowap-node-mcp in.
COPY --chown=appuser:appuser universal-node/mcp/mcp/ /app/mcp/
USER root
RUN pip install --no-cache-dir /app/mcp
# T-050: pre-create the agent-token store dir with appuser ownership BEFORE
# switching users. A first-mount named volume (iowap-agent-tokens →
# /data/agents) inherits this image-side content + ownership, so fresh
# installs are appuser-writable from the bake. Volumes that pre-date this
# change keep their (root) ownership — the store resolver's write probe +
# relay-dir fallback (node 2.3.68 / node-mcp 0.1.3) covers those at runtime.
RUN mkdir -p /data/agents && chown -R appuser:appuser /data/agents
USER appuser

# Universal-node entrypoint: derived from base/docker-entrypoint.sh with the
# MCP surface swapped to iowap-node-mcp (starts the daemon AND the bearer-
# gated MCP process on 7781).
COPY --chown=appuser:appuser universal-node/docker-entrypoint-universal.sh /app/docker-entrypoint-universal.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD ["python3", "/app/healthcheck.py"]

ENTRYPOINT ["/usr/bin/tini", "--", "/app/docker-entrypoint-universal.sh"]
CMD ["iowap-daemon"]
