
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SCRIPT_DATE="2026-03-16"

TEKTON_PIPELINES_VERSION="v0.68.0"
TEKTON_TRIGGERS_VERSION="v0.30.0"
TEKTON_DASHBOARD_VERSION="v0.52.0"
TKN_CLI_VERSION="v0.40.0"
ARGOCD_VERSION="v2.14.6"
TRIVY_VERSION="0.63.0"      
CONFTEST_VERSION="0.58.0"   
MINIKUBE_VERSION="v1.38.1"
MINIKUBE_CPUS=4
MINIKUBE_MEMORY="8192"
MINIKUBE_DISK="40g"
MINIKUBE_K8S_VERSION="v1.32.3"

CHART_PROMETHEUS="69.8.2"     
CHART_LOKI="2.10.2"           
CHART_OTEL="0.119.0"
CHART_SONARQUBE="10.8.0"
CHART_KYVERNO="3.4.4"
CHART_VAULT="0.30.0"
CHART_ESO="0.14.1"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

info()    { :; }
success() { :; }
section() { :; }
url()     { :; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

SKIP_MINIKUBE=true
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
  echo "  --minikube            Install and start Minikube (default: skipped — assumes existing cluster)"
  echo "  --skip-minikube       Explicitly skip Minikube (default behaviour)"
  echo "  --skip-tekton         Skip Tekton (Pipelines, Triggers, Dashboard, tkn)"
  echo "  --skip-security       Skip security tools (Trivy, SonarQube, Kyverno, Cosign, Vault, ESO, Conftest)"
  echo "  --skip-argocd         Skip ArgoCD install"
  echo "  --skip-observability  Skip observability stack (Prometheus, Grafana, Loki, OTel)"
  echo "  --dry-run             Print actions without executing"
  echo "  --help                Show this help"
  echo ""
  echo "Credentials:"
  echo "  Run ./scripts/k8s/vault-credentials.sh after this script to store"
  echo "  all credentials (Docker Hub, SonarQube, GitHub, Grafana, JWT, MongoDB)"
  echo "  in Vault and create the required Kubernetes secrets."
  echo ""
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-minikube)      SKIP_MINIKUBE=true ;;
      --minikube)           SKIP_MINIKUBE=false ;;
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

check_command() { command -v "$1" &>/dev/null; }

record_installed() { INSTALLED+=("$1"); }
record_skipped()   { SKIPPED+=("$1"); }
record_failed()    { FAILED+=("$1"); }

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
    record_skipped "$pkg"
    return 0
  fi
  dry_run_gate "install apt package: $pkg" || { record_skipped "$pkg"; return 0; }
  sudo apt-get install -y "$pkg"
  record_installed "$pkg"
}

install_binary() {
  local name="$1"
  local url="$2"
  local dest="${3:-/usr/local/bin}"
  local is_archive="${4:-false}"
  local archive_entry="${5:-$name}"

  if check_command "$name"; then
    record_skipped "$name"
    return 0
  fi

  dry_run_gate "install $name from $url" || { record_skipped "$name"; return 0; }

  local tmp
  tmp=$(mktemp -d)
  trap "rm -rf $tmp" RETURN

  if $is_archive; then
    curl -fsSL "$url" -o "$tmp/$name.tar.gz"
    tar -xzf "$tmp/$name.tar.gz" -C "$tmp" "$archive_entry" 2>/dev/null \
      || tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
    sudo install "$tmp/$archive_entry" "$dest/$name"
  else
    curl -fsSL "$url" -o "$tmp/$name"
    sudo install "$tmp/$name" "$dest/$name"
  fi

  record_installed "$name"
}

wait_for_deployment() {
  local ns="$1" name="$2" timeout="${3:-120}"
  if ! kubectl rollout status deployment/"$name" -n "$ns" --timeout="${timeout}s"; then
    warn "deployment/$name in $ns not ready within ${timeout}s — check: kubectl get pods -n $ns"
    return 1
  fi
}

wait_for_statefulset() {
  local ns="$1" name="$2" timeout="${3:-120}"
  if ! kubectl rollout status statefulset/"$name" -n "$ns" --timeout="${timeout}s"; then
    warn "statefulset/$name in $ns not ready within ${timeout}s — check: kubectl get pods -n $ns"
    return 1
  fi
}

