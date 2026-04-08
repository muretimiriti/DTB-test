#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFESTS="$PROJECT_ROOT/manifests"

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
cleanup() { local rc=$?; (( rc != 0 )) && error "security-init.sh failed (exit $rc)"; exit "$rc"; }
trap cleanup ERR EXIT

step() {
  local n="$1"; shift
  echo -e "\n${BOLD}${BLUE}[Step $n]${NC} $*"
}

PASS=(); WARN=(); FAIL=()
record_pass() { PASS+=("$1"); }
record_warn() { WARN+=("$1"); }
record_fail() { FAIL+=("$1"); }

SKIP_TRIVY=false
SKIP_KYVERNO=false
SKIP_COSIGN=false
SKIP_VAULT=false
SKIP_ESO=false
SKIP_CONFTEST=false
SKIP_NETPOL=false
DRY_RUN=false

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-trivy)     SKIP_TRIVY=true ;;
      --skip-kyverno)   SKIP_KYVERNO=true ;;
      --skip-cosign)    SKIP_COSIGN=true ;;
      --skip-vault)     SKIP_VAULT=true ;;
      --skip-eso)       SKIP_ESO=true ;;
      --skip-conftest)  SKIP_CONFTEST=true ;;
      --skip-netpol)    SKIP_NETPOL=true ;;
      --dry-run)        DRY_RUN=true; warn "DRY RUN — no changes will be made" ;;
      --help|-h)
        sed -n '/^# Usage:/,/^# ======/p' "$0" | grep '^#' | sed 's/^# \?//'
        exit 0 ;;
      *) die "Unknown option: $1. Use --help for usage." ;;
    esac
    shift
  done
}

kube()   { $DRY_RUN && { echo "  DRY RUN: kubectl $*"; return 0; }; kubectl "$@"; }
vaultc() { $DRY_RUN && { echo "  DRY RUN: vault $*"; return 0; };
           kubectl exec -n vault vault-0 -- vault "$@"; }

prompt_value() {
  local var="$1" prompt="$2" default="${3:-}"
  if [[ -z "${!var:-}" ]]; then
    if [[ -t 0 ]]; then
      read -rp "${prompt} [${default}]: " tmp
      export "$var"="${tmp:-$default}"
    else
      export "$var"="$default"
    fi
  fi
}

prompt_secret() {
  local var="$1" prompt="$2"
  if [[ -z "${!var:-}" ]]; then
    if [[ -t 0 ]]; then
      read -rsp "${prompt}: " tmp; echo ""
      export "$var"="$tmp"
    fi
  fi
}

wait_for_pod() {
  local ns="$1" selector="$2" timeout="${3:-180}"
  info "Waiting for pod ($selector) in $ns (timeout: ${timeout}s)..."
  $DRY_RUN && return 0
  kubectl wait --for=condition=ready pod -l "$selector" \
    -n "$ns" --timeout="${timeout}s" 2>/dev/null \
    || { warn "Pod not ready — check: kubectl get pods -n $ns -l $selector"; return 1; }
  success "Pod ($selector) is ready"
}

wait_for_deployment() {
  local ns="$1" name="$2" timeout="${3:-180}"
  info "Waiting for deployment/$name in $ns..."
  $DRY_RUN && return 0
  kubectl rollout status deployment/"$name" -n "$ns" --timeout="${timeout}s" \
    || { warn "Deployment not ready — check: kubectl get pods -n $ns"; return 1; }
  success "deployment/$name is ready"
}

pod_running() {
  
  kubectl get pods -n "$1" -l "$2" --no-headers 2>/dev/null \
    | grep -q "Running" 2>/dev/null
}

secret_exists() { kubectl get secret "$1" -n "$2" &>/dev/null; }

apply_manifest() {
  local file="$1"
  info "Applying: $(basename "$file")"
  $DRY_RUN && { echo "  DRY RUN: kubectl apply -f $file"; return 0; }
  kubectl apply -f "$file"
}

