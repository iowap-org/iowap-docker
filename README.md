# IOWAP Docker
#
# Central repository for all IOWAP Docker images. Each subdirectory builds
# one image. Build context is always the repo root so COPY paths mirror
# the directory structure.
#
# ## Images
#
# | Image               | Directory   | FROM                  | Build command                                              |
# |---------------------|-------------|-----------------------|------------------------------------------------------------|
# | `iowap-node-base`   | `base/`     | `python:3.11-slim`    | `docker build -t iowap-node-base -f base/Dockerfile .`     |
# | `iowap-storage`     | `storage/`  | `iowap-node-base`     | `docker build -t iowap-storage -f storage/Dockerfile .`    |
# | `iowap-server`      | `server/`   | `python:3.11-slim`    | `docker build -t iowap-server -f server/Dockerfile .`      |
#
# ## Build order
#
# ```bash
# # 1. Base image (node framework + Python runtime)
# docker build -t iowap-node-base -f base/Dockerfile .
#
# # 2. Service images
# docker build -t iowap-storage -f storage/Dockerfile .
# docker build -t iowap-server -f server/Dockerfile .
# ```
#
# ## Quick start (server)
#
# ```bash
# docker compose -f server/docker-compose.yml up -d
# ```
#
# Set `RELAY_MASTER_SEED` in `.env` to pin the admin seed. Default DB is
# SQLite (persisted in the `relay-data` volume). For PostgreSQL, add
# `--profile postgres`.
#
# ## Quick start (storage node)
#
# Build the base image first, then:
#
# ```bash
# RELAY_URL=http://192.168.1.100:8788 docker compose -f storage/docker-compose.yml up -d
# ```
#
# Approve the node on the relay dashboard. Bind-mount your NAS path:
#
# ```bash
# STORAGE_DIR=/mnt/nas/storage docker compose -f storage/docker-compose.yml up -d
# ```
#
# ## Build args
#
# Both base and server images have `IOWAP_NODE_REF` / `IOWAP_SERVER_REF`
# build args to pin a specific Git tag/branch/commit — default is `main`:
#
# ```bash
# docker build -t iowap-server:2.3.1 --build-arg IOWAP_SERVER_REF=v2.3.1 -f server/Dockerfile .
# ```
#
# ## Source repositories
#
# - [iowap-server](https://github.com/iowap-org/iowap-server) — relay server code
# - [iowap-node](https://github.com/iowap-org/iowap-node) — node framework (daemon, CLI, handler runner)
# - [iowap-storage](https://github.com/iowap-org/iowap-storage) — storage node handlers
# - [iowap-docs](https://github.com/iowap-org/iowap-docs) — full documentation