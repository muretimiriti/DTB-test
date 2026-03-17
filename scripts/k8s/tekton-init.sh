#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MANIFESTS="${ROOT_DIR}/manifests"

# =============================================================================
# ENV-VAR DEFAULTS — all behaviour can be overridden without editing this file
# =============================================================================
NAMESPACE="${TEKTON_NAMESPACE:-tekton-pipelines}"
BANKING_NS="${BANKING_NAMESPACE:-banking}"
INSTALL_TEKTON="${INSTALL_TEKTON:-true}"
INSTALL_DASHBOARD="${INSTALL_DASHBOARD:-true}"
APPLY_TRIGGERS="${APPLY_TRIGGERS:-true}"
RUN_PIPELINE="${RUN_PIPELINE_ON_SETUP:-true}"
DOCKER_REPO="${DOCKER_REPO:-muretimiriti/dtb-project}"
GIT_REVISION="${GIT_REVISION:-main}"
COSIGN_SIGN_ENABLED="${COSIGN_SIGN_ENABLED:-true}"
ARGOCD_AUTO_DEPLOY="${ARGOCD_AUTO_DEPLOY:-true}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_APP_NAME="${ARGOCD_APP_NAME:-dtb-banking-portal}"
RUN_INTEGRATION_TESTS="${RUN_INTEGRATION_TESTS:-true}"
TRIVY_FAIL_ON_CRITICAL="${TRIVY_FAIL_ON_CRITICAL:-true}"

LAST_PIPELINERUN_NAME=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

# =============================================================================
# LOGGING
# =============================================================================
log()     { echo -e "${BLUE}[tekton]${NC} $*"; }
success() { echo -e "${GREEN}[tekton]${NC} $*"; }
warn()    { echo -e "${YELLOW}[tekton]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${MAGENTA}══ $* ══${NC}"; }
die()     { echo -e "${RED}[tekton] ERROR:${NC} $*" >&2; exit 1; }

