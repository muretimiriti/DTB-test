#!/usr/bin/env bash
# =============================================================================
# vault-credentials.sh — Load all pipeline credentials into Vault
#
# Run this ONCE after prerequisites.sh. It is the single place where every
# credential is entered. From here they are:
#
#   1. Written to HashiCorp Vault (KV v2 at secret/banking/*)
#   2. The Docker Hub regcred secret is created immediately in all required
#      Kubernetes namespaces so the cluster can pull images right away.
#   3. ESO will sync all other secrets from Vault into native K8s secrets
#      automatically (see security-init.sh for ESO setup).
#
# Credentials stored:
#   secret/banking/docker      DOCKER_USERNAME, DOCKER_EMAIL
#   secret/banking/backend     JWT_SECRET, MONGO_APP_PASSWORD, NODE_ENV, ...
#   secret/banking/mongodb     MONGO_ROOT_USER, MONGO_ROOT_PASSWORD, MONGO_APP_USER, MONGO_APP_PASSWORD
#   secret/banking/sonarqube   SONAR_ADMIN_USER, SONAR_ADMIN_PASSWORD
#   secret/banking/grafana     GRAFANA_ADMIN_USER, GRAFANA_ADMIN_PASSWORD
#   secret/banking/github      GITHUB_TOKEN, GITHUB_WEBHOOK_SECRET
#   secret/banking/argocd      (admin password synced from argocd-initial-admin-secret)
#
#   K8s secret created directly (Docker Hub — needed before ESO runs):
#   regcred                    in: banking, tekton-pipelines, argocd, kyverno
#   sonarqube-token            in: tekton-pipelines
#   github-webhook-secret      in: tekton-triggers
#   grafana-admin-secret       in: monitoring  (used by Grafana helm chart)
#
# Usage:
#   ./scripts/k8s/vault-credentials.sh [OPTIONS]
#
# Options:
#   --vault-token TOKEN   Vault root token (default: root for dev mode)
#   --skip-docker         Skip Docker Hub credential entry
#   --skip-sonarqube      Skip SonarQube credential entry
#   --skip-github         Skip GitHub token/webhook secret entry
#   --skip-grafana        Skip Grafana admin password entry
#   --skip-app-secrets    Skip JWT secret and MongoDB password entry
#   --dry-run             Print what would be written without executing
#   --help                Show this help
#
# NOTE: This script never writes credentials to disk. All values are held
#       in shell variables for the duration of the run only.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${MAGENTA}══ $* ══${NC}"; }
die()     { error "$*"; exit 1; }

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
VAULT_TOKEN="${VAULT_TOKEN:-root}"
SKIP_DOCKER=false
SKIP_SONARQUBE=false
SKIP_GITHUB=false
SKIP_GRAFANA=false
SKIP_APP_SECRETS=false
DRY_RUN=false

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vault-token)      shift; VAULT_TOKEN="$1" ;;
      --skip-docker)      SKIP_DOCKER=true ;;
      --skip-sonarqube)   SKIP_SONARQUBE=true ;;
      --skip-github)      SKIP_GITHUB=true ;;
      --skip-grafana)     SKIP_GRAFANA=true ;;
      --skip-app-secrets) SKIP_APP_SECRETS=true ;;
      --dry-run)          DRY_RUN=true; warn "DRY RUN — no credentials will be written" ;;
      --help|-h)
        sed -n '/^# Usage:/,/^# ====/p' "$0" | grep '^#' | sed 's/^# \?//'
        exit 0 ;;
      *) die "Unknown option: $1. Use --help for usage." ;;
    esac
    shift
  done
}

# =============================================================================
# HELPERS
# =============================================================================

# prompt_value VAR "prompt text" [default]
# Sets VAR via stdin prompt (falls back to default in non-interactive mode)
prompt_value() {
  local var="$1" prompt="$2" default="${3:-}"
  if [[ -n "${!var:-}" ]]; then
    info "$var already set — skipping prompt"
    return 0
  fi
  if [[ -t 0 ]]; then
    local display_default=""
    [[ -n "$default" ]] && display_default=" [${default}]"
    read -rp "  ${prompt}${display_default}: " tmp
    export "$var"="${tmp:-$default}"
  else
    [[ -n "$default" ]] && export "$var"="$default" \
      || die "$var is required but not set (non-interactive mode)"
  fi
}

