#!/usr/bin/env bash
# Usage: ./scripts/k8s/teardown-security.sh [OPTIONS]
#
# Tears down all security resources created by security-init.sh:
#   - Kyverno ClusterPolicies (resource-limits, no-privileged, non-root, no-priv-escalation, etc.)
#   - NetworkPolicies in the banking namespace
#   - Cosign secrets (cosign-key in tekton-pipelines + banking)
#   - Cosign ConfigMap (cosign-pubkey in banking)
#   - OPA/conftest ConfigMap
#   - vault-eso-token secret in external-secrets namespace
#   - Optionally uninstalls Kyverno and External Secrets Operator via Helm
#
# Options:
#   --skip-kyverno-policies   Skip Kyverno ClusterPolicy deletion
#   --skip-netpol             Skip NetworkPolicy deletion
#   --skip-cosign             Skip cosign secret/configmap deletion
#   --skip-opa                Skip OPA ConfigMap deletion
#   --uninstall-kyverno       Also Helm-uninstall Kyverno entirely
#   --uninstall-eso           Also Helm-uninstall External Secrets Operator entirely
#   --dry-run                 Print what would be done without executing
#   -h, --help                Show this help
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}[security-teardown]${NC} $*"; }
success() { echo -e "${GREEN}[security-teardown]${NC} $*"; }
warn()    { echo -e "${YELLOW}[security-teardown]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${MAGENTA}══ $* ══${NC}"; }
die()     { echo -e "${RED}[security-teardown] ERROR:${NC} $*" >&2; exit 1; }

BANKING_NS="${BANKING_NAMESPACE:-banking}"
TEKTON_NS="${TEKTON_NAMESPACE:-tekton-pipelines}"
KYVERNO_NS="${KYVERNO_NAMESPACE:-kyverno}"
ESO_NS="${ESO_NAMESPACE:-external-secrets}"

SKIP_KYVERNO_POLICIES=false
SKIP_NETPOL=false
SKIP_COSIGN=false
SKIP_OPA=false
UNINSTALL_KYVERNO=false
UNINSTALL_ESO=false
DRY_RUN=false

usage() {
  sed -n '/^# Usage:/,/^set -/p' "$0" | grep '^#' | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-kyverno-policies) SKIP_KYVERNO_POLICIES=true ;;
    --skip-netpol)           SKIP_NETPOL=true ;;
    --skip-cosign)           SKIP_COSIGN=true ;;
    --skip-opa)              SKIP_OPA=true ;;
    --uninstall-kyverno)     UNINSTALL_KYVERNO=true ;;
    --uninstall-eso)         UNINSTALL_ESO=true ;;
    --dry-run)               DRY_RUN=true; warn "DRY RUN — no changes will be made" ;;
    -h|--help)               usage; exit 0 ;;
    *) die "Unknown option: $1. Use --help for usage." ;;
  esac
  shift
done

kube() { $DRY_RUN && { echo "  DRY RUN: kubectl $*"; return 0; }; kubectl "$@"; }

del_if_exists() {
  local kind="$1" name="$2" ns_flag="${3:-}"
  local ns_arg=()
  [[ -n "$ns_flag" ]] && ns_arg=("-n" "$ns_flag")
  if kubectl get "$kind" "$name" "${ns_arg[@]}" &>/dev/null 2>&1; then
    log "Deleting $kind/$name${ns_flag:+ in $ns_flag}"
    kube delete "$kind" "$name" "${ns_arg[@]}" --ignore-not-found
    success "Deleted $kind/$name"
  else
    log "$kind/$name not found — skipping"
  fi
}

# ── Preflight ──────────────────────────────────────────────────────────────────
command -v kubectl &>/dev/null || die "kubectl not found on PATH"
kubectl cluster-info --request-timeout=5s &>/dev/null || die "Cluster unreachable — is minikube running?"

# ── Kyverno Cluster Policies ──────────────────────────────────────────────────
if ! $SKIP_KYVERNO_POLICIES; then
  section "Kyverno ClusterPolicies"

  if kubectl api-resources --api-group=kyverno.io &>/dev/null 2>&1; then
    log "Listing active ClusterPolicies..."
    kubectl get clusterpolicies --no-headers 2>/dev/null || true

    POLICIES=(
      require-resource-limits
      disallow-privileged-containers
      require-non-root-user
      require-no-privilege-escalation
      require-service-selector
      require-signed-images
    )

    for policy in "${POLICIES[@]}"; do
      del_if_exists clusterpolicy "$policy"
    done

    # Delete any remaining policies for this project
    if $DRY_RUN; then
      echo "  DRY RUN: kubectl delete clusterpolicies --all"
    else
      remaining=$(kubectl get clusterpolicies --no-headers 2>/dev/null | awk '{print $1}' || true)
      for p in $remaining; do
        log "Deleting remaining ClusterPolicy: $p"
        kubectl delete clusterpolicy "$p" --ignore-not-found 2>/dev/null || true
      done
    fi

    # Delete PolicyReports
    log "Deleting PolicyReports in $BANKING_NS..."
    if $DRY_RUN; then
      echo "  DRY RUN: kubectl delete policyreports --all -n $BANKING_NS"
    else
      kubectl delete policyreports --all -n "$BANKING_NS" --ignore-not-found 2>/dev/null || true
      kubectl delete clusterpolicyreports --all --ignore-not-found 2>/dev/null || true
    fi

    success "Kyverno policies removed"
  else
    warn "Kyverno CRDs not present — skipping policy cleanup"
  fi
