#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}[bootstrap]${NC} $*"; }
success() { echo -e "${GREEN}[bootstrap]${NC} $*"; }
warn()    { echo -e "${YELLOW}[bootstrap]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${MAGENTA}════════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${MAGENTA}  $*${NC}"; \
            echo -e "${BOLD}${MAGENTA}════════════════════════════════════════${NC}"; }
die()     { echo -e "${RED}[bootstrap] FATAL:${NC} $*" >&2; exit 1; }

SKIP_PREREQUISITES=false
SKIP_CREDENTIALS=false
SKIP_SECURITY=false
SKIP_TEKTON=false
SKIP_ARGOCD=false
SKIP_OBSERVABILITY=false
DRY_RUN=false
RESUME_FROM=""
LOG_DIR="${ROOT_DIR}/logs/bootstrap"

STAGE_PREREQUISITES=false
STAGE_CREDENTIALS=false
STAGE_SECURITY=false
STAGE_TEKTON=false
STAGE_ARGOCD=false
STAGE_OBSERVABILITY=false

START_TIME=$(date +%s)

usage() {
  cat <<'USAGE'
Usage: ./scripts/bootstrap.sh [OPTIONS]

Master bootstrap — provisions the full DTB Banking Portal stack end-to-end:
  1. Prerequisites    tools, cluster, namespaces, Helm repos
  2. Credentials      Vault secrets, k8s regcred, git-credentials
  3. Security         Kyverno, Cosign, ESO, Vault policies, OPA, network policies
  4. Tekton           pipelines, tasks, triggers, initial PipelineRun
  5. ArgoCD           GitOps application, 30-min polling, Image Updater
  6. Observability    Prometheus, Grafana, Loki, OTel, dashboards

Each stage runs only after the previous one exits 0.
Logs for each stage are written to logs/bootstrap/.

Options:
  --skip-prerequisites   Skip stage 1
  --skip-credentials     Skip stage 2
  --skip-security        Skip stage 3
  --skip-tekton          Skip stage 4
  --skip-argocd          Skip stage 5
  --skip-observability   Skip stage 6
  --resume-from <stage>  Resume from a named stage (prerequisites|credentials|
                         security|tekton|argocd|observability)
  --dry-run              Pass --dry-run to every child script (no cluster changes)
  -h|--help              Show this help

Examples:
  ./scripts/bootstrap.sh                          # full stack
  ./scripts/bootstrap.sh --skip-prerequisites     # cluster already set up
  ./scripts/bootstrap.sh --resume-from security   # restart from security stage
  ./scripts/bootstrap.sh --dry-run                # preview all steps
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-prerequisites)  SKIP_PREREQUISITES=true ;;
      --skip-credentials)    SKIP_CREDENTIALS=true ;;
      --skip-security)       SKIP_SECURITY=true ;;
      --skip-tekton)         SKIP_TEKTON=true ;;
      --skip-argocd)         SKIP_ARGOCD=true ;;
      --skip-observability)  SKIP_OBSERVABILITY=true ;;
      --resume-from)         shift; RESUME_FROM="$1" ;;
      --dry-run)             DRY_RUN=true ;;
      -h|--help)             usage; exit 0 ;;
      *) die "Unknown option: $1. Use --help for usage." ;;
    esac
    shift
  done

  case "${RESUME_FROM}" in
    prerequisites) ;;
    credentials)   SKIP_PREREQUISITES=true ;;
    security)      SKIP_PREREQUISITES=true; SKIP_CREDENTIALS=true ;;
    tekton)        SKIP_PREREQUISITES=true; SKIP_CREDENTIALS=true; SKIP_SECURITY=true ;;
    argocd)        SKIP_PREREQUISITES=true; SKIP_CREDENTIALS=true; SKIP_SECURITY=true
                   SKIP_TEKTON=true ;;
    observability) SKIP_PREREQUISITES=true; SKIP_CREDENTIALS=true; SKIP_SECURITY=true
                   SKIP_TEKTON=true; SKIP_ARGOCD=true ;;
    "")            ;;
    *)             die "Unknown stage '${RESUME_FROM}'. Valid: prerequisites credentials security tekton argocd observability" ;;
  esac
}

elapsed() {
  local now; now=$(date +%s)
  local secs=$(( now - START_TIME ))
  printf '%dm%02ds' $(( secs / 60 )) $(( secs % 60 ))
}