# prompt_secret VAR "prompt text"
# Like prompt_value but hides input and never accepts an empty value
prompt_secret() {
  local var="$1" prompt="$2"
  if [[ -n "${!var:-}" ]]; then
    info "$var already set — skipping prompt"
    return 0
  fi
  if [[ -t 0 ]]; then
    local tmp=""
    while [[ -z "$tmp" ]]; do
      read -rsp "  ${prompt}: " tmp
      echo ""
      [[ -z "$tmp" ]] && warn "Value cannot be empty — try again"
    done
    export "$var"="$tmp"
  else
    die "$var is required but not set (non-interactive mode)"
  fi
}

# vault_write PATH KEY=VALUE ...
# Writes key-value pairs to the Vault KV v2 engine via kubectl exec
vault_write() {
  local path="$1"; shift
  local kv_args=("$@")

  if $DRY_RUN; then
    info "DRY RUN: vault kv put $path ${kv_args[*]}"
    return 0
  fi

  kubectl exec -n vault vault-0 -- \
    sh -c "VAULT_TOKEN=${VAULT_TOKEN} vault kv put ${path} $(printf '%q ' "${kv_args[@]}")"
  success "Written to Vault: $path"
}

# vault_running: returns 0 if vault-0 pod is reachable
vault_running() {
  kubectl get pod vault-0 -n vault --no-headers 2>/dev/null \
    | grep -q "Running"
}

# kube_secret_apply: idempotent kubectl create secret ... | apply
kube_secret_apply() {
  $DRY_RUN && { info "DRY RUN: kubectl apply secret $*"; return 0; }
  "$@" --dry-run=client -o yaml | kubectl apply -f -
}

# =============================================================================
# PREFLIGHT
# =============================================================================
preflight() {
  section "Preflight"

  kubectl cluster-info --request-timeout=10s &>/dev/null \
    || die "Cannot reach cluster. Is minikube running?"
  success "Cluster: reachable"

  vault_running \
    || die "Vault pod is not running. Run prerequisites.sh first."
  success "Vault: vault-0 is Running"

  # Verify Vault is initialised with our token
  local status
  if $DRY_RUN; then
    status="active"
  else
    status=$(kubectl exec -n vault vault-0 -- \
      sh -c "VAULT_TOKEN=${VAULT_TOKEN} vault status -format=json 2>/dev/null" \
      | grep -o '"sealed":[^,}]*' | cut -d: -f2 | tr -d ' ' || echo "unknown")
  fi

  if [[ "$status" == "false" ]]; then
    success "Vault: unsealed and ready"
  elif $DRY_RUN; then
    success "Vault: DRY RUN — skipping seal check"
  else
    warn "Vault seal status: $status — proceeding but writes may fail"
  fi

  # Ensure KV engine is enabled (idempotent)
  $DRY_RUN || kubectl exec -n vault vault-0 -- \
    sh -c "VAULT_TOKEN=${VAULT_TOKEN} vault secrets enable -path=secret kv-v2" \
    2>/dev/null || info "KV engine already enabled at secret/"
  success "Vault KV v2: enabled at secret/"
}

