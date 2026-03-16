#!/usr/bin/env bash
# =============================================================================
# tekton-init.sh — Initialize and start the full Tekton CI/CD pipeline
#
# Runs end-to-end from a clean cluster to a live pipeline visible in the
# Tekton Dashboard. Run once after prerequisites.sh has completed.
#
# What it does:
#   1.  Preflight — verify minikube, kubectl, helm are ready
#   2.  Namespace — create banking + tekton namespaces
#   3.  Secrets — Docker Hub, GitHub, SonarQube, Cosign, Webhook
#   4.  RBAC — ServiceAccount + Roles for the pipeline SA
#   5.  Workspaces — shared PVC for pipeline runs
#   6.  Tasks — apply all 13 Tekton Task definitions
#   7.  Pipelines — apply CI and CD pipeline definitions
#   8.  Triggers — EventListener, TriggerBinding, TriggerTemplate
#   9.  Verify — wait for all Tekton controllers and EventListener pod
#  10.  Test run — fire a manual PipelineRun to smoke-test the setup
#  11.  Dashboard — open Tekton Dashboard with port-forward
#
# Usage:
#   ./scripts/k8s/tekton-init.sh [OPTIONS]
#
# Options:
#   --skip-secrets       Skip interactive secret prompts (use env vars only)
#   --skip-test-run      Skip the initial manual PipelineRun
#   --skip-dashboard     Skip opening the Tekton Dashboard port-forward
#   --dry-run            Print kubectl/helm commands without executing
#   --help               Show this help
#
# Required env vars (or will prompt interactively):
#   DOCKER_USERNAME      Docker Hub username
#   DOCKER_PASSWORD      Docker Hub password or access token
#   DOCKER_EMAIL         Docker Hub email (default: cicd@dtb.local)
#   GITHUB_TOKEN         GitHub personal access token (repo + write:packages)
#   GITHUB_REPO_URL      HTTPS URL of the GitHub repository
#   SONAR_TOKEN          SonarQube authentication token
#   WEBHOOK_SECRET       Secret string for GitHub webhook HMAC validation
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFESTS="$PROJECT_ROOT/manifests"

# =============================================================================
# COLOURS & LOGGING
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${MAGENTA}══ $* ══${NC}"; }
url()     { echo -e "  ${CYAN}$*${NC}"; }
die()     { error "$*"; exit 1; }

step() {
  local n="$1"; shift
  echo -e "\n${BOLD}${BLUE}[Step $n]${NC} $*"
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
SKIP_SECRETS=false
SKIP_TEST_RUN=false
SKIP_DASHBOARD=false
DRY_RUN=false

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-secrets)   SKIP_SECRETS=true ;;
      --skip-test-run)  SKIP_TEST_RUN=true ;;
      --skip-dashboard) SKIP_DASHBOARD=true ;;
      --dry-run)        DRY_RUN=true; warn "DRY RUN — no changes will be made" ;;
      --help|-h)
        sed -n '/^# Usage:/,/^# ======/p' "$0" | grep '^#' | sed 's/^# \?//'
        exit 0 ;;
      *) die "Unknown option: $1. Use --help for usage." ;;
    esac
    shift
  done
}

# Wrap kubectl/helm for dry-run mode
kube() { $DRY_RUN && { echo "  DRY RUN: kubectl $*"; return 0; }; kubectl "$@"; }
helmc() { $DRY_RUN && { echo "  DRY RUN: helm $*"; return 0; }; helm "$@"; }

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================
prompt_secret() {
  # prompt_secret VAR_NAME "prompt text"
  local var="$1" prompt="$2"
  if [[ -z "${!var:-}" ]]; then
    if [[ -t 0 ]]; then
      read -rsp "${prompt}: " tmp; echo ""
      export "$var"="$tmp"
    else
      die "$var is required. Set it as an env var or run interactively."
    fi
  fi
}

