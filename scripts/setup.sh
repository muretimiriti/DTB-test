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
cleanup() { local rc=$?; (( rc != 0 )) && error "setup.sh failed (exit $rc)"; exit "$rc"; }
trap cleanup ERR EXIT

check_tool() { command -v "$1" &>/dev/null || die "$1 is required but not installed"; }

info "Checking prerequisites..."
check_tool node
check_tool npm
check_tool docker
command -v docker-compose &>/dev/null || docker compose version &>/dev/null || die "docker-compose or docker compose plugin is required but not installed"

NODE_VER=$(node -e "process.exit(parseInt(process.version.slice(1)) < 18 ? 1 : 0)" 2>/dev/null) || \
  die "Node.js 18+ is required (found $(node -v))"
success "All prerequisites met"

info "Setting up environment file..."
if [[ ! -f "$PROJECT_ROOT/.env" ]]; then
  cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
  if command -v openssl &>/dev/null; then
    JWT_SECRET=$(openssl rand -hex 64)
    sed -i "s|change_me_to_at_least_64_random_characters_use_openssl_rand|${JWT_SECRET}|g" "$PROJECT_ROOT/.env"
    success "Generated JWT_SECRET with openssl"
  else
    warn "openssl not found - please manually set JWT_SECRET in .env"
  fi
  warn ".env created from .env.example - review and update passwords before production use"
else
  info ".env already exists, skipping"
fi

info "Installing backend dependencies..."
cd "$PROJECT_ROOT/backend"
npm install
success "Backend dependencies installed"

info "Installing frontend dependencies..."
cd "$PROJECT_ROOT/frontend"
npm install
success "Frontend dependencies installed"

cd "$PROJECT_ROOT"

echo ""
success "Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Review and update .env (especially passwords)"
echo "  2. Run:  ./scripts/build.sh    to build Docker images"
echo "  3. Run:  ./scripts/deploy.sh   to start the stack"
echo "  4. Run:  ./scripts/test.sh     to run all tests"
