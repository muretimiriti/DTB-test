#!/usr/bin/env bash
# =============================================================================
# prerequisites.sh - Install and configure the full CI/CD pipeline stack
#
# Sets up everything needed to run the DTB Banking Portal pipeline:
#   CI:          Tekton Pipelines, Triggers, Dashboard + tkn CLI
#   Registry:    Docker Hub credentials
#   Security:    Trivy, SonarQube, Kyverno, Cosign, Vault, ESO, Conftest
#   Deploy:      ArgoCD + argocd CLI
#   Observability: Prometheus, Grafana, Loki, OpenTelemetry Collector
#   Infra:       Minikube, kubectl, Helm
#
# Usage:
#   ./scripts/prerequisites.sh [OPTIONS]
#
# Options:
#   --skip-minikube       Skip Minikube start/configure
#   --skip-tekton         Skip Tekton Pipelines/Triggers/Dashboard/tkn
#   --skip-security       Skip Trivy, SonarQube, Kyverno, Cosign, Vault, ESO, Conftest
#   --skip-argocd         Skip ArgoCD install
#   --skip-observability  Skip Prometheus, Grafana, Loki, OTel
#   --dry-run             Print what would be done without executing
#   --help                Show this help message
#
# Environment variables (optional — script will prompt if not set):
#   DOCKER_USERNAME       Docker Hub username
#   DOCKER_PASSWORD       Docker Hub password or access token
#   DOCKER_EMAIL          Docker Hub email (default: cicd@dtb.local)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SCRIPT_DATE="2026-03-16"

# =============================================================================
# VERSION PINS — edit here to upgrade components
# =============================================================================
TEKTON_PIPELINES_VERSION="v0.68.0"
TEKTON_TRIGGERS_VERSION="v0.30.0"
TEKTON_DASHBOARD_VERSION="v0.52.0"
TKN_CLI_VERSION="v0.40.0"
ARGOCD_VERSION="v2.14.6"
TRIVY_VERSION="0.63.0"      # used for apt repo (no leading v)
CONFTEST_VERSION="0.58.0"   # used for binary download (no leading v)
MINIKUBE_VERSION="v1.38.1"
MINIKUBE_CPUS=4
MINIKUBE_MEMORY="8192"
MINIKUBE_DISK="40g"
MINIKUBE_K8S_VERSION="v1.32.3"

# Helm chart versions — pinned as of ${SCRIPT_DATE}
CHART_PROMETHEUS="69.8.2"     # kube-prometheus-stack (Prometheus 3 + Grafana 11)
CHART_LOKI="2.10.2"           # loki-stack (Loki 2 + Promtail)
CHART_OTEL="0.119.0"          # opentelemetry-collector
CHART_SONARQUBE="10.8.0"      # sonarqube (Community Edition)
CHART_KYVERNO="3.4.4"         # kyverno
CHART_VAULT="0.30.0"          # vault (HashiCorp)
CHART_ESO="0.14.1"            # external-secrets operator

# =============================================================================
# COLOURS & LOGGING — matches existing script conventions
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

# =============================================================================
# ARGUMENT PARSING & GLOBAL STATE
# =============================================================================
SKIP_MINIKUBE=false
SKIP_TEKTON=false
SKIP_SECURITY=false
SKIP_ARGOCD=false
SKIP_OBSERVABILITY=false
DRY_RUN=false

INSTALLED=()
SKIPPED=()
FAILED=()

print_usage() {
  echo ""
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --skip-minikube       Skip Minikube start/configure"
  echo "  --skip-tekton         Skip Tekton (Pipelines, Triggers, Dashboard, tkn)"
  echo "  --skip-security       Skip security tools (Trivy, SonarQube, Kyverno, Cosign, Vault, ESO, Conftest)"
  echo "  --skip-argocd         Skip ArgoCD install"
  echo "  --skip-observability  Skip observability stack (Prometheus, Grafana, Loki, OTel)"
  echo "  --dry-run             Print actions without executing"
  echo "  --help                Show this help"
  echo ""
  echo "Environment variables:"
  echo "  DOCKER_USERNAME       Docker Hub username"
  echo "  DOCKER_PASSWORD       Docker Hub password/token"
  echo "  DOCKER_EMAIL          Docker Hub email (default: cicd@dtb.local)"
  echo ""
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-minikube)      SKIP_MINIKUBE=true ;;
      --skip-tekton)        SKIP_TEKTON=true ;;
      --skip-security)      SKIP_SECURITY=true ;;
      --skip-argocd)        SKIP_ARGOCD=true ;;
      --skip-observability) SKIP_OBSERVABILITY=true ;;
      --dry-run)            DRY_RUN=true; warn "DRY RUN mode — no changes will be made" ;;
      --help|-h)            print_usage; exit 0 ;;
      *) die "Unknown option: $1. Run with --help for usage." ;;
    esac
    shift
  done
}

