#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_DIR="/tmp/dtb-port-forwards"
LOG_DIR="/tmp/dtb-port-forwards/logs"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }
cleanup() { local rc=$?; (( rc != 0 )) && error "port-forward.sh failed (exit $rc)"; exit "$rc"; }
trap cleanup ERR EXIT

declare -A SVC_NS SVC_SVC SVC_LOCAL SVC_REMOTE SVC_PATH SVC_DESC

define_service() {
  local name="$1" ns="$2" svc="$3" local_port="$4" remote_port="$5" path="$6" desc="$7"
  SVC_NS[$name]="$ns"
  SVC_SVC[$name]="$svc"
  SVC_LOCAL[$name]="$local_port"
  SVC_REMOTE[$name]="$remote_port"
  SVC_PATH[$name]="$path"
  SVC_DESC[$name]="$desc"
}

define_service "tekton"      "tekton-pipelines" "tekton-dashboard"                              9097 9097 "/"             "Tekton Dashboard"
define_service "argocd"      "argocd"           "argocd-server"                                 8080 443  "/"             "ArgoCD UI"
define_service "grafana"     "monitoring"       "prometheus-grafana"                            3001 80   "/"             "Grafana"
define_service "prometheus"  "monitoring"       "prometheus-kube-prometheus-prometheus"         9090 9090 "/"             "Prometheus"
define_service "alertmanager" "monitoring"      "prometheus-kube-prometheus-alertmanager"       9093 9093 "/"             "Alertmanager"
define_service "sonarqube"   "sonarqube"        "sonarqube-sonarqube"                           9000 9000 "/"             "SonarQube"
define_service "vault"       "vault"            "vault"                                         8200 8200 "/ui"           "Vault UI"
define_service "backend"     "banking"          "banking-backend"                               3000 3000 "/api/health"   "Banking Backend API"
define_service "frontend"    "banking"          "banking-frontend"                              8081 80   "/"             "Banking Frontend"
define_service "loki"        "monitoring"       "loki"                                          3100 3100 "/ready"        "Loki (log aggregation)"
define_service "otel"        "otel"             "otel-collector-opentelemetry-collector"        4317 4317 ""              "OTel Collector (gRPC)"

ALL_SERVICES=(tekton argocd grafana prometheus alertmanager sonarqube vault backend frontend loki otel)

mkdir -p "$PID_DIR" "$LOG_DIR"

pid_file()  { echo "$PID_DIR/$1.pid"; }
log_file()  { echo "$LOG_DIR/$1.log"; }

svc_running() {
  local name="$1"
  local pf="$(pid_file "$name")"
  [[ -f "$pf" ]] && kill -0 "$(cat "$pf")" 2>/dev/null
}

port_in_use() {
  lsof -ti :"$1" &>/dev/null 2>&1
}

svc_exists_in_cluster() {
  local name="$1"
  kubectl get svc "${SVC_SVC[$name]}" -n "${SVC_NS[$name]}" &>/dev/null 2>&1
}

start_service() {
  local name="$1"
  local ns="${SVC_NS[$name]}"
  local svc="${SVC_SVC[$name]}"
  local lport="${SVC_LOCAL[$name]}"
  local rport="${SVC_REMOTE[$name]}"

  if svc_running "$name"; then
    info "$(printf '%-14s' "$name") already forwarding on :$lport"
    return 0
  fi

  if ! svc_exists_in_cluster "$name"; then
    warn "$(printf '%-14s' "$name") service not found in cluster — skipping"
    return 0
  fi

  if port_in_use "$lport"; then
    warn "$(printf '%-14s' "$name") port $lport already in use by another process — skipping"
    return 0
  fi

  kubectl port-forward "svc/$svc" "$lport:$rport" -n "$ns" \
    >"$(log_file "$name")" 2>&1 &
  local pid=$!
  echo "$pid" > "$(pid_file "$name")"

  sleep 1
  if svc_running "$name"; then
    success "$(printf '%-14s' "$name") :$lport  →  $ns/$svc:$rport"
  else
    error "$(printf '%-14s' "$name") failed to start — check $(log_file "$name")"
    rm -f "$(pid_file "$name")"
  fi
}

