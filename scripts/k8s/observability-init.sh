#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

MONITORING_NS="${MONITORING_NAMESPACE:-monitoring}"
OTEL_NS="${OTEL_NAMESPACE:-otel}"
BANKING_NS="${BANKING_NAMESPACE:-banking}"

PROMETHEUS_CHART_VERSION="${PROMETHEUS_CHART_VERSION:-69.8.2}"
LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-2.10.2}"
OTEL_CHART_VERSION="${OTEL_CHART_VERSION:-0.119.0}"

GRAFANA_LOCAL_PORT="${GRAFANA_LOCAL_PORT:-3001}"
PROMETHEUS_LOCAL_PORT="${PROMETHEUS_LOCAL_PORT:-9090}"
ALERTMANAGER_LOCAL_PORT="${ALERTMANAGER_LOCAL_PORT:-9093}"

SKIP_PROMETHEUS="${SKIP_PROMETHEUS:-false}"
SKIP_LOKI="${SKIP_LOKI:-false}"
SKIP_OTEL="${SKIP_OTEL:-false}"
SKIP_DATASOURCES="${SKIP_DATASOURCES:-false}"
SKIP_DASHBOARDS="${SKIP_DASHBOARDS:-false}"
SKIP_PORT_FORWARD="${SKIP_PORT_FORWARD:-false}"
DRY_RUN=false

GRAFANA_ADMIN_PASSWORD=""
GRAFANA_PF_STARTED=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}[obs]${NC} $*"; }
success() { echo -e "${GREEN}[obs]${NC} $*"; }
warn()    { echo -e "${YELLOW}[obs]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${MAGENTA}══ $* ══${NC}"; }
die()     { echo -e "${RED}[obs] ERROR:${NC} $*" >&2; exit 1; }

retry_cmd() {
  local attempts="$1" sleep_sec="$2"; shift 2
  local n=1
  until "$@"; do
    (( n >= attempts )) && return 1
    n=$((n + 1)); sleep "$sleep_sec"
  done
}

