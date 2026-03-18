#!/usr/bin/env bash
# Usage: ./scripts/k8s/teardown-observability.sh [OPTIONS]
#
# Tears down the observability stack created by observability-init.sh:
#   - Helm uninstalls: kube-prometheus-stack, loki, otel-collector
#   - Deletes Grafana datasource/dashboard ConfigMaps
#   - Deletes the monitoring and otel namespaces
#   - Kills any Grafana/Prometheus/Alertmanager port-forward processes
#
# Options:
#   --skip-prometheus      Skip kube-prometheus-stack uninstall
#   --skip-loki            Skip loki-stack uninstall
#   --skip-otel            Skip opentelemetry-collector uninstall
#   --keep-namespaces      Do NOT delete the monitoring/otel namespaces
#   --namespace <ns>       Monitoring namespace (default: monitoring)
#   --dry-run              Print what would be done without executing
#   -h, --help             Show this help
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}[obs-teardown]${NC} $*"; }
success() { echo -e "${GREEN}[obs-teardown]${NC} $*"; }
warn()    { echo -e "${YELLOW}[obs-teardown]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${MAGENTA}══ $* ══${NC}"; }
die()     { echo -e "${RED}[obs-teardown] ERROR:${NC} $*" >&2; exit 1; }

MONITORING_NS="${MONITORING_NAMESPACE:-monitoring}"
OTEL_NS="${OTEL_NAMESPACE:-otel}"

SKIP_PROMETHEUS=false
SKIP_LOKI=false
SKIP_OTEL=false
KEEP_NAMESPACES=false
DRY_RUN=false

