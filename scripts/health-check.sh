#!/usr/bin/env bash
# =============================================================================
# health-check.sh - Verify all services are healthy
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✔${NC} $*"; }
fail() { echo -e "  ${RED}✘${NC} $*"; }
info() { echo -e "  ${YELLOW}•${NC} $*"; }

cd "$PROJECT_ROOT"
source .env 2>/dev/null || true

FRONTEND_PORT="${FRONTEND_PORT:-3000}"
MAX_WAIT=60
INTERVAL=5
ALL_HEALTHY=true

wait_for() {
  local name="$1"; local url="$2"
  local elapsed=0
  info "Checking ${name}..."
  while [[ $elapsed -lt $MAX_WAIT ]]; do
    if curl -sf "$url" &>/dev/null; then
      ok "${name} is healthy"
      return 0
    fi
    sleep $INTERVAL
    elapsed=$((elapsed + INTERVAL))
  done
  fail "${name} did not become healthy within ${MAX_WAIT}s"
  ALL_HEALTHY=false
  return 1
}

wait_for_container() {
  local name="$1"; local container="$2"; local path="$3"
  local elapsed=0
  info "Checking ${name}..."
  while [[ $elapsed -lt $MAX_WAIT ]]; do
    if docker exec "$container" wget -qO- "http://127.0.0.1:5000${path}" &>/dev/null; then
      ok "${name} is healthy"
      return 0
    fi
    sleep $INTERVAL
    elapsed=$((elapsed + INTERVAL))
  done
  fail "${name} did not become healthy within ${MAX_WAIT}s"
  ALL_HEALTHY=false
  return 1
}

echo ""
echo "=== Service Health Check ==="
wait_for_container "Backend"  "banking_backend"  "/health" || true
wait_for           "Frontend" "http://localhost:${FRONTEND_PORT}/health" || true

echo ""
echo "=== Container Status ==="
if command -v docker-compose &>/dev/null; then
  docker-compose ps 2>/dev/null || true
elif docker compose version &>/dev/null 2>&1; then
  docker compose ps 2>/dev/null || true
fi

echo ""
if $ALL_HEALTHY; then
  echo -e "${GREEN}All services are healthy${NC}"
else
  echo -e "${RED}One or more services are unhealthy${NC}"
  exit 1
fi