wait_for_pods() {
  local ns="$1" selector="$2" timeout="${3:-120}"
  if ! kubectl wait --for=condition=ready pod -l "$selector" -n "$ns" \
      --timeout="${timeout}s" 2>/dev/null; then
    warn "Pods with selector '$selector' in $ns did not become ready within ${timeout}s — check: kubectl get pods -n $ns -l $selector"
    return 1
  fi
}

pods_running() {
  kubectl get pods -n "$1" -l "$2" --no-headers 2>/dev/null \
    | grep -q "^[^ ]* \+[0-9]*/[0-9]* \+Running"
}

helm_install_or_upgrade() {
  local release="$1" chart="$2" ns="$3" version="$4"
  shift 4

  local helm_timeout="5m0s"
  local extra_args=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--helm-timeout" ]]; then
      shift; helm_timeout="$1"
    else
      extra_args+=("$1")
    fi
    shift
  done

  dry_run_gate "helm install/upgrade $release ($chart) in $ns" || {
    record_skipped "$release"
    return 0
  }

  if helm status "$release" -n "$ns" &>/dev/null; then
    helm upgrade "$release" "$chart" -n "$ns" \
      --version "$version" \
      --reuse-values \
      "${extra_args[@]}" 2>/dev/null \
      || true
    record_skipped "$release"
  else
    helm install "$release" "$chart" \
      -n "$ns" \
      --version "$version" \
      --create-namespace \
      --wait \
      --timeout "$helm_timeout" \
      "${extra_args[@]}"
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
}

ARGOCD_PASSWORD=""

on_error() {
  local line="$1"
  error "Script failed at line $line"
  print_summary
  exit 1
}
trap 'on_error $LINENO' ERR