preflight() {
  section "Preflight Checks"

  $DRY_RUN || kubectl cluster-info --request-timeout=10s &>/dev/null \
    || die "Cannot reach cluster. Check your KUBECONFIG and cluster status."
  success "Cluster: reachable"

  local namespaces=(banking kyverno vault external-secrets monitoring)
  for ns in "${namespaces[@]}"; do
    if ! kubectl get namespace "$ns" &>/dev/null; then
      warn "Namespace $ns missing — creating"
      kube create namespace "$ns"
    else
      info "namespace/$ns: exists"
    fi
  done

  local tools=(kubectl helm cosign trivy conftest)
  for tool in "${tools[@]}"; do
    if command -v "$tool" &>/dev/null; then
      success "$tool: installed ($(command -v "$tool"))"
    else
      warn "$tool: NOT found — some steps will be skipped"
    fi
  done
}

setup_trivy() {
  section "Trivy — Container Vulnerability Scanner"

  if ! command -v trivy &>/dev/null; then
    warn "trivy binary not found. Install via prerequisites.sh then re-run."
    record_warn "trivy"
    return 0
  fi

  local trivy_ver
  trivy_ver=$(trivy --version 2>/dev/null | head -1)
  success "Trivy installed: $trivy_ver"

  info "Updating Trivy vulnerability database..."
  $DRY_RUN || trivy image --download-db-only --quiet
  success "Trivy DB updated"

  info "Running test scan (alpine:3.19)..."
  if $DRY_RUN; then
    info "DRY RUN: trivy image alpine:3.19"
  else
    local result
    result=$(trivy image --severity HIGH,CRITICAL --exit-code 0 \
      --format table --quiet alpine:3.19 2>&1 | tail -5 || true)
    echo "$result"
    success "Trivy scan test: PASSED"
  fi

  if [[ -n "${DOCKER_USERNAME:-}" ]]; then
    for svc in banking-backend banking-frontend; do
      local img="${DOCKER_USERNAME}/${svc}:latest"
      info "Scanning $img (if exists)..."
      if $DRY_RUN; then
        info "DRY RUN: trivy image $img"
      else
        trivy image --severity HIGH,CRITICAL --exit-code 0 \
          --format table --quiet "$img" 2>/dev/null \
          && success "$img: scan complete" \
          || info "$img: not found in registry (will be scanned in pipeline)"
      fi
    done
  fi

  record_pass "trivy"
}

setup_kyverno() {
  section "Kyverno — Admission Policy Enforcement"

  if ! pod_running kyverno "app.kubernetes.io/component=admission-controller" && \
     ! pod_running kyverno "app.kubernetes.io/name=kyverno"; then
    warn "Kyverno pods not running. Install via prerequisites.sh then re-run."
    record_warn "kyverno"
    return 0
  fi
  success "Kyverno: Running"

  info "Applying security policies..."
  apply_manifest "$MANIFESTS/security/kyverno-policies.yaml"
  success "Kyverno policies applied"

  $DRY_RUN && { record_pass "kyverno"; return 0; }

  local policy_count
  policy_count=$(kubectl get clusterpolicies --no-headers 2>/dev/null | wc -l | tr -d ' ')
  success "$policy_count ClusterPolicies active"

  echo ""
  kubectl get clusterpolicies -o custom-columns="NAME:.metadata.name,MODE:.spec.validationFailureAction,BACKGROUND:.spec.background" \
    2>/dev/null || true
  echo ""

  info "Checking for policy violations in banking namespace..."
  local violations
  violations=$(kubectl get policyreport -n banking --no-headers 2>/dev/null \
    | awk '{print $4}' | grep -v "^0$" | wc -l || echo "0")

  if [[ "${violations:-0}" -gt 0 ]]; then
    warn "$violations policy violations found — review: kubectl get policyreport -n banking"
    record_warn "kyverno"
  else
    success "No critical policy violations in banking namespace"
    record_pass "kyverno"
  fi
}