usage() {
  cat <<'USAGE'
Usage: ./scripts/k8s/observability-init.sh [options]

Bootstraps the DTB Banking Portal observability stack:
  - kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
  - loki-stack (Loki + Promtail)
  - opentelemetry-collector
  - Configures Grafana datasources (Prometheus + Loki) via HTTP API
  - Imports standard dashboards (Node Exporter, K8s Cluster, Loki Logs)
  - Port-forwards Grafana :3001, Prometheus :9090, Alertmanager :9093

Options:
  --skip-prometheus      Skip kube-prometheus-stack install
  --skip-loki            Skip loki-stack install
  --skip-otel            Skip opentelemetry-collector install
  --skip-datasources     Skip Grafana datasource configuration
  --skip-dashboards      Skip Grafana dashboard imports
  --skip-port-forward    Skip background port-forwards
  --namespace <ns>       Monitoring namespace (default: MONITORING_NAMESPACE or monitoring)
  --dry-run              Print actions without executing
  -h, --help             Show this help

Environment:
  MONITORING_NAMESPACE         Monitoring namespace (default: monitoring)
  OTEL_NAMESPACE               OTel namespace (default: otel)
  PROMETHEUS_CHART_VERSION     kube-prometheus-stack chart version (default: 69.8.2)
  LOKI_CHART_VERSION           loki-stack chart version (default: 2.10.2)
  OTEL_CHART_VERSION           opentelemetry-collector chart version (default: 0.119.0)
  GRAFANA_LOCAL_PORT           Local port for Grafana (default: 3001)
  PROMETHEUS_LOCAL_PORT        Local port for Prometheus (default: 9090)
  ALERTMANAGER_LOCAL_PORT      Local port for Alertmanager (default: 9093)
  GRAFANA_ADMIN_PASSWORD       Override Grafana admin password (read from secret by default)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-prometheus)   SKIP_PROMETHEUS="true" ;;
    --skip-loki)         SKIP_LOKI="true" ;;
    --skip-otel)         SKIP_OTEL="true" ;;
    --skip-datasources)  SKIP_DATASOURCES="true" ;;
    --skip-dashboards)   SKIP_DASHBOARDS="true" ;;
    --skip-port-forward) SKIP_PORT_FORWARD="true" ;;
    --namespace)
      [[ $# -ge 2 ]] || die "Missing value for --namespace"
      MONITORING_NS="$2"; shift ;;
    --dry-run) DRY_RUN=true; warn "DRY RUN — no cluster changes will be made" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1. Use --help for usage." ;;
  esac
  shift
done

preflight() {
  section "Preflight"

  command -v kubectl &>/dev/null || die "kubectl not found on PATH"
  command -v helm &>/dev/null    || die "helm not found on PATH — install: https://helm.sh/docs/intro/install/"
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

  if ! command -v curl &>/dev/null; then
    warn "curl not found — Grafana datasource and dashboard steps will be skipped"
    SKIP_DATASOURCES="true"
    SKIP_DASHBOARDS="true"
  else
    success "curl: $(command -v curl)"
  fi

  for ns in "$MONITORING_NS" "$OTEL_NS" "$BANKING_NS"; do
    $DRY_RUN || kubectl create namespace "$ns" 2>/dev/null || true
  done
  success "namespaces: ready"
}

ensure_helm_repos() {
  section "Helm Repositories"

  declare -A repos=(
    [prometheus-community]="https://prometheus-community.github.io/helm-charts"
    [grafana]="https://grafana.github.io/helm-charts"
    [open-telemetry]="https://open-telemetry.github.io/opentelemetry-helm-charts"
  )

  for name in "${!repos[@]}"; do
    local url="${repos[$name]}"
    if helm repo list 2>/dev/null | grep -q "^${name}[[:space:]]"; then
      log "helm repo '$name': already added"
    else
      log "adding helm repo: $name → $url"
      $DRY_RUN || helm repo add "$name" "$url"
      success "helm repo '$name' added"
    fi
  done

  log "updating helm repos..."
  $DRY_RUN || helm repo update
  success "helm repos updated"
}

install_kube_prometheus_stack() {
  section "Prometheus + Grafana + Alertmanager"

  if kubectl get deployment prometheus-grafana -n "$MONITORING_NS" &>/dev/null; then
    success "kube-prometheus-stack already installed — skipping"
    return 0
  fi

  log "installing kube-prometheus-stack v${PROMETHEUS_CHART_VERSION} in $MONITORING_NS..."
  $DRY_RUN || helm upgrade --install kube-prometheus-stack \
    prometheus-community/kube-prometheus-stack \
    --version "$PROMETHEUS_CHART_VERSION" \
    --namespace "$MONITORING_NS" \
    --create-namespace \
    --set grafana.service.type=ClusterIP \
    --set prometheus.prometheusSpec.retention=30d \
    --set "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=10Gi" \
    --wait \
    --timeout 10m

  $DRY_RUN && return 0

  log "waiting for prometheus-grafana..."
  kubectl rollout status deployment/prometheus-grafana \
    -n "$MONITORING_NS" --timeout=300s

  log "waiting for prometheus-kube-prometheus-operator..."
  kubectl rollout status deployment/prometheus-kube-prometheus-operator \
    -n "$MONITORING_NS" --timeout=300s

  log "waiting for prometheus StatefulSet..."
  kubectl rollout status statefulset/prometheus-kube-prometheus-prometheus \
    -n "$MONITORING_NS" --timeout=300s

  success "kube-prometheus-stack ready"
}

install_loki_stack() {
  section "Loki + Promtail"

  if kubectl get statefulset loki -n "$MONITORING_NS" &>/dev/null; then
    success "loki-stack already installed — skipping"
    return 0
  fi

  log "installing loki-stack v${LOKI_CHART_VERSION} in $MONITORING_NS..."
  $DRY_RUN || helm upgrade --install loki \
    grafana/loki-stack \
    --version "$LOKI_CHART_VERSION" \
    --namespace "$MONITORING_NS" \
    --set loki.enabled=true \
    --set loki.persistence.enabled=true \
    --set loki.persistence.size=10Gi \
    --set promtail.enabled=true \
    --set grafana.enabled=false \
    --wait \
    --timeout 5m

  $DRY_RUN && return 0

  log "waiting for loki StatefulSet..."
  kubectl rollout status statefulset/loki \
    -n "$MONITORING_NS" --timeout=180s

  log "waiting for loki-promtail DaemonSet..."
  kubectl rollout status daemonset/loki-promtail \
    -n "$MONITORING_NS" --timeout=180s

  success "loki-stack ready"
}

install_otel_collector() {
  section "OpenTelemetry Collector"

  if kubectl get deployment otel-collector-opentelemetry-collector \
      -n "$OTEL_NS" &>/dev/null; then
    success "opentelemetry-collector already installed — skipping"
    return 0
  fi

  log "installing opentelemetry-collector v${OTEL_CHART_VERSION} in $OTEL_NS..."
  $DRY_RUN || helm upgrade --install otel-collector \
    open-telemetry/opentelemetry-collector \
    --version "$OTEL_CHART_VERSION" \
    --namespace "$OTEL_NS" \
    --create-namespace \
    --set mode=deployment \
    --set image.repository=otel/opentelemetry-collector-k8s \
    --set "config.receivers.otlp.protocols.grpc.endpoint=0.0.0.0:4317" \
    --set "config.receivers.otlp.protocols.http.endpoint=0.0.0.0:4318" \
    --wait \
    --timeout 5m

  $DRY_RUN && return 0

  log "waiting for otel-collector deployment..."
  kubectl rollout status deployment/otel-collector-opentelemetry-collector \
    -n "$OTEL_NS" --timeout=180s

  success "opentelemetry-collector ready"
}

retrieve_grafana_password() {
  section "Grafana Credentials"
  $DRY_RUN && { GRAFANA_ADMIN_PASSWORD="${GRAFANA_DRY_RUN_PW:-<dry-run>}"; return 0; }

  if [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
    log "using GRAFANA_ADMIN_PASSWORD from environment"
    return 0
  fi

  if kubectl get secret prometheus-grafana -n "$MONITORING_NS" &>/dev/null; then
    GRAFANA_ADMIN_PASSWORD="$(
      kubectl get secret prometheus-grafana \
        -n "$MONITORING_NS" \
        -o jsonpath='{.data.admin-password}' | base64 -d
    )"
    export GRAFANA_ADMIN_PASSWORD
    success "Grafana admin password retrieved from prometheus-grafana secret"
  else
    GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-prom-operator}"
    warn "prometheus-grafana secret not found — using chart default password (GRAFANA_ADMIN_PASSWORD)"
    warn "Set GRAFANA_ADMIN_PASSWORD env var to override"
  fi
}