# =============================================================================
# SECTION 1: DOCKER HUB
# =============================================================================
setup_docker() {
  section "Docker Hub Credentials"

  echo ""
  echo -e "  Docker Hub credentials are used to:"
  echo -e "  - Pull/push images in the Tekton pipeline (kaniko, cosign-sign)"
  echo -e "  - Create the 'regcred' ImagePullSecret in every namespace"
  echo ""

  prompt_value   DOCKER_USERNAME "Docker Hub username"
  prompt_secret  DOCKER_PASSWORD "Docker Hub password or access token"
  prompt_value   DOCKER_EMAIL    "Docker Hub email" "cicd@dtb.local"

  # Write username + email to Vault (password is NOT stored in Vault — it is
  # only used to create the regcred secret below, then discarded)
  vault_write "secret/banking/docker" \
    "DOCKER_USERNAME=${DOCKER_USERNAME}" \
    "DOCKER_EMAIL=${DOCKER_EMAIL}"

  $DRY_RUN && { success "DRY RUN: Docker Hub section complete"; return 0; }

  # Docker Hub login
  echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin \
    && success "Logged in to Docker Hub as $DOCKER_USERNAME" \
    || die "Docker Hub login failed — check username/password"

  # Create regcred in all namespaces that pull images
  local namespaces=(banking tekton-pipelines argocd kyverno)
  for ns in "${namespaces[@]}"; do
    kube_secret_apply kubectl create secret docker-registry regcred \
      --docker-server=https://index.docker.io/v1/ \
      --docker-username="$DOCKER_USERNAME" \
      --docker-password="$DOCKER_PASSWORD" \
      --docker-email="$DOCKER_EMAIL" \
      -n "$ns"
    info "regcred applied in namespace: $ns"
  done
  success "Docker Hub regcred created in: ${namespaces[*]}"
}

# =============================================================================
# SECTION 2: SONARQUBE
# =============================================================================
setup_sonarqube() {
  section "SonarQube Credentials"

  echo ""
  echo -e "  SonarQube admin password is used to:"
  echo -e "  - Log in to the SonarQube UI"
  echo -e "  - Generate the analysis token stored in Vault and the cluster"
  echo ""

  prompt_value  SONAR_ADMIN_USER "SonarQube admin username" "admin"
  prompt_secret SONAR_ADMIN_PASSWORD "SonarQube admin password (default: admin)"
  [[ -z "${SONAR_ADMIN_PASSWORD:-}" ]] && SONAR_ADMIN_PASSWORD="admin"

  vault_write "secret/banking/sonarqube" \
    "SONAR_ADMIN_USER=${SONAR_ADMIN_USER}" \
    "SONAR_ADMIN_PASSWORD=${SONAR_ADMIN_PASSWORD}"

  $DRY_RUN && { success "DRY RUN: SonarQube section complete"; return 0; }

  # Generate analysis token via SonarQube API (requires port-forward to be running)
  info "Attempting to generate SonarQube analysis token..."
  info "Ensure port-forward is running: kubectl port-forward svc/sonarqube-sonarqube -n sonarqube 9000:9000 &"

  local token_resp sonar_token
  token_resp=$(curl -sf \
    -u "${SONAR_ADMIN_USER}:${SONAR_ADMIN_PASSWORD}" \
    -X POST "http://localhost:9000/api/user_tokens/generate" \
    -d "name=tekton-pipeline-token&type=GLOBAL_ANALYSIS_TOKEN" 2>/dev/null \
    || echo "{}")
  sonar_token=$(echo "$token_resp" \
    | grep -o '"token":"[^"]*"' | cut -d'"' -f4 || echo "")

  if [[ -n "$sonar_token" ]]; then
    # Store analysis token in Vault
    vault_write "secret/banking/sonarqube" \
      "SONAR_ADMIN_USER=${SONAR_ADMIN_USER}" \
      "SONAR_ADMIN_PASSWORD=${SONAR_ADMIN_PASSWORD}" \
      "SONAR_TOKEN=${sonar_token}"

    # Also create as a k8s secret in tekton-pipelines (pipeline reads it directly)
    kube_secret_apply kubectl create secret generic sonarqube-token \
      --from-literal=SONAR_TOKEN="$sonar_token" \
      -n tekton-pipelines
    success "SonarQube analysis token generated and stored"
  else
    warn "Could not generate SonarQube analysis token — SonarQube may not be ready"
    warn "Re-run this section once SonarQube is up: --skip-docker --skip-github --skip-grafana --skip-app-secrets"
    warn "Or generate manually: security-init.sh handles this in Step 3"
  fi
}

