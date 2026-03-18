
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MANIFESTS="${ROOT_DIR}/manifests"

NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
BANKING_NS="${BANKING_NAMESPACE:-banking}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v2.14.6}"
ARGOCD_APP_NAME="${ARGOCD_APP_NAME:-dtb-banking-portal}"
DOCKER_REPO="${DOCKER_REPO:-muretimiriti/dtb-project}"
POLLING_INTERVAL="${POLLING_INTERVAL:-1800}"
INSTALL_ARGOCD="${INSTALL_ARGOCD:-true}"
SKIP_CLI="${SKIP_CLI:-false}"
SKIP_PORT_FORWARD="${SKIP_PORT_FORWARD:-false}"
DRY_RUN=false
ARGOCD_ADMIN_PASSWORD=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}[argocd]${NC} $*"; }
success() { echo -e "${GREEN}[argocd]${NC} $*"; }
warn()    { echo -e "${YELLOW}[argocd]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${MAGENTA}══ $* ══${NC}"; }
die()     { echo -e "${RED}[argocd] ERROR:${NC} $*" >&2; exit 1; }

retry_cmd() {
  local attempts="$1" sleep_sec="$2"; shift 2
  local n=1
  until "$@"; do
    (( n >= attempts )) && return 1
    n=$((n + 1)); sleep "$sleep_sec"
  done
}

kube()   { $DRY_RUN && { log "DRY RUN: kubectl $*"; return 0; }; kubectl "$@"; }
secret_exists() { kubectl get secret "$1" -n "$2" &>/dev/null; }