ensure_grafana_port_forward() {
  $DRY_RUN && return 0

  if lsof -i :"$GRAFANA_LOCAL_PORT" &>/dev/null 2>&1; then
    log "Grafana already reachable on :${GRAFANA_LOCAL_PORT}"
    GRAFANA_PF_STARTED=true
    return 0
  fi

  if ! kubectl get svc prometheus-grafana -n "$MONITORING_NS" &>/dev/null; then
    warn "prometheus-grafana service not found — datasource and dashboard steps will be skipped"
    GRAFANA_PF_STARTED=false
    return 0
  fi

  kubectl port-forward svc/prometheus-grafana \
    -n "$MONITORING_NS" \
    "${GRAFANA_LOCAL_PORT}:80" \
    >/tmp/grafana-api-pf.log 2>&1 &
  local pid=$!
  echo "$pid" > /tmp/obs-grafana-pf.pid
  sleep 4

  if kill -0 "$pid" 2>/dev/null; then
    log "Grafana API port-forward active on :${GRAFANA_LOCAL_PORT} (PID $pid)"
    GRAFANA_PF_STARTED=true
  else
    warn "Grafana port-forward failed — datasource and dashboard configuration will be skipped"
    GRAFANA_PF_STARTED=false
  fi
}

configure_grafana_datasources() {
  section "Grafana Datasources"

  if [[ "$SKIP_DATASOURCES" == "true" ]]; then
    log "skipping datasources (--skip-datasources)"
    return 0
  fi

  if [[ "$GRAFANA_PF_STARTED" == "false" ]]; then
    warn "Grafana not reachable — skipping datasource configuration"
    return 0
  fi

  $DRY_RUN && { log "DRY RUN: skipping Grafana API calls"; return 0; }

  local base="http://localhost:${GRAFANA_LOCAL_PORT}"
  local auth="admin:${GRAFANA_ADMIN_PASSWORD}"

  _ds_exists() {
    curl -sf -u "$auth" "${base}/api/datasources/name/${1}" &>/dev/null
  }

  _ds_id() {
    curl -sf -u "$auth" "${base}/api/datasources/name/${1}" \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo ""
  }

  _upsert_ds() {
    local name="$1" payload="$2"
    if _ds_exists "$name"; then
      local id; id="$(_ds_id "$name")"
      if [[ -n "$id" ]]; then
        curl -sf -X PUT -u "$auth" \
          -H "Content-Type: application/json" \
          -d "$payload" \
          "${base}/api/datasources/${id}" &>/dev/null
        log "datasource '$name': updated (id=$id)"
      fi
    else
      curl -sf -X POST -u "$auth" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${base}/api/datasources" &>/dev/null
      log "datasource '$name': created"
    fi
  }

  local prom_url="http://prometheus-kube-prometheus-prometheus.${MONITORING_NS}.svc.cluster.local:9090"
  _upsert_ds "Prometheus" "{
    \"name\": \"Prometheus\",
    \"type\": \"prometheus\",
    \"url\": \"${prom_url}\",
    \"access\": \"proxy\",
    \"isDefault\": true,
    \"jsonData\": {\"timeInterval\": \"30s\", \"httpMethod\": \"POST\"}
  }"
  success "Prometheus datasource: configured"

  local loki_url="http://loki.${MONITORING_NS}.svc.cluster.local:3100"
  _upsert_ds "Loki" "{
    \"name\": \"Loki\",
    \"type\": \"loki\",
    \"url\": \"${loki_url}\",
    \"access\": \"proxy\",
    \"isDefault\": false,
    \"jsonData\": {\"maxLines\": 1000}
  }"
  success "Loki datasource: configured"
}