# =============================================================================
# USAGE
# =============================================================================
usage() {
  cat <<'USAGE'
Usage: ./scripts/k8s/tekton-init.sh [options]

Bootstraps the full DTB Banking Portal Tekton CI/CD pipeline:
  - Installs Tekton Pipelines, Triggers, Dashboard (if not present)
  - Applies RBAC, PVC, all Tasks, CI/CD Pipelines, and Triggers
  - Resolves credentials from docker login + existing k8s secrets (no prompts)
  - Creates an initial PipelineRun and port-forwards the Dashboard

Options:
  --skip-install         Skip installing Tekton components (use if already installed)
  --skip-dashboard       Skip Dashboard install/port-forward
  --skip-triggers        Skip applying Trigger manifests
  --skip-run             Skip creating the initial PipelineRun
  --namespace <ns>       Target namespace (default: TEKTON_NAMESPACE or tekton-pipelines)
  --dry-run              Print actions without executing
  -h, --help             Show this help

Environment:
  TEKTON_NAMESPACE         Namespace for Tekton resources (default: tekton-pipelines)
  BANKING_NAMESPACE        App namespace (default: banking)
  DOCKER_REPO              Docker Hub repo for image push (default: muretimiriti/dtb-project)
  GIT_REVISION             Branch/tag/SHA to build (default: current branch or main)
  COSIGN_SIGN_ENABLED      true/false — sign images with cosign-key secret (default: true)
  ARGOCD_AUTO_DEPLOY       true/false — sync ArgoCD after pipeline succeeds (default: true)
  ARGOCD_APP_NAME          ArgoCD application name (default: dtb-banking-portal)
  RUN_INTEGRATION_TESTS    true/false — run npm-integration-test stage (default: true)
  TRIVY_FAIL_ON_CRITICAL   true/false — fail pipeline on HIGH/CRITICAL CVEs (default: true)
  RUN_PIPELINE_ON_SETUP    true/false — create PipelineRun after setup (default: true)
  DOCKER_CONFIG_JSON       Path to docker config.json (default: ~/.docker/config.json)
USAGE
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-install)   INSTALL_TEKTON="false" ;;
    --skip-dashboard) INSTALL_DASHBOARD="false" ;;
    --skip-triggers)  APPLY_TRIGGERS="false" ;;
    --skip-run)       RUN_PIPELINE="false" ;;
    --dry-run)        DRY_RUN=true; warn "DRY RUN — no cluster changes will be made" ;;
    --namespace)
      [[ $# -ge 2 ]] || die "Missing value for --namespace"
      NAMESPACE="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1. Use --help for usage." ;;
  esac
  shift
done

# =============================================================================
# UTILITIES
# =============================================================================
k()           { kubectl -n "$NAMESPACE" "$@"; }
kube()        { $DRY_RUN && { log "DRY RUN: kubectl $*"; return 0; }; kubectl "$@"; }
kn()          { $DRY_RUN && { log "DRY RUN: kubectl -n $NAMESPACE $*"; return 0; }; k "$@"; }

retry_cmd() {
  local attempts="$1" sleep_sec="$2"; shift 2
  local n=1
  until "$@"; do
    (( n >= attempts )) && return 1
    n=$((n + 1)); sleep "$sleep_sec"
  done
}

apply_manifest() {
  local path="$1"
  log "applying ${path#"$ROOT_DIR"/}"
  $DRY_RUN && return 0
  retry_cmd 3 2 kubectl -n "$NAMESPACE" apply -f "$path"
}

apply_manifest_cluster() {
  local path="$1"
  log "applying ${path#"$ROOT_DIR"/} (cluster-scoped)"
  $DRY_RUN && return 0
  retry_cmd 3 2 kubectl apply -f "$path"
}

secret_exists() { kubectl get secret "$1" -n "$2" &>/dev/null; }

# =============================================================================
# PREFLIGHT — verify cluster and tools
# =============================================================================
preflight() {
  section "Preflight"

  command -v kubectl &>/dev/null || die "kubectl not found on PATH"
  kubectl version --client &>/dev/null || die "kubectl is not usable"
  $DRY_RUN || kubectl cluster-info &>/dev/null \
    || die "Cannot reach cluster — ensure minikube is running: minikube start"

  # Start minikube if not running
  local mk_status
  mk_status=$(minikube status --format='{{.Host}}' 2>/dev/null || echo "NotRunning")
  if [[ "$mk_status" != "Running" ]] && ! $DRY_RUN; then
    warn "minikube not running — starting with recommended settings..."
    minikube start \
      --driver=docker \
      --cpus=4 \
      --memory=8192 \
      --kubernetes-version=v1.32.3 \
      --addons=ingress,metrics-server,storage-provisioner
    success "minikube started"
  else
    success "cluster: reachable"
  fi

  for tool in helm cosign tkn; do
    command -v "$tool" &>/dev/null \
      && success "$tool: $(command -v "$tool")" \
      || warn "$tool not found — some features will be limited"
  done
}

# =============================================================================
# NAMESPACES
# =============================================================================
ensure_namespaces() {
  section "Namespaces"
  for ns in "$NAMESPACE" "$BANKING_NS" kyverno vault external-secrets monitoring argocd; do
    if $DRY_RUN || ! kubectl get namespace "$ns" &>/dev/null; then
      kube create namespace "$ns" 2>/dev/null || true
      log "namespace/$ns: created"
    else
      log "namespace/$ns: exists"
    fi
  done
  apply_manifest_cluster "$MANIFESTS/k8s/namespace.yaml"
}

# =============================================================================
# TEKTON INSTALLATION
# =============================================================================
wait_for_tekton_crds() {
  log "waiting for Tekton CRDs to establish..."
  local crds=(
    pipelines.tekton.dev
    tasks.tekton.dev
    pipelineruns.tekton.dev
    eventlisteners.triggers.tekton.dev
    triggerbindings.triggers.tekton.dev
    triggertemplates.triggers.tekton.dev
  )
  for crd in "${crds[@]}"; do
    kubectl wait --for=condition=Established --timeout=240s "crd/${crd}"
  done
  success "Tekton CRDs established"
}

wait_for_tekton_deployments() {
  section "Waiting for Tekton controllers"

  local pipelines_deploys=(
    tekton-pipelines-controller
    tekton-pipelines-webhook
    tekton-events-controller
  )
  for d in "${pipelines_deploys[@]}"; do
    kubectl -n tekton-pipelines rollout status "deployment/$d" --timeout=300s \
      && success "$d: ready" \
      || warn "$d did not become ready (non-fatal)"
  done

  local triggers_deploys=(
    tekton-triggers-controller
    tekton-triggers-webhook
    tekton-triggers-core-interceptors
  )
  for d in "${triggers_deploys[@]}"; do
    kubectl -n tekton-pipelines rollout status "deployment/$d" --timeout=300s \
      && success "$d: ready" \
      || warn "$d did not become ready (non-fatal)"
  done

  if [[ "$INSTALL_DASHBOARD" == "true" ]]; then
    kubectl -n tekton-pipelines rollout status deployment/tekton-dashboard --timeout=300s \
      && success "tekton-dashboard: ready" \
      || warn "tekton-dashboard did not become ready"
  fi
}

configure_tekton_feature_flags() {
  log "configuring Tekton feature flags (coschedule=disabled)"
  $DRY_RUN && return 0
  kubectl -n tekton-pipelines patch configmap feature-flags \
    --type merge \
    -p '{"data":{"coschedule":"disabled"}}' &>/dev/null || true
}

install_tekton_components() {
  section "Installing Tekton"

  log "installing Tekton Pipelines (v0.68.0)"
  retry_cmd 3 4 kubectl apply -f \
    "https://storage.googleapis.com/tekton-releases/pipeline/previous/v0.68.0/release.yaml"

  log "installing Tekton Triggers (v0.30.0)"
  retry_cmd 3 4 kubectl apply -f \
    "https://storage.googleapis.com/tekton-releases/triggers/previous/v0.30.0/release.yaml"
  retry_cmd 3 4 kubectl apply -f \
    "https://storage.googleapis.com/tekton-releases/triggers/previous/v0.30.0/interceptors.yaml"

  if [[ "$INSTALL_DASHBOARD" == "true" ]]; then
    log "installing Tekton Dashboard (v0.52.0)"
    retry_cmd 3 4 kubectl apply -f \
      "https://storage.googleapis.com/tekton-releases/dashboard/previous/v0.52.0/release.yaml"
  fi

  wait_for_tekton_crds
  wait_for_tekton_deployments
  configure_tekton_feature_flags
}

# =============================================================================
# SECRETS — resolve from existing k8s secrets / docker login (no prompts)
# =============================================================================
resolve_docker_config_path() {
  if [[ -n "${DOCKER_CONFIG_JSON:-}" ]]; then
    echo "$DOCKER_CONFIG_JSON"; return
  fi
  if [[ -n "${DOCKER_CONFIG:-}" ]]; then
    echo "${DOCKER_CONFIG}/config.json"; return
  fi
  echo "${HOME}/.docker/config.json"
}

resolve_docker_username() {
  # 1. From existing docker-hub-params secret
  if secret_exists docker-hub-params "$NAMESPACE"; then
    local u
    u=$(kubectl get secret docker-hub-params -n "$NAMESPACE" \
      -o jsonpath='{.data.DOCKER_USERNAME}' 2>/dev/null | base64 -d || echo "")
    [[ -n "$u" ]] && { echo "$u"; return; }
  fi
  # 2. Parse ~/.docker/config.json
  local cfg; cfg="$(resolve_docker_config_path)"
  if [[ -f "$cfg" ]]; then
    python3 -c "
import json, base64, sys
try:
  cfg = json.load(open('${cfg}'))
  for key in ('https://index.docker.io/v1/', 'index.docker.io'):
    auth = cfg.get('auths', {}).get(key, {}).get('auth', '')
    if auth:
      print(base64.b64decode(auth).decode().split(':')[0]); sys.exit(0)
except Exception: pass
" 2>/dev/null || true
  fi
}

resolve_git_url() {
  local url
  url="${TEKTON_REPO_URL:-$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || echo "")}"
  # Normalise SSH → HTTPS
  if [[ "$url" == git@github.com:* ]]; then
    url="${url/git@github.com:/https://github.com/}"
  fi
  echo "$url"
}

ensure_secrets() {
  section "Secrets"

  # ── regcred ───────────────────────────────────────────────────────────────
  local docker_cfg; docker_cfg="$(resolve_docker_config_path)"
  [[ -f "$docker_cfg" ]] || die "docker config not found at $docker_cfg — run 'docker login' first"

  for ns in "$NAMESPACE" "$BANKING_NS"; do
    if secret_exists regcred "$ns"; then
      log "regcred: exists in $ns"
    else
      kube create secret generic regcred \
        --from-file=.dockerconfigjson="$docker_cfg" \
        --type=kubernetes.io/dockerconfigjson \
        -n "$ns"
      success "regcred created in $ns"
    fi
  done

  # ── docker-hub-params ─────────────────────────────────────────────────────
  local docker_user; docker_user="$(resolve_docker_username)"
  [[ -n "$docker_user" ]] || die "Cannot resolve Docker username — run 'docker login' or vault-credentials.sh first"

  if secret_exists docker-hub-params "$NAMESPACE"; then
    log "docker-hub-params: exists"
  else
    kn create secret generic docker-hub-params \
      --from-literal=DOCKER_USERNAME="$docker_user" \
      --from-literal=DOCKER_REPO="$DOCKER_REPO"
    success "docker-hub-params created (user=$docker_user, repo=$DOCKER_REPO)"
  fi

  # ── git-credentials ───────────────────────────────────────────────────────
  local git_url; git_url="$(resolve_git_url)"
  [[ -n "$git_url" ]] || die "Cannot resolve git URL — set TEKTON_REPO_URL or ensure git remote origin is set"

  if secret_exists git-credentials "$NAMESPACE"; then
    log "git-credentials: exists"
  else
    kn create secret generic git-credentials \
      --from-literal=repo-url="$git_url"
    success "git-credentials created (url=$git_url)"
  fi

  # ── cosign-key ────────────────────────────────────────────────────────────
  if secret_exists cosign-key "$NAMESPACE"; then
    success "cosign-key: present"
  else
    if command -v cosign &>/dev/null && [[ "$COSIGN_SIGN_ENABLED" == "true" ]]; then
      log "generating cosign key pair (security-init.sh not yet run)..."
      $DRY_RUN || COSIGN_PASSWORD="" cosign generate-key-pair \
        "k8s://${NAMESPACE}/cosign-key"
      success "cosign-key generated"
    else
      warn "cosign-key missing — image signing will be skipped (set COSIGN_SIGN_ENABLED=false to suppress)"
    fi
  fi

  # ── github-webhook-secret (auto-generated) ────────────────────────────────
  if secret_exists github-webhook-secret "$NAMESPACE"; then
    log "github-webhook-secret: exists"
  else
    local ws; ws="$(openssl rand -hex 32)"
    kn create secret generic github-webhook-secret \
      --from-literal=webhook-secret="$ws"
    success "github-webhook-secret created (save for GitHub Settings → Webhooks: $ws)"
  fi

  export DOCKER_USERNAME="$docker_user"
  export GIT_REPO_URL="$git_url"
}

# =============================================================================
# RBAC
# =============================================================================
apply_rbac() {
  section "RBAC"
  apply_manifest "$MANIFESTS/tekton/rbac/serviceaccount.yaml"
  apply_manifest "$MANIFESTS/tekton/rbac/rolebinding.yaml"

  # Patch SA to pull images using regcred
  $DRY_RUN || kubectl patch serviceaccount tekton-pipeline-sa \
    -n "$NAMESPACE" --type=json \
    -p='[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"regcred"}}]' \
    2>/dev/null || true
  success "RBAC configured"
}

# =============================================================================
# WORKSPACES (PVC)
# =============================================================================
apply_workspaces() {
  section "Workspaces"
  apply_manifest "$MANIFESTS/tekton/workspaces/pvc.yaml"

  $DRY_RUN && return 0
  local elapsed=0
  while (( elapsed < 60 )); do
    local status
    status=$(kubectl get pvc pipeline-workspace-pvc -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    [[ "$status" == "Bound" ]] && { success "PVC pipeline-workspace-pvc: Bound"; return 0; }
    sleep 5; elapsed=$((elapsed + 5))
    log "PVC status: $status (${elapsed}s)..."
  done
  warn "PVC not Bound after 60s — check: kubectl get pvc -n $NAMESPACE"
}

# =============================================================================
# TASKS — apply all 13 task definitions in dependency order
# =============================================================================
apply_tasks() {
  section "Tekton Tasks"

  local task_order=(
    git-clone
    generate-tag
    lint-sast
    test-backend
    test-frontend
    npm-integration-test
    kaniko
    trivy-scan
    cosign-sign
    update-manifests
    smoke-test
    build-push
  )

  local applied=0 skipped=0
  for task in "${task_order[@]}"; do
    local f="$MANIFESTS/tekton/tasks/${task}.yaml"
    if [[ -f "$f" ]]; then
      apply_manifest "$f"
      applied=$((applied + 1))
    else
      warn "task file not found: $f (skipping)"
      skipped=$((skipped + 1))
    fi
  done

  $DRY_RUN && return 0
  local count
  count=$(kubectl get tasks -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  success "$count Task(s) registered ($applied applied, $skipped missing)"
}

# =============================================================================
# PIPELINES
# =============================================================================
apply_pipelines() {
  section "Pipelines"
  apply_manifest "$MANIFESTS/tekton/pipelines/ci-pipeline.yaml"
  apply_manifest "$MANIFESTS/tekton/pipelines/cd-pipeline.yaml"

  $DRY_RUN && return 0
  local count
  count=$(kubectl get pipelines -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  success "$count Pipeline(s) registered"
}

# =============================================================================
# TRIGGERS
# =============================================================================
apply_triggers() {
  section "Triggers"
  retry_cmd 3 2 kubectl -n "$NAMESPACE" apply -f \
    "$MANIFESTS/tekton/triggers/trigger-binding.yaml"
  retry_cmd 3 2 kubectl -n "$NAMESPACE" apply -f \
    "$MANIFESTS/tekton/triggers/trigger-template.yaml"
  retry_cmd 3 2 kubectl -n "$NAMESPACE" apply -f \
    "$MANIFESTS/tekton/triggers/event-listener.yaml"

  $DRY_RUN && return 0
  local elapsed=0
  while (( elapsed < 90 )); do
    kubectl get pod -n "$NAMESPACE" \
      -l eventlistener=banking-event-listener \
      --no-headers 2>/dev/null | grep -q "Running" \
      && { success "EventListener pod: Running"; return 0; }
    sleep 5; elapsed=$((elapsed + 5))
    log "waiting for EventListener pod (${elapsed}s)..."
  done
  kubectl get svc el-banking-event-listener -n "$NAMESPACE" &>/dev/null \
    && success "EventListener service up (pod still starting)" \
    || warn "EventListener may not be ready — check: kubectl get pods -n $NAMESPACE"
}

# =============================================================================
# VERIFY — confirm everything registered correctly
# =============================================================================
verify_setup() {
  section "Verification"
  $DRY_RUN && { success "skipping verification (dry run)"; return 0; }

  local all_ok=true

  echo ""
  echo -e "  ${BOLD}Controllers:${NC}"
  for d in tekton-pipelines-controller tekton-pipelines-webhook; do
    local ready
    ready=$(kubectl get deployment "$d" -n tekton-pipelines \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${ready:-0}" -gt 0 ]]; then
      echo -e "    ${GREEN}✔${NC} $d (${ready} ready)"
    else
      echo -e "    ${RED}✘${NC} $d (not ready)"
      all_ok=false
    fi
  done

  echo ""
  echo -e "  ${BOLD}Resources in $NAMESPACE:${NC}"
  local tasks pipelines tbs tts els
  tasks=$(kubectl get tasks -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  pipelines=$(kubectl get pipelines -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  tbs=$(kubectl get triggerbindings -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  tts=$(kubectl get triggertemplates -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  els=$(kubectl get eventlisteners -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  printf "    %-22s %s\n" "Tasks:"            "$tasks"
  printf "    %-22s %s\n" "Pipelines:"        "$pipelines"
  printf "    %-22s %s\n" "TriggerBindings:"  "$tbs"
  printf "    %-22s %s\n" "TriggerTemplates:" "$tts"
  printf "    %-22s %s\n" "EventListeners:"   "$els"

  echo ""
  echo -e "  ${BOLD}Required secrets in $NAMESPACE:${NC}"
  local prereq_missing=false
  for s in regcred docker-hub-params git-credentials cosign-key github-webhook-secret; do
    if secret_exists "$s" "$NAMESPACE"; then
      echo -e "    ${GREEN}✔${NC} $s"
    else
      echo -e "    ${RED}✘${NC} $s (missing)"
      all_ok=false; prereq_missing=true
    fi
  done

  if $prereq_missing; then
    echo ""
    warn "Missing secrets — run in order:"
    echo  "    1. docker login"
    echo  "    2. ./scripts/k8s/security-init.sh   (generates cosign-key)"
    echo  "    3. ./scripts/k8s/vault-credentials.sh"
  fi

  echo ""
  $all_ok && success "all checks passed — pipeline ready" \
    || warn "some checks failed — review ✘ items above"
}

# =============================================================================
# TEKTON DASHBOARD — port-forward
# =============================================================================
open_dashboard() {
  section "Tekton Dashboard"
  $DRY_RUN && { log "DRY RUN: would port-forward :9097"; return 0; }

  if lsof -i :9097 &>/dev/null 2>&1; then
    success "port 9097 already forwarded — Dashboard already running"
    echo -e "  ${CYAN}http://localhost:9097${NC}"
    return 0
  fi

  log "starting Dashboard port-forward on http://localhost:9097 (background)..."
  kubectl port-forward svc/tekton-dashboard \
    -n tekton-pipelines 9097:9097 \
    &>/tmp/tekton-dashboard-pf.log &
  local pid=$!

  sleep 3
  if kill -0 "$pid" 2>/dev/null; then
    success "Dashboard port-forward running (PID $pid)"
    echo -e "  ${CYAN}http://localhost:9097${NC}"
  else
    warn "port-forward failed — start manually:"
    echo -e "  ${CYAN}kubectl port-forward svc/tekton-dashboard -n tekton-pipelines 9097:9097 &${NC}"
  fi
}

# =============================================================================
# PIPELINERUN — create initial run with all params auto-resolved
# =============================================================================
create_pipeline_run() {
  section "PipelineRun"
  $DRY_RUN && { log "DRY RUN: would create PipelineRun"; return 0; }

  # Resolve params (may already be exported from ensure_secrets)
  local docker_user="${DOCKER_USERNAME:-$(resolve_docker_username)}"
  local git_url="${GIT_REPO_URL:-$(resolve_git_url)}"
  local git_rev="${GIT_REVISION:-main}"

  [[ -n "$docker_user" ]] || die "Cannot resolve Docker username"
  [[ -n "$git_url" ]]     || die "Cannot resolve git URL"

  # Cosign gating
  if [[ "$COSIGN_SIGN_ENABLED" == "true" ]] && \
     ! secret_exists cosign-key "$NAMESPACE"; then
    die "COSIGN_SIGN_ENABLED=true but cosign-key secret is missing in $NAMESPACE — run security-init.sh first or set COSIGN_SIGN_ENABLED=false"
  fi

  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  local run_name="banking-ci-${ts}"
  local image_tag="${git_rev}-${ts}"

  log "creating PipelineRun: $run_name"
  log "  git:          $git_url @ $git_rev"
  log "  image:        $DOCKER_REPO:$image_tag"
  log "  cosign:       $COSIGN_SIGN_ENABLED"
  log "  argocd:       $ARGOCD_AUTO_DEPLOY ($ARGOCD_NAMESPACE/$ARGOCD_APP_NAME)"
  log "  int-tests:    $RUN_INTEGRATION_TESTS"

  kubectl -n "$NAMESPACE" create -f - <<EOF
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: ${run_name}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: dtb-banking-portal
    app.kubernetes.io/part-of: dtb-banking-portal
    triggered-by: tekton-init-script
spec:
  serviceAccountName: tekton-pipeline-sa
  timeouts:
    pipeline: 1h0m0s
    tasks:    55m0s
    finally:  5m0s
  pipelineRef:
    name: banking-ci-pipeline
  podTemplate:
    securityContext:
      fsGroup: 65532
  params:
    - name: git-url
      value: "${git_url}"
    - name: git-revision
      value: "${git_rev}"
    - name: image-repo
      value: "${DOCKER_REPO}"
    - name: image-tag
      value: "${image_tag}"
    - name: docker-username
      value: "${docker_user}"
    - name: run-integration-tests
      value: "${RUN_INTEGRATION_TESTS}"
    - name: trivy-fail-on-critical
      value: "${TRIVY_FAIL_ON_CRITICAL}"
    - name: cosign-sign-enabled
      value: "${COSIGN_SIGN_ENABLED}"
    - name: argocd-auto-deploy
      value: "${ARGOCD_AUTO_DEPLOY}"
    - name: argocd-namespace
      value: "${ARGOCD_NAMESPACE}"
    - name: argocd-app-name
      value: "${ARGOCD_APP_NAME}"
  workspaces:
    - name: pipeline-workspace
      volumeClaimTemplate:
        spec:
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 5Gi
    - name: docker-credentials
      secret:
        secretName: regcred
    - name: cosign-keys
      secret:
        secretName: cosign-key
EOF

  LAST_PIPELINERUN_NAME="$run_name"
  success "PipelineRun created: $run_name"

  echo ""
  echo -e "  ${BOLD}${GREEN}View in Dashboard:${NC}"
  echo -e "  ${CYAN}http://localhost:9097/#/namespaces/${NAMESPACE}/pipelineruns/${run_name}${NC}"
  echo ""
  echo -e "  ${BOLD}Follow logs:${NC}"
  echo -e "  ${CYAN}tkn pipelinerun logs ${run_name} -f -n ${NAMESPACE}${NC}"
  echo ""

  # Wait up to 30s for run to transition to Running
  local elapsed=0
  while (( elapsed < 30 )); do
    local reason
    reason=$(kubectl get pipelinerun "$run_name" -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || echo "Pending")
    case "$reason" in
      Running)
        success "PipelineRun is Running — watch it in the Dashboard"
        break ;;
      Failed|PipelineRunFailed|CouldntGetPipeline)
        warn "PipelineRun entered $reason state immediately:"
        kubectl -n "$NAMESPACE" describe pipelinerun "$run_name" 2>/dev/null | tail -20
        break ;;
    esac
    sleep 5; elapsed=$((elapsed + 5))
    log "status: $reason (${elapsed}s)..."
  done
}

# =============================================================================
# FINAL SUMMARY
# =============================================================================
print_summary() {
  section "Setup Complete"

  echo ""
  echo -e "  ${BOLD}Tekton Dashboard${NC}"
  echo -e "  ${CYAN}http://localhost:9097${NC}  →  Pipelines → banking-ci-pipeline"
  echo ""
  echo -e "  ${BOLD}Quick commands${NC}"
  echo  "    kubectl -n $NAMESPACE get pipelines,tasks,pipelineruns,eventlisteners"
  echo  "    kubectl -n $NAMESPACE get secret regcred docker-hub-params git-credentials cosign-key"
  echo  "    tkn pipeline list -n $NAMESPACE"
  echo  "    tkn pipelinerun list -n $NAMESPACE"
  if [[ -n "$LAST_PIPELINERUN_NAME" ]]; then
    echo  "    tkn pipelinerun logs $LAST_PIPELINERUN_NAME -f -n $NAMESPACE"
  fi
  echo ""
  echo -e "  ${BOLD}Trigger a new run${NC}"
  echo  "    RUN_PIPELINE_ON_SETUP=true ./scripts/k8s/tekton-init.sh --skip-install --skip-run=false"
  echo ""
  local el_ip
  el_ip=$(kubectl get svc el-banking-event-listener -n "$NAMESPACE" \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "<EventListener-IP>")
  echo -e "  ${BOLD}GitHub Webhook${NC}"
  echo  "    Payload URL: http://${el_ip}:8080/"
  echo  "    Content-Type: application/json"
  echo  "    Events: push, pull_request"
  echo ""
}

# =============================================================================
# MAIN
# =============================================================================
echo ""
echo -e "${BOLD}DTB Banking Portal — Tekton Pipeline Bootstrap${NC}"
echo -e "  namespace : $NAMESPACE"
echo -e "  repo      : ${ROOT_DIR}"
$DRY_RUN && echo -e "  ${YELLOW}DRY RUN — no cluster changes${NC}"
echo ""

log "starting setup (install_tekton=$INSTALL_TEKTON, dashboard=$INSTALL_DASHBOARD, triggers=$APPLY_TRIGGERS, run=$RUN_PIPELINE)"

preflight
ensure_namespaces

if [[ "$INSTALL_TEKTON" == "true" ]]; then
  install_tekton_components
else
  log "skipping Tekton install"
  configure_tekton_feature_flags
fi

ensure_secrets
apply_rbac
apply_workspaces
apply_tasks
apply_pipelines

if [[ "$APPLY_TRIGGERS" == "true" ]]; then
  apply_triggers
else
  log "skipping trigger manifests"
fi

verify_setup

if [[ "$INSTALL_DASHBOARD" == "true" ]]; then
  open_dashboard
fi

if [[ "$RUN_PIPELINE" == "true" ]]; then
  create_pipeline_run
else
  log "skipping PipelineRun (RUN_PIPELINE_ON_SETUP=false)"
fi

print_summary

echo -e "${GREEN}${BOLD}Tekton bootstrap complete!${NC}"
echo ""