usage() {
  cat <<'USAGE'
Usage: ./scripts/k8s/argocd-init.sh [options]

Bootstraps ArgoCD for the DTB Banking Portal:
  - Installs ArgoCD v2.14.6 (if not present)
  - Configures 30-minute git polling via argocd-cm
  - Registers the git repo and creates the dtb-banking-portal Application
  - Automated sync: prune + selfHeal (GitOps — no manual sync needed)
  - Port-forwards the ArgoCD UI on https://localhost:8080

Options:
  --skip-install         Skip ArgoCD installation (use if already installed)
  --skip-cli             Skip steps requiring the argocd CLI binary
  --skip-port-forward    Skip port-forwarding the UI
  --namespace <ns>       ArgoCD namespace (default: ARGOCD_NAMESPACE or argocd)
  --dry-run              Print actions without executing
  -h, --help             Show this help

Environment:
  ARGOCD_NAMESPACE       ArgoCD namespace (default: argocd)
  BANKING_NAMESPACE      App namespace (default: banking)
  ARGOCD_VERSION         ArgoCD version to install (default: v2.14.6)
  ARGOCD_APP_NAME        Application name (default: dtb-banking-portal)
  POLLING_INTERVAL       Git poll interval in seconds (default: 1800 = 30 min)
  ARGOCD_ADMIN_PASSWORD  Override admin password (read from secret by default)
  TEKTON_REPO_URL        Override git repo URL (auto-detected from git remote)
  INSTALL_ARGOCD         true/false — install if missing (default: true)
  SKIP_CLI               true/false — skip argocd CLI steps (default: false)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-install)      INSTALL_ARGOCD="false" ;;
    --skip-cli)          SKIP_CLI="true" ;;
    --skip-port-forward) SKIP_PORT_FORWARD="true" ;;
    --namespace)
      [[ $# -ge 2 ]] || die "Missing value for --namespace"
      NAMESPACE="$2"; shift ;;
    --dry-run) DRY_RUN=true; warn "DRY RUN — no cluster changes will be made" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1. Use --help for usage." ;;
  esac
  shift
done

resolve_git_url() {
  local url="${TEKTON_REPO_URL:-$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || echo "")}"
  if [[ "$url" == git@github.com:* ]]; then
    url="${url/git@github.com:/https://github.com/}"
  fi
  echo "$url"
}

preflight() {
  section "Preflight"

  command -v kubectl &>/dev/null || die "kubectl not found on PATH"
  $DRY_RUN || kubectl cluster-info &>/dev/null \
    || die "Cannot reach cluster — ensure minikube is running: minikube start"

  local mk_status
  mk_status=$(minikube status --format='{{.Host}}' 2>/dev/null || echo "NotRunning")
  if [[ "$mk_status" != "Running" ]] && ! $DRY_RUN; then
    warn "minikube not running — starting..."
    minikube start \
      --driver=docker --cpus=4 --memory=8192 \
      --kubernetes-version=v1.32.3 \
      --addons=ingress,metrics-server,storage-provisioner
    success "minikube started"
  else
    success "cluster: reachable"
  fi

  if ! command -v argocd &>/dev/null; then
    warn "argocd CLI not found — CLI-based steps will be skipped"
    warn "Install: https://argo-cd.readthedocs.io/en/stable/cli_installation/"
    SKIP_CLI="true"
  else
    success "argocd CLI: $(command -v argocd)"
  fi

  command -v envsubst &>/dev/null || die "envsubst not found — install gettext: sudo apt-get install -y gettext"

  for ns in "$NAMESPACE" "$BANKING_NS" monitoring otel; do
    $DRY_RUN || kubectl create namespace "$ns" 2>/dev/null || true
  done
  success "namespaces: ready"
}

install_argocd() {
  section "ArgoCD Installation"

  if kubectl get deployment argocd-server -n "$NAMESPACE" &>/dev/null; then
    success "ArgoCD already installed — skipping"
    return 0
  fi

  log "installing ArgoCD $ARGOCD_VERSION..."
  retry_cmd 3 4 kubectl apply -f \
    "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

  log "waiting for argocd-server..."
  kubectl rollout status deployment/argocd-server \
    -n "$NAMESPACE" --timeout=300s

  log "waiting for argocd-repo-server..."
  kubectl rollout status deployment/argocd-repo-server \
    -n "$NAMESPACE" --timeout=300s

  log "waiting for argocd-application-controller (StatefulSet)..."
  kubectl rollout status statefulset/argocd-application-controller \
    -n "$NAMESPACE" --timeout=300s

  success "ArgoCD $ARGOCD_VERSION installed"
}

configure_polling_interval() {
  section "Git Polling Interval"

  log "setting timeout.reconciliation=${POLLING_INTERVAL}s in argocd-cm ($(( POLLING_INTERVAL / 60 )) min)"
  $DRY_RUN && return 0

  kubectl -n "$NAMESPACE" patch configmap argocd-cm \
    --type merge \
    -p "{\"data\":{\"timeout.reconciliation\":\"${POLLING_INTERVAL}s\"}}"

  success "polling interval: ${POLLING_INTERVAL}s — ArgoCD will poll git every $(( POLLING_INTERVAL / 60 )) minutes"
}

retrieve_admin_password() {
  section "Admin Credentials"
  $DRY_RUN && { ARGOCD_ADMIN_PASSWORD="dry-run-password"; return 0; }

  if [[ -n "${ARGOCD_ADMIN_PASSWORD:-}" ]]; then
    log "using ARGOCD_ADMIN_PASSWORD from environment"
    return 0
  fi

  local elapsed=0
  while (( elapsed < 60 )); do
    if secret_exists argocd-initial-admin-secret "$NAMESPACE"; then
      ARGOCD_ADMIN_PASSWORD="$(
        kubectl get secret argocd-initial-admin-secret \
          -n "$NAMESPACE" \
          -o jsonpath='{.data.password}' | base64 -d
      )"
      export ARGOCD_ADMIN_PASSWORD
      success "admin password retrieved from argocd-initial-admin-secret"
      return 0
    fi
    sleep 5; elapsed=$((elapsed + 5))
    log "waiting for argocd-initial-admin-secret (${elapsed}s)..."
  done

  warn "argocd-initial-admin-secret not found after 60s"
  warn "Set ARGOCD_ADMIN_PASSWORD env var to supply it manually"
}

