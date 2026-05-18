#!/bin/bash
# Usage: bash eks/regression-test.sh
#   BASE auto-detected from the ingress-nginx LoadBalancer after deploy.
#   Override: BASE=http://<your-elb> bash eks/regression-test.sh
set -e

BASE="${BASE:-http://$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)}"
PASS=0
FAIL=0

ok()   { echo "  ✅  $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌  $1"; FAIL=$((FAIL+1)); }

check_status() {
  local label="$1" expected="$2" actual="$3"
  [ "$actual" = "$expected" ] && ok "$label (HTTP $actual)" || fail "$label — expected $expected, got $actual"
}

echo "=== Regression Test — taskmanager-chau-lab (2-node) ==="
echo "    BASE: $BASE"
echo ""

# 1. Health check
echo "[1/11] api-gateway /health"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/health")
check_status "GET /api/health" "200" "$STATUS"

# 2. Register lead user
echo "[2/11] Register lead user"
TS=$(date +%s)
EMAIL="regtest_${TS}@example.com"
BODY="{\"email\":\"${EMAIL}\",\"password\":\"Test1234!\",\"role\":\"lead\",\"full_name\":\"Reg Test\"}"
REGISTER_BODY=$(curl -s -X POST "$BASE/api/users" \
  -H "Content-Type: application/json" -d "$BODY")
REGISTER_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/users" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"regtest2_${TS}@example.com\",\"password\":\"Test1234!\",\"role\":\"lead\",\"full_name\":\"Reg Test 2\"}")
check_status "POST /api/users (register)" "201" "$REGISTER_STATUS"
USER_ID=$(echo "$REGISTER_BODY" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
[ -n "$USER_ID" ] && echo "      User ID: $USER_ID" || fail "Could not extract user ID from registration"

# 3. Login → JWT
echo "[3/11] Login"
LOGIN=$(curl -s -X POST "$BASE/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${EMAIL}\",\"password\":\"Test1234!\"}")
TOKEN=$(echo "$LOGIN" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
[ -n "$TOKEN" ] && ok "POST /api/auth/login → JWT received" || fail "POST /api/auth/login → no token in response: $LOGIN"

# 4. Create task (assignee_id required)
echo "[4/11] Create task"
TASK=$(curl -s -X POST "$BASE/api/tasks" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"title\":\"Regression task\",\"description\":\"auto test\",\"assignee_id\":\"${USER_ID}\"}")
STATUS=$(echo "$TASK" | grep -o '"id":"' | head -1 | grep -c '"id":"' || true)
TASK_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/tasks" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"title\":\"Regression task\",\"description\":\"auto test\",\"assignee_id\":\"${USER_ID}\"}")
check_status "POST /api/tasks" "201" "$TASK_STATUS"

# 5. Create task and capture ID
TASK=$(curl -s -X POST "$BASE/api/tasks" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"title\":\"Task with ID\",\"description\":\"for detail test\",\"assignee_id\":\"${USER_ID}\"}")
TASK_ID=$(echo "$TASK" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
[ -n "$TASK_ID" ] && ok "Task created — ID: $TASK_ID" || fail "Could not extract task ID: $TASK"

# 6. List tasks
echo "[6/11] List tasks"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/tasks" \
  -H "Authorization: Bearer $TOKEN")
check_status "GET /api/tasks" "200" "$STATUS"

# 7. Get task detail
echo "[7/11] Get task detail"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/tasks/$TASK_ID" \
  -H "Authorization: Bearer $TOKEN")
check_status "GET /api/tasks/:id" "200" "$STATUS"

# 8. Status transition TODO → IN_PROGRESS
echo "[8/11] PATCH status TODO → IN_PROGRESS"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH "$BASE/api/tasks/$TASK_ID/status" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"status":"IN_PROGRESS"}')
check_status "PATCH /api/tasks/:id/status (TODO→IN_PROGRESS)" "200" "$STATUS"

# 9. Invalid backward transition (should 400)
echo "[9/11] PATCH invalid backward transition IN_PROGRESS → TODO"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH "$BASE/api/tasks/$TASK_ID/status" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"status":"TODO"}')
check_status "PATCH invalid transition (expect 400)" "400" "$STATUS"

# 10. Add comment
echo "[10/11] Add comment"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/tasks/$TASK_ID/comments" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text":"regression comment"}')
check_status "POST /api/tasks/:id/comments" "201" "$STATUS"

# 11. Frontend returns 200
echo "[11/11] Frontend"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/")
check_status "GET / (frontend)" "200" "$STATUS"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && echo "    ALL TESTS PASSED ✅" || { echo "    FAILURES DETECTED ❌"; exit 1; }