# =============================================================================
# SECTION 3: GITHUB
# =============================================================================
setup_github() {
  section "GitHub Credentials"

  echo ""
  echo -e "  GitHub credentials are used to:"
  echo -e "  - Allow the Tekton git-clone task to clone private repos"
  echo -e "  - Validate incoming webhook payloads from GitHub (HMAC-SHA256)"
  echo -e "  - Allow the update-manifests task to push GitOps commits"
  echo ""

  prompt_secret  GITHUB_TOKEN          "GitHub personal access token (repo + write:packages scope)"
  prompt_secret  GITHUB_WEBHOOK_SECRET "GitHub webhook secret (random string — must match GitHub repo settings)"

  vault_write "secret/banking/github" \
    "GITHUB_TOKEN=${GITHUB_TOKEN}" \
    "GITHUB_WEBHOOK_SECRET=${GITHUB_WEBHOOK_SECRET}"

  $DRY_RUN && { success "DRY RUN: GitHub section complete"; return 0; }

  # git-credentials secret — used by the git-clone Tekton task
  kube_secret_apply kubectl create secret generic git-credentials \
    --from-literal=token="$GITHUB_TOKEN" \
    -n tekton-pipelines
  success "git-credentials secret created in tekton-pipelines"

  # GitHub webhook secret — used by the Tekton EventListener
  kube_secret_apply kubectl create secret generic github-webhook-secret \
    --from-literal=secretToken="$GITHUB_WEBHOOK_SECRET" \
    -n tekton-triggers
  success "github-webhook-secret created in tekton-triggers"

  # Also put the token in the banking namespace for update-manifests task
  kube_secret_apply kubectl create secret generic git-credentials \
    --from-literal=token="$GITHUB_TOKEN" \
    -n banking
  success "git-credentials secret created in banking"
}

# =============================================================================
# SECTION 4: GRAFANA
# =============================================================================
setup_grafana() {
  section "Grafana Admin Credentials"

  echo ""
  echo -e "  Grafana credentials are used to:"
  echo -e "  - Log in to the Grafana UI"
  echo -e "  - The Helm chart reads from the 'grafana-admin-secret' K8s secret"
  echo ""

  prompt_value  GRAFANA_ADMIN_USER     "Grafana admin username" "admin"
  prompt_secret GRAFANA_ADMIN_PASSWORD "Grafana admin password"

  vault_write "secret/banking/grafana" \
    "GRAFANA_ADMIN_USER=${GRAFANA_ADMIN_USER}" \
    "GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}"

  $DRY_RUN && { success "DRY RUN: Grafana section complete"; return 0; }

  # Create the K8s secret that the Grafana Helm chart references
  # (--set grafana.admin.existingSecret=grafana-admin-secret in prerequisites.sh)
  kube_secret_apply kubectl create secret generic grafana-admin-secret \
    --from-literal=admin-user="$GRAFANA_ADMIN_USER" \
    --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
    -n monitoring
  success "grafana-admin-secret created in monitoring namespace"
}

# =============================================================================
# SECTION 5: APP SECRETS (JWT + MongoDB)
# =============================================================================
setup_app_secrets() {
  section "Application Secrets"

  echo ""
  echo -e "  These are the secrets the banking backend and MongoDB use at runtime."
  echo -e "  ESO will sync them from Vault into K8s secrets automatically."
  echo ""

  # JWT secret — generate a strong random one if not provided
  if [[ -z "${JWT_SECRET:-}" ]]; then
    if command -v openssl &>/dev/null; then
      JWT_SECRET=$(openssl rand -hex 64)
      info "JWT_SECRET: auto-generated (64-byte random hex)"
    else
      prompt_secret JWT_SECRET "JWT secret (min 64 random characters)"
    fi
  fi

  prompt_secret MONGO_ROOT_PASSWORD "MongoDB root password"
  prompt_secret MONGO_APP_PASSWORD  "MongoDB app_user password"

  vault_write "secret/banking/backend" \
    "JWT_SECRET=${JWT_SECRET}" \
    "MONGO_APP_PASSWORD=${MONGO_APP_PASSWORD}" \
    "NODE_ENV=production" \
    "JWT_EXPIRES_IN=1h" \
    "BCRYPT_ROUNDS=12" \
    "RATE_LIMIT_WINDOW_MS=60000" \
    "RATE_LIMIT_MAX=100" \
    "AUTH_RATE_LIMIT_MAX=5"
  success "Backend secrets written to secret/banking/backend"

  vault_write "secret/banking/mongodb" \
    "MONGO_ROOT_USER=root" \
    "MONGO_ROOT_PASSWORD=${MONGO_ROOT_PASSWORD}" \
    "MONGO_APP_USER=app_user" \
    "MONGO_APP_PASSWORD=${MONGO_APP_PASSWORD}"
  success "MongoDB secrets written to secret/banking/mongodb"

  $DRY_RUN && { success "DRY RUN: App secrets section complete"; return 0; }

  # Verify the writes are readable
  local verify
  verify=$(kubectl exec -n vault vault-0 -- \
    sh -c "VAULT_TOKEN=${VAULT_TOKEN} vault kv get -format=json secret/banking/backend" \
    2>/dev/null | grep -c "JWT_SECRET" || echo "0")
  if [[ "$verify" -gt 0 ]]; then
    success "Vault read-back verification: PASSED"
  else
    warn "Could not verify Vault write — check Vault status"
  fi
}

