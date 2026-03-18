#!/usr/bin/env bash
# Usage: ./scripts/teardown.sh [OPTIONS]
#
# Master teardown — removes the full DTB Banking Portal stack in reverse order:
#   6. Observability    Prometheus, Grafana, Loki, OTel
#   5. ArgoCD           Application, GitOps sync, Image Updater
#   4. Tekton           Pipelines, tasks, triggers, PVCs, RBAC
#   3. Security         Kyverno policies, NetworkPolicies, Cosign, ESO, OPA
#   2. Credentials      Vault KV paths, k8s secrets
#   1. Compose          Docker Compose containers, volumes, networks
#
# Each stage is independent — use --skip-* flags to skip any you want to keep.
# By default the cluster itself (minikube) is NOT deleted; use --delete-cluster.
#
# Options:
#   --skip-observability  Skip stage 6 teardown
#   --skip-argocd         Skip stage 5 teardown
#   --skip-tekton         Skip stage 4 teardown
#   --skip-security       Skip stage 3 teardown
#   --skip-credentials    Skip stage 2 teardown
#   --skip-compose        Skip stage 1 teardown
#
#   --uninstall-tekton    Pass --uninstall-tekton to teardown-tekton.sh
#   --uninstall-argocd    Pass --uninstall-argocd to teardown-argocd.sh
#   --uninstall-kyverno   Pass --uninstall-kyverno to teardown-security.sh
#   --uninstall-eso       Pass --uninstall-eso to teardown-security.sh
#   --remove-images       Pass --remove-images to teardown-compose.sh
#   --delete-cluster      Run: minikube delete (destroys the entire cluster)
#   --nuke                Full wipe: all stages + uninstall everything + delete cluster
#
#   --dry-run             Pass --dry-run to every child script (no changes)
#   -h|--help             Show this help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}[teardown]${NC} $*"; }
success() { echo -e "${GREEN}[teardown]${NC} $*"; }
warn()    { echo -e "${YELLOW}[teardown]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${MAGENTA}════════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${MAGENTA}  $*${NC}"; \
            echo -e "${BOLD}${MAGENTA}════════════════════════════════════════${NC}"; }
die()     { echo -e "${RED}[teardown] FATAL:${NC} $*" >&2; exit 1; }

SKIP_OBSERVABILITY=false
SKIP_ARGOCD=false
SKIP_TEKTON=false
SKIP_SECURITY=false
SKIP_CREDENTIALS=false
SKIP_COMPOSE=false

UNINSTALL_TEKTON=false
UNINSTALL_ARGOCD=false
UNINSTALL_KYVERNO=false
UNINSTALL_ESO=false
REMOVE_IMAGES=false
DELETE_CLUSTER=false
DRY_RUN=false

LOG_DIR="${ROOT_DIR}/logs/teardown"
START_TIME=$(date +%s)

# Stage result tracking
STAGE_OBSERVABILITY=false
STAGE_ARGOCD=false
STAGE_TEKTON=false
STAGE_SECURITY=false
STAGE_CREDENTIALS=false
STAGE_COMPOSE=false

usage() {
  sed -n '/^# Usage:/,/^set -/p' "$0" | grep '^#' | sed 's/^# \?//'
}

elapsed() {
  local now; now=$(date +%s)
  local secs=$(( now - START_TIME ))
  printf '%dm%02ds' $(( secs / 60 )) $(( secs % 60 ))
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-observability) SKIP_OBSERVABILITY=true ;;
      --skip-argocd)        SKIP_ARGOCD=true ;;
      --skip-tekton)        SKIP_TEKTON=true ;;
      --skip-security)      SKIP_SECURITY=true ;;
      --skip-credentials)   SKIP_CREDENTIALS=true ;;
      --skip-compose)       SKIP_COMPOSE=true ;;
      --uninstall-tekton)   UNINSTALL_TEKTON=true ;;
      --uninstall-argocd)   UNINSTALL_ARGOCD=true ;;
      --uninstall-kyverno)  UNINSTALL_KYVERNO=true ;;
      --uninstall-eso)      UNINSTALL_ESO=true ;;
      --remove-images)      REMOVE_IMAGES=true ;;
      --delete-cluster)     DELETE_CLUSTER=true ;;
      --nuke)
        UNINSTALL_TEKTON=true
        UNINSTALL_ARGOCD=true
        UNINSTALL_KYVERNO=true
        UNINSTALL_ESO=true
        REMOVE_IMAGES=true
        DELETE_CLUSTER=true
        ;;
      --dry-run) DRY_RUN=true ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1. Use --help for usage." ;;
    esac
    shift
  done
}