prompt_value() {
  local var="$1" prompt="$2" default="${3:-}"
  if [[ -z "${!var:-}" ]]; then
    if [[ -t 0 ]]; then
      read -rp "${prompt} [${default}]: " tmp
      export "$var"="${tmp:-$default}"
    else
      [[ -n "$default" ]] && export "$var"="$default" || die "$var is required."
    fi
  fi
}

secret_exists() {
  kubectl get secret "$1" -n "$2" &>/dev/null
}

apply_idempotent() {
  # Apply a file or directory; log what's being applied
  local target="$1"
  info "Applying: $(basename "$target")"
  $DRY_RUN && { echo "  DRY RUN: kubectl apply -f $target"; return 0; }
  kubectl apply -f "$target"
}

wait_for_deployment() {
  local ns="$1" name="$2" timeout="${3:-120}"
  info "Waiting for deployment/$name in $ns..."
  $DRY_RUN && return 0
  kubectl rollout status deployment/"$name" -n "$ns" --timeout="${timeout}s" \
    || { warn "$name not ready within ${timeout}s — check: kubectl get pods -n $ns"; return 1; }
  success "deployment/$name is ready"
}

wait_for_pod_label() {
  local ns="$1" selector="$2" timeout="${3:-120}"
  info "Waiting for pod ($selector) in $ns..."
  $DRY_RUN && return 0
  kubectl wait --for=condition=ready pod -l "$selector" -n "$ns" \
    --timeout="${timeout}s" 2>/dev/null \
    || { warn "Pod not ready within ${timeout}s — check: kubectl get pods -n $ns -l $selector"; return 1; }
  success "pod ($selector) ready"
}

# =============================================================================
# STEP 1 — PREFLIGHT CHECKS
# =============================================================================
preflight() {
  section "Preflight Checks"

  # minikube running
  local mk_status
  mk_status=$(minikube status --format='{{.Host}}' 2>/dev/null || echo "NotRunning")
  if [[ "$mk_status" != "Running" ]]; then
    warn "minikube is not running (status: $mk_status). Starting..."
    $DRY_RUN || minikube start \
      --driver=docker \
      --cpus=4 \
      --memory=8192 \
      --kubernetes-version=v1.32.3 \
      --addons=ingress,metrics-server,storage-provisioner
    success "minikube started"
  else
    success "minikube: Running"
  fi

  # kubectl connectivity
  $DRY_RUN || kubectl cluster-info --request-timeout=10s &>/dev/null \
    || die "kubectl cannot reach the cluster. Check minikube status."
  success "kubectl: connected to cluster"

  # Tekton Pipelines CRDs
  if ! kubectl get crd pipelines.tekton.dev &>/dev/null; then
    warn "Tekton Pipelines CRDs not found — installing now..."
    $DRY_RUN || kubectl apply -f \
      "https://storage.googleapis.com/tekton-releases/pipeline/previous/v0.68.0/release.yaml"
    wait_for_deployment tekton-pipelines tekton-pipelines-controller 180
    wait_for_deployment tekton-pipelines tekton-pipelines-webhook 120
  else
    success "Tekton Pipelines: CRDs present"
  fi

  # Tekton Triggers CRDs
  if ! kubectl get crd eventlisteners.triggers.tekton.dev &>/dev/null; then
    warn "Tekton Triggers CRDs not found — installing now..."
    local tbase="https://storage.googleapis.com/tekton-releases/triggers/previous/v0.30.0"
    $DRY_RUN || kubectl apply -f "${tbase}/release.yaml"
    $DRY_RUN || kubectl apply -f "${tbase}/interceptors.yaml"
    wait_for_deployment tekton-triggers tekton-triggers-controller 120
  else
    success "Tekton Triggers: CRDs present"
  fi

  # Tekton Dashboard
  if ! kubectl get deployment tekton-dashboard -n tekton-dashboard &>/dev/null; then
    warn "Tekton Dashboard not found — installing now..."
    $DRY_RUN || kubectl apply -f \
      "https://storage.googleapis.com/tekton-releases/dashboard/previous/v0.52.0/release.yaml"
    wait_for_deployment tekton-dashboard tekton-dashboard 120
  else
    success "Tekton Dashboard: installed"
  fi
}