# =============================================================================
# SUMMARY
# =============================================================================
print_summary() {
  section "Vault Credentials Summary"

  echo ""
  echo -e "  ${BOLD}Vault secret paths:${NC}"
  echo -e "  ${CYAN}secret/banking/docker${NC}       DOCKER_USERNAME, DOCKER_EMAIL"
  echo -e "  ${CYAN}secret/banking/sonarqube${NC}    SONAR_ADMIN_USER, SONAR_ADMIN_PASSWORD, SONAR_TOKEN"
  echo -e "  ${CYAN}secret/banking/grafana${NC}      GRAFANA_ADMIN_USER, GRAFANA_ADMIN_PASSWORD"
  echo -e "  ${CYAN}secret/banking/github${NC}       GITHUB_TOKEN, GITHUB_WEBHOOK_SECRET"
  echo -e "  ${CYAN}secret/banking/backend${NC}      JWT_SECRET, MONGO_APP_PASSWORD, NODE_ENV, ..."
  echo -e "  ${CYAN}secret/banking/mongodb${NC}      MONGO_ROOT_USER/PASSWORD, MONGO_APP_USER/PASSWORD"

  echo ""
  echo -e "  ${BOLD}Kubernetes secrets created directly:${NC}"
  echo -e "  regcred                  → banking, tekton-pipelines, argocd, kyverno"
  echo -e "  sonarqube-token          → tekton-pipelines"
  echo -e "  git-credentials          → tekton-pipelines, banking"
  echo -e "  github-webhook-secret    → tekton-triggers"
  echo -e "  grafana-admin-secret     → monitoring"

  echo ""
  echo -e "  ${BOLD}Remaining secrets (synced by ESO after security-init.sh):${NC}"
  echo -e "  backend-secret           → banking  (from secret/banking/backend)"
  echo -e "  mongodb-secret           → banking  (from secret/banking/mongodb)"

  echo ""
  echo -e "  ${BOLD}Verify:${NC}"
  echo  "    kubectl exec -n vault vault-0 -- sh -c 'VAULT_TOKEN=root vault kv list secret/banking/'"
  echo  "    kubectl get secrets -n tekton-pipelines"
  echo  "    kubectl get secrets -n banking"

  echo ""
  echo -e "  ${BOLD}Next step: initialise security components${NC}"
  echo  "    ./scripts/k8s/security-init.sh"
  echo ""
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  parse_args "$@"

  echo ""
  echo -e "${BOLD}DTB Banking Portal — Vault Credential Loader${NC}"
  echo -e "Credentials are entered once here and stored in Vault."
  $DRY_RUN && echo -e "${YELLOW}DRY RUN MODE — nothing will be written${NC}"
  echo ""

  preflight

  $SKIP_DOCKER      || setup_docker
  $SKIP_SONARQUBE   || setup_sonarqube
  $SKIP_GITHUB      || setup_github
  $SKIP_GRAFANA     || setup_grafana
  $SKIP_APP_SECRETS || setup_app_secrets

  print_summary
  success "All credentials loaded into Vault"
}

main "$@"