usage() {
  sed -n '/^# Usage:/,/^set -/p' "$0" | grep '^#' | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-prometheus)  SKIP_PROMETHEUS=true ;;
    --skip-loki)        SKIP_LOKI=true ;;
    --skip-otel)        SKIP_OTEL=true ;;
    --keep-namespaces)  KEEP_NAMESPACES=true ;;
    --namespace)
      [[ $# -ge 2 ]] || die "Missing value for --namespace"
      MONITORING_NS="$2"; shift ;;
    --dry-run) DRY_RUN=true; warn "DRY RUN — no changes will be made" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1. Use --help for usage." ;;
  esac
  shift
done

helm_uninstall() {
  local release="$1" ns="$2"
  if $DRY_RUN; then
    echo "  DRY RUN: helm uninstall $release -n $ns"
    return 0
  fi
  if helm status "$release" -n "$ns" &>/dev/null 2>&1; then
    log "Helm uninstalling: $release in $ns..."
    helm uninstall "$release" -n "$ns" --wait --timeout 5m 2>/dev/null \
      && success "Uninstalled: $release" \
      || warn "helm uninstall $release returned non-zero — resources may be partially removed"
  else
    log "Helm release $release not found in $ns — skipping"
  fi
}

delete_ns() {
  local ns="$1"
  if $DRY_RUN; then
    echo "  DRY RUN: kubectl delete namespace $ns"
    return 0
  fi
  if kubectl get namespace "$ns" &>/dev/null 2>&1; then
    log "Deleting namespace: $ns..."
    kubectl delete namespace "$ns" --ignore-not-found 2>/dev/null || true
    local elapsed=0
    while kubectl get namespace "$ns" &>/dev/null 2>&1; do
      (( elapsed >= 60 )) && { warn "Namespace $ns still terminating — continuing"; break; }
      sleep 3; elapsed=$(( elapsed + 3 ))
    done
    kubectl get namespace "$ns" &>/dev/null 2>&1 \
      && warn "$ns still exists — may have stuck finalizers" \
      || success "Namespace $ns deleted"
  else
    log "Namespace $ns not found — skipping"
  fi
}

# ── Preflight ──────────────────────────────────────────────────────────────────
command -v kubectl &>/dev/null || die "kubectl not found on PATH"
command -v helm    &>/dev/null || die "helm not found on PATH"
kubectl cluster-info --request-timeout=5s &>/dev/null || die "Cluster unreachable — is minikube running?"

# ── Kill port-forward processes ───────────────────────────────────────────────
section "Stop Observability Port-Forwards"
if ! $DRY_RUN; then
  for pattern in \
    "port-forward.*3001" \
    "port-forward.*9090" \
    "port-forward.*9093" \
    "kubectl.*grafana" \
    "kubectl.*prometheus" \
    "kubectl.*alertmanager"; do
    pkill -f "$pattern" 2>/dev/null || true
  done
  log "Port-forward processes stopped"
else
  echo "  DRY RUN: pkill -f port-forward (grafana:3001, prometheus:9090, alertmanager:9093)"
fi
success "Port-forwards cleaned up"

# ── Prometheus + Grafana ──────────────────────────────────────────────────────
if ! $SKIP_PROMETHEUS; then
  section "kube-prometheus-stack (Prometheus + Grafana + Alertmanager)"

  helm_uninstall "kube-prometheus-stack" "$MONITORING_NS"

  # Remove CRDs left behind by kube-prometheus-stack
  if ! $DRY_RUN; then
    log "Removing Prometheus Operator CRDs..."
    for crd in \
      alertmanagerconfigs.monitoring.coreos.com \
      alertmanagers.monitoring.coreos.com \
      podmonitors.monitoring.coreos.com \
      probes.monitoring.coreos.com \
      prometheusagents.monitoring.coreos.com \
      prometheuses.monitoring.coreos.com \
      prometheusrules.monitoring.coreos.com \
      scrapeconfigs.monitoring.coreos.com \
      servicemonitors.monitoring.coreos.com \
      thanosrulers.monitoring.coreos.com; do
      kubectl delete crd "$crd" --ignore-not-found 2>/dev/null || true
    done
    success "Prometheus Operator CRDs removed"
  else
    echo "  DRY RUN: kubectl delete crd alertmanagers.monitoring.coreos.com (and others)"
  fi

  # Remove Grafana-specific ConfigMaps/Secrets if left over
  if ! $DRY_RUN; then
    kubectl delete configmap \
      grafana-datasources grafana-dashboards grafana-dashboard-config \
      -n "$MONITORING_NS" --ignore-not-found 2>/dev/null || true
  fi
else
  log "Skipping kube-prometheus-stack uninstall (--skip-prometheus)"
fi

# ── Loki ──────────────────────────────────────────────────────────────────────
if ! $SKIP_LOKI; then
  section "Loki + Promtail"
  helm_uninstall "loki" "$MONITORING_NS"

  # Loki PVCs are not removed by helm uninstall
  if ! $DRY_RUN; then
    log "Removing Loki PersistentVolumeClaims..."
    kubectl delete pvc -l "app=loki" -n "$MONITORING_NS" --ignore-not-found 2>/dev/null || true
    kubectl delete pvc -l "app.kubernetes.io/name=loki" -n "$MONITORING_NS" --ignore-not-found 2>/dev/null || true
    success "Loki PVCs removed"
  else
    echo "  DRY RUN: kubectl delete pvc -l app=loki -n $MONITORING_NS"
  fi
else
  log "Skipping Loki uninstall (--skip-loki)"
fi

# ── OpenTelemetry Collector ───────────────────────────────────────────────────
if ! $SKIP_OTEL; then
  section "OpenTelemetry Collector"
  helm_uninstall "otel-collector" "$OTEL_NS"

  # Remove OTel CRDs if present
  if ! $DRY_RUN; then
    kubectl delete crd opentelemetrycollectors.opentelemetry.io --ignore-not-found 2>/dev/null || true
    kubectl delete crd instrumentations.opentelemetry.io --ignore-not-found 2>/dev/null || true
  else
    echo "  DRY RUN: kubectl delete crd opentelemetrycollectors.opentelemetry.io"
  fi
else
  log "Skipping OTel uninstall (--skip-otel)"
fi

# ── Monitoring ConfigMaps in banking namespace ────────────────────────────────
section "Observability ConfigMaps in banking namespace"
BANKING_NS="${BANKING_NAMESPACE:-banking}"
if ! $DRY_RUN; then
  kubectl delete configmap prometheus-config otel-config -n "$BANKING_NS" --ignore-not-found 2>/dev/null || true
else
  echo "  DRY RUN: kubectl delete configmap prometheus-config otel-config -n $BANKING_NS"
fi

# ── Namespaces ────────────────────────────────────────────────────────────────
if ! $KEEP_NAMESPACES; then
  section "Delete Namespaces"
  delete_ns "$OTEL_NS"
  delete_ns "$MONITORING_NS"
else
  log "Keeping namespaces $MONITORING_NS + $OTEL_NS (--keep-namespaces)"
fi

section "Observability Teardown Complete"
echo ""
$SKIP_PROMETHEUS || echo -e "  ${GREEN}✓${NC} kube-prometheus-stack uninstalled (Prometheus + Grafana + Alertmanager)"
$SKIP_LOKI       || echo -e "  ${GREEN}✓${NC} Loki + Promtail uninstalled"
$SKIP_OTEL       || echo -e "  ${GREEN}✓${NC} OpenTelemetry Collector uninstalled"
$KEEP_NAMESPACES || echo -e "  ${GREEN}✓${NC} Namespaces $MONITORING_NS + $OTEL_NS deleted"
echo -e "  ${GREEN}✓${NC} Port-forwards stopped"
echo ""
echo -e "  To reinstall: ${CYAN}./scripts/k8s/observability-init.sh${NC}"
echo ""
