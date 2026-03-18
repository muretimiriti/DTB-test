#!/usr/bin/env bash
# Usage: ./scripts/k8s/teardown-tekton.sh [OPTIONS]
#
# Tears down all Tekton resources created by tekton-init.sh:
#   - Cancels and deletes all active PipelineRuns and TaskRuns
#   - Deletes custom Tasks, Pipelines, EventListeners, TriggerTemplates,
#     TriggerBindings, PVCs, ServiceAccounts, and RBAC in tekton-pipelines
#   - Deletes Tekton resources in the banking namespace (SA, secrets, etc.)
#   - Optionally uninstalls Tekton Pipelines, Triggers, and Dashboard entirely
#
# Options:
#   --skip-runs           Skip PipelineRun/TaskRun deletion
#   --skip-custom-resources  Skip custom Task/Pipeline/Trigger deletion
#   --skip-rbac           Skip ServiceAccount/RBAC deletion
#   --uninstall-tekton    Also uninstall Tekton Pipelines + Triggers + Dashboard
#   --namespace <ns>      Tekton namespace (default: tekton-pipelines)
#   --dry-run             Print what would be done without executing
#   -h, --help            Show this help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MANIFESTS="${ROOT_DIR}/manifests"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}[tekton-teardown]${NC} $*"; }
success() { echo -e "${GREEN}[tekton-teardown]${NC} $*"; }
warn()    { echo -e "${YELLOW}[tekton-teardown]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${MAGENTA}══ $* ══${NC}"; }
die()     { echo -e "${RED}[tekton-teardown] ERROR:${NC} $*" >&2; exit 1; }

NAMESPACE="${TEKTON_NAMESPACE:-tekton-pipelines}"
BANKING_NS="${BANKING_NAMESPACE:-banking}"
SKIP_RUNS=false
SKIP_CUSTOM_RESOURCES=false
SKIP_RBAC=false
UNINSTALL_TEKTON=false
DRY_RUN=false

# Tekton install URLs (must match versions used in tekton-init.sh)
TEKTON_PIPELINE_VERSION="${TEKTON_PIPELINE_VERSION:-v0.68.0}"
TEKTON_TRIGGERS_VERSION="${TEKTON_TRIGGERS_VERSION:-v0.30.0}"
TEKTON_DASHBOARD_VERSION="${TEKTON_DASHBOARD_VERSION:-v0.52.0}"

