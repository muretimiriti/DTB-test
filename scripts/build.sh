#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
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

BUILD_TAG="${1:-latest}"
export BUILD_TAG

info "Building all Docker images (tag: ${BUILD_TAG})..."

if command -v hadolint &>/dev/null; then
  info "Linting Dockerfiles..."
  hadolint backend/Dockerfile frontend/Dockerfile && success "Dockerfile linting passed"
else
  echo "  (hadolint not installed, skipping Dockerfile lint)"
fi

info "Building backend image..."
docker build \
  --no-cache \
  --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --build-arg GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')" \
  -t "banking-backend:${BUILD_TAG}" \
  ./backend
success "Backend image built: banking-backend:${BUILD_TAG}"

info "Building frontend image..."
docker build \
  --no-cache \
  --build-arg REACT_APP_API_URL="" \
  -t "banking-frontend:${BUILD_TAG}" \
  ./frontend
success "Frontend image built: banking-frontend:${BUILD_TAG}"

echo ""
success "All images built successfully"
docker images | grep -E "banking-(backend|frontend)" || true