run_stage() {
  local name="$1" label="$2" script="$3"
  shift 3
  local extra_args=("$@")
  local log_file="${LOG_DIR}/${name}.log"

  section "Stage: ${label}"
  log "Script:  ${script#"$ROOT_DIR/"}"
  log "Log:     ${log_file#"$ROOT_DIR/"}"

  $DRY_RUN && extra_args+=("--dry-run")

  local exit_code=0
  if ! bash "$script" "${extra_args[@]}" 2>&1 | tee "$log_file"; then
    exit_code=${PIPESTATUS[0]}
  fi

  if [[ $exit_code -eq 0 ]]; then
    local _var="STAGE_$(echo "$name" | tr '[:lower:]' '[:upper:]')"
    printf -v "$_var" "true"
    success "${label}: DONE (elapsed: $(elapsed))"
  else
    warn "${label}: exited with code ${exit_code} — continuing teardown"
    warn "Full log: ${log_file}"
    tail -10 "$log_file" >&2 || true
  fi
}

print_final_summary() {
  section "Teardown Complete"
  echo ""
  echo -e "  ${BOLD}Total time:${NC} $(elapsed)"
  echo ""
  echo -e "  ${BOLD}Stage Results:${NC}"

  declare -A STAGE_MAP=(
    [OBSERVABILITY]="Observability (Prometheus/Grafana/Loki/OTel)"
    [ARGOCD]="ArgoCD"
    [TEKTON]="Tekton CI/CD"
    [SECURITY]="Security (Kyverno/NetworkPolicies/Cosign/OPA)"
    [CREDENTIALS]="Credentials (Vault/Secrets)"
    [COMPOSE]="Docker Compose"
  )

  for stage_name in OBSERVABILITY ARGOCD TEKTON SECURITY CREDENTIALS COMPOSE; do
    local var="STAGE_${stage_name}"
    local label="${STAGE_MAP[$stage_name]}"
    if [[ "${!var}" == "true" ]]; then
      echo -e "    ${GREEN}✓${NC} ${label}"
    else
      echo -e "    ${YELLOW}⊘${NC} ${label} (skipped)"
    fi
  done

  echo ""
  if $DELETE_CLUSTER; then
    echo -e "  ${GREEN}✓${NC} Minikube cluster deleted"
  else
    echo -e "  ${CYAN}ℹ${NC}  Cluster still running — to delete: ${CYAN}minikube delete${NC}"
  fi
  echo ""
  echo -e "  Stage logs: ${LOG_DIR#"$ROOT_DIR/"}"
  echo ""
  echo -e "${GREEN}${BOLD}DTB Banking Portal stack torn down.${NC}"
  echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  mkdir -p "$LOG_DIR"

  echo ""
  echo -e "${BOLD}${RED}DTB Banking Portal — Master Teardown${NC}"
  echo -e "${BOLD}${RED}=====================================  ${NC}"
  $DRY_RUN && echo -e "${YELLOW}DRY RUN MODE — no changes will be made${NC}"
  echo ""
  echo -e "  Logs directory: ${LOG_DIR#"$ROOT_DIR/"}"
  echo -e "  Started:        $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""

  # Confirm before destructive teardown (unless dry-run or fully scripted)
  if ! $DRY_RUN && [[ -t 0 ]]; then
    echo -e "  ${YELLOW}WARNING: This will tear down the following components:${NC}"
    $SKIP_OBSERVABILITY || echo -e "    - Observability (Prometheus, Grafana, Loki, OTel)"
    $SKIP_ARGOCD        || echo -e "    - ArgoCD (Application + GitOps sync)"
    $SKIP_TEKTON        || echo -e "    - Tekton (Pipelines, Tasks, Triggers)"
    $SKIP_SECURITY      || echo -e "    - Security (Kyverno, NetworkPolicies, Cosign, OPA)"
    $SKIP_CREDENTIALS   || echo -e "    - Credentials (Vault secrets, k8s secrets)"
    $SKIP_COMPOSE       || echo -e "    - Docker Compose (containers, volumes, networks)"
    $DELETE_CLUSTER     && echo -e "    - ${RED}Minikube cluster (IRREVERSIBLE)${NC}"
    echo ""
    read -rp "  Proceed? [y/N]: " confirm
    [[ "${confirm,,}" =~ ^y(es)?$ ]] || { log "Teardown cancelled."; exit 0; }
    echo ""
  fi

  # ── Stage 6: Observability (tear down first — depends on nothing) ─────────
  if ! $SKIP_OBSERVABILITY; then
    local obs_args=()
    run_stage "observability" "Observability" "${K8S_DIR}/teardown-observability.sh" "${obs_args[@]}"
  else
    log "Stage 6 (observability): skipped"
  fi

  # ── Stage 5: ArgoCD ───────────────────────────────────────────────────────
  if ! $SKIP_ARGOCD; then
    local argocd_args=()
    $UNINSTALL_ARGOCD && argocd_args+=("--uninstall-argocd")
    run_stage "argocd" "ArgoCD" "${K8S_DIR}/teardown-argocd.sh" "${argocd_args[@]}"
  else
    log "Stage 5 (argocd): skipped"
  fi

  # ── Stage 4: Tekton ───────────────────────────────────────────────────────
  if ! $SKIP_TEKTON; then
    local tekton_args=()
    $UNINSTALL_TEKTON && tekton_args+=("--uninstall-tekton")
    run_stage "tekton" "Tekton CI/CD" "${K8S_DIR}/teardown-tekton.sh" "${tekton_args[@]}"
  else
    log "Stage 4 (tekton): skipped"
  fi

  # ── Stage 3: Security ─────────────────────────────────────────────────────
  if ! $SKIP_SECURITY; then
    local sec_args=()
    $UNINSTALL_KYVERNO && sec_args+=("--uninstall-kyverno")
    $UNINSTALL_ESO     && sec_args+=("--uninstall-eso")
    run_stage "security" "Security" "${K8S_DIR}/teardown-security.sh" "${sec_args[@]}"
  else
    log "Stage 3 (security): skipped"
  fi

  # ── Stage 2: Credentials ──────────────────────────────────────────────────
  if ! $SKIP_CREDENTIALS; then
    run_stage "credentials" "Credentials" "${K8S_DIR}/teardown-credentials.sh"
  else
    log "Stage 2 (credentials): skipped"
  fi

  # ── Stage 1: Docker Compose ───────────────────────────────────────────────
  if ! $SKIP_COMPOSE; then
    local compose_args=()
    $REMOVE_IMAGES && compose_args+=("--remove-images")
    run_stage "compose" "Docker Compose" "${SCRIPT_DIR}/teardown-compose.sh" "${compose_args[@]}"
  else
    log "Stage 1 (compose): skipped"
  fi

  # ── Minikube cluster delete (optional / --nuke) ───────────────────────────
  if $DELETE_CLUSTER; then
    section "Delete Minikube Cluster"
    warn "Deleting minikube cluster — ALL cluster data will be lost"
    if $DRY_RUN; then
      echo "  DRY RUN: minikube delete"
    else
      if command -v minikube &>/dev/null; then
        minikube delete && success "Minikube cluster deleted" || warn "minikube delete returned non-zero"
      else
        warn "minikube not found on PATH — skipping cluster deletion"
      fi
    fi
  fi

  print_final_summary
}

main "$@"