usage() {
  sed -n '/^# Usage:/,/^set -/p' "$0" | grep '^#' | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-runs)              SKIP_RUNS=true ;;
    --skip-custom-resources)  SKIP_CUSTOM_RESOURCES=true ;;
    --skip-rbac)              SKIP_RBAC=true ;;
    --uninstall-tekton)       UNINSTALL_TEKTON=true ;;
    --namespace)
      [[ $# -ge 2 ]] || die "Missing value for --namespace"
      NAMESPACE="$2"; shift ;;
    --dry-run) DRY_RUN=true; warn "DRY RUN — no changes will be made" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1. Use --help for usage." ;;
  esac
  shift
done

kube()  { $DRY_RUN && { echo "  DRY RUN: kubectl $*"; return 0; }; kubectl "$@"; }
kn()    { $DRY_RUN && { echo "  DRY RUN: kubectl -n $NAMESPACE $*"; return 0; }; kubectl -n "$NAMESPACE" "$@"; }

del_all() {
  local kind="$1" ns="$2"
  if $DRY_RUN; then
    echo "  DRY RUN: kubectl delete $kind --all -n $ns"
    return 0
  fi
  local count
  count=$(kubectl get "$kind" -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$count" -gt 0 ]]; then
    log "Deleting $count ${kind}(s) in $ns..."
    kubectl delete "$kind" --all -n "$ns" --ignore-not-found 2>/dev/null || true
    success "Deleted $kind in $ns"
  else
    log "No $kind found in $ns — skipping"
  fi
}

# ── Preflight ──────────────────────────────────────────────────────────────────
command -v kubectl &>/dev/null || die "kubectl not found on PATH"
kubectl cluster-info --request-timeout=5s &>/dev/null || die "Cluster unreachable — is minikube running?"

# ── Kill port-forward processes ───────────────────────────────────────────────
section "Stop Tekton Dashboard Port-Forwards"
if ! $DRY_RUN; then
  pkill -f "kubectl.*port-forward.*tekton" 2>/dev/null && log "Killed Tekton port-forward processes" || true
  pkill -f "port-forward.*9097" 2>/dev/null || true
else
  echo "  DRY RUN: pkill -f kubectl.*port-forward.*tekton"
fi

# ── PipelineRuns + TaskRuns ───────────────────────────────────────────────────
if ! $SKIP_RUNS; then
  section "PipelineRuns + TaskRuns"

  if kubectl api-resources --api-group=tekton.dev &>/dev/null 2>&1; then
    # Cancel running PipelineRuns gracefully first
    if ! $DRY_RUN; then
      running_prs=$(kubectl get pipelineruns -n "$NAMESPACE" \
        -o jsonpath='{.items[?(@.status.conditions[0].status=="Unknown")].metadata.name}' 2>/dev/null || echo "")
      for pr in $running_prs; do
        log "Cancelling PipelineRun: $pr"
        kubectl patch pipelinerun "$pr" -n "$NAMESPACE" \
          --type merge -p '{"spec":{"status":"CancelledRunFinally"}}' 2>/dev/null || true
      done
    fi

    del_all pipelineruns "$NAMESPACE"
    del_all taskruns     "$NAMESPACE"
    success "All PipelineRuns and TaskRuns deleted"
  else
    warn "Tekton CRDs not installed — skipping run deletion"
  fi
else
  log "Skipping PipelineRun/TaskRun deletion (--skip-runs)"
fi

# ── Custom Tekton Resources ───────────────────────────────────────────────────
if ! $SKIP_CUSTOM_RESOURCES; then
  section "Custom Tasks, Pipelines, Triggers"

  if kubectl api-resources --api-group=tekton.dev &>/dev/null 2>&1; then
    del_all pipelines        "$NAMESPACE"
    del_all tasks            "$NAMESPACE"
    del_all eventlisteners   "$NAMESPACE"
    del_all triggertemplates "$NAMESPACE"
    del_all triggerbindings  "$NAMESPACE"
    del_all interceptors     "$NAMESPACE"
    success "Custom Tekton resources deleted"
  else
    warn "Tekton CRDs not present — skipping"
  fi

  # PVC
  section "Pipeline PVC"
  del_all persistentvolumeclaims "$NAMESPACE"

  # Manifests that were kubectl-applied from the manifests/tekton directory
  if [[ -d "$MANIFESTS/tekton" ]] && ! $DRY_RUN; then
    log "Deleting applied Tekton manifests from $MANIFESTS/tekton..."
    for dir in triggers tasks pipelines workspaces rbac; do
      local_dir="$MANIFESTS/tekton/$dir"
      if [[ -d "$local_dir" ]]; then
        kubectl delete -f "$local_dir" --ignore-not-found 2>/dev/null || true
      fi
    done
  fi
else
  log "Skipping custom resource deletion (--skip-custom-resources)"
fi

# ── RBAC ──────────────────────────────────────────────────────────────────────
if ! $SKIP_RBAC; then
  section "ServiceAccounts + RBAC"

  for sa in banking-pipeline tekton-pipeline-sa pipeline-runner; do
    if kubectl get sa "$sa" -n "$NAMESPACE" &>/dev/null 2>&1; then
      log "Deleting ServiceAccount $sa in $NAMESPACE"
      kn delete sa "$sa" --ignore-not-found
    fi
    if kubectl get sa "$sa" -n "$BANKING_NS" &>/dev/null 2>&1; then
      log "Deleting ServiceAccount $sa in $BANKING_NS"
      kube delete sa "$sa" -n "$BANKING_NS" --ignore-not-found
    fi
  done

  for crb in tekton-triggers-eventlistener banking-pipeline-rb pipeline-sa-rb; do
    kube delete clusterrolebinding "$crb" --ignore-not-found 2>/dev/null || true
  done
  for rb in tekton-triggers-eventlistener pipeline-role-binding; do
    kube delete rolebinding "$rb" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
    kube delete rolebinding "$rb" -n "$BANKING_NS" --ignore-not-found 2>/dev/null || true
  done

  success "RBAC resources removed"
else
  log "Skipping RBAC deletion (--skip-rbac)"
fi

# ── Optional: Uninstall Tekton entirely ───────────────────────────────────────
if $UNINSTALL_TEKTON; then
  section "Uninstall Tekton Pipelines + Triggers + Dashboard"
  warn "This will remove ALL Tekton CRDs and controllers from the cluster"

  BASE_URL="https://storage.googleapis.com/tekton-releases"

  for component in \
    "pipeline/previous/${TEKTON_PIPELINE_VERSION}/release.yaml" \
    "triggers/previous/${TEKTON_TRIGGERS_VERSION}/release.yaml" \
    "triggers/previous/${TEKTON_TRIGGERS_VERSION}/interceptors.yaml" \
    "dashboard/previous/${TEKTON_DASHBOARD_VERSION}/release.yaml"; do

    url="${BASE_URL}/${component}"
    log "Deleting: $url"
    if $DRY_RUN; then
      echo "  DRY RUN: kubectl delete -f $url"
    else
      kubectl delete -f "$url" --ignore-not-found 2>/dev/null || true
    fi
  done

  # Delete the namespace itself
  if $DRY_RUN; then
    echo "  DRY RUN: kubectl delete namespace $NAMESPACE"
  else
    kubectl delete namespace "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  fi

  success "Tekton fully uninstalled"
fi

section "Tekton Teardown Complete"
echo ""
echo -e "  ${GREEN}✓${NC} PipelineRuns and TaskRuns deleted"
echo -e "  ${GREEN}✓${NC} Custom Tasks, Pipelines, Triggers deleted"
echo -e "  ${GREEN}✓${NC} Pipeline PVC deleted"
echo -e "  ${GREEN}✓${NC} ServiceAccounts and RBAC removed"
$UNINSTALL_TEKTON && echo -e "  ${GREEN}✓${NC} Tekton controllers + CRDs uninstalled"
echo ""
echo -e "  To reinstall: ${CYAN}./scripts/k8s/tekton-init.sh${NC}"
echo ""