print_summary() {
  echo -e "\n${BOLD}${MAGENTA}══ Installation Summary ══${NC}"

  if [[ ${#INSTALLED[@]} -gt 0 ]]; then
    echo -e "  ${GREEN}Installed${NC}  (${#INSTALLED[@]}): ${INSTALLED[*]}"
  fi
  if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo -e "  ${BLUE}Skipped${NC}    (${#SKIPPED[@]}): ${SKIPPED[*]}"
  fi
  if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo -e "  ${RED}FAILED${NC}     (${#FAILED[@]}): ${FAILED[*]}"
  fi

  echo -e "\n${BOLD}${MAGENTA}══ Access URLs  (use kubectl port-forward to access) ══${NC}"

  echo ""
  echo -e "  ${BOLD}ArgoCD${NC}"
  echo -e "  ${CYAN}    kubectl port-forward svc/argocd-server -n argocd 8080:443 &${NC}"
  echo -e "  ${CYAN}    https://localhost:8080${NC}"
  if [[ -n "$ARGOCD_PASSWORD" ]]; then
    echo  "    Username: admin  |  Password: $ARGOCD_PASSWORD"
  else
    echo  "    Username: admin  |  Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
  fi

  echo ""
  echo -e "  ${BOLD}Tekton Dashboard${NC}"
  echo -e "  ${CYAN}    kubectl port-forward svc/tekton-dashboard -n tekton-pipelines 9097:9097 &${NC}"
  echo -e "  ${CYAN}    http://localhost:9097${NC}"

  echo ""
  echo -e "  ${BOLD}SonarQube${NC}"
  echo -e "  ${CYAN}    kubectl port-forward svc/sonarqube-sonarqube -n sonarqube 9000:9000 &${NC}"
  echo -e "  ${CYAN}    http://localhost:9000${NC}"
  echo  "    Credentials: see Vault at secret/banking/sonarqube"

  echo ""
  echo -e "  ${BOLD}Grafana${NC}"
  echo -e "  ${CYAN}    kubectl port-forward svc/prometheus-grafana -n monitoring 3001:80 &${NC}"
  echo -e "  ${CYAN}    http://localhost:3001${NC}"
  echo  "    Credentials: see Vault at secret/banking/grafana"

  echo ""
  echo -e "  ${BOLD}Vault UI${NC}"
  echo -e "  ${CYAN}    kubectl port-forward svc/vault -n vault 8200:8200 &${NC}"
  echo -e "  ${CYAN}    http://localhost:8200${NC}"
  echo  "    Token: root  (DEV MODE — in-memory only)"

  echo ""
  echo -e "  ${BOLD}Prometheus${NC}"
  echo -e "  ${CYAN}    kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090 &${NC}"
  echo -e "  ${CYAN}    http://localhost:9090${NC}"

  echo ""
  echo -e "  ${BOLD}Quick CLI checks${NC}"
  echo  "    tkn pipeline list -n tekton-pipelines"
  echo  "    trivy --version && cosign version && conftest --version"
  echo  "    kubectl get pods -A"
  echo ""
  echo -e "  ${YELLOW}${BOLD}Next step: load all credentials into Vault${NC}"
  echo  "    ./scripts/k8s/vault-credentials.sh"
  echo  "  This creates Docker Hub regcred, SonarQube token, GitHub webhook,"
  echo  "  Grafana admin secret, and all banking app secrets in one go."
  echo ""
}

run_preflight() {
  section "Preflight Checks"

  if [[ "$(uname -s)" != "Linux" ]]; then
    die "This script requires Linux. Detected: $(uname -s)"
  fi
  success "OS: Linux"

  if $DRY_RUN; then
    warn "sudo: check skipped in dry-run mode"
  elif sudo -n true 2>/dev/null; then
    success "sudo: passwordless access available"
  elif sudo -v 2>/dev/null; then
    success "sudo: access available (may prompt for password during install)"
  else
    die "sudo access is required to install system packages"
  fi

  if curl -sf --max-time 10 https://github.com >/dev/null; then
    success "Internet: reachable"
  else
    die "Internet access is required. Cannot reach https://github.com"
  fi

  if ! docker info &>/dev/null; then
    die "Docker daemon is not running. Start it with: sudo systemctl start docker"
  fi
  success "Docker: daemon is running"
}

install_system_utilities() {
  section "System Utilities"
  dry_run_gate "apt-get update" || { info "DRY RUN: skipping apt-get update"; return 0; }
  sudo apt-get update -qq
  local pkgs=(curl wget git jq apt-transport-https ca-certificates gnupg lsb-release)
  for pkg in "${pkgs[@]}"; do
    install_apt_package "$pkg"
  done
}

setup_docker() {
  section "Docker"

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

  if ! groups "$USER" | grep -qw docker; then
    warn "User '$USER' is not in the docker group."
    dry_run_gate "add $USER to docker group" || return 0
    sudo usermod -aG docker "$USER"
    die "Added '$USER' to the docker group. You must log out and back in (or run 'newgrp docker') for this to take effect. Then re-run this script."
  fi
  success "Docker group: $USER is a member"

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

setup_minikube() {
  section "Minikube"

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

  for addon in ingress metrics-server storage-provisioner; do
    dry_run_gate "enable minikube addon: $addon" || continue
    minikube addons enable "$addon" 2>/dev/null || true
  done
  success "minikube addons: ingress, metrics-server, storage-provisioner enabled"

  wait_for_deployment kube-system coredns 120 || warn "coredns took longer than expected"
}

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

  if kubectl cluster-info --request-timeout=10s &>/dev/null; then
    success "kubectl: connected to cluster"
  else
    warn "kubectl cannot reach cluster — ensure your kubeconfig is set and the cluster is running"
  fi
}

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

setup_tekton() {
  section "Tekton Pipelines"

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

  if kubectl get deployment tekton-triggers-controller -n tekton-pipelines &>/dev/null; then
    info "Tekton Triggers already installed, skipping"
    record_skipped "tekton-triggers"
  else
    dry_run_gate "install Tekton Triggers $TEKTON_TRIGGERS_VERSION" || { record_skipped "tekton-triggers"; }
    if ! $DRY_RUN; then
      local tbase="https://storage.googleapis.com/tekton-releases/triggers/previous"
      kubectl apply -f "${tbase}/${TEKTON_TRIGGERS_VERSION}/release.yaml"
      kubectl apply -f "${tbase}/${TEKTON_TRIGGERS_VERSION}/interceptors.yaml"
      wait_for_deployment tekton-pipelines tekton-triggers-controller 120
      wait_for_deployment tekton-pipelines tekton-triggers-webhook 120 \
        || warn "tekton-triggers-webhook slow — check: kubectl get pods -n tekton-pipelines"
      wait_for_deployment tekton-pipelines tekton-triggers-core-interceptors 120 \
        || warn "tekton-triggers-core-interceptors slow — check: kubectl get pods -n tekton-pipelines"
      success "Tekton Triggers installed"
      record_installed "tekton-triggers"
    fi
  fi

  if kubectl get deployment tekton-dashboard -n tekton-pipelines &>/dev/null; then
    info "Tekton Dashboard already installed, skipping"
    record_skipped "tekton-dashboard"
  else
    dry_run_gate "install Tekton Dashboard $TEKTON_DASHBOARD_VERSION" || { record_skipped "tekton-dashboard"; }
    if ! $DRY_RUN; then
      local dbase="https://storage.googleapis.com/tekton-releases/dashboard/previous"
      kubectl apply -f "${dbase}/${TEKTON_DASHBOARD_VERSION}/release.yaml"
      wait_for_deployment tekton-pipelines tekton-dashboard 120
      success "Tekton Dashboard installed"
      record_installed "tekton-dashboard"
    fi
  fi

  local tkn_ver="${TKN_CLI_VERSION#v}"
  local tkn_url="https://github.com/tektoncd/cli/releases/download/${TKN_CLI_VERSION}/tkn_${tkn_ver}_Linux_x86_64.tar.gz"
  install_binary tkn "$tkn_url" /usr/local/bin true tkn
}

setup_security() {
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

  section "SonarQube"
  if ! $DRY_RUN && pods_running sonarqube "app=sonarqube"; then
    record_skipped "sonarqube"
  else
    helm_install_or_upgrade sonarqube sonarqube/sonarqube sonarqube "$CHART_SONARQUBE" \
      --helm-timeout 20m0s \
      --set service.type=NodePort \
      --set resources.requests.memory=2Gi \
      --set resources.limits.memory=4Gi \
      --set persistence.enabled=true \
      --set persistence.size=10Gi
    if ! $DRY_RUN; then
      wait_for_deployment sonarqube sonarqube 1200 \
        || warn "SonarQube still starting — check: kubectl get pods -n sonarqube"
    fi
  fi

  section "Kyverno"
  if ! $DRY_RUN && pods_running kyverno "app.kubernetes.io/name=kyverno"; then
    record_skipped "kyverno"
  else
    helm_install_or_upgrade kyverno kyverno/kyverno kyverno "$CHART_KYVERNO" \
      --set admissionController.replicas=1 \
      --set backgroundController.replicas=1 \
      --set cleanupController.replicas=1 \
      --set admissionController.failurePolicy=Ignore
    if ! $DRY_RUN; then
      wait_for_deployment kyverno kyverno-admission-controller 120 \
        || warn "Kyverno admission controller check: kubectl get pods -n kyverno"
    fi
  fi

  section "Cosign"
  if check_command cosign; then
    info "cosign already installed: $(cosign version 2>/dev/null | head -1 || echo 'installed')"
    record_skipped "cosign"
  else
    local cosign_url="https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64"
    install_binary cosign "$cosign_url"
  fi

  section "Vault"
  if check_command vault; then
    info "vault CLI already installed: $(vault version 2>/dev/null)"
    record_skipped "vault-cli"
  else
    warn "vault CLI not found — install from https://developer.hashicorp.com/vault/downloads"
  fi

  if ! $DRY_RUN && pods_running vault "app.kubernetes.io/name=vault"; then
    record_skipped "vault"
  else
    helm_install_or_upgrade vault hashicorp/vault vault "$CHART_VAULT" \
      --set server.dev.enabled=true \
      --set server.dev.devRootToken="root" \
      --set ui.enabled=true \
      --set ui.serviceType=NodePort
    if ! $DRY_RUN; then
      wait_for_pods vault "app.kubernetes.io/name=vault" 120 \
        || warn "Vault pod check: kubectl get pods -n vault"
      warn "Vault is running in DEV MODE — data is in-memory only and will be lost on pod restart. Never use this in production."
    fi
  fi

  section "External Secrets Operator (ESO)"
  if ! $DRY_RUN && pods_running external-secrets "app.kubernetes.io/name=external-secrets"; then
    record_skipped "external-secrets"
  else
    helm_install_or_upgrade external-secrets external-secrets/external-secrets \
      external-secrets "$CHART_ESO" \
      --set installCRDs=true
    if ! $DRY_RUN; then
      wait_for_deployment external-secrets external-secrets 120 \
        || warn "ESO check: kubectl get pods -n external-secrets"
    fi
  fi

  section "Conftest"
  local conftest_url="https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}/conftest_${CONFTEST_VERSION}_Linux_x86_64.tar.gz"
  install_binary conftest "$conftest_url" /usr/local/bin true conftest
}

setup_argocd() {
  section "ArgoCD"

  if ! $DRY_RUN && pods_running argocd "app.kubernetes.io/name=argocd-server"; then
    record_skipped "argocd"
  else
    dry_run_gate "install ArgoCD $ARGOCD_VERSION" || { record_skipped "argocd"; }
    if ! $DRY_RUN; then
      local argocd_url="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
      kubectl apply -n argocd -f "$argocd_url"
      record_installed "argocd"
    fi

    if ! $DRY_RUN; then
      wait_for_deployment argocd argocd-server 240 \
        || warn "argocd-server slow — check: kubectl get pods -n argocd"
      wait_for_deployment argocd argocd-repo-server 180 \
        || warn "argocd-repo-server slow"
      wait_for_statefulset argocd argocd-application-controller 180 \
        || warn "argocd-application-controller slow"

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
      if [[ -z "$ARGOCD_PASSWORD" ]]; then
        warn "Could not retrieve ArgoCD initial password. Run: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
      fi
    fi
  fi

  local argocd_cli_url="https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64"
  install_binary argocd "$argocd_cli_url"
}

setup_observability() {
  section "Prometheus + Grafana"
  if ! $DRY_RUN && pods_running monitoring "app.kubernetes.io/name=grafana"; then
    record_skipped "prometheus"
  else
    helm_install_or_upgrade prometheus prometheus-community/kube-prometheus-stack \
      monitoring "$CHART_PROMETHEUS" \
      --set prometheus.prometheusSpec.retention=7d \
      --set grafana.admin.existingSecret=grafana-admin-secret \
      --set grafana.admin.userKey=admin-user \
      --set grafana.admin.passwordKey=admin-password \
      --set grafana.service.type=NodePort \
      --set alertmanager.enabled=false
    if ! $DRY_RUN; then
      wait_for_deployment monitoring prometheus-grafana 180 \
        || warn "Grafana slow — check: kubectl get pods -n monitoring"
      wait_for_statefulset monitoring prometheus-prometheus-kube-prometheus-prometheus 180 \
        || warn "Prometheus StatefulSet slow"
    fi
  fi

  section "Loki + Promtail"
  if ! $DRY_RUN && pods_running monitoring "app=loki"; then
    record_skipped "loki"
  else
    helm_install_or_upgrade loki grafana/loki-stack \
      monitoring "$CHART_LOKI" \
      --set loki.persistence.enabled=true \
      --set loki.persistence.size=10Gi \
      --set promtail.enabled=true
    if ! $DRY_RUN; then
      wait_for_pods monitoring "app=loki" 120 \
        || warn "Loki pod check: kubectl get pods -n monitoring -l app=loki"
    fi
  fi

  section "OpenTelemetry Collector"
  if ! $DRY_RUN && pods_running otel "app.kubernetes.io/name=opentelemetry-collector"; then
    record_skipped "otel-collector"
  else
    helm_install_or_upgrade otel-collector open-telemetry/opentelemetry-collector \
      otel "$CHART_OTEL" \
      --set mode=deployment \
      --set image.repository=otel/opentelemetry-collector-k8s
    if ! $DRY_RUN; then
      wait_for_deployment otel otel-collector-opentelemetry-collector 120 \
        || warn "OTel Collector not ready — check: kubectl get pods -n otel"
    fi
  fi
}

main() {
  parse_args "$@"

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
  create_namespaces

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