run_stage() {
  local name="$1" label="$2" script="$3"
  shift 3
  local extra_args=("$@")

  local log_file="${LOG_DIR}/${name}.log"
  local status_file="${LOG_DIR}/${name}.status"

  section "Stage: ${label}"
  log "Script:  ${script#"$ROOT_DIR/"}"
  log "Log:     ${log_file#"$ROOT_DIR/"}"
  log "Started: $(date '+%Y-%m-%d %H:%M:%S')"

  if $DRY_RUN; then
    extra_args+=("--dry-run")
  fi

  local exit_code=0
  if ! bash "$script" "${extra_args[@]}" 2>&1 | tee "$log_file"; then
    exit_code=${PIPESTATUS[0]}
  fi

  if [[ $exit_code -eq 0 ]]; then
    echo "PASS" > "$status_file"
    success "${label}: PASSED (elapsed: $(elapsed))"
    eval "STAGE_$(echo "$name" | tr '[:lower:]' '[:upper:]')=true"
  else
    echo "FAIL" > "$status_file"
    echo -e "${RED}[bootstrap] FAILED:${NC} ${label} exited with code ${exit_code}" >&2
    echo -e "${YELLOW}[bootstrap]${NC} Full log: ${log_file}" >&2
    echo -e "${YELLOW}[bootstrap]${NC} Last 20 lines:" >&2
    tail -20 "$log_file" >&2
    die "${label} failed — fix the errors above then re-run with: --resume-from ${name}"
  fi
}

wait_for_cluster() {
  log "Verifying cluster is reachable before next stage..."
  local attempts=0
  until kubectl cluster-info --request-timeout=5s &>/dev/null; do
    attempts=$(( attempts + 1 ))
    (( attempts > 12 )) && die "Cluster unreachable after 60s — check minikube status"
    warn "Cluster not ready (attempt $attempts/12) — waiting 5s"
    sleep 5
  done
  success "Cluster: reachable"
}

wait_for_vault() {
  log "Waiting for Vault pod to be Running..."
  local attempts=0
  until kubectl get pod vault-0 -n vault --no-headers 2>/dev/null | grep -q Running; do
    attempts=$(( attempts + 1 ))
    (( attempts > 24 )) && { warn "Vault not ready after 120s — credentials stage may fail"; return 0; }
    warn "Vault not Running (attempt $attempts/24) — waiting 5s"
    sleep 5
  done
  success "Vault: Running"
}

wait_for_tekton() {
  log "Waiting for Tekton pipelines controller..."
  local attempts=0
  until kubectl get deployment tekton-pipelines-controller -n tekton-pipelines &>/dev/null \
      && kubectl rollout status deployment/tekton-pipelines-controller \
           -n tekton-pipelines --timeout=10s &>/dev/null; do
    attempts=$(( attempts + 1 ))
    (( attempts > 36 )) && { warn "Tekton controller not ready after 180s — argocd stage may fail"; return 0; }
    warn "Tekton not ready (attempt $attempts/36) — waiting 5s"
    sleep 5
  done
  success "Tekton: controller Ready"
}

wait_for_pipelinerun() {
  local run_name="$1"
  log "Waiting for PipelineRun ${run_name} to complete..."
  local attempts=0
  local max=72

  until kubectl get pipelinerun "$run_name" -n tekton-pipelines &>/dev/null; do
    attempts=$(( attempts + 1 ))
    (( attempts > 12 )) && { warn "PipelineRun ${run_name} not found after 60s — continuing"; return 0; }
    sleep 5
  done

  attempts=0
  while true; do
    local succeeded failed
    succeeded=$(kubectl get pipelinerun "$run_name" -n tekton-pipelines \
      -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || echo "")
    failed=$(kubectl get pipelinerun "$run_name" -n tekton-pipelines \
      -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].reason}' 2>/dev/null || echo "")

    if [[ "$succeeded" == "True" ]]; then
      success "PipelineRun ${run_name}: Succeeded"
      return 0
    elif [[ "$succeeded" == "False" ]]; then
      warn "PipelineRun ${run_name}: Failed (reason: ${failed})"
      warn "Pipeline failed — ArgoCD will still be configured; check: tkn pipelinerun logs ${run_name} -f -n tekton-pipelines"
      return 0
    fi

    attempts=$(( attempts + 1 ))
    if (( attempts >= max )); then
      warn "PipelineRun ${run_name} still running after $(( max * 5 ))s — continuing without waiting"
      return 0
    fi

    local phase
    phase=$(kubectl get pipelinerun "$run_name" -n tekton-pipelines \
      -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].reason}' 2>/dev/null || echo "Running")
    log "  PipelineRun status: ${phase} ($(elapsed) elapsed, check $attempts/$max)"
    sleep 5
  done
}