# =============================================================================
# STEP 2 — NAMESPACES
# =============================================================================
create_namespaces() {
  section "Namespaces"
  local namespaces=(banking tekton-pipelines tekton-triggers tekton-dashboard)
  for ns in "${namespaces[@]}"; do
    if kubectl get namespace "$ns" &>/dev/null; then
      info "namespace/$ns already exists"
    else
      kube create namespace "$ns"
      success "Created namespace: $ns"
    fi
  done

  # Apply banking namespace manifest (adds labels)
  apply_idempotent "$MANIFESTS/k8s/namespace.yaml"
}

# =============================================================================
# STEP 3 — SECRETS
# =============================================================================
create_secrets() {
  section "Secrets"

  # ── Gather credentials ───────────────────────────────────────────────────
  prompt_value  DOCKER_USERNAME  "Docker Hub username"     ""
  prompt_secret DOCKER_PASSWORD  "Docker Hub password/token"
  prompt_value  DOCKER_EMAIL     "Docker Hub email"        "cicd@dtb.local"
  prompt_value  GITHUB_REPO_URL  "GitHub repo HTTPS URL"   ""
  prompt_secret GITHUB_TOKEN     "GitHub personal access token (repo scope)"
  prompt_secret SONAR_TOKEN      "SonarQube auth token"
  prompt_secret WEBHOOK_SECRET   "GitHub webhook secret (any random string)"

  local secret_namespaces=(tekton-pipelines banking)

  for ns in "${secret_namespaces[@]}"; do
    info "--- Secrets in namespace: $ns ---"

    # Docker Hub image pull secret (regcred)
    if secret_exists regcred "$ns"; then
      info "Secret regcred already exists in $ns"
    else
      $DRY_RUN && { info "DRY RUN: create regcred in $ns"; } || \
      kubectl create secret docker-registry regcred \
        --docker-server=https://index.docker.io/v1/ \
        --docker-username="$DOCKER_USERNAME" \
        --docker-password="$DOCKER_PASSWORD" \
        --docker-email="$DOCKER_EMAIL" \
        -n "$ns"
      success "Created regcred in $ns"
    fi
  done

  # Docker Hub username param (used in pipeline params)
  if secret_exists docker-hub-params tekton-pipelines; then
    info "Secret docker-hub-params already exists"
  else
    $DRY_RUN || kubectl create secret generic docker-hub-params \
      --from-literal=DOCKER_USERNAME="$DOCKER_USERNAME" \
      -n tekton-pipelines
    success "Created docker-hub-params"
  fi

  # GitHub token (git-clone + update-manifests push)
  if secret_exists git-credentials tekton-pipelines; then
    info "Secret git-credentials already exists"
  else
    $DRY_RUN || kubectl create secret generic git-credentials \
      --from-literal=GIT_TOKEN="$GITHUB_TOKEN" \
      -n tekton-pipelines
    success "Created git-credentials"
  fi

  # SonarQube token
  if secret_exists sonarqube-token tekton-pipelines; then
    info "Secret sonarqube-token already exists"
  else
    $DRY_RUN || kubectl create secret generic sonarqube-token \
      --from-literal=SONAR_TOKEN="$SONAR_TOKEN" \
      -n tekton-pipelines
    success "Created sonarqube-token"
  fi

  # GitHub webhook HMAC secret
  if secret_exists github-webhook-secret tekton-pipelines; then
    info "Secret github-webhook-secret already exists"
  else
    $DRY_RUN || kubectl create secret generic github-webhook-secret \
      --from-literal=webhook-secret="$WEBHOOK_SECRET" \
      -n tekton-pipelines
    success "Created github-webhook-secret"
  fi

  # Cosign key pair (generate if not present)
  if secret_exists cosign-key tekton-pipelines; then
    info "Secret cosign-key already exists"
  else
    if command -v cosign &>/dev/null; then
      info "Generating Cosign key pair..."
      $DRY_RUN || COSIGN_PASSWORD="" cosign generate-key-pair \
        k8s://tekton-pipelines/cosign-key
      success "Cosign key pair generated and stored as k8s secret"
    else
      warn "cosign not found — skipping key generation. Install cosign and re-run."
    fi
  fi
}