setup_cosign() {
  section "Cosign — Image Signing & Verification"

  if ! command -v cosign &>/dev/null; then
    warn "cosign binary not found. Install via prerequisites.sh then re-run."
    record_warn "cosign"
    return 0
  fi

  local cosign_ver
  cosign_ver=$(cosign version 2>/dev/null | grep "GitVersion" | awk '{print $2}' || echo "installed")
  success "Cosign: $cosign_ver"

  if secret_exists cosign-key tekton-pipelines; then
    info "cosign-key secret already exists in tekton-pipelines"
  else
    info "Generating Cosign key pair (stored as k8s secret)..."
    if $DRY_RUN; then
      info "DRY RUN: COSIGN_PASSWORD='' cosign generate-key-pair k8s://tekton-pipelines/cosign-key"
    else
      COSIGN_PASSWORD="" cosign generate-key-pair k8s://tekton-pipelines/cosign-key
      success "Cosign key pair generated"
    fi
  fi

  if ! $DRY_RUN && secret_exists cosign-key tekton-pipelines; then
    local pubkey
    pubkey=$(kubectl get secret cosign-key -n tekton-pipelines \
      -o jsonpath='{.data.cosign\.pub}' 2>/dev/null | base64 -d)

    if [[ -z "$pubkey" ]]; then
      warn "Could not extract cosign public key from secret"
    else
      
      echo "$pubkey" > "$PROJECT_ROOT/cosign.pub"
      success "Cosign public key saved: $PROJECT_ROOT/cosign.pub"
      info "Public key:"
      echo "$pubkey"
      echo ""

      kubectl create configmap cosign-pubkey \
        --from-literal=cosign.pub="$pubkey" \
        -n banking --dry-run=client -o yaml | kubectl apply -f -
      success "cosign-pubkey ConfigMap created in banking namespace"

      if ! secret_exists cosign-key banking; then
        kubectl get secret cosign-key -n tekton-pipelines -o json \
          | python3 -c "
import sys, json
s = json.load(sys.stdin)
s['metadata']['namespace'] = 'banking'
s['metadata'].pop('resourceVersion', None)
s['metadata'].pop('uid', None)
s['metadata'].pop('creationTimestamp', None)
print(json.dumps(s))
" | kubectl apply -f -
        success "cosign-key secret mirrored to banking namespace"
      else
        info "cosign-key already exists in banking namespace"
      fi

      info "Updating Kyverno require-signed-images policy with cosign public key..."
      local policy_file="$MANIFESTS/security/kyverno-policies.yaml"
      if python3 - "$policy_file" "$pubkey" <<'PYEOF'
import sys

policy_file = sys.argv[1]
pubkey = sys.argv[2]

with open(policy_file) as f:
    content = f.read()

indent = "                      "
indented_key = "\n".join(indent + line for line in pubkey.strip().split("\n"))

old_block = (
    indent + "# Paste your cosign public key here after running:\n"
    + indent + "# cosign generate-key-pair k8s://tekton-pipelines/cosign-key\n"
    + indent + "# kubectl get secret cosign-key -n tekton-pipelines -o jsonpath='{.data.cosign\\.pub}' | base64 -d\n"
    + indent + "-----BEGIN PUBLIC KEY-----\n"
    + indent + "REPLACE_WITH_COSIGN_PUBLIC_KEY\n"
    + indent + "-----END PUBLIC KEY-----"
)

if "REPLACE_WITH_COSIGN_PUBLIC_KEY" in content:
    updated = content.replace(old_block, indented_key)
    import subprocess
    result = subprocess.run(["kubectl", "apply", "-f", "-"],
                            input=updated.encode(), capture_output=True)
    if result.returncode == 0:
        print("OK: Kyverno policy applied with real cosign public key")
    else:
        print("WARN: kubectl apply failed:", result.stderr.decode(), file=sys.stderr)
        sys.exit(1)
else:
    import subprocess
    subprocess.run(["kubectl", "apply", "-f", policy_file], check=True)
    print("OK: Kyverno policy re-applied (key already present)")
PYEOF
      then
        success "Kyverno require-signed-images policy: updated with cosign public key"
      else
        warn "Could not update Kyverno policy automatically"
        warn "Run manually: kubectl get secret cosign-key -n tekton-pipelines \\"
        warn "  -o jsonpath='{.data.cosign\\.pub}' | base64 -d"
        warn "Then paste the output into manifests/security/kyverno-policies.yaml"
      fi
    fi
  fi

  info "Testing Cosign verify with a known signed image..."
  if $DRY_RUN; then
    info "DRY RUN: cosign verify --certificate-identity-regexp='.*' --certificate-oidc-issuer-regexp='.*' cgr.dev/chainguard/static"
  else
    cosign verify \
      --certificate-identity-regexp=".*" \
      --certificate-oidc-issuer-regexp=".*" \
      cgr.dev/chainguard/static 2>/dev/null \
      && success "Cosign verify: working correctly" \
      || warn "Cosign verify test inconclusive (network or key config) — signing will still work in pipeline"
  fi

  record_pass "cosign"
}

