#!/usr/bin/env bash
# Usage: ./scripts/teardown-compose.sh [OPTIONS]
#
# Tears down the Docker Compose local development stack:
#   - Stops and removes containers
#   - Removes named volumes (mongo_data, mongo_config)
#   - Removes the custom bridge networks
#   - Optionally prunes built images
#
# Options:
#   --remove-images   Also remove the locally built backend/frontend images
#   --dry-run         Print what would be done without executing
#   -h, --help        Show this help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}[compose-teardown]${NC} $*"; }
success() { echo -e "${GREEN}[compose-teardown]${NC} $*"; }
warn()    { echo -e "${YELLOW}[compose-teardown]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${MAGENTA}══ $* ══${NC}"; }
die()     { echo -e "${RED}[compose-teardown] ERROR:${NC} $*" >&2; exit 1; }

REMOVE_IMAGES=false
DRY_RUN=false

usage() {
  sed -n '/^# Usage:/,/^set -/p' "$0" | grep '^#' | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove-images) REMOVE_IMAGES=true ;;
    --dry-run) DRY_RUN=true; warn "DRY RUN — no changes will be made" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1. Use --help for usage." ;;
  esac
  shift
done

run() {
  if $DRY_RUN; then
    echo "  DRY RUN: $*"
  else
    "$@"
  fi
}

cd "$ROOT_DIR"

section "Docker Compose — Stop & Remove Containers + Volumes"

if ! command -v docker &>/dev/null; then
  die "docker not found on PATH"
fi

# Pick the right compose file(s) that are present
COMPOSE_FILES=()
[[ -f "docker-compose.yml" ]]     && COMPOSE_FILES+=("-f" "docker-compose.yml")
[[ -f "docker-compose.dev.yml" ]] && COMPOSE_FILES+=("-f" "docker-compose.dev.yml")

if [[ ${#COMPOSE_FILES[@]} -eq 0 ]]; then
  warn "No docker-compose.yml found in $ROOT_DIR — nothing to tear down"
  exit 0
fi

log "Compose files: ${COMPOSE_FILES[*]}"
log "Stopping and removing containers, networks, and named volumes..."
run docker compose "${COMPOSE_FILES[@]}" down --volumes --remove-orphans 2>/dev/null || \
  run docker-compose "${COMPOSE_FILES[@]}" down --volumes --remove-orphans 2>/dev/null || \
  warn "docker compose down returned non-zero — containers may already be stopped"

success "Containers, networks, and volumes removed"

section "Dangling Volume Cleanup"
if ! $DRY_RUN; then
  # Remove any leftover named volumes specific to this project
  for vol in dtb-tets_mongo_data dtb-tets_mongo_config mongo_data mongo_config; do
    if docker volume inspect "$vol" &>/dev/null 2>&1; then
      log "Removing volume: $vol"
      docker volume rm "$vol" 2>/dev/null && success "Removed volume: $vol" || warn "Could not remove $vol (may be in use)"
    fi
  done
else
  echo "  DRY RUN: docker volume rm dtb-tets_mongo_data dtb-tets_mongo_config"
fi

if $REMOVE_IMAGES; then
  section "Remove Built Images"
  for img in \
      muretimiriti/dtb-project-backend \
      muretimiriti/dtb-project-frontend \
      dtb-tets-backend \
      dtb-tets-frontend; do
    if ! $DRY_RUN; then
      if docker image inspect "$img" &>/dev/null 2>&1; then
        log "Removing image: $img"
        docker rmi "$img" 2>/dev/null && success "Removed: $img" || warn "Could not remove $img"
      fi
      # Remove all tags of the image
      while IFS= read -r tagged; do
        [[ -n "$tagged" ]] || continue
        log "Removing tagged image: $tagged"
        docker rmi "$tagged" 2>/dev/null || true
      done < <(docker images --format '{{.Repository}}:{{.Tag}}' | grep "^${img}:" || true)
    else
      echo "  DRY RUN: docker rmi $img"
    fi
  done
  success "Images removed"
fi

section "Summary"
if ! $DRY_RUN; then
  echo ""
  echo -e "  ${GREEN}✓${NC} Containers stopped and removed"
  echo -e "  ${GREEN}✓${NC} Networks removed"
  echo -e "  ${GREEN}✓${NC} Named volumes (mongo_data, mongo_config) removed"
  $REMOVE_IMAGES && echo -e "  ${GREEN}✓${NC} Built images removed"
  echo ""
  echo -e "  To rebuild and restart: ${CYAN}docker compose up -d --build${NC}"
else
  echo ""
  echo -e "  ${YELLOW}DRY RUN complete — no changes were made${NC}"
fi
