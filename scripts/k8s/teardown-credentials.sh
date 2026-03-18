#!/usr/bin/env bash
# Usage: ./scripts/k8s/teardown-credentials.sh [OPTIONS]
#
# Tears down Vault secrets and the Kubernetes secrets created by vault-credentials.sh:
#   - Deletes k8s secrets: regcred, docker-repo, git-credentials, sonarqube-token,
#     grafana-credentials, jwt-secret, mongodb-credentials in banking/tekton-pipelines
#   - Deletes ExternalSecret resources in banking namespace
#   - Deletes SecretStore resources in banking namespace
#   - Wipes all KV v2 paths under secret/banking/ in Vault (optional)
#
# Options:
#   --skip-vault      Skip Vault secret deletion (keep Vault data intact)
#   --skip-k8s        Skip Kubernetes secret deletion
#   --skip-eso        Skip ExternalSecret/SecretStore deletion
#   --dry-run         Print what would be done without executing
#   -h, --help        Show this help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}[creds-teardown]${NC} $*"; }
success() { echo -e "${GREEN}[creds-teardown]${NC} $*"; }
warn()    { echo -e "${YELLOW}[creds-teardown]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${MAGENTA}══ $* ══${NC}"; }
die()     { echo -e "${RED}[creds-teardown] ERROR:${NC} $*" >&2; exit 1; }

BANKING_NS="${BANKING_NAMESPACE:-banking}"
TEKTON_NS="${TEKTON_NAMESPACE:-tekton-pipelines}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"
SKIP_VAULT=false
SKIP_K8S=false
SKIP_ESO=false
DRY_RUN=false

usage() {
  sed -n '/^# Usage:/,/^set -/p' "$0" | grep '^#' | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-vault)   SKIP_VAULT=true ;;
    --skip-k8s)     SKIP_K8S=true ;;
    --skip-eso)     SKIP_ESO=true ;;
    --vault-token)  shift; VAULT_TOKEN="$1" ;;
    --dry-run)      DRY_RUN=true; warn "DRY RUN — no changes will be made" ;;
    -h|--help)      usage; exit 0 ;;
    *) die "Unknown option: $1. Use --help for usage." ;;
  esac
  shift
done

kube() { $DRY_RUN && { echo "  DRY RUN: kubectl $*"; return 0; }; kubectl "$@"; }

delete_secret() {
  local name="$1" ns="$2"
  if kubectl get secret "$name" -n "$ns" &>/dev/null 2>&1; then
    log "Deleting secret/$name in $ns"
    kube delete secret "$name" -n "$ns" --ignore-not-found
    success "Deleted secret/$name in $ns"
  else
    log "secret/$name not found in $ns — skipping"
  fi
}

delete_resource() {
  local kind="$1" name="$2" ns="$3"
  if kubectl get "$kind" "$name" -n "$ns" &>/dev/null 2>&1; then
    log "Deleting $kind/$name in $ns"
    kube delete "$kind" "$name" -n "$ns" --ignore-not-found
    success "Deleted $kind/$name in $ns"
  else
    log "$kind/$name not found in $ns — skipping"
  fi
}

# ── Preflight ──────────────────────────────────────────────────────────────────
command -v kubectl &>/dev/null || die "kubectl not found on PATH"
kubectl cluster-info --request-timeout=5s &>/dev/null || die "Cluster unreachable — is minikube running?"

# ── Kubernetes Secrets ─────────────────────────────────────────────────────────
if ! $SKIP_K8S; then
  section "Kubernetes Secrets — banking namespace"
  for secret in regcred docker-repo git-credentials sonarqube-token \
                grafana-credentials jwt-secret mongodb-credentials \
                banking-secrets vault-eso-token; do
    delete_secret "$secret" "$BANKING_NS"
  done

  section "Kubernetes Secrets — tekton-pipelines namespace"
  for secret in git-credentials docker-credentials regcred cosign-key sonarqube-token; do
    delete_secret "$secret" "$TEKTON_NS"
  done
else
  log "Skipping Kubernetes secret deletion (--skip-k8s)"
fi

# ── ExternalSecrets + SecretStores ────────────────────────────────────────────
if ! $SKIP_ESO; then
  section "ExternalSecrets + SecretStores — banking namespace"

  if kubectl api-resources --api-group=external-secrets.io &>/dev/null 2>&1; then
    log "Deleting all ExternalSecrets in $BANKING_NS..."
    if $DRY_RUN; then
      echo "  DRY RUN: kubectl delete externalsecrets --all -n $BANKING_NS"
    else
      kubectl delete externalsecrets --all -n "$BANKING_NS" --ignore-not-found 2>/dev/null || true
    fi
    success "ExternalSecrets removed from $BANKING_NS"

    log "Deleting all SecretStores in $BANKING_NS..."
    if $DRY_RUN; then
      echo "  DRY RUN: kubectl delete secretstores --all -n $BANKING_NS"
    else
      kubectl delete secretstores --all -n "$BANKING_NS" --ignore-not-found 2>/dev/null || true
    fi
    success "SecretStores removed from $BANKING_NS"

    log "Deleting ClusterSecretStores..."
    if $DRY_RUN; then
      echo "  DRY RUN: kubectl delete clustersecretstores --all"
    else
      kubectl delete clustersecretstores --all --ignore-not-found 2>/dev/null || true
    fi
    success "ClusterSecretStores removed"
  else
    warn "External Secrets CRDs not present — skipping ESO resource cleanup"
  fi
else
  log "Skipping ESO resource deletion (--skip-eso)"
fi

# ── Vault Secret Paths ────────────────────────────────────────────────────────
if ! $SKIP_VAULT; then
  section "Vault — Wipe secret/banking/ KV paths"

  if ! kubectl get pod vault-0 -n vault &>/dev/null 2>&1; then
    warn "vault-0 pod not found in vault namespace — skipping Vault cleanup"
  else
    vaultc() {
      $DRY_RUN && { echo "  DRY RUN: vault $*"; return 0; }
      kubectl exec -n vault vault-0 -- env VAULT_TOKEN="$VAULT_TOKEN" vault "$@"
    }

    local_paths=(
      "secret/banking/docker"
      "secret/banking/github"
      "secret/banking/sonarqube"
      "secret/banking/grafana"
      "secret/banking/jwt"
      "secret/banking/mongodb"
    )

    for path in "${local_paths[@]}"; do
      log "Deleting Vault path: $path"
      vaultc kv delete "$path" 2>/dev/null && success "Deleted: $path" || warn "Could not delete $path (may not exist)"
      vaultc kv metadata delete "$path" 2>/dev/null || true
    done

    # Disable the KV engine if it was only used for this project
    log "Optionally disabling KV engine at secret/..."
    warn "Skipping KV engine disable (may be shared) — run manually if desired:"
    warn "  kubectl exec -n vault vault-0 -- vault secrets disable secret/"

    success "Vault banking secrets wiped"
  fi
else
  log "Skipping Vault cleanup (--skip-vault)"
fi

section "Credentials Teardown Complete"
echo ""
echo -e "  ${GREEN}✓${NC} Kubernetes secrets removed (banking + tekton-pipelines)"
echo -e "  ${GREEN}✓${NC} ExternalSecrets and SecretStores removed"
$SKIP_VAULT || echo -e "  ${GREEN}✓${NC} Vault KV paths wiped"
echo ""
