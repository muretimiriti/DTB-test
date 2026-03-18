#!/usr/bin/env bash
# Usage: ./scripts/k8s/teardown-argocd.sh [OPTIONS]
#
# Tears down ArgoCD resources created by argocd-init.sh:
#   - Deletes the dtb-banking-portal Application (stops GitOps sync)
#   - Removes the banking namespace Application and all synced resources
#   - Optionally uninstalls ArgoCD entirely from the cluster
#   - Kills any ArgoCD port-forward processes
#
# Options:
#   --app-name <name>        ArgoCD Application name (default: dtb-banking-portal)
#   --skip-app               Skip Application deletion only
#   --skip-banking-ns        Skip deleting the banking namespace and its resources
#   --uninstall-argocd       Also uninstall ArgoCD entirely
#   --namespace <ns>         ArgoCD namespace (default: argocd)
#   --dry-run                Print what would be done without executing
#   -h, --help               Show this help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MANIFESTS="${ROOT_DIR}/manifests"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}[argocd-teardown]${NC} $*"; }
success() { echo -e "${GREEN}[argocd-teardown]${NC} $*"; }
warn()    { echo -e "${YELLOW}[argocd-teardown]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${MAGENTA}══ $* ══${NC}"; }
die()     { echo -e "${RED}[argocd-teardown] ERROR:${NC} $*" >&2; exit 1; }

NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
BANKING_NS="${BANKING_NAMESPACE:-banking}"
APP_NAME="${ARGOCD_APP_NAME:-dtb-banking-portal}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v2.14.6}"
SKIP_APP=false
SKIP_BANKING_NS=false
UNINSTALL_ARGOCD=false
DRY_RUN=false

usage() {
  sed -n '/^# Usage:/,/^set -/p' "$0" | grep '^#' | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name)
      [[ $# -ge 2 ]] || die "Missing value for --app-name"
      APP_NAME="$2"; shift ;;
    --namespace)
      [[ $# -ge 2 ]] || die "Missing value for --namespace"
      NAMESPACE="$2"; shift ;;
    --skip-app)          SKIP_APP=true ;;
    --skip-banking-ns)   SKIP_BANKING_NS=true ;;
    --uninstall-argocd)  UNINSTALL_ARGOCD=true ;;
    --dry-run) DRY_RUN=true; warn "DRY RUN — no changes will be made" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1. Use --help for usage." ;;
  esac
  shift
done

kube() { $DRY_RUN && { echo "  DRY RUN: kubectl $*"; return 0; }; kubectl "$@"; }

# ── Preflight ──────────────────────────────────────────────────────────────────
command -v kubectl &>/dev/null || die "kubectl not found on PATH"
kubectl cluster-info --request-timeout=5s &>/dev/null || die "Cluster unreachable — is minikube running?"

# ── Kill port-forward processes ───────────────────────────────────────────────
section "Stop ArgoCD Port-Forwards"
if ! $DRY_RUN; then
  pkill -f "kubectl.*port-forward.*argocd" 2>/dev/null && log "Killed ArgoCD port-forward processes" || true
  pkill -f "port-forward.*8080" 2>/dev/null || true
else
  echo "  DRY RUN: pkill -f kubectl.*port-forward.*argocd"
fi
success "Port-forward processes stopped"