# =============================================================================
# STEP 4 — RBAC
# =============================================================================
apply_rbac() {
  section "RBAC"
  apply_idempotent "$MANIFESTS/tekton/rbac/serviceaccount.yaml"
  apply_idempotent "$MANIFESTS/tekton/rbac/rolebinding.yaml"

  # Patch the SA so it can pull images from Docker Hub
  $DRY_RUN || kubectl patch serviceaccount tekton-pipeline-sa \
    -n tekton-pipelines \
    --type='json' \
    -p='[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"regcred"}}]' \
    2>/dev/null || true

  success "RBAC configured"
}

# =============================================================================
# STEP 5 — WORKSPACES (PVC)
# =============================================================================
apply_workspaces() {
  section "Workspaces"
  apply_idempotent "$MANIFESTS/tekton/workspaces/pvc.yaml"

  # Verify PVC is bound (may take a few seconds on minikube)
  info "Waiting for PVC to bind..."
  local elapsed=0
  $DRY_RUN && { success "PVC ready (dry run)"; return 0; }
  while [[ $elapsed -lt 60 ]]; do
    local pvc_status
    pvc_status=$(kubectl get pvc pipeline-workspace-pvc -n tekton-pipelines \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    if [[ "$pvc_status" == "Bound" ]]; then
      success "PVC pipeline-workspace-pvc is Bound"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    info "PVC status: $pvc_status — waiting..."
  done
  warn "PVC not Bound after 60s. Check: kubectl get pvc -n tekton-pipelines"
}

# =============================================================================
# STEP 6 — TASKS
# =============================================================================
apply_tasks() {
  section "Tekton Tasks"

  # Apply in dependency order — git-clone and generate-tag first as they
  # are referenced as the first steps in the pipeline
  local task_order=(
    git-clone
    generate-tag
    lint-sast
    sonarqube-scan
    test-backend
    test-frontend
    npm-integration-test
    kaniko
    trivy-scan
    cosign-sign
    update-manifests
    smoke-test
    build-push        # composite task kept for backwards compat
  )

  for task in "${task_order[@]}"; do
    local file="$MANIFESTS/tekton/tasks/${task}.yaml"
    if [[ -f "$file" ]]; then
      apply_idempotent "$file"
    else
      warn "Task file not found: $file (skipping)"
    fi
  done

  # Verify tasks are registered
  $DRY_RUN && return 0
  local task_count
  task_count=$(kubectl get tasks -n tekton-pipelines --no-headers 2>/dev/null | wc -l | tr -d ' ')
  success "$task_count Task(s) registered in tekton-pipelines"
}

# =============================================================================
# STEP 7 — PIPELINES
# =============================================================================
apply_pipelines() {
  section "Tekton Pipelines"
  apply_idempotent "$MANIFESTS/tekton/pipelines/ci-pipeline.yaml"
  apply_idempotent "$MANIFESTS/tekton/pipelines/cd-pipeline.yaml"

  $DRY_RUN && return 0
  local pipeline_count
  pipeline_count=$(kubectl get pipelines -n tekton-pipelines --no-headers 2>/dev/null | wc -l | tr -d ' ')
  success "$pipeline_count Pipeline(s) registered"
}

# =============================================================================
# STEP 8 — TRIGGERS
# =============================================================================
apply_triggers() {
  section "Tekton Triggers"
  apply_idempotent "$MANIFESTS/tekton/triggers/trigger-binding.yaml"
  apply_idempotent "$MANIFESTS/tekton/triggers/trigger-template.yaml"
  apply_idempotent "$MANIFESTS/tekton/triggers/event-listener.yaml"

  # Wait for the EventListener pod to be ready
  info "Waiting for EventListener pod..."
  $DRY_RUN && { success "EventListener ready (dry run)"; return 0; }
  local elapsed=0
  while [[ $elapsed -lt 90 ]]; do
    if kubectl get pod -n tekton-pipelines \
        -l eventlistener=banking-event-listener \
        --no-headers 2>/dev/null | grep -q "Running"; then
      success "EventListener pod is Running"
      return 0
    fi
    sleep 5; elapsed=$((elapsed + 5))
    info "Waiting for EventListener... (${elapsed}s)"
  done

  # Fallback: check the service exists
  if kubectl get svc el-banking-event-listener -n tekton-pipelines &>/dev/null; then
    success "EventListener service is up (pod may still be starting)"
  else
    warn "EventListener may not be ready — check: kubectl get pods -n tekton-pipelines"
  fi
}

# =============================================================================
# STEP 9 — VERIFY EVERYTHING
# =============================================================================
verify_setup() {
  section "Verification"
  $DRY_RUN && { success "Skipping verification (dry run)"; return 0; }

  local all_ok=true

  echo ""
  echo -e "  ${BOLD}Tekton controllers:${NC}"
  for deploy in tekton-pipelines-controller tekton-pipelines-webhook; do
    if kubectl get deployment "$deploy" -n tekton-pipelines &>/dev/null; then
      local ready
      ready=$(kubectl get deployment "$deploy" -n tekton-pipelines \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
      if [[ "${ready:-0}" -gt 0 ]]; then
        echo -e "    ${GREEN}✔${NC} $deploy (${ready} ready)"
      else
        echo -e "    ${RED}✘${NC} $deploy (not ready)"
        all_ok=false
      fi
    fi
  done

  echo ""
  echo -e "  ${BOLD}Registered resources:${NC}"
  local task_count pipeline_count tb_count tt_count el_count
  task_count=$(kubectl get tasks -n tekton-pipelines --no-headers 2>/dev/null | wc -l | tr -d ' ')
  pipeline_count=$(kubectl get pipelines -n tekton-pipelines --no-headers 2>/dev/null | wc -l | tr -d ' ')
  tb_count=$(kubectl get triggerbindings -n tekton-pipelines --no-headers 2>/dev/null | wc -l | tr -d ' ')
  tt_count=$(kubectl get triggertemplates -n tekton-pipelines --no-headers 2>/dev/null | wc -l | tr -d ' ')
  el_count=$(kubectl get eventlisteners -n tekton-pipelines --no-headers 2>/dev/null | wc -l | tr -d ' ')

  echo -e "    Tasks:              ${task_count}"
  echo -e "    Pipelines:          ${pipeline_count}"
  echo -e "    TriggerBindings:    ${tb_count}"
  echo -e "    TriggerTemplates:   ${tt_count}"
  echo -e "    EventListeners:     ${el_count}"

  echo ""
  echo -e "  ${BOLD}Secrets:${NC}"
  local secrets=(regcred docker-hub-params git-credentials sonarqube-token github-webhook-secret)
  for s in "${secrets[@]}"; do
    if secret_exists "$s" tekton-pipelines; then
      echo -e "    ${GREEN}✔${NC} $s"
    else
      echo -e "    ${RED}✘${NC} $s (missing)"
      all_ok=false
    fi
  done

  echo ""
  if $all_ok; then
    success "All checks passed — pipeline is ready"
  else
    warn "Some checks failed — review the items marked ✘ above"
  fi
}

# =============================================================================
# STEP 10 — MANUAL TEST PIPELINERUN
# =============================================================================
trigger_test_run() {
  section "Initial Test PipelineRun"
  $DRY_RUN && { info "DRY RUN: would create a PipelineRun"; return 0; }

  local git_url="${GITHUB_REPO_URL:-}"
  local docker_user="${DOCKER_USERNAME:-}"

  if [[ -z "$git_url" || -z "$docker_user" ]]; then
    warn "Skipping test run — GITHUB_REPO_URL or DOCKER_USERNAME not set"
    return 0
  fi

  local run_name="banking-ci-init-$(date +%Y%m%d-%H%M%S)"

  info "Creating PipelineRun: $run_name"
  kubectl create -f - <<EOF
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: ${run_name}
  namespace: tekton-pipelines
  labels:
    app.kubernetes.io/part-of: dtb-banking-portal
    triggered-by: tekton-init-script
spec:
  pipelineRef:
    name: banking-ci-pipeline
  serviceAccountName: tekton-pipeline-sa
  params:
    - name: git-url
      value: "${git_url}"
    - name: git-revision
      value: "main"
    - name: image-tag
      value: "init-$(date +%Y%m%d-%H%M%S)"
    - name: docker-username
      value: "${docker_user}"
    - name: sonar-token
      value: "${SONAR_TOKEN:-placeholder}"
  workspaces:
    - name: pipeline-workspace
      persistentVolumeClaim:
        claimName: pipeline-workspace-pvc
    - name: docker-credentials
      secret:
        secretName: regcred
  timeouts:
    pipeline: "1h0m0s"
    tasks: "45m0s"
EOF

  success "PipelineRun $run_name created"
  info "Watch progress:"
  echo ""
  echo -e "  ${CYAN}tkn pipelinerun logs $run_name -f -n tekton-pipelines${NC}"
  echo -e "  ${CYAN}tkn pipelinerun describe $run_name -n tekton-pipelines${NC}"
  echo ""
}

# =============================================================================
# STEP 11 — TEKTON DASHBOARD
# =============================================================================
open_dashboard() {
  section "Tekton Dashboard"

  $DRY_RUN && { info "DRY RUN: would port-forward Tekton Dashboard on :9097"; return 0; }

  # Check if already port-forwarded
  if lsof -i :9097 &>/dev/null 2>&1; then
    success "Port 9097 already in use — Dashboard is likely already forwarded"
    url "http://localhost:9097"
    return 0
  fi

  info "Starting port-forward for Tekton Dashboard on http://localhost:9097 ..."
  info "(Running in background — kill with: pkill -f 'port-forward.*tekton-dashboard')"
  echo ""

  kubectl port-forward svc/tekton-dashboard \
    -n tekton-dashboard 9097:9097 &>/tmp/tekton-dashboard-pf.log &
  local pf_pid=$!

  # Give it 3 seconds to bind
  sleep 3
  if kill -0 "$pf_pid" 2>/dev/null; then
    success "Tekton Dashboard port-forward running (PID $pf_pid)"
    url "  http://localhost:9097"
  else
    warn "Port-forward failed — start manually:"
    echo -e "  ${CYAN}kubectl port-forward svc/tekton-dashboard -n tekton-dashboard 9097:9097 &${NC}"
  fi
}

# =============================================================================
# FINAL SUMMARY
# =============================================================================
print_final_summary() {
  section "Setup Complete — Quick Reference"

  echo ""
  echo -e "  ${BOLD}Tekton Dashboard${NC}"
  url "    http://localhost:9097"
  echo  "    → Pipelines → banking-ci-pipeline to see your runs"
  echo ""
  echo -e "  ${BOLD}CLI commands${NC}"
  echo  "    tkn pipeline list -n tekton-pipelines"
  echo  "    tkn pipelinerun list -n tekton-pipelines"
  echo  "    tkn pipelinerun logs <run-name> -f -n tekton-pipelines"
  echo ""
  echo -e "  ${BOLD}Trigger a new run manually${NC}"
  echo  "    kubectl create -f - <<EOF"
  echo  "    apiVersion: tekton.dev/v1"
  echo  "    kind: PipelineRun"
  echo  "    metadata:"
  echo  "      generateName: banking-ci-manual-"
  echo  "      namespace: tekton-pipelines"
  echo  "    spec:"
  echo  "      pipelineRef:"
  echo  "        name: banking-ci-pipeline"
  echo  "      serviceAccountName: tekton-pipeline-sa"
  echo  "      params:"
  echo  "        - name: git-url"
  echo  "          value: \"${GITHUB_REPO_URL:-https://github.com/YOUR_ORG/DTB-tets.git}\""
  echo  "        - name: git-revision"
  echo  "          value: main"
  echo  "        - name: image-tag"
  echo  "          value: \$(date +%Y%m%d-%H%M%S)"
  echo  "        - name: docker-username"
  echo  "          value: \"${DOCKER_USERNAME:-YOUR_DOCKER_USERNAME}\""
  echo  "        - name: sonar-token"
  echo  "          value: \"\${SONAR_TOKEN}\""
  echo  "      workspaces:"
  echo  "        - name: pipeline-workspace"
  echo  "          persistentVolumeClaim:"
  echo  "            claimName: pipeline-workspace-pvc"
  echo  "        - name: docker-credentials"
  echo  "          secret:"
  echo  "            secretName: regcred"
  echo  "    EOF"
  echo ""
  echo -e "  ${BOLD}GitHub Webhook (configure in repo Settings → Webhooks)${NC}"
  local el_ip
  el_ip=$(kubectl get svc el-banking-event-listener -n tekton-pipelines \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "<EventListener-IP>")
  echo  "    Payload URL:  http://${el_ip}:8080/"
  echo  "    Content-Type: application/json"
  echo  "    Secret:       value of WEBHOOK_SECRET"
  echo  "    Events:       push, pull_request"
  echo ""
  echo -e "  ${BOLD}Useful debugging${NC}"
  echo  "    kubectl get pods -n tekton-pipelines"
  echo  "    kubectl get tasks,pipelines,eventlisteners -n tekton-pipelines"
  echo  "    kubectl get pvc -n tekton-pipelines"
  echo  "    kubectl describe eventlistener banking-event-listener -n tekton-pipelines"
  echo ""
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  parse_args "$@"

  echo ""
  echo -e "${BOLD}DTB Banking Portal — Tekton Pipeline Initialisation${NC}"
  echo -e "Repository root: $PROJECT_ROOT"
  $DRY_RUN && echo -e "${YELLOW}DRY RUN MODE — no changes will be made${NC}"
  echo ""

  step 1  "Preflight checks"
  preflight

  step 2  "Namespaces"
  create_namespaces

  step 3  "Secrets"
  if $SKIP_SECRETS; then
    info "Skipping secret prompts (--skip-secrets)"
    warn "Ensure all required secrets exist in tekton-pipelines namespace before running a pipeline"
  else
    create_secrets
  fi

  step 4  "RBAC"
  apply_rbac

  step 5  "Workspaces (PVC)"
  apply_workspaces

  step 6  "Tasks (13 task definitions)"
  apply_tasks

  step 7  "Pipelines (CI + CD)"
  apply_pipelines

  step 8  "Triggers (EventListener, Bindings, Templates)"
  apply_triggers

  step 9  "Verification"
  verify_setup

  step 10 "Initial PipelineRun"
  if $SKIP_TEST_RUN; then
    info "Skipping test run (--skip-test-run)"
  else
    trigger_test_run
  fi

  step 11 "Tekton Dashboard"
  if $SKIP_DASHBOARD; then
    info "Skipping Dashboard port-forward (--skip-dashboard)"
    info "Start manually: kubectl port-forward svc/tekton-dashboard -n tekton-dashboard 9097:9097 &"
  else
    open_dashboard
  fi

  print_final_summary

  echo -e "${GREEN}${BOLD}Tekton pipeline initialisation complete!${NC}"
  echo ""
}

main "$@"