print_pipeline_run_name() {
  local latest
  latest=$(kubectl get pipelinerun -n tekton-pipelines \
    --sort-by='.metadata.creationTimestamp' \
    -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
  echo "$latest"
}

print_final_summary() {
  local total_time; total_time=$(elapsed)

  section "Bootstrap Complete"

  echo ""
  echo -e "  ${BOLD}Total time:${NC} ${total_time}"
  echo ""

  echo -e "  ${BOLD}Stage Results:${NC}"
  for stage_name in PREREQUISITES CREDENTIALS SECURITY TEKTON ARGOCD OBSERVABILITY; do
    local var="STAGE_${stage_name}"
    local label="${stage_name,,}"
    if [[ "${!var}" == "true" ]]; then
      echo -e "    ${GREEN}✓${NC} ${label}"
    else
      echo -e "    ${YELLOW}⊘${NC} ${label} (skipped)"
    fi
  done

  echo ""
  echo -e "  ${BOLD}${CYAN}Service URLs${NC}"
  echo -e "  ┌─────────────────────────┬─────────────────────────────┬──────────────────────────┐"
  echo -e "  │ Service                 │ URL                         │ Credentials              │"
  echo -e "  ├─────────────────────────┼─────────────────────────────┼──────────────────────────┤"
  echo -e "  │ Tekton Dashboard        │ http://localhost:9097        │ (no auth)                │"
  echo -e "  │ ArgoCD                  │ https://localhost:8080       │ admin / (see below)      │"
  echo -e "  │ Grafana                 │ http://localhost:3001        │ admin / (see below)      │"
  echo -e "  │ Prometheus              │ http://localhost:9090        │ (no auth)                │"
  echo -e "  │ Alertmanager            │ http://localhost:9093        │ (no auth)                │"
  echo -e "  │ Vault UI                │ http://localhost:8200        │ token: root              │"
  echo -e "  └─────────────────────────┴─────────────────────────────┴──────────────────────────┘"
  echo ""

  local argocd_pass=""
  argocd_pass=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "<not available>")
  local grafana_pass=""
  grafana_pass=$(kubectl get secret prometheus-grafana -n monitoring \
    -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "<not available>")

  echo -e "  ${BOLD}Credentials:${NC}"
  echo -e "  ArgoCD admin password:  ${CYAN}${argocd_pass}${NC}"
  echo -e "  Grafana admin password: ${CYAN}${grafana_pass}${NC}"
  echo ""

  local pr_name; pr_name=$(print_pipeline_run_name)
  if [[ -n "$pr_name" ]]; then
    echo -e "  ${BOLD}Active PipelineRun:${NC} ${pr_name}"
    echo  "    tkn pipelinerun logs ${pr_name} -f -n tekton-pipelines"
    echo  "    kubectl get pipelinerun ${pr_name} -n tekton-pipelines"
    echo ""
  fi

  echo -e "  ${BOLD}Quick health checks:${NC}"
  echo  "    kubectl get pods -A | grep -v Running | grep -v Completed"
  echo  "    kubectl get application dtb-banking-portal -n argocd"
  echo  "    tkn pipelinerun list -n tekton-pipelines"
  echo ""

  echo -e "  ${BOLD}Stage logs:${NC}  ${LOG_DIR#"$ROOT_DIR/"}"
  echo ""
  echo -e "${GREEN}${BOLD}DTB Banking Portal stack is up.${NC}"
  echo ""
}

main() {
  parse_args "$@"

  mkdir -p "$LOG_DIR"

  echo ""
  echo -e "${BOLD}${CYAN}DTB Banking Portal — Master Bootstrap${NC}"
  echo -e "${BOLD}${CYAN}======================================${NC}"
  $DRY_RUN && echo -e "${YELLOW}DRY RUN MODE — no cluster changes will be made${NC}"
  [[ -n "$RESUME_FROM" ]] && echo -e "${YELLOW}Resuming from stage: ${RESUME_FROM}${NC}"
  echo ""
  echo -e "  Logs directory: ${LOG_DIR#"$ROOT_DIR/"}"
  echo -e "  Started:        $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""

  if ! $SKIP_PREREQUISITES; then
    run_stage "prerequisites" "Prerequisites" "${SCRIPT_DIR}/prerequisites.sh"
    wait_for_cluster
  else
    log "Stage 1 (prerequisites): skipped"
    wait_for_cluster
  fi

  if ! $SKIP_CREDENTIALS; then
    wait_for_vault
    run_stage "credentials" "Vault Credentials" "${K8S_DIR}/vault-credentials.sh"
  else
    log "Stage 2 (credentials): skipped"
  fi

  if ! $SKIP_SECURITY; then
    wait_for_cluster
    run_stage "security" "Security" "${K8S_DIR}/security-init.sh"
  else
    log "Stage 3 (security): skipped"
  fi

  if ! $SKIP_TEKTON; then
    wait_for_cluster
    run_stage "tekton" "Tekton CI/CD" "${K8S_DIR}/tekton-init.sh"

    local pr_name; pr_name=$(print_pipeline_run_name)
    if [[ -n "$pr_name" ]]; then
      wait_for_pipelinerun "$pr_name"
    fi
  else
    log "Stage 4 (tekton): skipped"
  fi

  if ! $SKIP_ARGOCD; then
    wait_for_cluster
    run_stage "argocd" "ArgoCD GitOps" "${K8S_DIR}/argocd-init.sh"
  else
    log "Stage 5 (argocd): skipped"
  fi

  if ! $SKIP_OBSERVABILITY; then
    wait_for_cluster
    run_stage "observability" "Observability" "${K8S_DIR}/observability-init.sh"
  else
    log "Stage 6 (observability): skipped"
  fi

  print_final_summary
}

main "$@"
