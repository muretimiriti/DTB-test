#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

cd "$PROJECT_ROOT"

[[ -f ".env" ]] || die ".env not found. Run ./scripts/setup.sh first"

if command -v docker-compose &>/dev/null; then
  COMPOSE="docker-compose"
elif docker compose version &>/dev/null 2>&1; then
  COMPOSE="docker compose"
else
  die "docker-compose or docker compose plugin required"
fi

CMD="${1:-up}"

case "$CMD" in
  up)
    info "Starting banking stack..."
    $COMPOSE --env-file .env up -d --build
    echo ""
    info "Waiting for services to be healthy..."
    sleep 5
    bash "$SCRIPT_DIR/health-check.sh"
    success "Stack is running"
    echo ""
    echo "  Frontend: http://localhost:${FRONTEND_PORT:-3000}"
    echo "  Backend:  http://localhost:5000/health  (internal)"
    ;;
  down)
    warn "Stopping banking stack..."
    $COMPOSE down
    success "Stack stopped"
    ;;
  restart)
    info "Restarting banking stack..."
    $COMPOSE restart
    success "Stack restarted"
    ;;
  logs)
    SERVICE="${2:-}"
    $COMPOSE logs -f --tail=100 $SERVICE
    ;;
  status)
    $COMPOSE ps
    ;;
  clean)
    warn "This will remove containers AND volumes (all data will be lost)!"
    read -r -p "Are you sure? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      $COMPOSE down -v --remove-orphans
      success "Stack and volumes removed"
    else
      info "Cancelled"
    fi
    ;;
  *)
    echo "Usage: $0 [up|down|restart|logs [service]|status|clean]"
    exit 1
    ;;
esac