# =============================================================================
# CORE UTILITY FUNCTIONS
# =============================================================================

check_command() { command -v "$1" &>/dev/null; }

record_installed() { INSTALLED+=("$1"); }
record_skipped()   { SKIPPED+=("$1"); }
record_failed()    { FAILED+=("$1"); }

# dry_run_gate: if DRY_RUN, print what would happen and return 1 (callers: || return 0)
dry_run_gate() {
  if $DRY_RUN; then
    info "DRY RUN: would $*"
    return 1
  fi
  return 0
}

install_apt_package() {
  local pkg="$1"
  if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
    info "$pkg already installed, skipping"
    record_skipped "$pkg"
    return 0
  fi
  dry_run_gate "install apt package: $pkg" || { record_skipped "$pkg"; return 0; }
  sudo apt-get install -y "$pkg"
  record_installed "$pkg"
}

# install_binary: idempotent binary installer from URL
# Supports plain binaries and .tar.gz archives (extracts the named binary)
# Args: name url [dest=/usr/local/bin] [is_archive=false] [archive_entry=name]
install_binary() {
  local name="$1"
  local url="$2"
  local dest="${3:-/usr/local/bin}"
  local is_archive="${4:-false}"
  local archive_entry="${5:-$name}"

  if check_command "$name"; then
    info "$name already installed ($(command -v "$name")), skipping"
    record_skipped "$name"
    return 0
  fi

  dry_run_gate "install $name from $url" || { record_skipped "$name"; return 0; }

  local tmp
  tmp=$(mktemp -d)
  trap "rm -rf $tmp" RETURN

  if $is_archive; then
    info "Downloading $name archive..."
    curl -fsSL "$url" -o "$tmp/$name.tar.gz"
    tar -xzf "$tmp/$name.tar.gz" -C "$tmp" "$archive_entry" 2>/dev/null \
      || tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
    sudo install "$tmp/$archive_entry" "$dest/$name"
  else
    info "Downloading $name binary..."
    curl -fsSL "$url" -o "$tmp/$name"
    sudo install "$tmp/$name" "$dest/$name"
  fi

  success "$name installed to $dest/$name"
  record_installed "$name"
}

wait_for_deployment() {
  local ns="$1" name="$2" timeout="${3:-120}"
  info "Waiting for deployment/$name in namespace $ns (timeout: ${timeout}s)..."
  if ! kubectl rollout status deployment/"$name" -n "$ns" --timeout="${timeout}s"; then
    warn "Deployment $name in $ns did not become ready within ${timeout}s"
    return 1
  fi
  success "deployment/$name is ready"
}

wait_for_statefulset() {
  local ns="$1" name="$2" timeout="${3:-120}"
  info "Waiting for statefulset/$name in namespace $ns (timeout: ${timeout}s)..."
  if ! kubectl rollout status statefulset/"$name" -n "$ns" --timeout="${timeout}s"; then
    warn "StatefulSet $name in $ns did not become ready within ${timeout}s"
    return 1
  fi
  success "statefulset/$name is ready"
}

wait_for_pods() {
  local ns="$1" selector="$2" timeout="${3:-120}"
  info "Waiting for pods ($selector) in namespace $ns (timeout: ${timeout}s)..."
  if ! kubectl wait --for=condition=ready pod -l "$selector" -n "$ns" \
      --timeout="${timeout}s" 2>/dev/null; then
    warn "Pods with selector '$selector' in $ns did not become ready within ${timeout}s"
    return 1
  fi
  success "pods ($selector) in $ns are ready"
}

# helm_install_or_upgrade: idempotent Helm release management
# If release exists: upgrade (reuse values); otherwise: install
helm_install_or_upgrade() {
  local release="$1" chart="$2" ns="$3" version="$4"
  shift 4
  local extra_args=("$@")

  dry_run_gate "helm install/upgrade $release ($chart) in $ns" || {
    record_skipped "$release"
    return 0
  }

  if helm status "$release" -n "$ns" &>/dev/null; then
    info "$release already installed in $ns, upgrading if needed..."
    helm upgrade "$release" "$chart" -n "$ns" \
      --version "$version" \
      --reuse-values \
      "${extra_args[@]}" 2>/dev/null \
      || info "$release already at target version, no upgrade needed"
    record_skipped "$release"
  else
    info "Installing $release ($chart v$version) in namespace $ns..."
    helm install "$release" "$chart" \
      -n "$ns" \
      --version "$version" \
      --create-namespace \
      --wait \
      "${extra_args[@]}"
    success "$release installed"
    record_installed "$release"
  fi
}

