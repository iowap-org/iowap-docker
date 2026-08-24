# syntax=docker/dockerfile:1
# IOWAP — Server image.
#
# Builds the relay server from the iowap-server package on GitHub.
# Installs the postgres extra so both SQLite (default) and PostgreSQL
# backends are available; the backend is selected at runtime via
# RELAY_DB_TYPE / RELAY_PG_DSN.

ARG IOWAP_SERVER_REF=main

FROM python:3.11-slim

# tini as PID 1 so signals (SIGTERM/SIGINT) reach uvicorn cleanly on stop.
RUN apt-get update && apt-get install -y --no-install-recommends tini git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install iowap-server from GitHub with optional postgres support.
# Override IOWAP_SERVER_REF to pin a specific tag/branch/commit.
ARG IOWAP_SERVER_REF=main
RUN pip install --no-cache-dir \
    "iowap-server[postgres] @ git+https://github.com/iowap-org/iowap-server.git@${IOWAP_SERVER_REF}" \
    "psycopg[binary]>=3.1"

# --- appuser ---------------------------------------------------------------
# Non-root runtime user. PUID/PGID are overridable so a NAS operator can map
# the container's file ownership to their host user for bind-mounted volumes.
ARG PUID=1000
ARG PGID=1000
RUN groupadd -g ${PGID} appuser \
    && useradd -m -u ${PUID} -g appuser appuser \
    && install -d -o appuser -g appuser /app /app/.relay /app/.ssn

ENV HOME=/home/appuser
ENV PATH="/home/appuser/.local/bin:${PATH}"
ENV PYTHONUNBUFFERED=1

USER appuser

# Entrypoint runs DB init + seed init, then execs the server.
COPY --chown=appuser:appuser server/docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh
# Healthcheck script (tries http, then https).
COPY --chown=appuser:appuser server/healthcheck.py /app/healthcheck.py

EXPOSE 8788

ENTRYPOINT ["/usr/bin/tini", "--", "/app/docker-entrypoint.sh"]
CMD ["relay-server", "server"]