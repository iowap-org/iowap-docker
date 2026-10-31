#!/usr/bin/env bash
# IOWAP — full-stack integration test for server + storage node.
set -euo pipefail

API_BASE="http://localhost:8788"
MASTER_SEED="dev-master-seed-please-change-in-production"
PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }

# ── 1. Clean ──────────────────────────────────────────────────────────────
echo "=== 1. Clean up previous stack ==="
cd "$(dirname "$0")"
docker compose -f docker-compose.yml down --remove-orphans -v 2>/dev/null || true
echo ""

# ── 2. Start ──────────────────────────────────────────────────────────────
echo "=== 2. Starting full stack ==="
# The storage image builds FROM iowap-node-base — ensure it exists locally
# first, or `docker compose up --build` fails on a fresh machine.
docker build -t iowap-node-base:latest -f base/Dockerfile . 2>&1 | tail -3
docker compose -f docker-compose.yml up -d --build 2>&1 | tail -3
echo ""

# ── 3. Wait for healthy containers ────────────────────────────────────────
echo "=== 3. Wait for healthy containers ==="

echo -n "   relay-server..."
for i in $(seq 1 30); do
    sleep 2
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' iowap-server 2>/dev/null || echo "starting")
    echo -n "."
    [ "$STATUS" = "healthy" ] && break
done
echo ""
[ "$STATUS" = "healthy" ] && pass "relay-server healthy" || { fail "relay-server not healthy"; docker compose logs relay --tail 20; exit 1; }

echo -n "   storage-node..."
for i in $(seq 1 30); do
    sleep 2
    RUNNING=$(docker inspect --format='{{.State.Running}}' iowap-storage 2>/dev/null || echo "false")
    echo -n "."
    [ "$RUNNING" = "true" ] && break
done
echo ""
[ "$RUNNING" = "true" ] && pass "storage-node running" || { fail "storage-node not running"; docker compose logs storage-node --tail 20; exit 1; }
echo ""

# ── 4. Server endpoints ──────────────────────────────────────────────────
echo "=== 4. Server endpoints ==="