cmd_start() {
  local targets=("$@")
  [[ ${#targets[@]} -eq 0 ]] && targets=("${ALL_SERVICES[@]}")

  echo ""
  echo -e "${BOLD}Starting port-forwards...${NC}"
  echo ""

  for name in "${targets[@]}"; do
    [[ -v "SVC_NS[$name]" ]] || { warn "Unknown service: $name"; continue; }
    start_service "$name"
  done

  echo ""
  cmd_status
}

stop_service() {
  local name="$1"
  local pf="$(pid_file "$name")"
  if [[ -f "$pf" ]]; then
    local pid
    pid=$(cat "$pf")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null && success "Stopped: $name (pid $pid)"
    fi
    rm -f "$pf"
  fi
}

cmd_stop() {
  local targets=("$@")
  [[ ${#targets[@]} -eq 0 ]] && targets=("${ALL_SERVICES[@]}")

  echo ""
  echo -e "${BOLD}Stopping port-forwards...${NC}"
  echo ""

  for name in "${targets[@]}"; do
    stop_service "$name"
  done

  pkill -f "kubectl port-forward" 2>/dev/null || true
  rm -f "$PID_DIR"/*.pid
  success "All port-forwards stopped"
}

cmd_status() {
  echo -e "${BOLD}Port-Forward Status${NC}"
  echo ""
  printf "  ${BOLD}%-14s %-6s %-10s %-10s %s${NC}\n" "SERVICE" "PORT" "STATUS" "NAMESPACE" "URL"
  printf "  %-14s %-6s %-10s %-10s %s\n" "-------" "----" "------" "---------" "---"

  for name in "${ALL_SERVICES[@]}"; do
    local lport="${SVC_LOCAL[$name]}"
    local path="${SVC_PATH[$name]}"
    local protocol="http"
    [[ "$name" == "argocd" ]] && protocol="https"
    [[ "$name" == "otel" ]]   && { protocol="grpc"; path=""; }

    local url="${protocol}://localhost:${lport}${path}"

    if svc_running "$name"; then
      printf "  ${GREEN}%-14s${NC} %-6s ${GREEN}%-10s${NC} %-10s ${CYAN}%s${NC}\n" \
        "$name" ":$lport" "Running" "${SVC_NS[$name]}" "$url"
    elif ! svc_exists_in_cluster "$name" 2>/dev/null; then
      printf "  ${YELLOW}%-14s${NC} %-6s ${YELLOW}%-10s${NC} %-10s\n" \
        "$name" ":$lport" "No svc" "${SVC_NS[$name]}"
    else
      printf "  ${RED}%-14s${NC} %-6s ${RED}%-10s${NC} %-10s\n" \
        "$name" ":$lport" "Stopped" "${SVC_NS[$name]}"
    fi
  done

  echo ""
  print_credentials
}

cmd_restart() {
  local targets=("$@")
  [[ ${#targets[@]} -eq 0 ]] && targets=("${ALL_SERVICES[@]}")
  for name in "${targets[@]}"; do
    stop_service "$name"
  done
  sleep 1
  cmd_start "${targets[@]}"
}

cmd_logs() {
  local name="${1:-}"
  [[ -z "$name" ]] && die "Usage: $0 logs <service>"
  [[ -v "SVC_NS[$name]" ]] || die "Unknown service: $name"
  local lf="$(log_file "$name")"
  [[ -f "$lf" ]] || die "No log file for $name yet. Start it first."
  tail -f "$lf"
}

print_credentials() {
  echo -e "  ${BOLD}Default credentials:${NC}"
  echo ""
  printf "  %-14s %s\n" "Tekton"      "http://localhost:9097  (no auth)"
  printf "  %-14s %s\n" "ArgoCD"      "https://localhost:8080  admin / \$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
  printf "  %-14s %s\n" "Grafana"     "http://localhost:3001  admin / prom-operator"
  printf "  %-14s %s\n" "Prometheus"  "http://localhost:9090  (no auth)"
  printf "  %-14s %s\n" "SonarQube"   "http://localhost:9000  admin / admin"
  printf "  %-14s %s\n" "Vault"       "http://localhost:8200/ui  Token: root"
  printf "  %-14s %s\n" "Backend"     "http://localhost:3000/api/health"
  printf "  %-14s %s\n" "Frontend"    "http://localhost:8081"
  echo ""
  echo -e "  ${BOLD}ArgoCD password shortcut:${NC}"
  echo -e "  ${CYAN}kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo${NC}"
  echo ""
}

usage() {
  cat <<EOF

${BOLD}DTB Banking Portal — Port Forward Manager${NC}

Usage: $(basename "$0") <command> [services...]

Commands:
  start   [svc...]   Start port-forwards (all services if none specified)
  stop    [svc...]   Stop port-forwards (all if none specified)
  restart [svc...]   Restart port-forwards
  status             Show status of all port-forwards
  logs    <svc>      Tail the kubectl log for a service

Services:
  tekton        Tekton Dashboard     :9097
  argocd        ArgoCD UI            :8080
  grafana       Grafana              :3001
  prometheus    Prometheus           :9090
  alertmanager  Alertmanager         :9093
  sonarqube     SonarQube            :9000
  vault         Vault UI             :8200
  backend       Banking Backend API  :3000
  frontend      Banking Frontend     :8081
  loki          Loki                 :3100
  otel          OTel Collector       :4317

Examples:
  $(basename "$0") start
  $(basename "$0") start tekton argocd
  $(basename "$0") stop
  $(basename "$0") restart grafana
  $(basename "$0") status
  $(basename "$0") logs sonarqube

EOF
}

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
  start)   cmd_start   "$@" ;;
  stop)    cmd_stop    "$@" ;;
  restart) cmd_restart "$@" ;;
  status)  cmd_status       ;;
  logs)    cmd_logs    "$@" ;;
  help|--help|-h) usage ;;
  *) error "Unknown command: $COMMAND"; usage; exit 1 ;;
esac
