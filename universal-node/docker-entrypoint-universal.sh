#!/usr/bin/env bash
# IOWAP — universal-node entrypoint (T-020/T-037).
#
# Derived 1:1 from base/docker-entrypoint.sh (T-119) with the MCP surface
# swapped to iowap-node-mcp (T-037): the universal-node flavour layers the
# container-HTTP MCP on top of the plain node stack, while the base image
# keeps serving the other service images unchanged. This derivative exists
# because the base entrypoint still calls the stdio-only local package
# (`iowap-mcp --http`) — iowap-client-mcp >= 0.2.0 dropped --http, so the
# universal node starts `iowap-node-mcp --http` instead.
#
# Translates environment variables into the files the node stack reads from
# ~/.relay (relay_config.json, node.yaml, iowap-agent.json|ai-relay-agent.json, token) and
# then execs the iowap-daemon (SSE, event-driven).
#
# Environment variables (all optional unless noted):
#   RELAY_URL          — relay base URL, e.g. https://relay.example.com (optional since T-011 blank-start — daemon idles until configured)
#   NODE_NAME          — human-friendly node name (default: container hostname)
#   NODE_PROFILE       — profile name to publish from /app/profiles/ (optional)
#   NODE_ROLE          — node role: "worker" (default) or "service"
#   NODE_ENDPOINT      — upstream endpoint for bridge-route upstream URLs
#   NODE_REGISTRATION_SECRET — pre-created registration secret (rs_...)
#   RELAY_HEARTBEAT_INTERVAL — overrides heartbeat_interval (seconds)
#   RELAY_CLAIM_INTERVAL     — overrides claim_interval (seconds)
#   RELAY_REQUEST_TIMEOUT    — overrides request_timeout (seconds)
#   RELAY_LOG_LEVEL          — log level (DEBUG/INFO/WARNING/ERROR)
#   IOWAP_MCP_BEARER   — Bearer token for the node's HTTP MCP endpoint.
#                        Non-empty → entrypoint starts `iowap-node-mcp --http`
#                        on port 7781 in the background (T-020/T-037); empty →
#                        the MCP server stays off.
#
# Idempotent: reuses existing meta + token on subsequent starts.

set -euo pipefail

RELAY_DIR="${HOME}/.relay"
CONFIG_JSON="${RELAY_DIR}/relay_config.json"
# T-148a: prefer the post-migration file names (iowap-agent.*); fall back
# to the legacy ai-relay-agent.* names for volumes created before the
# rebranding. The daemon migrates to iowap-agent.* on first token rotation
# and removes the legacy files, so the entrypoint must accept both —
# otherwise a healthy node re-registers on restart and hits 409 (node_name
# already taken in the relay DB).
META_JSON="${RELAY_DIR}/iowap-agent.json"
TOKEN_FILE="${RELAY_DIR}/iowap-agent.token"
if [ ! -f "${META_JSON}" ] && [ -f "${RELAY_DIR}/ai-relay-agent.json" ]; then
    META_JSON="${RELAY_DIR}/ai-relay-agent.json"
fi
if [ ! -f "${TOKEN_FILE}" ] && [ -f "${RELAY_DIR}/ai-relay-agent.token" ]; then
    TOKEN_FILE="${RELAY_DIR}/ai-relay-agent.token"
fi
NODE_YAML="${RELAY_DIR}/node.yaml"

mkdir -p "${RELAY_DIR}"

# --- RELAY_URL: explicit env, else mDNS discovery -------------------------
# T-011 blank-start: if RELAY_URL is unset and mDNS finds nothing, the daemon
# still starts and idles until configuration exists (register via
# `iowap-cli node register` inside the container). Missing RELAY_URL is NOT
# fatal anymore — the pre-T-011 hard exit crashed container loops.
BLANK_START=0
if [ -z "${RELAY_URL:-}" ]; then
    echo "[entrypoint] RELAY_URL not set — attempting mDNS discovery..."
    DISCOVERED=$(python3 - <<'PY'
import sys
try:
    from nodes.common.relay_client import _discover_relay_mdns
    url = _discover_relay_mdns(timeout=3.0)
    if url:
        print(url)
except Exception as exc:
    print(f"mDNS discovery failed: {exc}", file=sys.stderr)
PY
    )
    if [ -n "${DISCOVERED}" ]; then
        RELAY_URL="${DISCOVERED}"
        export RELAY_URL
        echo "[entrypoint] mDNS discovered relay at ${RELAY_URL}"
    else
        echo "[entrypoint] RELAY_URL not set and mDNS discovery found no relay — blank-start idle (T-011): daemon waits for configuration."
        BLANK_START=1
    fi