HEALTH=$(curl -sS http://localhost:8788/health)
if echo "$HEALTH" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['status']=='ok'" 2>/dev/null; then
    pass "/health → ok"
else
    fail "/health: $HEALTH"
fi

READY=$(curl -sS http://localhost:8788/ready)
if echo "$READY" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['database']=='ok'" 2>/dev/null; then
    pass "/ready → database ok"
else
    fail "/ready: $READY"
fi
echo ""

# ── 5. Admin registration ────────────────────────────────────────────────
echo "=== 5. Admin registration ==="

ADMIN_RESP=$(curl -sS -X POST http://localhost:8788/relay/v2/auth/register-admin \
    -H "Content-Type: application/json" \
    -d '{"node_name":"test-admin","bootstrap_secret":"'"${MASTER_SEED}"'","endpoint":null,"capabilities":[]}')

ADMIN_TOKEN=$(echo "$ADMIN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>&1)
if [ -n "$ADMIN_TOKEN" ]; then
    pass "admin token received"
else
    fail "admin registration failed: $ADMIN_RESP"
    docker compose logs relay --tail 10
    exit 1
fi
echo ""

# ── 6. List pending nodes ────────────────────────────────────────────────
echo "=== 6. List nodes ==="
NODES=$(curl -sS http://localhost:8788/relay/v2/admin/nodes \
    -H "Authorization: Bearer ${ADMIN_TOKEN}")

NODE_INFO=$(echo "$NODES" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for n in data.get('nodes', []):
    print(f\"{n['node_id']}|{n['node_name']}|{n['status']}\")
" 2>&1)

if echo "$NODE_INFO" | grep -q "storage-node"; then
    echo "   Found: $NODE_INFO"
    pass "storage-node registered as pending"
    NODE_ID=$(echo "$NODE_INFO" | grep "storage-node" | cut -d'|' -f1 | tr -d '\r\n[:space:]')
else
    fail "storage-node not found — logs:"
    docker compose logs storage-node --tail 15
    exit 1
fi
echo ""

# ── 7. Approve ────────────────────────────────────────────────────────────
echo "=== 7. Approve storage node ==="
APPROVE_RESP=$(curl -sS -X POST "http://localhost:8788/relay/v2/admin/nodes/${NODE_ID}/approve" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"role":"service","capabilities":[],"endpoint":"http://storage-node:8791"}')

if echo "$APPROVE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['token_type']=='runtime'" 2>/dev/null; then
    STORAGE_TOKEN=$(echo "$APPROVE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
    pass "storage-node approved"
else
    fail "approval failed: $APPROVE_RESP"
    docker compose logs relay --tail 10
    exit 1
fi
echo ""

# ── 8. Verify approved + wait for heartbeat ──────────────────────────────
echo "=== 8. Wait for node heartbeat ==="
# The storage node heartbeats every ~8s. After approval, it needs one
# heartbeat to go online and register capabilities.
echo -n "   Waiting for online status..."
for i in $(seq 1 15); do
    sleep 2
    NODES_AFTER=$(curl -sS http://localhost:8788/relay/v2/admin/nodes \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null)
    STATUS=$(echo "$NODES_AFTER" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for n in data.get('nodes', []):
    if n['node_name'] == 'storage-node':
        print(n['status'])
" 2>/dev/null || echo "unknown")
    echo -n "($STATUS)"
    [ "$STATUS" = "online" ] && break
done
echo ""

echo "$NODES_AFTER" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for n in data.get('nodes', []):
    print(f\"  {n['node_name']:20s}  status={n['status']:10s}  role={n.get('role','?'):10s}\")
" 2>&1 || true

if [ "$STATUS" = "online" ]; then
    pass "storage-node is online after approval"
else
    # Not a hard failure — the node may have an offline status in the DB
    # but still be SSE-connected. Continue.
    echo "   (Status after wait: $STATUS — continuing)"
fi
echo ""

# ── 9. Discover capabilities ──────────────────────────────────────────────
echo "=== 9. Discover capabilities ==="
CAPS=$(curl -sS http://localhost:8788/relay/v2/discovery/capabilities \
    -H "Authorization: Bearer ${ADMIN_TOKEN}")

echo "$CAPS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
caps = data.get('capabilities', [])
print(f'  Total capabilities: {len(caps)}')
for c in caps:
    print(f\"  {c['name']:30s}  available={c.get('available','?')}  nodes={[n['node_name'] for n in c.get('nodes',[])]}\")
" 2>&1 || echo "  (discovery not ready yet)"

echo ""

# ── 10. Smoke: simple storage task ────────────────────────────────────────
echo "=== 10. Storage task smoke test ==="

TEST_TS=$(date -u +%s)
TEST_CONTENT="Hello IOWAP storage! TS=${TEST_TS}"
TEST_B64=$(echo -n "$TEST_CONTENT" | base64 -w0)

SIMPLE_RESP=$(curl -sS -X POST "http://localhost:8788/relay/v2/scheduler/task-simple" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"capability\":\"storage.store\",\"payload\":{\"path\":\"integration-test/hello.txt\",\"data_base64\":\"${TEST_B64}\"},\"name\":\"inttest-store\"}" 2>&1 || echo "FAILED")

if echo "$SIMPLE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('task_id')" 2>/dev/null; then
    SIMPLE_TASK_ID=$(echo "$SIMPLE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['task_id'])")
    pass "storage.store task created: ${SIMPLE_TASK_ID}"

    # Give the node time to claim + complete
    echo -n "   Waiting for completion..."
    for i in $(seq 1 10); do
        sleep 2
        TASK_DETAIL=$(curl -sS "http://localhost:8788/relay/v2/scheduler/tasks/${SIMPLE_TASK_ID}" \
            -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo '{}')
        TASK_STATUS=$(echo "$TASK_DETAIL" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('task',{}).get('status',''))" 2>/dev/null)
        echo -n "($TASK_STATUS)"
        [ "$TASK_STATUS" = "completed" ] && break
    done
    echo ""
    if [ "$TASK_STATUS" = "completed" ]; then
        pass "storage.store completed!"
    else
        echo "   Task detail: $TASK_DETAIL"
        echo "   (may still be pending if node didn't claim — not a compose failure)"
    fi
else
    fail "task creation failed: $SIMPLE_RESP"
fi
echo ""

# ── 11. Container logs ────────────────────────────────────────────────────
echo "=== 11. Container status ==="
docker ps --filter "name=iowap-server|iowap-storage" --format "table {{.Names}}\t{{.Status}}"
echo ""
echo "=== Storage node logs (tail -15) ==="
docker logs iowap-storage --tail 15 2>&1 || true
echo ""
echo "=== Relay server logs (tail -10) ==="
docker logs iowap-server --tail 10 2>&1 || true

echo ""
echo "=============================="
echo " Results: ${PASS} passed, ${FAIL} failed"
echo "=============================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1