import_grafana_dashboards() {
  section "Grafana Dashboards"

  if [[ "$SKIP_DASHBOARDS" == "true" ]]; then
    log "skipping dashboard imports (--skip-dashboards)"
    return 0
  fi

  if [[ "$GRAFANA_PF_STARTED" == "false" ]]; then
    warn "Grafana not reachable — skipping dashboard imports"
    return 0
  fi

  $DRY_RUN && { log "DRY RUN: skipping dashboard imports"; return 0; }

  local base="http://localhost:${GRAFANA_LOCAL_PORT}"
  local auth="admin:${GRAFANA_ADMIN_PASSWORD}"

  local dashboards=(
    "1860|DS_PROMETHEUS|prometheus|Prometheus|Node Exporter Full"
    "7249|DS_PROMETHEUS|prometheus|Prometheus|Kubernetes Cluster"
    "13639|DS_LOKI|loki|Loki|Loki Logs"
  )

  for entry in "${dashboards[@]}"; do
    IFS='|' read -r dash_id ds_input ds_type ds_name dash_title <<< "$entry"

    local existing
    existing=$(curl -sf -u "$auth" \
      "${base}/api/search?query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${dash_title}'))")" \
      | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

    if [[ "$existing" -gt 0 ]]; then
      log "dashboard '$dash_title' already exists — skipping"
      continue
    fi

    log "fetching dashboard $dash_id ($dash_title)..."
    local dash_json
    dash_json=$(curl -sf \
      "https://grafana.com/api/dashboards/${dash_id}/revisions/latest/download" \
      2>/dev/null || echo "")

    if [[ -z "$dash_json" ]]; then
      warn "could not fetch dashboard $dash_id from grafana.com — skipping"
      continue
    fi

    local import_payload
    import_payload=$(python3 - <<PYEOF
import json, sys
try:
    dashboard = json.loads('''${dash_json}''')
    dashboard['id'] = None
    payload = {
        'dashboard': dashboard,
        'overwrite': True,
        'folderId': 0,
        'inputs': [{
            'name': '${ds_input}',
            'type': 'datasource',
            'pluginId': '${ds_type}',
            'value': '${ds_name}'
        }]
    }
    print(json.dumps(payload))
except Exception as e:
    print('{}', file=sys.stderr)
    sys.exit(1)
PYEOF
    ) || { warn "could not build payload for dashboard $dash_id — skipping"; continue; }

    local result
    result=$(curl -sf -X POST -u "$auth" \
      -H "Content-Type: application/json" \
      -d "$import_payload" \
      "${base}/api/dashboards/import" 2>/dev/null || echo "")

    if echo "$result" | grep -q '"status":"success"'; then
      success "dashboard '$dash_title' (ID $dash_id): imported"
    else
      warn "dashboard '$dash_title': import may have failed — verify in Grafana UI"
    fi
  done
}