fi

BASE_URL="${RELAY_URL:-}"; BASE_URL="${BASE_URL%/}"
NODE_NAME="${NODE_NAME:-$(hostname 2>/dev/null || echo node)}"
NODE_ROLE="${NODE_ROLE:-worker}"

# --- relay_config.json ----------------------------------------------------
if [ "${BLANK_START}" -eq 1 ]; then
    echo "[entrypoint] blank-start: skipping relay_config.json + registration until configured."
fi
if [ "${BLANK_START}" -eq 0 ]; then
cat > "${CONFIG_JSON}" <<EOF
{
  "base_url": "${BASE_URL}",
  "heartbeat_interval": ${RELAY_HEARTBEAT_INTERVAL:-8},
  "claim_interval": ${RELAY_CLAIM_INTERVAL:-5},
  "status_interval": 7200,
  "rt_refresh_before_seconds": 86400,
  "rs_refresh_before_seconds": 3600,
  "request_timeout": ${RELAY_REQUEST_TIMEOUT:-10},
  "task_timeout": 600,
  "log_level": "${RELAY_LOG_LEVEL:-INFO}"
}
EOF
echo "[entrypoint] relay_config.json written (base_url=${BASE_URL})"
fi

# --- node.yaml -------------------------------------------------------------
if [ ! -f "${NODE_YAML}" ]; then
    cat > "${NODE_YAML}" <<EOF
# Auto-generated by iowap-docker/base entrypoint.
node_name: ${NODE_NAME}
EOF
    echo "[entrypoint] node.yaml seeded (node_name=${NODE_NAME})"
fi

if [ -n "${NODE_PROFILE:-}" ]; then
    IMAGE_PROFILES_DIR="/app/profiles"
    PROFILE_FILE=""
    if [ -f "${IMAGE_PROFILES_DIR}/${NODE_PROFILE}" ]; then
        PROFILE_FILE="${IMAGE_PROFILES_DIR}/${NODE_PROFILE}"
    elif [ -f "${IMAGE_PROFILES_DIR}/${NODE_PROFILE}.yaml" ]; then
        PROFILE_FILE="${IMAGE_PROFILES_DIR}/${NODE_PROFILE}.yaml"
    elif [ -f "${IMAGE_PROFILES_DIR}/${NODE_PROFILE}.yml" ]; then
        PROFILE_FILE="${IMAGE_PROFILES_DIR}/${NODE_PROFILE}.yml"
    else
        echo "[entrypoint] ERROR: NODE_PROFILE='${NODE_PROFILE}' not found in ${IMAGE_PROFILES_DIR}" >&2
        exit 1
    fi
    cp "${PROFILE_FILE}" "${NODE_YAML}"
    echo "[entrypoint] node.yaml published from profile '${NODE_PROFILE}' (${PROFILE_FILE})"
fi

# --- first-start registration ---------------------------------------------
if [ "${BLANK_START}" -eq 1 ]; then
    echo "[entrypoint] blank-start: skipping registration (no relay configured yet)."
elif [ ! -f "${META_JSON}" ]; then
    echo "[entrypoint] no metadata found — registering node '${NODE_NAME}' with relay"

    REGISTER_PAYLOAD=$(python3 - <<'PY'
import json, os, yaml
caps = []
node_yaml = os.path.expanduser("~/.relay/node.yaml")
try:
    with open(node_yaml) as f:
        prof = yaml.safe_load(f) or {}
    caps = prof.get("capabilities", []) or []
except Exception:
    pass
clean = []
for c in caps:
    if isinstance(c, dict) and "name" in c:
        clean.append({"name": c["name"], "version": str(c.get("version", "1.0.0"))})
print(json.dumps({
    "node_name": os.environ.get("NODE_NAME", "node"),
    "endpoint": os.environ.get("NODE_ENDPOINT") or None,
    "capabilities": clean,
    "role": os.environ.get("NODE_ROLE", "worker"),
}))
PY
    )
    REGISTER_PAYLOAD_FILE="${RELAY_DIR}/register-payload.json"
    printf '%s' "${REGISTER_PAYLOAD}" > "${REGISTER_PAYLOAD_FILE}"
    python3 - <<PY