# ── ArgoCD Application ────────────────────────────────────────────────────────
if ! $SKIP_APP; then
  section "ArgoCD Application — $APP_NAME"

  if ! kubectl get namespace "$NAMESPACE" &>/dev/null 2>&1; then
    warn "ArgoCD namespace '$NAMESPACE' not found — skipping Application deletion"
  elif ! kubectl api-resources --api-group=argoproj.io &>/dev/null 2>&1; then
    warn "ArgoCD CRDs not installed — skipping Application deletion"
  else
    if kubectl get application "$APP_NAME" -n "$NAMESPACE" &>/dev/null 2>&1; then
      log "Disabling auto-sync on $APP_NAME before deletion..."
      if $DRY_RUN; then
        echo "  DRY RUN: argocd app set $APP_NAME --sync-policy none (or kubectl patch)"
      else
        # Patch to disable automated sync before deletion to prevent re-creation
        kubectl patch application "$APP_NAME" -n "$NAMESPACE" \
          --type merge \
          -p '{"spec":{"syncPolicy":null}}' 2>/dev/null || true
        log "Auto-sync disabled"
      fi

      log "Deleting ArgoCD Application: $APP_NAME"
      kube delete application "$APP_NAME" -n "$NAMESPACE" \
        --cascade=foreground --ignore-not-found
      success "Application $APP_NAME deleted"
    else
      log "Application $APP_NAME not found in $NAMESPACE — skipping"
    fi

    # Delete all remaining Applications if any
    if ! $DRY_RUN; then
      remaining=$(kubectl get applications -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' || true)
      for app in $remaining; do
        log "Deleting remaining Application: $app"
        kubectl patch application "$app" -n "$NAMESPACE" \
          --type merge -p '{"spec":{"syncPolicy":null}}' 2>/dev/null || true
        kubectl delete application "$app" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
      done
    fi

    # Delete ArgoCD Image Updater if installed
    log "Removing ArgoCD Image Updater (if present)..."
    if $DRY_RUN; then
      echo "  DRY RUN: kubectl delete -n $NAMESPACE deploy/argocd-image-updater"
    else
      kubectl delete deploy argocd-image-updater -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
      kubectl delete sa argocd-image-updater -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
      kubectl delete configmap argocd-image-updater-config -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
      kubectl delete secret argocd-image-updater-secret -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
    fi

    # Remove repo credentials and repository entries
    log "Removing ArgoCD repository registrations..."
    if $DRY_RUN; then
      echo "  DRY RUN: kubectl delete secrets -l argocd.argoproj.io/secret-type=repository -n $NAMESPACE"
    else
      kubectl delete secrets -l "argocd.argoproj.io/secret-type=repository" \
        -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
      kubectl delete secrets -l "argocd.argoproj.io/secret-type=cluster" \
        -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
    fi

    # Remove argocd-cm customisations (polling interval, etc.)
    log "Resetting argocd-cm configmap..."
    if $DRY_RUN; then
      echo "  DRY RUN: kubectl patch configmap argocd-cm -n $NAMESPACE"
    else
      kubectl patch configmap argocd-cm -n "$NAMESPACE" \
        --type merge -p '{"data":null}' 2>/dev/null || true
    fi

    success "ArgoCD Application resources removed"
  fi
else
  log "Skipping Application deletion (--skip-app)"
fi

# ── Banking Namespace (synced by ArgoCD) ──────────────────────────────────────
if ! $SKIP_BANKING_NS; then
  section "Banking Namespace — ArgoCD-managed resources"
  warn "Deleting the banking namespace removes ALL app resources (backend, frontend, mongodb)"

  if kubectl get namespace "$BANKING_NS" &>/dev/null 2>&1; then
    log "Deleting namespace: $BANKING_NS (and all resources within)"
    kube delete namespace "$BANKING_NS" --ignore-not-found
    log "Waiting for $BANKING_NS termination..."
    if ! $DRY_RUN; then
      local_timeout=60
      local_elapsed=0
      while kubectl get namespace "$BANKING_NS" &>/dev/null 2>&1; do
        (( local_elapsed >= local_timeout )) && { warn "Namespace $BANKING_NS still terminating — continuing"; break; }
        sleep 3; local_elapsed=$(( local_elapsed + 3 ))
        log "  Still terminating... (${local_elapsed}s)"
      done
      kubectl get namespace "$BANKING_NS" &>/dev/null 2>&1 \
        && warn "$BANKING_NS still exists — may have stuck finalizers" \
        || success "Namespace $BANKING_NS deleted"
    fi
  else
    log "Namespace $BANKING_NS not found — skipping"
  fi
else
  log "Skipping banking namespace deletion (--skip-banking-ns)"
fi

# ── Optional: Uninstall ArgoCD ────────────────────────────────────────────────
if $UNINSTALL_ARGOCD; then
  section "Uninstall ArgoCD — $ARGOCD_VERSION"
  warn "This will remove ALL ArgoCD controllers and CRDs"

  INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
  log "Deleting ArgoCD manifests from $INSTALL_URL..."
  if $DRY_RUN; then
    echo "  DRY RUN: kubectl delete -f $INSTALL_URL"
    echo "  DRY RUN: kubectl delete namespace $NAMESPACE"
  else
    kubectl delete -f "$INSTALL_URL" --ignore-not-found 2>/dev/null || \
      warn "kubectl delete of ArgoCD manifests returned non-zero — some resources may already be gone"

    # Delete the argocd namespace last
    kubectl delete namespace "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  fi

  # Remove argocd CLI if installed locally (optional, only if user installed it)
  if command -v argocd &>/dev/null; then
    warn "argocd CLI is installed locally at $(command -v argocd)"
    warn "Remove manually if desired: sudo rm $(command -v argocd)"
  fi

  success "ArgoCD uninstalled"
fi

# Delete the manifests/argocd/application.yaml-created resources if present
if [[ -f "$MANIFESTS/argocd/application.yaml" ]]; then
  log "Cleaning up manifests/argocd/application.yaml resources..."
  kube delete -f "$MANIFESTS/argocd/application.yaml" --ignore-not-found 2>/dev/null || true
fi

section "ArgoCD Teardown Complete"
echo ""
echo -e "  ${GREEN}✓${NC} ArgoCD port-forwards stopped"
echo -e "  ${GREEN}✓${NC} Application $APP_NAME deleted (auto-sync disabled first)"
$SKIP_BANKING_NS || echo -e "  ${GREEN}✓${NC} Banking namespace deleted"
$UNINSTALL_ARGOCD && echo -e "  ${GREEN}✓${NC} ArgoCD fully uninstalled"
echo ""
echo -e "  To reinstall: ${CYAN}./scripts/k8s/argocd-init.sh${NC}"
echo ""