_start_pf() {
  local name="$1" svc="$2" ns="$3" local_port="$4" remote_port="$5" log_file="$6"

  if lsof -i :"$local_port" &>/dev/null 2>&1; then
    success "$name: already forwarding on :$local_port"
    return 0
  fi

  if ! kubectl get svc "$svc" -n "$ns" &>/dev/null; then
    warn "$svc not found in $ns — skipping port-forward"
    return 0
  fi

  kubectl port-forward "svc/$svc" \
    "${local_port}:${remote_port}" -n "$ns" \
    >"$log_file" 2>&1 &
  local pid=$!
  sleep 3

  if kill -0 "$pid" 2>/dev/null; then
    success "$name port-forward: PID $pid → :$local_port"
  else
    warn "$name port-forward failed — start manually:"
    warn "  kubectl port-forward svc/$svc ${local_port}:${remote_port} -n $ns &"
    warn "  (log: $log_file)"
  fi
}

open_observability_uis() {
  section "Port Forwards"

  if [[ "$SKIP_PORT_FORWARD" == "true" ]]; then
    log "skipping port-forwards (--skip-port-forward)"
    return 0
  fi

  $DRY_RUN && {
    log "DRY RUN: would port-forward Grafana:${GRAFANA_LOCAL_PORT}, Prometheus:${PROMETHEUS_LOCAL_PORT}, Alertmanager:${ALERTMANAGER_LOCAL_PORT}"
    return 0
  }

  _start_pf "Grafana" \
    "prometheus-grafana" "$MONITORING_NS" \
    "$GRAFANA_LOCAL_PORT" "80" \
    "/tmp/grafana-pf.log"

  _start_pf "Prometheus" \
    "prometheus-kube-prometheus-prometheus" "$MONITORING_NS" \
    "$PROMETHEUS_LOCAL_PORT" "9090" \
    "/tmp/prometheus-pf.log"

  _start_pf "Alertmanager" \
    "prometheus-kube-prometheus-alertmanager" "$MONITORING_NS" \
    "$ALERTMANAGER_LOCAL_PORT" "9093" \
    "/tmp/alertmanager-pf.log"
}

print_observability_summary() {
  section "Observability Stack Ready"

  local pw_display="$GRAFANA_ADMIN_PASSWORD"
  [[ "$DRY_RUN" == "true" ]] && pw_display="<dry-run>"

  echo ""
  printf "  %-16s %-32s %s\n" "COMPONENT" "URL" "CREDENTIALS"
  printf "  %-16s %-32s %s\n" "---------" "---" "-----------"
  printf "  %-16s %-32s %s\n" "Grafana" "http://localhost:${GRAFANA_LOCAL_PORT}" "admin / ${pw_display}"
  printf "  %-16s %-32s %s\n" "Prometheus" "http://localhost:${PROMETHEUS_LOCAL_PORT}" "(no auth)"
  printf "  %-16s %-32s %s\n" "Alertmanager" "http://localhost:${ALERTMANAGER_LOCAL_PORT}" "(no auth)"
  printf "  %-16s %-32s %s\n" "Loki" "(in-cluster only)" "${MONITORING_NS}:3100"
  printf "  %-16s %-32s %s\n" "OTel Collector" "(in-cluster only)" "${OTEL_NS}:4317 (gRPC)"
  echo ""
  echo -e "  ${BOLD}Grafana dashboards imported:${NC}"
  echo  "    Node Exporter Full  (ID 1860) — host/node metrics"
  echo  "    Kubernetes Cluster  (ID 7249) — cluster overview"
  echo  "    Loki Logs           (ID 13639) — log explorer"
  echo ""
  echo -e "  ${BOLD}Quick commands:${NC}"
  echo  "    helm list -n $MONITORING_NS"
  echo  "    helm list -n $OTEL_NS"
  echo  "    kubectl get pods -n $MONITORING_NS"
  echo  "    kubectl get pods -n $OTEL_NS"
  echo ""
}

echo ""
echo -e "${BOLD}DTB Banking Portal — Observability Stack Bootstrap${NC}"
echo -e "  monitoring ns : $MONITORING_NS"
echo -e "  otel ns       : $OTEL_NS"
$DRY_RUN && echo -e "  ${YELLOW}DRY RUN — no cluster changes${NC}"
echo ""

preflight
ensure_helm_repos

$SKIP_PROMETHEUS || install_kube_prometheus_stack
$SKIP_LOKI       || install_loki_stack
$SKIP_OTEL       || install_otel_collector

retrieve_grafana_password
ensure_grafana_port_forward
configure_grafana_datasources
import_grafana_dashboards
open_observability_uis
print_observability_summary

success "observability stack ready"
echo ""