import json, os, sys
import httpx
base_url = os.environ["RELAY_URL"].rstrip("/")
with open(os.path.expanduser("~/.relay/register-payload.json")) as f:
    payload = json.load(f)
headers = {}
secret = os.environ.get("NODE_REGISTRATION_SECRET")
if secret:
    headers["X-Registration-Secret"] = secret
try:
    r = httpx.post(f"{base_url}/relay/v2/auth/register", json=payload, headers=headers, timeout=30)
    r.raise_for_status()
except httpx.HTTPError as exc:
    print(f"[entrypoint] ERROR: registration failed: {exc}", file=sys.stderr)
    sys.exit(1)
data = r.json()
meta = {
    "base_url": base_url,
    "node_id": data["node_id"],
    "node_name": data.get("node_name", payload["node_name"]),
    "registration_secret": data.get("registration_secret"),
    "capabilities": payload["capabilities"],
}
rel = os.path.expanduser("~/.relay")
import pathlib
pathlib.Path(rel).mkdir(parents=True, exist_ok=True)
pathlib.Path(rel, "iowap-agent.json").write_text(json.dumps(meta, indent=2))
os.chmod(os.path.join(rel, "iowap-agent.json"), 0o600)
token = data.get("token")
if token:
    token_path = pathlib.Path(rel, "iowap-agent.token")
    token_path.write_text(json.dumps({"token": token, "expires_at": None}) + "\n")
    os.chmod(token_path, 0o600)
status = data.get("status", "pending")
print(f"[entrypoint] registered node_id={data['node_id']} status={status}")
if status == "pending":
    print("[entrypoint] node is pending approval — approve it via dashboard or admin API")
PY
    rm -f "${REGISTER_PAYLOAD_FILE}"
else
    echo "[entrypoint] reusing existing metadata (${META_JSON})"
fi

# --- HTTP MCP supervisor (T-020) -------------------------------------------
# The universal-node profile publishes 127.0.0.1:7781 → the in-container HTTP
# MCP endpoint. Start `iowap-node-mcp --http` in the background only when a bearer
# token is configured — without one the endpoint must stay off. The process
# inherits this shell's stdout/stderr (container logs) and IOWAP_MCP_BEARER;
# the PID file (~/.relay/mcp.pid) enables later enable/disable from the node
# dashboard (T-021).
MCP_PID_FILE="${RELAY_DIR}/mcp.pid"
MCP_BEARER_FILE="${RELAY_DIR}/mcp_bearer"
# T-021/T-016d: a manual `docker compose up` carries no IOWAP_MCP_BEARER env —
# restore it from the dashboard's bearer file so the endpoint survives
# container recreates that were not done via the daemon bootstrap.
# T-016e: the FILE is the single source of truth for the running MCP
# process — the dashboard writes and renders it, so a rotated file must
# win over a stale container env (invalid_token desync).
if [ -s "${MCP_BEARER_FILE}" ]; then
    IOWAP_MCP_BEARER="$(tr -d '[:space:]' < "${MCP_BEARER_FILE}")"
    export IOWAP_MCP_BEARER
    echo "[entrypoint] IOWAP_MCP_BEARER from ${MCP_BEARER_FILE} (file wins)"
elif [ -n "${IOWAP_MCP_BEARER:-}" ]; then
    printf '%s\n' "${IOWAP_MCP_BEARER}" > "${MCP_BEARER_FILE}"
    echo "[entrypoint] IOWAP_MCP_BEARER mirrored to ${MCP_BEARER_FILE}"
fi
if [ -n "${IOWAP_MCP_BEARER:-}" ]; then
    echo "[entrypoint] starting iowap-node-mcp --http on port 7781 (bearer set)"
    # --host 0.0.0.0: the process defaults to container-internal loopback, but
    # the compose profile publishes 127.0.0.1:7781 -> container eth0 — a
    # 127.0.0.1 bind inside the container would never receive that traffic.
    # Exposure stays local: the host-side publish is loopback-only.
    nohup iowap-node-mcp --http --host 0.0.0.0 --port 7781 &
    echo $! > "${MCP_PID_FILE}"
    echo "[entrypoint] iowap-node-mcp running (pid $(cat "${MCP_PID_FILE}"), pidfile ${MCP_PID_FILE})"
else
    echo "[entrypoint] MCP disabled (no bearer)"
fi

exec "$@"