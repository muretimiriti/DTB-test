#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

SUITE="${1:-all}"
FAILED=0

run_backend_tests() {
  local suite="$1"
  info "Running backend ${suite} tests..."
  cd "$PROJECT_ROOT/backend"

  if [[ ! -f ".env" ]]; then
    cp .env.example .env 2>/dev/null || true
  fi

  export NODE_ENV=test
  export MONGODB_URI="mongodb://localhost/banking_test_$$"
  export JWT_SECRET="test_secret_for_ci_at_least_32_chars_long_1234"

  case "$suite" in
    unit)        npm run test:unit || FAILED=1 ;;
    integration) npm run test:integration || FAILED=1 ;;
    coverage)    npm run test:coverage || FAILED=1 ;;
    all)         npm test || FAILED=1 ;;
  esac

  cd "$PROJECT_ROOT"
}

run_frontend_tests() {
  info "Running frontend tests..."
  cd "$PROJECT_ROOT/frontend"
  export CI=true
  npm test || FAILED=1
  cd "$PROJECT_ROOT"
}

case "$SUITE" in
  unit)
    run_backend_tests unit
    ;;
  integration)
    run_backend_tests integration
    ;;
  coverage)
    run_backend_tests coverage
    run_frontend_tests
    ;;
  frontend)
    run_frontend_tests
    ;;
  backend)
    run_backend_tests all
    ;;
  all)
    run_backend_tests all
    run_frontend_tests
    ;;
  *)
    echo "Usage: $0 [unit|integration|coverage|frontend|backend|all]"
    exit 1
    ;;
esac

echo ""
if [[ $FAILED -eq 0 ]]; then
  success "All tests passed!"
else
  error "One or more test suites failed"
  exit 1
fi
