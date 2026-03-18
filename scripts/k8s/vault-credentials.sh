#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DOCKER_REPO="muretimiriti/dtb-project"

GIT_REPO_URL=$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || echo "")

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${MAGENTA}══ $* ══${NC}"; }
die()     { error "$*"; exit 1; }
cleanup() { local rc=$?; (( rc != 0 )) && error "vault-credentials.sh failed (exit $rc)"; exit "$rc"; }
trap cleanup ERR EXIT

VAULT_TOKEN="${VAULT_TOKEN:-root}"
SKIP_DOCKER=false
SKIP_GITHUB=false
SKIP_APP_SECRETS=false
DRY_RUN=false

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vault-token)      shift; VAULT_TOKEN="$1" ;;
      --skip-docker)      SKIP_DOCKER=true ;;
      --skip-github)      SKIP_GITHUB=true ;;

      --skip-app-secrets) SKIP_APP_SECRETS=true ;;
      --dry-run)          DRY_RUN=true; warn "DRY RUN — no credentials will be written" ;;
      --help|-h)          grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
      *) die "Unknown option: $1. Use --help for usage." ;;
    esac
    shift
  done
}

prompt_value() {
  local var="$1" prompt="$2" default="${3:-}"
  if [[ -n "${!var:-}" ]]; then
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

prompt_secret() {
  local var="$1" prompt="$2"
  if [[ -n "${!var:-}" ]]; then
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

vault_running() {
  kubectl get pod vault-0 -n vault --no-headers 2>/dev/null \
    | grep -q "Running"
}

vault_secret_exists() {
  local path="$1"
  kubectl exec -n vault vault-0 -- \
    sh -c "VAULT_TOKEN=${VAULT_TOKEN} vault kv get ${path}" \
    &>/dev/null 2>&1
}

load_env() {
  local env_file="$PROJECT_ROOT/.env"
  [[ -f "$env_file" ]] || die ".env not found at $env_file — run ./scripts/setup.sh first"
  set -a
  source "$env_file"
  set +a
}

kube_secret_apply() {
  $DRY_RUN && { info "DRY RUN: kubectl apply secret $*"; return 0; }
  local n=1 max=4 sleep_s=5
  until "$@" --dry-run=client -o yaml | kubectl apply -f -; do
    (( n >= max )) && { error "kubectl apply failed after $max attempts"; return 1; }
    warn "kubectl apply failed (attempt $n/$max) — cluster may be restarting, retrying in ${sleep_s}s"
    n=$(( n + 1 )); sleep "$sleep_s"
    kubectl cluster-info --request-timeout=10s &>/dev/null || { warn "Cluster still unreachable — waiting longer"; sleep 10; }
  done
}

preflight() {
  section "Preflight"

  kubectl cluster-info --request-timeout=10s &>/dev/null \
    || die "Cannot reach cluster. Is minikube running?"
  success "Cluster: reachable"

  vault_running \
    || die "Vault pod is not running. Run prerequisites.sh first."
  success "Vault: vault-0 is Running"

  local status
  if $DRY_RUN; then
    status="false"
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

  $DRY_RUN || kubectl exec -n vault vault-0 -- \
    sh -c "VAULT_TOKEN=${VAULT_TOKEN} vault secrets enable -path=secret kv-v2" \
    2>/dev/null || true
  success "Vault KV v2: enabled at secret/"
}

setup_docker() {
  section "Docker Hub"

  if vault_secret_exists "secret/banking/docker" && \
     kubectl get secret regcred -n tekton-pipelines &>/dev/null; then
    success "Docker: already configured — skipping"
    return 0
  fi

  if [[ ! -f "${HOME}/.docker/config.json" ]]; then
    die "No Docker credentials found at ~/.docker/config.json. Run 'docker login' first."
  fi

  if ! grep -q "index.docker.io" "${HOME}/.docker/config.json" 2>/dev/null; then
    die "Not logged in to Docker Hub. Run 'docker login' first."
  fi
  success "Docker Hub: using existing login from ~/.docker/config.json"

  vault_write "secret/banking/docker" \
    "DOCKER_REPO=${DOCKER_REPO}"

  $DRY_RUN && { success "DRY RUN: Docker section complete"; return 0; }

  local namespaces=(banking tekton-pipelines argocd kyverno)
  for ns in "${namespaces[@]}"; do
    kube_secret_apply kubectl create secret generic regcred \
      --from-file=.dockerconfigjson="${HOME}/.docker/config.json" \
      --type=kubernetes.io/dockerconfigjson \
      -n "$ns"
  done
  success "regcred created in: ${namespaces[*]}"

  kube_secret_apply kubectl create secret generic docker-repo \
    --from-literal=DOCKER_REPO="${DOCKER_REPO}" \
    -n tekton-pipelines
  success "docker-repo secret created (repo: ${DOCKER_REPO})"
}

setup_github() {
  section "GitHub Credentials"

  if vault_secret_exists "secret/banking/github" && \
     kubectl get secret git-credentials -n tekton-pipelines &>/dev/null; then
    success "GitHub: already configured — skipping"
    return 0
  fi

  if [[ -n "$GIT_REPO_URL" ]]; then
    info "Auto-detected repo: $GIT_REPO_URL"
  else
    prompt_value GIT_REPO_URL "GitHub repo URL"
  fi

  vault_write "secret/banking/github" \
    "GIT_REPO_URL=${GIT_REPO_URL}"

  $DRY_RUN && { success "DRY RUN: GitHub section complete"; return 0; }

  kube_secret_apply kubectl create secret generic git-credentials \
    --from-literal=repo-url="${GIT_REPO_URL}" \
    -n tekton-pipelines
  success "git-credentials secret created in tekton-pipelines"

  kube_secret_apply kubectl create secret generic git-credentials \
    --from-literal=repo-url="${GIT_REPO_URL}" \
    -n banking
  success "git-credentials secret created in banking"
}

setup_app_secrets() {
  section "Application Secrets"

  if vault_secret_exists "secret/banking/backend" && \
     vault_secret_exists "secret/banking/mongodb"; then
    success "App secrets: already in Vault — skipping"
    return 0
  fi

  if [[ -z "${JWT_SECRET:-}" ]]; then
    JWT_SECRET=$(openssl rand -hex 64)
  fi

  local MONGO_ROOT_PASSWORD="${MONGO_ROOT_PASSWORD:-}"
  local MONGO_APP_PASSWORD="${MONGO_APP_PASSWORD:-}"

  if [[ -z "$MONGO_ROOT_PASSWORD" || -z "$MONGO_APP_PASSWORD" ]]; then
    die "MONGO_ROOT_PASSWORD and MONGO_APP_PASSWORD not found. Ensure .env is present and sourced."
  fi

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
    "MONGO_ROOT_USER=${MONGO_ROOT_USER:-root}" \
    "MONGO_ROOT_PASSWORD=${MONGO_ROOT_PASSWORD}" \
    "MONGO_APP_USER=${MONGO_APP_USER:-app_user}" \
    "MONGO_APP_PASSWORD=${MONGO_APP_PASSWORD}"
  success "MongoDB secrets written to secret/banking/mongodb"

  $DRY_RUN && return 0

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

print_summary() {
  section "Vault Credentials Summary"

  echo ""
  echo -e "  ${BOLD}Vault secret paths:${NC}"
  echo -e "  ${CYAN}secret/banking/docker${NC}       DOCKER_REPO"
  echo -e "  ${CYAN}secret/banking/github${NC}       GIT_REPO_URL"

  echo -e "  ${CYAN}secret/banking/backend${NC}      JWT_SECRET, MONGO_APP_PASSWORD, NODE_ENV, ..."
  echo -e "  ${CYAN}secret/banking/mongodb${NC}      MONGO_ROOT_USER/PASSWORD, MONGO_APP_USER/PASSWORD"

  echo ""
  echo -e "  ${BOLD}Kubernetes secrets created:${NC}"
  echo -e "  regcred                  → banking, tekton-pipelines, argocd, kyverno"
  echo -e "  docker-repo              → tekton-pipelines  (DOCKER_REPO=${DOCKER_REPO})"
  echo -e "  git-credentials          → tekton-pipelines, banking  (repo-url only)"

  echo ""
  echo -e "  ${BOLD}Synced by ESO after security-init.sh:${NC}"
  echo -e "  backend-secret           → banking  (from secret/banking/backend)"
  echo -e "  mongodb-secret           → banking  (from secret/banking/mongodb)"

  echo ""
  echo -e "  ${BOLD}SonarQube token:${NC}"
  echo -e "  Run security-init.sh — Step 3 handles token generation once SonarQube is up."

  echo ""
  echo -e "  ${BOLD}Verify:${NC}"
  echo  "    kubectl exec -n vault vault-0 -- sh -c 'VAULT_TOKEN=root vault kv list secret/banking/'"
  echo  "    kubectl get secrets -n tekton-pipelines"
  echo  "    kubectl get secrets -n banking"

  echo ""
  echo -e "  ${BOLD}Next step:${NC}"
  echo  "    ./scripts/k8s/security-init.sh"
  echo ""
}

main() {
  parse_args "$@"

  echo ""
  echo -e "${BOLD}DTB Banking Portal — Vault Credential Loader${NC}"
  $DRY_RUN && echo -e "${YELLOW}DRY RUN MODE — nothing will be written${NC}"
  echo ""

  load_env
  preflight

  $SKIP_DOCKER      || setup_docker
  $SKIP_GITHUB      || setup_github
  $SKIP_APP_SECRETS || setup_app_secrets

  print_summary
  success "All credentials loaded into Vault"
}

main "$@"