else
  log "Skipping Kyverno policy deletion (--skip-kyverno-policies)"
fi

# ── Network Policies ──────────────────────────────────────────────────────────
if ! $SKIP_NETPOL; then
  section "NetworkPolicies — $BANKING_NS"

  NETPOLS=(
    default-deny-all
    allow-ingress-to-frontend
    allow-frontend-to-backend
    allow-backend-to-mongodb
    allow-dns-egress
    allow-observability-egress
    allow-tekton-egress
  )

  for np in "${NETPOLS[@]}"; do
    del_if_exists networkpolicy "$np" "$BANKING_NS"
  done

  # Catch-all: remove any remaining NetworkPolicies in banking
  if $DRY_RUN; then
    echo "  DRY RUN: kubectl delete networkpolicies --all -n $BANKING_NS"
  else
    kubectl delete networkpolicies --all -n "$BANKING_NS" --ignore-not-found 2>/dev/null || true
  fi
  success "NetworkPolicies removed from $BANKING_NS"
else
  log "Skipping NetworkPolicy deletion (--skip-netpol)"
fi

# ── Cosign Resources ──────────────────────────────────────────────────────────
if ! $SKIP_COSIGN; then
  section "Cosign — Secrets + ConfigMaps"

  del_if_exists secret  cosign-key    "$TEKTON_NS"
  del_if_exists secret  cosign-key    "$BANKING_NS"
  del_if_exists configmap cosign-pubkey "$BANKING_NS"

  success "Cosign resources removed"
else
  log "Skipping cosign resource deletion (--skip-cosign)"
fi

# ── OPA / Conftest ConfigMap ──────────────────────────────────────────────────
if ! $SKIP_OPA; then
  section "OPA / Conftest ConfigMap"

  for ns in "$BANKING_NS" "$TEKTON_NS"; do
    del_if_exists configmap opa-k8s-policy "$ns"
    del_if_exists configmap conftest-policy "$ns"
    del_if_exists configmap k8s-security-policy "$ns"
  done

  success "OPA ConfigMaps removed"
else
  log "Skipping OPA ConfigMap deletion (--skip-opa)"
fi

# ── ESO vault token secret ────────────────────────────────────────────────────
section "ESO — vault-eso-token secret"
del_if_exists secret vault-eso-token "$ESO_NS"

# ── RBAC created by security-init ────────────────────────────────────────────
section "RBAC — security-related ClusterRoleBindings"
for crb in tekton-pipeline-runner banking-pipeline-runner; do
  del_if_exists clusterrolebinding "$crb"
done
for cr in tekton-pipeline-runner banking-pipeline-runner; do
  del_if_exists clusterrole "$cr"
done

# ── Optional: Helm Uninstall Kyverno ─────────────────────────────────────────
if $UNINSTALL_KYVERNO; then
  section "Helm Uninstall — Kyverno"
  command -v helm &>/dev/null || { warn "helm not found — skipping Kyverno uninstall"; }
  if helm status kyverno -n "$KYVERNO_NS" &>/dev/null 2>&1; then
    log "Uninstalling Kyverno Helm release..."
    if $DRY_RUN; then
      echo "  DRY RUN: helm uninstall kyverno -n $KYVERNO_NS"
    else
      helm uninstall kyverno -n "$KYVERNO_NS" --wait 2>/dev/null || warn "helm uninstall kyverno returned non-zero"
      kubectl delete namespace "$KYVERNO_NS" --ignore-not-found 2>/dev/null || true
    fi
    success "Kyverno uninstalled"
  else
    warn "Kyverno Helm release not found — skipping"
  fi
fi

# ── Optional: Helm Uninstall ESO ─────────────────────────────────────────────
if $UNINSTALL_ESO; then
  section "Helm Uninstall — External Secrets Operator"
  command -v helm &>/dev/null || { warn "helm not found — skipping ESO uninstall"; }
  for release in external-secrets; do
    if helm status "$release" -n "$ESO_NS" &>/dev/null 2>&1; then
      log "Uninstalling ESO Helm release: $release"
      if $DRY_RUN; then
        echo "  DRY RUN: helm uninstall $release -n $ESO_NS"
      else
        helm uninstall "$release" -n "$ESO_NS" --wait 2>/dev/null || warn "helm uninstall $release returned non-zero"
        kubectl delete namespace "$ESO_NS" --ignore-not-found 2>/dev/null || true
      fi
      success "ESO ($release) uninstalled"
    else
      warn "ESO release $release not found — skipping"
    fi
  done
fi

section "Security Teardown Complete"
echo ""
echo -e "  ${GREEN}✓${NC} Kyverno ClusterPolicies removed"
echo -e "  ${GREEN}✓${NC} NetworkPolicies removed from $BANKING_NS"
echo -e "  ${GREEN}✓${NC} Cosign secrets + ConfigMaps removed"
echo -e "  ${GREEN}✓${NC} OPA/conftest ConfigMaps removed"
echo -e "  ${GREEN}✓${NC} ESO vault-eso-token removed"
$UNINSTALL_KYVERNO && echo -e "  ${GREEN}✓${NC} Kyverno Helm release uninstalled"
$UNINSTALL_ESO     && echo -e "  ${GREEN}✓${NC} External Secrets Operator uninstalled"
echo ""