argocd_cli_login() {
  section "ArgoCD CLI Login"

  if [[ "$SKIP_CLI" == "true" ]]; then
    log "CLI login skipped"
    return 0
  fi

  $DRY_RUN && { log "DRY RUN: argocd login localhost:8080 ..."; return 0; }

  [[ -n "${ARGOCD_ADMIN_PASSWORD:-}" ]] || retrieve_admin_password

  local pf_pid=""
  local pf_needed=false
  lsof -i :8080 &>/dev/null || pf_needed=true

  if $pf_needed; then
    kubectl port-forward svc/argocd-server \
      -n "$NAMESPACE" 8080:443 \
      >/tmp/argocd-login-pf.log 2>&1 &
    pf_pid=$!
    sleep 3
  fi

  retry_cmd 3 3 argocd login localhost:8080 \
    --username admin \
    --password "$ARGOCD_ADMIN_PASSWORD" \
    --insecure \
    --grpc-web \
    &>/dev/null

  success "ArgoCD CLI: logged in as admin"

  if $pf_needed && [[ -n "$pf_pid" ]]; then
    kill "$pf_pid" 2>/dev/null || true
  fi
}

register_git_repo() {
  section "Git Repository"

  local git_url
  git_url="$(resolve_git_url)"
  [[ -n "$git_url" ]] || die "Cannot resolve git URL — set TEKTON_REPO_URL or ensure git remote origin is set"

  log "git repo: $git_url"

  $DRY_RUN && { log "DRY RUN: would register $git_url"; return 0; }

  local existing
  existing=$(kubectl get secrets -n "$NAMESPACE" \
    -l "argocd.argoproj.io/secret-type=repo" \
    -o jsonpath='{.items[*].data.url}' 2>/dev/null \
    | tr ' ' '\n' \
    | while read -r b64; do echo "$b64" | base64 -d 2>/dev/null; done \
    | grep -c "$git_url" || echo "0")

  if [[ "$existing" -gt 0 ]]; then
    success "git repo already registered: $git_url"
    return 0
  fi

  local git_token=""
  if secret_exists git-credentials tekton-pipelines; then
    git_token=$(kubectl get secret git-credentials -n tekton-pipelines \
      -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  fi

  if [[ "$SKIP_CLI" == "false" ]] && command -v argocd &>/dev/null; then
    log "registering repo via argocd CLI..."
    if [[ -n "$git_token" ]]; then
      argocd repo add "$git_url" \
        --username git --password "$git_token" \
        --insecure-skip-server-verification
    else
      argocd repo add "$git_url" --insecure-skip-server-verification
    fi
  else
    log "registering repo via kubectl secret..."
    local repo_name
    repo_name="argocd-repo-$(echo "$git_url" | md5sum | cut -c1-8)"
    kubectl -n "$NAMESPACE" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${repo_name}
  namespace: ${NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repo
    app.kubernetes.io/part-of: dtb-banking-portal
type: Opaque
stringData:
  type: git
  url: "${git_url}"
EOF
  fi

  success "git repo registered: $git_url"
}

generate_application_yaml() {
  section "ArgoCD Application"

  local git_url
  git_url="$(resolve_git_url)"
  [[ -n "$git_url" ]] || die "Cannot resolve git URL"

  local app_file="${MANIFESTS}/argocd/application.yaml"
  [[ -f "$app_file" ]] || die "Application manifest not found: $app_file"

  log "applying Application: $ARGOCD_APP_NAME"
  log "  source: $git_url / manifests/k8s"
  log "  target: $BANKING_NS @ https://kubernetes.default.svc"
  log "  sync:   automated (prune=true, selfHeal=true)"

  $DRY_RUN && { log "DRY RUN: REPO_URL=$git_url envsubst | kubectl apply -f -"; return 0; }

  REPO_URL="$git_url" envsubst < "$app_file" \
    | retry_cmd 3 2 kubectl apply -f -

  success "Application '$ARGOCD_APP_NAME' applied"

  log "waiting for Application to be created..."
  local elapsed=0
  while (( elapsed < 30 )); do
    kubectl get application "$ARGOCD_APP_NAME" -n "$NAMESPACE" &>/dev/null \
      && { success "Application '$ARGOCD_APP_NAME': ready"; return 0; }
    sleep 3; elapsed=$((elapsed + 3))
  done
  warn "Application may still be propagating — check: kubectl get application -n $NAMESPACE"
}

configure_image_updater() {
  section "Image Updater"

  if ! kubectl get deployment argocd-image-updater -n "$NAMESPACE" &>/dev/null; then
    warn "argocd-image-updater not installed — registry polling annotations in application.yaml will be inactive"
    warn "Install: https://argocd-image-updater.readthedocs.io/"
    log "GitOps polling (via git commit from update-manifests task) is still active"
    return 0
  fi

  success "argocd-image-updater detected — image polling annotations are active"
  log "  backend:  muretimiriti/dtb-project-backend (strategy: latest)"
  log "  frontend: muretimiriti/dtb-project-frontend (strategy: latest)"
}

open_argocd_ui() {
  section "ArgoCD UI"

  if [[ "$SKIP_PORT_FORWARD" == "true" ]]; then
    log "port-forward skipped (--skip-port-forward)"
    log "Start manually: kubectl port-forward svc/argocd-server -n $NAMESPACE 8080:443 &"
    return 0
  fi

  $DRY_RUN && { log "DRY RUN: would port-forward :8080 → 443"; return 0; }

  if lsof -i :8080 &>/dev/null 2>&1; then
    success "port 8080 already in use — ArgoCD UI likely already forwarded"
    echo -e "  ${CYAN}https://localhost:8080${NC}"
    return 0
  fi

  log "starting ArgoCD UI port-forward on https://localhost:8080 (background)..."
  kubectl port-forward svc/argocd-server \
    -n "$NAMESPACE" 8080:443 \
    >/tmp/argocd-pf.log 2>&1 &
  local pid=$!

  sleep 3
  if kill -0 "$pid" 2>/dev/null; then
    success "ArgoCD port-forward running (PID $pid)"
    echo -e "  ${CYAN}https://localhost:8080${NC}"
  else
    warn "port-forward failed — start manually:"
    echo -e "  ${CYAN}kubectl port-forward svc/argocd-server -n $NAMESPACE 8080:443 &${NC}"
  fi
}

print_summary() {
  section "Setup Complete"

  echo ""
  echo -e "  ${BOLD}ArgoCD UI${NC}"
  echo -e "  ${CYAN}https://localhost:8080${NC}"
  echo  "    Username: admin"
  if [[ -n "${ARGOCD_ADMIN_PASSWORD:-}" ]] && [[ "$ARGOCD_ADMIN_PASSWORD" != "dry-run-password" ]]; then
    echo  "    Password: $ARGOCD_ADMIN_PASSWORD"
  else
    echo  "    Password: kubectl get secret argocd-initial-admin-secret -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d"
  fi
  echo ""
  echo -e "  ${BOLD}Git polling${NC}"
  echo  "    Interval: ${POLLING_INTERVAL}s ($(( POLLING_INTERVAL / 60 )) min) — set in argocd-cm"
  echo  "    ArgoCD will detect new image tags committed by the Tekton update-manifests task"
  echo ""
  echo -e "  ${BOLD}Quick commands${NC}"
  echo  "    kubectl get application -n $NAMESPACE"
  echo  "    kubectl get application $ARGOCD_APP_NAME -n $NAMESPACE -o yaml"
  if [[ "$SKIP_CLI" == "false" ]]; then
    echo  "    argocd app list"
    echo  "    argocd app sync $ARGOCD_APP_NAME"
    echo  "    argocd app wait $ARGOCD_APP_NAME --health"
  fi
  echo ""
}

echo ""
echo -e "${BOLD}DTB Banking Portal — ArgoCD Bootstrap${NC}"
echo -e "  namespace : $NAMESPACE"
echo -e "  app name  : $ARGOCD_APP_NAME"
echo -e "  poll:     : ${POLLING_INTERVAL}s ($(( POLLING_INTERVAL / 60 )) min)"
$DRY_RUN && echo -e "  ${YELLOW}DRY RUN — no cluster changes${NC}"
echo ""

preflight

if [[ "$INSTALL_ARGOCD" == "true" ]]; then
  install_argocd
else
  log "skipping ArgoCD install (INSTALL_ARGOCD=false)"
fi

configure_polling_interval
retrieve_admin_password
argocd_cli_login
register_git_repo
generate_application_yaml
configure_image_updater
open_argocd_ui
print_summary

success "ArgoCD bootstrap complete"
echo ""