create_namespace_if_absent() {
  local ns="$1"
  if kubectl get namespace "$ns" &>/dev/null; then
    return 0
  fi
  dry_run_gate "create namespace $ns" || return 0
  kubectl create namespace "$ns"
  info "Created namespace: $ns"
}

# =============================================================================
# ERROR TRAP
# =============================================================================
ARGOCD_PASSWORD=""   # populated in setup_argocd, used in print_summary

on_error() {
  local line="$1"
  error "Script failed at line $line"
  print_summary
  exit 1
}
trap 'on_error $LINENO' ERR

# =============================================================================
# FINAL SUMMARY
# =============================================================================
print_summary() {
  section "Installation Summary"

  if [[ ${#INSTALLED[@]} -gt 0 ]]; then
    echo -e "  ${GREEN}Installed${NC}  (${#INSTALLED[@]}): ${INSTALLED[*]}"
  fi
  if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo -e "  ${BLUE}Skipped${NC}    (${#SKIPPED[@]}): ${SKIPPED[*]}"
  fi
  if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo -e "  ${RED}FAILED${NC}     (${#FAILED[@]}): ${FAILED[*]}"
  fi

  section "Access URLs  (use kubectl port-forward to access)"

  echo ""
  echo -e "  ${BOLD}ArgoCD${NC}"
  url "    kubectl port-forward svc/argocd-server -n argocd 8080:443 &"
  url "    https://localhost:8080"
  if [[ -n "$ARGOCD_PASSWORD" ]]; then
    echo  "    Username: admin  |  Password: $ARGOCD_PASSWORD"
  else
    echo  "    Username: admin  |  Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
  fi

  echo ""
  echo -e "  ${BOLD}Tekton Dashboard${NC}"
  url "    kubectl port-forward svc/tekton-dashboard -n tekton-dashboard 9097:9097 &"
  url "    http://localhost:9097"

  echo ""
  echo -e "  ${BOLD}SonarQube${NC}"
  url "    kubectl port-forward svc/sonarqube-sonarqube -n sonarqube 9000:9000 &"
  url "    http://localhost:9000"
  echo  "    Username: admin  |  Password: admin  (change on first login)"

  echo ""
  echo -e "  ${BOLD}Grafana${NC}"
  url "    kubectl port-forward svc/prometheus-grafana -n monitoring 3001:80 &"
  url "    http://localhost:3001"
  echo  "    Username: admin  |  Password: admin123"

  echo ""
  echo -e "  ${BOLD}Vault UI${NC}"
  url "    kubectl port-forward svc/vault -n vault 8200:8200 &"
  url "    http://localhost:8200"
  echo  "    Token: root  (DEV MODE — in-memory only)"

  echo ""
  echo -e "  ${BOLD}Prometheus${NC}"
  url "    kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090 &"
  url "    http://localhost:9090"

  echo ""
  echo -e "  ${BOLD}Quick CLI checks${NC}"
  echo  "    tkn pipeline list -n tekton-pipelines"
  echo  "    argocd login localhost:8080 --username admin --password \$ARGOCD_PASSWORD --insecure"
  echo  "    trivy --version && cosign version && conftest --version"
  echo  "    kubectl get pods -A"
  echo ""
}

# =============================================================================
# PHASE 1: PREFLIGHT CHECKS
# =============================================================================
run_preflight() {
  section "Preflight Checks"

  # OS check
  if [[ "$(uname -s)" != "Linux" ]]; then
    die "This script requires Linux. Detected: $(uname -s)"
  fi
  success "OS: Linux"

  # sudo access
  if sudo -n true 2>/dev/null; then
    success "sudo: passwordless access available"
  elif sudo -v 2>/dev/null; then
    success "sudo: access available (may prompt for password during install)"
  else
    die "sudo access is required to install system packages"
  fi

  # Internet connectivity
  if curl -sf --max-time 10 https://github.com >/dev/null; then
    success "Internet: reachable"
  else
    die "Internet access is required. Cannot reach https://github.com"
  fi

  # Disk space (require ≥20GB free on /)
  local free_gb
  free_gb=$(df -BG / | awk 'NR==2{print $4}' | tr -d 'G')
  if [[ "$free_gb" -lt 20 ]]; then
    die "Insufficient disk space: ${free_gb}GB free on /. At least 20GB required."
  fi
  success "Disk: ${free_gb}GB free"

  # RAM (require ≥10GB total)
  local total_mb
  total_mb=$(free -m | awk '/^Mem:/{print $2}')
  if [[ "$total_mb" -lt 10240 ]]; then
    warn "Total RAM: ${total_mb}MB. Recommended: 10240MB+. SonarQube and minikube may struggle."
  else
    success "RAM: ${total_mb}MB total"
  fi

  # Docker daemon
  if ! docker info &>/dev/null; then
    die "Docker daemon is not running. Start it with: sudo systemctl start docker"
  fi
  success "Docker: daemon is running"
}

# =============================================================================
# PHASE 2: SYSTEM UTILITIES
# =============================================================================
install_system_utilities() {
  section "System Utilities"
  sudo apt-get update -qq
  local pkgs=(curl wget git jq apt-transport-https ca-certificates gnupg lsb-release)
  for pkg in "${pkgs[@]}"; do
    install_apt_package "$pkg"
  done
}

# =============================================================================
# PHASE 3: DOCKER
# =============================================================================
setup_docker() {
  section "Docker"

  # Install Docker if missing
  if check_command docker; then
    local ver
    ver=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
    info "Docker already installed: $ver"
    record_skipped "docker"
  else
    dry_run_gate "install Docker via get.docker.com" || { record_skipped "docker"; }
    if ! $DRY_RUN; then
      curl -fsSL https://get.docker.com | sh
      record_installed "docker"
    fi
  fi

  # Check docker group membership (required for minikube --driver=docker)
  if ! groups "$USER" | grep -qw docker; then
    warn "User '$USER' is not in the docker group."
    dry_run_gate "add $USER to docker group" || return 0
    sudo usermod -aG docker "$USER"
    die "Added '$USER' to the docker group. You must log out and back in (or run 'newgrp docker') for this to take effect. Then re-run this script."
  fi
  success "Docker group: $USER is a member"

  # Install Docker Compose plugin if missing
  if docker compose version &>/dev/null 2>&1; then
    local compose_ver
    compose_ver=$(docker compose version --short 2>/dev/null || echo "unknown")
    info "Docker Compose plugin already installed: $compose_ver"
    record_skipped "docker-compose"
  else
    dry_run_gate "install Docker Compose v2 plugin" || { record_skipped "docker-compose"; return 0; }
    mkdir -p ~/.docker/cli-plugins
    local compose_url="https://github.com/docker/compose/releases/download/v2.36.0/docker-compose-linux-x86_64"
    curl -fsSL "$compose_url" -o ~/.docker/cli-plugins/docker-compose
    chmod +x ~/.docker/cli-plugins/docker-compose
    success "Docker Compose plugin installed"
    record_installed "docker-compose"
  fi
}

# =============================================================================
# PHASE 4: MINIKUBE
# =============================================================================
setup_minikube() {
  section "Minikube"

  # Install minikube binary if missing
  if check_command minikube; then
    local ver
    ver=$(minikube version --short 2>/dev/null | tr -d 'v')
    info "minikube already installed: v$ver"
    record_skipped "minikube"
  else
    dry_run_gate "install minikube $MINIKUBE_VERSION" || { record_skipped "minikube"; }
    if ! $DRY_RUN; then
      local url="https://storage.googleapis.com/minikube/releases/${MINIKUBE_VERSION}/minikube-linux-amd64"
      curl -fsSL "$url" -o /tmp/minikube
      sudo install /tmp/minikube /usr/local/bin/minikube
      rm /tmp/minikube
      success "minikube installed"
      record_installed "minikube"
    fi
  fi

  # Start minikube if not already running
  local mk_status
  mk_status=$(minikube status --format='{{.Host}}' 2>/dev/null || echo "NotRunning")

  if [[ "$mk_status" == "Running" ]]; then
    success "minikube is already running"
  else
    info "minikube status: $mk_status — starting cluster..."
    dry_run_gate "start minikube (${MINIKUBE_CPUS} CPUs, ${MINIKUBE_MEMORY}MB RAM, ${MINIKUBE_DISK} disk)" || return 0
    minikube start \
      --driver=docker \
      --cpus="$MINIKUBE_CPUS" \
      --memory="$MINIKUBE_MEMORY" \
      --disk-size="$MINIKUBE_DISK" \
      --kubernetes-version="$MINIKUBE_K8S_VERSION" \
      --addons=ingress,metrics-server,storage-provisioner
    success "minikube started"
  fi

  # Ensure required addons are enabled (idempotent)
  for addon in ingress metrics-server storage-provisioner; do
    dry_run_gate "enable minikube addon: $addon" || continue
    minikube addons enable "$addon" 2>/dev/null || true
  done
  success "minikube addons: ingress, metrics-server, storage-provisioner enabled"

  # Wait for coredns to be ready
  wait_for_deployment kube-system coredns 120 || warn "coredns took longer than expected"
}

# =============================================================================
# PHASE 5: KUBECTL
# =============================================================================
setup_kubectl() {
  section "kubectl"

  if check_command kubectl; then
    local ver
    ver=$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)
    info "kubectl already installed: $ver"
    record_skipped "kubectl"
  else
    dry_run_gate "install kubectl" || { record_skipped "kubectl"; return 0; }
    local k8s_ver
    k8s_ver=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
    curl -fsSL "https://dl.k8s.io/release/${k8s_ver}/bin/linux/amd64/kubectl" -o /tmp/kubectl
    sudo install /tmp/kubectl /usr/local/bin/kubectl
    rm /tmp/kubectl
    success "kubectl installed"
    record_installed "kubectl"
  fi

  # Verify connection to cluster
  if kubectl cluster-info --request-timeout=10s &>/dev/null; then
    success "kubectl: connected to cluster"
  else
    warn "kubectl cannot reach cluster — minikube may still be starting"
  fi
}

# =============================================================================
# PHASE 6: HELM + REPOS
# =============================================================================
setup_helm() {
  section "Helm"

  if check_command helm; then
    local ver
    ver=$(helm version --short 2>/dev/null)
    info "Helm already installed: $ver"
    record_skipped "helm"
  else
    dry_run_gate "install Helm v3" || { record_skipped "helm"; return 0; }
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    success "Helm installed"
    record_installed "helm"
  fi

  dry_run_gate "add/update Helm repositories" || return 0

  info "Adding Helm repositories..."
  # Add repos — 2>/dev/null suppresses "already exists" warnings; || true prevents exit on duplicate
  declare -A HELM_REPOS=(
    ["prometheus-community"]="https://prometheus-community.github.io/helm-charts"
    ["grafana"]="https://grafana.github.io/helm-charts"
    ["hashicorp"]="https://helm.releases.hashicorp.com"
    ["external-secrets"]="https://charts.external-secrets.io"
    ["kyverno"]="https://kyverno.github.io/kyverno/"
    ["sonarqube"]="https://SonarSource.github.io/helm-chart-sonarqube"
    ["open-telemetry"]="https://open-telemetry.github.io/opentelemetry-helm-charts"
    ["argo"]="https://argoproj.github.io/argo-helm"
  )

  for repo_name in "${!HELM_REPOS[@]}"; do
    helm repo add "$repo_name" "${HELM_REPOS[$repo_name]}" 2>/dev/null || true
  done

  info "Updating Helm repo cache..."
  helm repo update
  success "Helm repos configured and updated"
}

# =============================================================================
# PHASE 7: KUBERNETES NAMESPACES
# =============================================================================
create_namespaces() {
  section "Kubernetes Namespaces"
  dry_run_gate "create all required namespaces" || return 0

  local namespaces=(
    tekton-pipelines
    tekton-triggers
    tekton-dashboard
    argocd
    vault
    external-secrets
    kyverno
    sonarqube
    monitoring
    otel
    banking
  )

  for ns in "${namespaces[@]}"; do
    create_namespace_if_absent "$ns"
  done
  success "All namespaces created/verified"
}

# =============================================================================
# PHASE 8: DOCKER HUB CREDENTIALS
# =============================================================================
setup_docker_credentials() {
  section "Docker Hub Credentials"

  # Gather credentials — prompt only in interactive sessions
  if [[ -z "${DOCKER_USERNAME:-}" ]]; then
    if [[ -t 0 ]]; then
      read -rp "Docker Hub username: " DOCKER_USERNAME
    else
      die "DOCKER_USERNAME env var is required in non-interactive mode"
    fi
  fi

  if [[ -z "${DOCKER_PASSWORD:-}" ]]; then
    if [[ -t 0 ]]; then
      read -rsp "Docker Hub password/token: " DOCKER_PASSWORD
      echo ""
    else
      die "DOCKER_PASSWORD env var is required in non-interactive mode"
    fi
  fi

  local email="${DOCKER_EMAIL:-cicd@dtb.local}"

  dry_run_gate "docker login and create regcred secrets" || return 0

  # Login to Docker Hub
  echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin
  success "Logged in to Docker Hub as $DOCKER_USERNAME"

  # Create regcred image pull secret in relevant namespaces
  # Using --dry-run=client -o yaml | kubectl apply -f - for idempotency
  local secret_namespaces=(banking tekton-pipelines argocd kyverno)
  for ns in "${secret_namespaces[@]}"; do
    kubectl create secret docker-registry regcred \
      --docker-server=https://index.docker.io/v1/ \
      --docker-username="$DOCKER_USERNAME" \
      --docker-password="$DOCKER_PASSWORD" \
      --docker-email="$email" \
      -n "$ns" \
      --dry-run=client -o yaml | kubectl apply -f -
    info "Docker Hub regcred secret applied in namespace: $ns"
  done
  success "Docker Hub credentials configured in all namespaces"
}

# =============================================================================
# PHASE 9: TEKTON CI
# =============================================================================
setup_tekton() {
  section "Tekton Pipelines"

  # ── Tekton Pipelines ──────────────────────────────────────────────────────
  if kubectl get deployment tekton-pipelines-controller -n tekton-pipelines &>/dev/null; then
    info "Tekton Pipelines already installed, skipping"
    record_skipped "tekton-pipelines"
  else
    dry_run_gate "install Tekton Pipelines $TEKTON_PIPELINES_VERSION" || { record_skipped "tekton-pipelines"; }
    if ! $DRY_RUN; then
      local base="https://storage.googleapis.com/tekton-releases/pipeline/previous"
      kubectl apply -f "${base}/${TEKTON_PIPELINES_VERSION}/release.yaml"
      wait_for_deployment tekton-pipelines tekton-pipelines-controller 180
      wait_for_deployment tekton-pipelines tekton-pipelines-webhook 120
      success "Tekton Pipelines installed"
      record_installed "tekton-pipelines"
    fi
  fi

  # ── Tekton Triggers ───────────────────────────────────────────────────────
  section "Tekton Triggers"
  if kubectl get deployment tekton-triggers-controller -n tekton-triggers &>/dev/null; then
    info "Tekton Triggers already installed, skipping"
    record_skipped "tekton-triggers"
  else
    dry_run_gate "install Tekton Triggers $TEKTON_TRIGGERS_VERSION" || { record_skipped "tekton-triggers"; }
    if ! $DRY_RUN; then
      local tbase="https://storage.googleapis.com/tekton-releases/triggers/previous"
      kubectl apply -f "${tbase}/${TEKTON_TRIGGERS_VERSION}/release.yaml"
      kubectl apply -f "${tbase}/${TEKTON_TRIGGERS_VERSION}/interceptors.yaml"
      wait_for_deployment tekton-triggers tekton-triggers-controller 120
      success "Tekton Triggers installed"
      record_installed "tekton-triggers"
    fi
  fi

  # ── Tekton Dashboard ──────────────────────────────────────────────────────
  section "Tekton Dashboard"
  if kubectl get deployment tekton-dashboard -n tekton-dashboard &>/dev/null; then
    info "Tekton Dashboard already installed, skipping"
    record_skipped "tekton-dashboard"
  else
    dry_run_gate "install Tekton Dashboard $TEKTON_DASHBOARD_VERSION" || { record_skipped "tekton-dashboard"; }
    if ! $DRY_RUN; then
      local dbase="https://storage.googleapis.com/tekton-releases/dashboard/previous"
      kubectl apply -f "${dbase}/${TEKTON_DASHBOARD_VERSION}/release.yaml"
      wait_for_deployment tekton-dashboard tekton-dashboard 120
      success "Tekton Dashboard installed"
      record_installed "tekton-dashboard"
    fi
  fi

  # ── tkn CLI ───────────────────────────────────────────────────────────────
  section "tkn CLI"
  local tkn_ver="${TKN_CLI_VERSION#v}"  # strip leading v for filename
  local tkn_url="https://github.com/tektoncd/cli/releases/download/${TKN_CLI_VERSION}/tkn_${tkn_ver}_Linux_x86_64.tar.gz"
  install_binary tkn "$tkn_url" /usr/local/bin true tkn
}

# =============================================================================
# PHASE 10: SECURITY TOOLS
# =============================================================================
setup_security() {
  # ── Trivy ─────────────────────────────────────────────────────────────────
  section "Trivy"
  if check_command trivy; then
    info "trivy already installed: $(trivy --version 2>/dev/null | head -1)"
    record_skipped "trivy"
  else
    dry_run_gate "install Trivy via apt" || { record_skipped "trivy"; }
    if ! $DRY_RUN; then
      curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key \
        | gpg --dearmor \
        | sudo tee /usr/share/keyrings/trivy.gpg >/dev/null
      echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
        | sudo tee /etc/apt/sources.list.d/trivy.list
      sudo apt-get update -qq
      sudo apt-get install -y trivy
      success "trivy installed: $(trivy --version 2>/dev/null | head -1)"
      record_installed "trivy"
    fi
  fi

  # ── SonarQube ─────────────────────────────────────────────────────────────
  section "SonarQube"
  helm_install_or_upgrade sonarqube sonarqube/sonarqube sonarqube "$CHART_SONARQUBE" \
    --set service.type=NodePort \
    --set resources.requests.memory=2Gi \
    --set resources.limits.memory=4Gi \
    --set persistence.enabled=true \
    --set persistence.size=10Gi \
    --timeout 600s
  # SonarQube takes longer to start (JVM + PostgreSQL)
  if ! $DRY_RUN && helm status sonarqube -n sonarqube &>/dev/null; then
    wait_for_deployment sonarqube sonarqube 300 || warn "SonarQube is starting slowly — check: kubectl get pods -n sonarqube"
  fi

  # ── Kyverno ───────────────────────────────────────────────────────────────
  section "Kyverno"
  # Install with failurePolicy=Ignore (audit mode) so webhook doesn't block other installs
  helm_install_or_upgrade kyverno kyverno/kyverno kyverno "$CHART_KYVERNO" \
    --set admissionController.replicas=1 \
    --set backgroundController.replicas=1 \
    --set cleanupController.replicas=1 \
    --set admissionController.failurePolicy=Ignore
  if ! $DRY_RUN && helm status kyverno -n kyverno &>/dev/null; then
    wait_for_deployment kyverno kyverno-admission-controller 120 \
      || warn "Kyverno admission controller check: kubectl get pods -n kyverno"
  fi

  # ── Cosign ────────────────────────────────────────────────────────────────
  section "Cosign"
  if check_command cosign; then
    info "cosign already installed: $(cosign version 2>/dev/null | head -1 || echo 'installed')"
    record_skipped "cosign"
  else
    # Install latest cosign binary from sigstore
    local cosign_url="https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64"
    install_binary cosign "$cosign_url"
  fi

  # ── Vault ─────────────────────────────────────────────────────────────────
  section "Vault"
  # CLI check (already installed on this machine)
  if check_command vault; then
    info "vault CLI already installed: $(vault version 2>/dev/null)"
    record_skipped "vault-cli"
  else
    warn "vault CLI not found — install from https://developer.hashicorp.com/vault/downloads"
  fi

  # Deploy Vault server in cluster (dev mode for local use)
  helm_install_or_upgrade vault hashicorp/vault vault "$CHART_VAULT" \
    --set server.dev.enabled=true \
    --set server.dev.devRootToken="root" \
    --set ui.enabled=true \
    --set ui.serviceType=NodePort
  if ! $DRY_RUN && helm status vault -n vault &>/dev/null; then
    wait_for_pods vault "app.kubernetes.io/name=vault" 120 \
      || warn "Vault pod check: kubectl get pods -n vault"
    warn "Vault is running in DEV MODE — data is in-memory only and will be lost on pod restart. Never use this in production."
  fi

  # ── External Secrets Operator ─────────────────────────────────────────────
  section "External Secrets Operator (ESO)"
  helm_install_or_upgrade external-secrets external-secrets/external-secrets \
    external-secrets "$CHART_ESO" \
    --set installCRDs=true
  if ! $DRY_RUN && helm status external-secrets -n external-secrets &>/dev/null; then
    wait_for_deployment external-secrets external-secrets 120 \
      || warn "ESO check: kubectl get pods -n external-secrets"
  fi

  # ── Conftest ──────────────────────────────────────────────────────────────
  section "Conftest"
  local conftest_url="https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}/conftest_${CONFTEST_VERSION}_Linux_x86_64.tar.gz"
  install_binary conftest "$conftest_url" /usr/local/bin true conftest
}

# =============================================================================
# PHASE 11: ARGOCD
# =============================================================================
setup_argocd() {
  section "ArgoCD"

  if kubectl get deployment argocd-server -n argocd &>/dev/null; then
    info "ArgoCD already installed, skipping manifest apply"
    record_skipped "argocd"
  else
    dry_run_gate "install ArgoCD $ARGOCD_VERSION" || { record_skipped "argocd"; }
    if ! $DRY_RUN; then
      local argocd_url="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
      kubectl apply -n argocd -f "$argocd_url"
      record_installed "argocd"
    fi
  fi

  if ! $DRY_RUN; then
    wait_for_deployment argocd argocd-server 240 \
      || warn "argocd-server slow — check: kubectl get pods -n argocd"
    wait_for_deployment argocd argocd-repo-server 180 \
      || warn "argocd-repo-server slow"
    # app-controller is a StatefulSet, not a Deployment
    wait_for_statefulset argocd argocd-application-controller 180 \
      || warn "argocd-application-controller slow"

    # Retrieve initial admin password (secret is created async by argocd-server)
    info "Retrieving ArgoCD initial admin password..."
    local attempts=0
    while [[ $attempts -lt 30 ]]; do
      ARGOCD_PASSWORD=$(
        kubectl -n argocd get secret argocd-initial-admin-secret \
          -o jsonpath="{.data.password}" 2>/dev/null \
        | base64 -d 2>/dev/null
      ) && [[ -n "$ARGOCD_PASSWORD" ]] && break
      sleep 5
      attempts=$((attempts + 1))
    done
    if [[ -n "$ARGOCD_PASSWORD" ]]; then
      success "ArgoCD initial password retrieved"
    else
      warn "Could not retrieve ArgoCD initial password. Run: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
    fi
  fi

  # ── argocd CLI ────────────────────────────────────────────────────────────
  section "argocd CLI"
  local argocd_cli_url="https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64"
  install_binary argocd "$argocd_cli_url"
}

# =============================================================================
# PHASE 12: OBSERVABILITY
# =============================================================================
setup_observability() {
  # ── Prometheus + Grafana (kube-prometheus-stack) ──────────────────────────
  section "Prometheus + Grafana"
  helm_install_or_upgrade prometheus prometheus-community/kube-prometheus-stack \
    monitoring "$CHART_PROMETHEUS" \
    --set prometheus.prometheusSpec.retention=7d \
    --set grafana.adminPassword=admin123 \
    --set grafana.service.type=NodePort \
    --set alertmanager.enabled=false
  if ! $DRY_RUN && helm status prometheus -n monitoring &>/dev/null; then
    wait_for_deployment monitoring prometheus-grafana 180 \
      || warn "Grafana slow — check: kubectl get pods -n monitoring"
    # Prometheus itself is a StatefulSet
    wait_for_statefulset monitoring prometheus-prometheus-kube-prometheus-prometheus 180 \
      || warn "Prometheus StatefulSet slow"
  fi

  # ── Loki + Promtail ───────────────────────────────────────────────────────
  section "Loki + Promtail"
  # Deploy into monitoring namespace so Grafana can reach Loki by service name
  helm_install_or_upgrade loki grafana/loki-stack \
    monitoring "$CHART_LOKI" \
    --set loki.persistence.enabled=true \
    --set loki.persistence.size=10Gi \
    --set promtail.enabled=true
  if ! $DRY_RUN && helm status loki -n monitoring &>/dev/null; then
    wait_for_pods monitoring "app=loki" 120 \
      || warn "Loki pod check: kubectl get pods -n monitoring -l app=loki"
  fi

  # ── OpenTelemetry Collector ───────────────────────────────────────────────
  section "OpenTelemetry Collector"
  helm_install_or_upgrade otel-collector open-telemetry/opentelemetry-collector \
    otel "$CHART_OTEL" \
    --set mode=deployment
  if ! $DRY_RUN && helm status otel-collector -n otel &>/dev/null; then
    wait_for_deployment otel otel-collector-opentelemetry-collector 120 \
      || warn "OTel Collector check: kubectl get pods -n otel"
  fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  parse_args "$@"

  echo ""
  echo -e "${BOLD}DTB Banking Portal — CI/CD Prerequisites Setup${NC}"
  echo -e "Chart versions pinned as of ${SCRIPT_DATE}. Run 'helm search repo <name>' to check for updates."
  if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN MODE — no changes will be made${NC}"
  fi
  echo ""

  run_preflight
  install_system_utilities
  setup_docker
  setup_kubectl

  if $SKIP_MINIKUBE; then
    section "Minikube"
    info "Skipping Minikube (--skip-minikube)"
  else
    setup_minikube
  fi

  setup_helm

  # Namespaces and credentials require a running cluster
  if ! $SKIP_MINIKUBE; then
    create_namespaces
    setup_docker_credentials
  fi

  if $SKIP_TEKTON; then
    section "Tekton CI"
    info "Skipping Tekton (--skip-tekton)"
  else
    setup_tekton
  fi

  if $SKIP_SECURITY; then
    section "Security Tools"
    info "Skipping security tools (--skip-security)"
  else
    setup_security
  fi

  if $SKIP_ARGOCD; then
    section "ArgoCD"
    info "Skipping ArgoCD (--skip-argocd)"
  else
    setup_argocd
  fi

  if $SKIP_OBSERVABILITY; then
    section "Observability"
    info "Skipping observability stack (--skip-observability)"
  else
    setup_observability
  fi

  print_summary
  echo -e "${GREEN}${BOLD}Prerequisites setup complete!${NC}"
  echo ""
}

main "$@"