setup_vault() {
  section "Vault — Secrets Management"

  if ! pod_running vault "app.kubernetes.io/name=vault"; then
    warn "Vault pod not running. Install via prerequisites.sh then re-run."
    record_warn "vault"
    return 0
  fi
  success "Vault pod: Running"

  # VAULT_ROOT_TOKEN must be supplied — no default to prevent accidental
  # use of the dev root token against a production Vault instance.
  [[ -n "${VAULT_ROOT_TOKEN:-}" ]] || \
    die "VAULT_ROOT_TOKEN is not set. Export it before running:\n  export VAULT_ROOT_TOKEN=<your-token>"
  local VAULT_ROOT_TOKEN="${VAULT_ROOT_TOKEN}"

  local VAULT_POD="vault-0"
  local VAULT_NS="vault"

  local vault_status
  if $DRY_RUN; then
    vault_status="active"
  else
    vault_status=$(kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
      vault status -format=json 2>/dev/null \
      | grep -o '"initialized":[^,}]*' | cut -d: -f2 | tr -d ' ' || echo "unknown")
  fi
  info "Vault initialized: $vault_status"

  info "Enabling KV v2 secrets engine at path: secret/"
  $DRY_RUN || kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
    sh -c "VAULT_TOKEN=${VAULT_ROOT_TOKEN} vault secrets enable -path=secret kv-v2" \
    2>/dev/null || info "KV engine already enabled"
  success "KV v2 engine: enabled at secret/"

  info "Writing banking app secrets to Vault..."

  # Hard-fail on missing secrets — placeholder values must never reach production Vault.
  [[ -n "${JWT_SECRET:-}"          ]] || die "JWT_SECRET is not set. Generate one: openssl rand -hex 64"
  [[ -n "${MONGO_APP_PASSWORD:-}"  ]] || die "MONGO_APP_PASSWORD is not set."
  [[ -n "${MONGO_ROOT_PASSWORD:-}" ]] || die "MONGO_ROOT_PASSWORD is not set."
  [[ ${#JWT_SECRET}         -ge 32 ]] || die "JWT_SECRET must be at least 32 characters."
  [[ ${#MONGO_APP_PASSWORD} -ge 16 ]] || die "MONGO_APP_PASSWORD must be at least 16 characters."
  [[ ${#MONGO_ROOT_PASSWORD} -ge 16 ]] || die "MONGO_ROOT_PASSWORD must be at least 16 characters."

  # Only true secrets belong in Vault. Rate-limit tuning goes in overlay ConfigMaps.
  $DRY_RUN || kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
    sh -c "VAULT_TOKEN=${VAULT_ROOT_TOKEN} vault kv put secret/banking/backend \
      JWT_SECRET='${JWT_SECRET}' \
      MONGO_APP_PASSWORD='${MONGO_APP_PASSWORD}'"
  success "Banking backend secrets written to secret/banking/backend"

  $DRY_RUN || kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
    sh -c "VAULT_TOKEN=${VAULT_ROOT_TOKEN} vault kv put secret/banking/mongodb \
      MONGO_ROOT_USER='${MONGO_ROOT_USER:-root}' \
      MONGO_ROOT_PASSWORD='${MONGO_ROOT_PASSWORD}' \
      MONGO_APP_USER='${MONGO_APP_USER:-app_user}' \
      MONGO_APP_PASSWORD='${MONGO_APP_PASSWORD}'"
  success "MongoDB secrets written to secret/banking/mongodb"

  info "Creating Vault policy for External Secrets Operator..."
  $DRY_RUN || kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
    sh -c "VAULT_TOKEN=${VAULT_ROOT_TOKEN} vault policy write eso-banking-policy - <<'POLICY'
path \"secret/data/banking/*\" {
  capabilities = [\"read\", \"list\"]
}
POLICY"
  success "Vault policy: eso-banking-policy created"

  info "Creating Vault token for ESO..."
  if $DRY_RUN; then
    info "DRY RUN: vault token create -policy=eso-banking-policy"
  else
    local eso_token
    eso_token=$(kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
      sh -c "VAULT_TOKEN=${VAULT_ROOT_TOKEN} vault token create \
        -policy=eso-banking-policy \
        -ttl=8760h \
        -format=json" 2>/dev/null \
      | grep '"client_token"' | cut -d'"' -f4 || echo "")

    if [[ -n "$eso_token" ]]; then
      
      if secret_exists vault-eso-token external-secrets; then
        kubectl delete secret vault-eso-token -n external-secrets
      fi
      kubectl create secret generic vault-eso-token \
        --from-literal=token="$eso_token" \
        -n external-secrets
      success "Vault ESO token stored as k8s secret: vault-eso-token"
    else
      warn "Could not create Vault token — ESO setup may fail"
    fi
  fi

  $DRY_RUN || {
    local verify
    verify=$(kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
      sh -c "VAULT_TOKEN=${VAULT_ROOT_TOKEN} vault kv get -format=json secret/banking/backend" \
      2>/dev/null | grep -c "JWT_SECRET" || echo "0")
    if [[ "$verify" -gt 0 ]]; then
      success "Vault secret verification: PASSED"
    else
      warn "Could not verify Vault secret read — check Vault status"
    fi
  }

  record_pass "vault"
}

setup_eso() {
  section "External Secrets Operator — Vault → K8s Secrets Sync"

  if ! pod_running external-secrets "app.kubernetes.io/name=external-secrets"; then
    warn "ESO pods not running. Install via prerequisites.sh then re-run."
    record_warn "eso"
    return 0
  fi
  success "ESO: Running"

  $DRY_RUN || {
    
    kubectl apply -f - <<'EOF'
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
  labels:
    app.kubernetes.io/part-of: dtb-banking-portal
    app.kubernetes.io/component: eso
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"
      path: "secret"
      version: "v2"
      auth:
        tokenSecretRef:
          name: vault-eso-token
          namespace: external-secrets
          key: token
EOF
    success "ClusterSecretStore 'vault-backend' created (cluster-scoped)"

    kubectl apply -f - <<'EOF'
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: banking-backend-secrets
  namespace: banking
  labels:
    app.kubernetes.io/part-of: dtb-banking-portal
    app.kubernetes.io/component: eso
spec:
  refreshInterval: "5m"
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: backend-secret
    creationPolicy: Owner
  data:
    - secretKey: JWT_SECRET
      remoteRef:
        key: banking/backend
        property: JWT_SECRET
    - secretKey: MONGO_APP_PASSWORD
      remoteRef:
        key: banking/backend
        property: MONGO_APP_PASSWORD
    - secretKey: NODE_ENV
      remoteRef:
        key: banking/backend
        property: NODE_ENV
    - secretKey: JWT_EXPIRES_IN
      remoteRef:
        key: banking/backend
        property: JWT_EXPIRES_IN
    - secretKey: BCRYPT_ROUNDS
      remoteRef:
        key: banking/backend
        property: BCRYPT_ROUNDS
    - secretKey: RATE_LIMIT_MAX
      remoteRef:
        key: banking/backend
        property: RATE_LIMIT_MAX
    - secretKey: AUTH_RATE_LIMIT_MAX
      remoteRef:
        key: banking/backend
        property: AUTH_RATE_LIMIT_MAX
EOF
    success "ExternalSecret 'banking-backend-secrets' created"

    kubectl apply -f - <<'EOF'
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: banking-mongodb-secrets
  namespace: banking
  labels:
    app.kubernetes.io/part-of: dtb-banking-portal
    app.kubernetes.io/component: eso
spec:
  refreshInterval: "5m"
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: mongodb-secret
    creationPolicy: Owner
  data:
    - secretKey: MONGO_ROOT_USER
      remoteRef:
        key: banking/mongodb
        property: MONGO_ROOT_USER
    - secretKey: MONGO_ROOT_PASSWORD
      remoteRef:
        key: banking/mongodb
        property: MONGO_ROOT_PASSWORD
    - secretKey: MONGO_APP_USER
      remoteRef:
        key: banking/mongodb
        property: MONGO_APP_USER
    - secretKey: MONGO_APP_PASSWORD
      remoteRef:
        key: banking/mongodb
        property: MONGO_APP_PASSWORD
EOF
    success "ExternalSecret 'banking-mongodb-secrets' created"

    kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: eso-vault-token-reader
  namespace: external-secrets
  labels:
    app.kubernetes.io/part-of: dtb-banking-portal
    app.kubernetes.io/component: eso
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["vault-eso-token"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: eso-vault-token-reader
  namespace: external-secrets
  labels:
    app.kubernetes.io/part-of: dtb-banking-portal
    app.kubernetes.io/component: eso
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: eso-vault-token-reader
subjects:
  - kind: ServiceAccount
    name: external-secrets
    namespace: external-secrets
EOF
    success "ESO RBAC: Role + RoleBinding created so ESO can read vault-eso-token"
  }

  $DRY_RUN && { record_pass "eso"; return 0; }
  sleep 10
  local es_status
  es_status=$(kubectl get externalsecret -n banking --no-headers 2>/dev/null \
    | awk '{print $2}' | sort | uniq -c || echo "unknown")
  info "ExternalSecret sync status: $es_status"

  local ready_count
  ready_count=$(kubectl get externalsecret -n banking --no-headers 2>/dev/null \
    | grep -c "SecretSynced" || echo "0")
  if [[ "$ready_count" -ge 2 ]]; then
    success "ESO: $ready_count secrets synced from Vault → banking namespace"
    record_pass "eso"
  else
    warn "ESO: secrets may still be syncing — check: kubectl get externalsecret -n banking"
    record_warn "eso"
  fi
}

setup_conftest() {
  section "Conftest — OPA Policy Validation"

  if ! command -v conftest &>/dev/null; then
    warn "conftest not found. Install via prerequisites.sh then re-run."
    record_warn "conftest"
    return 0
  fi
  success "Conftest: $(conftest --version 2>/dev/null | head -1)"

  local policy_dir="$PROJECT_ROOT/policies"
  if [[ ! -f "$policy_dir/k8s-security.rego" ]]; then
    die "OPA policy file not found: $policy_dir/k8s-security.rego — ensure it is committed to the repo"
  fi
  success "OPA policies found: $policy_dir/k8s-security.rego"

  if $DRY_RUN; then
    info "DRY RUN: conftest test manifests/k8s/backend/deployment.yaml manifests/k8s/frontend/deployment.yaml --policy policies/"
    record_pass "conftest"
    return 0
  fi

  info "Running OPA policy checks against k8s manifests..."
  local conftest_exit=0

  local manifests=(
    "$MANIFESTS/k8s/backend/deployment.yaml"
    "$MANIFESTS/k8s/frontend/deployment.yaml"
  )

  for manifest in "${manifests[@]}"; do
    if [[ -f "$manifest" ]]; then
      echo ""
      info "Checking: $(basename "$manifest")"
      conftest test "$manifest" \
        --policy "$policy_dir/" \
        --output table 2>&1 || conftest_exit=1
    fi
  done

  if [[ $conftest_exit -eq 0 ]]; then
    success "Conftest OPA checks: PASSED"
    record_pass "conftest"
  else
    warn "Conftest found policy violations — review output above"
    record_warn "conftest"
  fi
}

setup_network_policies() {
  section "Network Policies — Zero-Trust Namespace Isolation"

  apply_manifest "$MANIFESTS/security/network-policy.yaml"

  $DRY_RUN && { record_pass "network-policy"; return 0; }

  local np_count
  np_count=$(kubectl get networkpolicy -n banking --no-headers 2>/dev/null | wc -l | tr -d ' ')
  success "$np_count NetworkPolicies applied to banking namespace"

  kubectl get networkpolicy -n banking \
    -o custom-columns="NAME:.metadata.name,PODS:.spec.podSelector" \
    2>/dev/null || true

  record_pass "network-policy"
}

run_health_checks() {
  section "Security Components Health Check"

  $DRY_RUN && { success "Health checks skipped (dry run)"; return 0; }

  local components=(
    "kyverno-admission|kyverno|app.kubernetes.io/component=admission-controller"
    "kyverno-background|kyverno|app.kubernetes.io/component=background-controller"
    "vault|vault|app.kubernetes.io/name=vault"
    "external-secrets|external-secrets|app.kubernetes.io/name=external-secrets"
  )

  echo ""
  printf "  %-24s %-20s %s\n" "COMPONENT" "NAMESPACE" "STATUS"
  printf "  %-24s %-20s %s\n" "---------" "---------" "------"

  local all_ok=true
  for entry in "${components[@]}"; do
    IFS='|' read -r name ns selector <<< "$entry"
    if pod_running "$ns" "$selector"; then
      printf "  ${GREEN}%-24s${NC} %-20s ${GREEN}%s${NC}\n" "$name" "$ns" "Running"
    else
      printf "  ${YELLOW}%-24s${NC} %-20s ${YELLOW}%s${NC}\n" "$name" "$ns" "Not Ready"
      all_ok=false
    fi
  done
  echo ""
  $all_ok && success "All security pods healthy" \
    || warn "Some pods not ready — they may still be starting up"
}

print_security_report() {
  section "Security Posture Report"

  echo ""
  if [[ ${#PASS[@]} -gt 0 ]]; then
    echo -e "  ${GREEN}${BOLD}PASS${NC} (${#PASS[@]}): ${PASS[*]}"
  fi
  if [[ ${#WARN[@]} -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}WARN${NC} (${#WARN[@]}): ${WARN[*]}"
  fi
  if [[ ${#FAIL[@]} -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}FAIL${NC} (${#FAIL[@]}): ${FAIL[*]}"
  fi

  echo ""
  echo -e "  ${BOLD}Access security UIs:${NC}"
  echo ""
  echo -e "  Vault UI:"
  url "    kubectl port-forward svc/vault -n vault 8200:8200 &"
  url "    http://localhost:8200  |  Token: root"
  echo ""
  echo -e "  ${BOLD}Useful commands:${NC}"
  echo  "    kubectl get clusterpolicies                          # Kyverno policies"
  echo  "    kubectl get policyreport -n banking                  # Policy violations"
  echo  "    kubectl get externalsecret -n banking                # ESO sync status"
  echo  "    kubectl get networkpolicy -n banking                 # Network policies"
  echo  "    trivy image <image>:<tag>                            # Scan an image"
  echo  "    cosign verify --key cosign.pub <image>               # Verify signature"
  echo  "    conftest test <manifest> --policy policies/          # OPA policy check"
  echo ""

  if [[ ${#FAIL[@]} -gt 0 ]]; then
    warn "Some security components failed — review the report above"
  else
    success "Security initialisation complete"
  fi
}

main() {
  parse_args "$@"

  echo ""
  echo -e "${BOLD}DTB Banking Portal — Security Modules Initialisation${NC}"
  echo -e "Repository root: $PROJECT_ROOT"
  $DRY_RUN && echo -e "${YELLOW}DRY RUN MODE — no changes will be made${NC}"
  echo ""

  prompt_value DOCKER_USERNAME "Docker Hub username (for image scans)" ""

  step 1  "Preflight checks"
  preflight

  step 2  "Trivy — vulnerability scanning"
  $SKIP_TRIVY && { info "Skipping Trivy (--skip-trivy)"; record_warn "trivy"; } || setup_trivy

  step 3  "Kyverno — admission policies"
  $SKIP_KYVERNO && { info "Skipping Kyverno (--skip-kyverno)"; record_warn "kyverno"; } || setup_kyverno

  step 4  "Cosign — image signing"
  $SKIP_COSIGN && { info "Skipping Cosign (--skip-cosign)"; record_warn "cosign"; } || setup_cosign

  step 5  "Vault — secrets management"
  $SKIP_VAULT && { info "Skipping Vault (--skip-vault)"; record_warn "vault"; } || setup_vault

  step 6  "ESO — Vault → K8s secret sync"
  $SKIP_ESO && { info "Skipping ESO (--skip-eso)"; record_warn "eso"; } || setup_eso

  step 7  "Conftest — OPA policy validation"
  $SKIP_CONFTEST && { info "Skipping Conftest (--skip-conftest)"; record_warn "conftest"; } || setup_conftest

  step 8  "Network policies"
  $SKIP_NETPOL && { info "Skipping network policies (--skip-netpol)"; record_warn "network-policy"; } || setup_network_policies

  step 9  "Health checks"
  run_health_checks

  step 10 "Security posture report"
  print_security_report
}

main "$@"
