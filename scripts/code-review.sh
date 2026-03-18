#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}[review]${NC} $*"; }
success() { echo -e "${GREEN}[review]${NC} $*"; }
warn()    { echo -e "${YELLOW}[review]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${MAGENTA}══ $* ══${NC}"; }
die()     { echo -e "${RED}[review] ERROR:${NC} $*" >&2; exit 1; }

AUTO_FIX=false
STRICT=false
INSTALL_TOOLS=false
REPORT_FILE="${ROOT_DIR}/code-review-report.txt"
SKIP_JS=false
SKIP_YAML=false
SKIP_SHELL=false
SKIP_DOCKER=false
SKIP_SECRETS=false

ISSUES_ERROR=0
ISSUES_WARN=0
ISSUES_FIXED=0
declare -A FILE_STATUS

usage() {
  cat <<'USAGE'
Usage: ./scripts/code-review.sh [OPTIONS]

Reviews all source files for enterprise coding standards and security thresholds.
Auto-corrects safe issues in place.

Options:
  --fix               Auto-correct safe issues (default: report only)
  --install-tools     Install missing analysis tools (shellcheck, hadolint, yamllint, gitleaks)
  --strict            Treat warnings as errors (non-zero exit on any finding)
  --skip-js           Skip JavaScript/Node.js checks
  --skip-yaml         Skip YAML manifest checks
  --skip-shell        Skip shell script checks
  --skip-docker       Skip Dockerfile checks
  --skip-secrets      Skip hardcoded-secret scan
  --report <file>     Write report to file (default: code-review-report.txt)
  -h|--help           Show this help

Exit codes:
  0   All checks passed (or only warnings found without --strict)
  1   One or more errors found
  2   Tool installation failed

Examples:
  ./scripts/code-review.sh --fix            # review and auto-correct
  ./scripts/code-review.sh --strict         # fail on any finding
  ./scripts/code-review.sh --skip-js --fix  # fix shell + yaml + docker only
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fix)           AUTO_FIX=true ;;
      --install-tools) INSTALL_TOOLS=true ;;
      --strict)        STRICT=true ;;
      --skip-js)       SKIP_JS=true ;;
      --skip-yaml)     SKIP_YAML=true ;;
      --skip-shell)    SKIP_SHELL=true ;;
      --skip-docker)   SKIP_DOCKER=true ;;
      --skip-secrets)  SKIP_SECRETS=true ;;
      --report)        shift; REPORT_FILE="$1" ;;
      -h|--help)       usage; exit 0 ;;
      *) die "Unknown option: $1. Use --help for usage." ;;
    esac
    shift
  done
}

record_error() { ISSUES_ERROR=$(( ISSUES_ERROR + 1 )); FILE_STATUS["$1"]="FAIL"; }
record_warn()  { ISSUES_WARN=$(( ISSUES_WARN + 1 ));  [[ "${FILE_STATUS[$1]:-}" != "FAIL" ]] && FILE_STATUS["$1"]="WARN"; }
record_pass()  { [[ -z "${FILE_STATUS[$1]:-}" ]] && FILE_STATUS["$1"]="PASS"; }
record_fixed() { ISSUES_FIXED=$(( ISSUES_FIXED + 1 )); }

REPORT_LINES=()
rpt() { REPORT_LINES+=("$*"); }

emit_finding() {
  local severity="$1" file="$2" line_ref="$3" msg="$4"
  local colour="$RED"
  [[ "$severity" == "WARN" ]] && colour="$YELLOW"
  [[ "$severity" == "INFO" ]] && colour="$CYAN"
  local short="${file#"$ROOT_DIR/"}"
  echo -e "  ${colour}[${severity}]${NC} ${short}${line_ref:+:${line_ref}} — ${msg}"
  rpt "[$severity] $short${line_ref:+:${line_ref}} — $msg"
}

HAS_SHELLCHECK=false
HAS_HADOLINT=false
HAS_YAMLLINT=false
HAS_GITLEAKS=false
HAS_ESLINT=false

try_install_tool() {
  local name="$1"; shift
  if ! sudo -n true 2>/dev/null; then
    warn "No passwordless sudo — cannot auto-install $name. Run: $*"
    return 1
  fi
  DEBIAN_FRONTEND=noninteractive "$@" 2>/dev/null || {
    warn "Install failed for $name — related checks will use grep-only fallback"
    return 1
  }
  command -v "$name" &>/dev/null
}

preflight() {
  section "Tool Preflight"

  if command -v shellcheck &>/dev/null; then
    HAS_SHELLCHECK=true
    success "shellcheck: $(shellcheck --version 2>/dev/null | grep version: | awk '{print $2}')"
  elif $INSTALL_TOOLS; then
    try_install_tool shellcheck sudo apt-get install -y shellcheck && HAS_SHELLCHECK=true || true
  else
    warn "shellcheck not found — install with: sudo apt-get install shellcheck  (or pass --install-tools)"
  fi

  if command -v hadolint &>/dev/null; then
    HAS_HADOLINT=true
    success "hadolint: $(hadolint --version 2>/dev/null | awk '{print $2}')"
  elif $INSTALL_TOOLS; then
    log "Installing hadolint..."
    curl -fsSL https://github.com/hadolint/hadolint/releases/latest/download/hadolint-Linux-x86_64 \
      -o /tmp/hadolint 2>/dev/null && \
      sudo install /tmp/hadolint /usr/local/bin/hadolint 2>/dev/null && \
      HAS_HADOLINT=true || warn "hadolint install failed — Dockerfile checks will be basic"
  else
    warn "hadolint not found — Dockerfile checks will be basic  (or pass --install-tools)"
  fi

  if command -v yamllint &>/dev/null; then
    HAS_YAMLLINT=true
    success "yamllint: $(yamllint --version 2>/dev/null)"
  elif $INSTALL_TOOLS; then
    try_install_tool yamllint sudo apt-get install -y yamllint && HAS_YAMLLINT=true || \
    { pip3 install yamllint --quiet 2>/dev/null && HAS_YAMLLINT=true; } || true
  else
    warn "yamllint not found — YAML checks will be basic  (or pass --install-tools)"
  fi

  if command -v gitleaks &>/dev/null; then
    HAS_GITLEAKS=true
    success "gitleaks: $(gitleaks version 2>/dev/null)"
  elif $INSTALL_TOOLS; then
    log "Installing gitleaks..."
    local gl_ver="8.24.3"
    curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${gl_ver}/gitleaks_${gl_ver}_linux_x64.tar.gz" \
      2>/dev/null | tar -xz -C /tmp gitleaks 2>/dev/null && \
      sudo install /tmp/gitleaks /usr/local/bin/gitleaks 2>/dev/null && \
      HAS_GITLEAKS=true || warn "gitleaks install failed — falling back to grep-based secret scan"
  else
    warn "gitleaks not found — using grep-based secret scan  (install: --install-tools)"
  fi

  if [[ -f "${ROOT_DIR}/backend/node_modules/.bin/eslint" || \
        -f "${ROOT_DIR}/frontend/node_modules/.bin/eslint" ]]; then
    HAS_ESLINT=true
    success "eslint: found in node_modules/.bin/"
  else
    warn "eslint not found in node_modules — JS lint checks will use grep-only fallback"
  fi
}

check_shell_file() {
  local file="$1"
  local short="${file#"$ROOT_DIR/"}"
  local changed=false

  local content
  content=$(cat "$file")

  if ! head -1 "$file" | grep -q '^#!'; then
    emit_finding "WARN" "$file" "1" "No shebang line — add '#!/usr/bin/env bash'"
    record_warn "$file"
    if $AUTO_FIX; then
      sed -i '1s/^/#!/usr/bin/env bash\n/' "$file"
      emit_finding "INFO" "$file" "1" "AUTO-FIXED: inserted shebang"
      record_fixed; changed=true
    fi
  fi

  if ! grep -q 'set -euo pipefail\|set -e.*set -u\|set -eu' "$file"; then
    emit_finding "ERROR" "$file" "" "Missing 'set -euo pipefail' — script will not fail on unset vars or pipeline errors"
    record_error "$file"
    if $AUTO_FIX; then
      if head -1 "$file" | grep -q '^#!'; then
        sed -i '1a\\nset -euo pipefail' "$file"
      else
        sed -i '1s/^/set -euo pipefail\n/' "$file"
      fi
      emit_finding "INFO" "$file" "" "AUTO-FIXED: inserted 'set -euo pipefail'"
      record_fixed; changed=true
    fi
  fi

  while IFS= read -r line_content; do
    local lineno
    lineno=$(grep -n "$line_content" "$file" 2>/dev/null | head -1 | cut -d: -f1 || echo "?")
    emit_finding "ERROR" "$file" "$lineno" "Dangerous pattern: chmod 777 — use least-privilege permissions"
    record_error "$file"
  done < <(grep -n 'chmod 777\|chmod -R 777\|chmod a+rwx' "$file" 2>/dev/null | cut -d: -f1,2 || true)

  while IFS=: read -r lineno line_content; do
    [[ -z "$lineno" ]] && continue
    emit_finding "ERROR" "$file" "$lineno" "Command injection risk: eval used on external/variable input — '$line_content'"
    record_error "$file"
  done < <(grep -n '\beval\b' "$file" 2>/dev/null || true)

  while IFS=: read -r lineno line_content; do
    [[ -z "$lineno" ]] && continue
    emit_finding "WARN" "$file" "$lineno" "Unverified pipe-to-shell: consider checksum verification before executing downloaded scripts"
    record_warn "$file"
  done < <(grep -n 'curl.*|.*sh\b\|wget.*|.*sh\b\|curl.*|.*bash\b' "$file" 2>/dev/null || true)

  while IFS=: read -r lineno line_content; do
    [[ -z "$lineno" ]] && continue
    emit_finding "WARN" "$file" "$lineno" "Hardcoded credential pattern detected — use env var or secret manager"
    record_warn "$file"
  done < <(grep -nE '(password|passwd|secret|token|api_key|apikey)\s*=\s*"[^$\{][^"]{3,}"' \
    "$file" 2>/dev/null | grep -iv 'VAULT_TOKEN.*:-' | grep -iv 'example\|placeholder\|REPLACE\|your_' || true)

  if ! grep -q 'trap\b' "$file"; then
    emit_finding "WARN" "$file" "" "No trap handler — consider 'trap ... ERR EXIT' for cleanup on failure"
    record_warn "$file"
  fi

  if $HAS_SHELLCHECK; then
    local sc_out sc_exit=0
    sc_out=$(shellcheck --severity=warning --format=tty "$file" 2>&1) || sc_exit=$?

    if [[ $sc_exit -ne 0 ]]; then
      while IFS= read -r sc_line; do
        [[ -z "$sc_line" ]] && continue
        local sc_lineno msg
        sc_lineno=$(echo "$sc_line" | grep -oP 'line \K[0-9]+' || echo "")
        msg=$(echo "$sc_line" | sed 's|.*: ||')
        if echo "$sc_line" | grep -q '\[SC[0-9]*\]'; then
          local code
          code=$(echo "$sc_line" | grep -oP 'SC[0-9]+')
          local severity="WARN"
          echo "$sc_line" | grep -q 'error' && severity="ERROR"
          emit_finding "$severity" "$file" "$sc_lineno" "shellcheck $code: $msg"
          [[ "$severity" == "ERROR" ]] && record_error "$file" || record_warn "$file"
        fi
      done <<< "$sc_out"

      if $AUTO_FIX; then
        local diff_out
        diff_out=$(shellcheck --severity=style --format=diff "$file" 2>/dev/null || true)
        if [[ -n "$diff_out" ]]; then
          echo "$diff_out" | patch -p1 --silent "$file" 2>/dev/null && {
            emit_finding "INFO" "$file" "" "AUTO-FIXED: applied shellcheck style patches"
            record_fixed
          } || true
        fi
      fi
    fi
  fi

  if $changed || [[ "${FILE_STATUS[$file]:-}" == "PASS" ]]; then
    record_pass "$file"
  fi

  if [[ -z "${FILE_STATUS[$file]:-}" ]]; then record_pass "$file"; fi
  return 0
}

check_yaml_file() {
  local file="$1"
  local short="${file#"$ROOT_DIR/"}"

  if $HAS_YAMLLINT; then
    local yl_out yl_exit=0
    yl_out=$(yamllint -d '{extends: relaxed, rules: {line-length: {max: 200}}}' "$file" 2>&1) || yl_exit=$?
    if [[ $yl_exit -ne 0 ]]; then
      while IFS= read -r yl_line; do
        [[ -z "$yl_line" || "$yl_line" == *"$file"* ]] && continue
        local lineno severity msg
        lineno=$(echo "$yl_line" | grep -oP '^\s*\K[0-9]+' || echo "")
        severity="WARN"
        echo "$yl_line" | grep -q '\[error\]' && severity="ERROR"
        msg=$(echo "$yl_line" | sed 's/^ *[0-9]*:[0-9]* *//')
        emit_finding "$severity" "$file" "$lineno" "yamllint: $msg"
        [[ "$severity" == "ERROR" ]] && record_error "$file" || record_warn "$file"
      done <<< "$yl_out"
    fi
  fi

  local ln msg
  while IFS=: read -r ln msg; do
    emit_finding "WARN" "$file" "$ln" "Image pinned to ':latest' — use explicit digest or semver tag"
    record_warn "$file"
  done < <(grep -nE '^\s+image:\s+[^$"'"'"']+:latest' "$file" 2>/dev/null || true)

  while IFS=: read -r ln msg; do
    emit_finding "ERROR" "$file" "$ln" "privileged: true — remove or justify with admission policy exception"
    record_error "$file"
  done < <(grep -nE 'privileged:\s*true' "$file" 2>/dev/null || true)

  while IFS=: read -r ln msg; do
    emit_finding "ERROR" "$file" "$ln" "allowPrivilegeEscalation: true — set to false"
    record_error "$file"
    if $AUTO_FIX; then
      sed -i "${ln}s/allowPrivilegeEscalation: true/allowPrivilegeEscalation: false/" "$file"
      emit_finding "INFO" "$file" "$ln" "AUTO-FIXED: allowPrivilegeEscalation set to false"
      record_fixed
    fi
  done < <(grep -nE 'allowPrivilegeEscalation:\s*true' "$file" 2>/dev/null || true)

  while IFS=: read -r ln msg; do
    emit_finding "WARN" "$file" "$ln" "runAsNonRoot: false — containers should run as non-root"
    record_warn "$file"
  done < <(grep -nE 'runAsNonRoot:\s*false' "$file" 2>/dev/null || true)

  while IFS=: read -r ln msg; do
    emit_finding "ERROR" "$file" "$ln" "Hardcoded secret in manifest — use secretKeyRef or ExternalSecret"
    record_error "$file"
  done < <(grep -nE '^\s+(password|token|secret|api_key):\s+"[^$\{][^"]{2,}"' "$file" 2>/dev/null || true)

  if grep -q 'kind: Deployment\|kind: StatefulSet\|kind: DaemonSet' "$file"; then
    if ! grep -q 'resources:' "$file"; then
      emit_finding "WARN" "$file" "" "Workload has no resource requests/limits — set cpu/memory for scheduler predictability"
      record_warn "$file"
    fi
    if ! grep -q 'readinessProbe:\|livenessProbe:' "$file"; then
      emit_finding "WARN" "$file" "" "Workload has no liveness/readiness probes — add probes for production health checks"
      record_warn "$file"
    fi
  fi

  if [[ -z "${FILE_STATUS[$file]:-}" ]]; then record_pass "$file"; fi
  return 0
}

check_dockerfile() {
  local file="$1"

  if $HAS_HADOLINT; then
    local hl_out hl_exit=0
    hl_out=$(hadolint --format tty "$file" 2>&1) || hl_exit=$?
    if [[ $hl_exit -ne 0 ]]; then
      while IFS= read -r hl_line; do
        [[ -z "$hl_line" ]] && continue
        local lineno code msg severity="WARN"
        lineno=$(echo "$hl_line" | grep -oP ':\K[0-9]+' | head -1 || echo "")
        code=$(echo "$hl_line" | grep -oP 'DL[0-9]+|SC[0-9]+' || echo "hadolint")
        msg=$(echo "$hl_line" | sed 's/.*DL[0-9]* //' | sed 's/.*SC[0-9]* //')
        echo "$hl_line" | grep -q 'error' && severity="ERROR"
        emit_finding "$severity" "$file" "$lineno" "hadolint $code: $msg"
        [[ "$severity" == "ERROR" ]] && record_error "$file" || record_warn "$file"
      done <<< "$hl_out"
    fi
  fi

  local lineno=0
  while IFS= read -r line; do
    lineno=$(( lineno + 1 ))

    if echo "$line" | grep -qE '^USER\s+root\s*$|^USER\s+0\s*$'; then
      emit_finding "ERROR" "$file" "$lineno" "Container runs as root USER — add a non-root user"
      record_error "$file"
    fi

    if echo "$line" | grep -qE '^ADD\s+https?://'; then
      emit_finding "WARN" "$file" "$lineno" "ADD with remote URL — use COPY + curl with checksum verification instead"
      record_warn "$file"
    fi

    if echo "$line" | grep -qE 'apt-get install' && ! echo "$line" | grep -qE '\bno-install-recommends\b'; then
      emit_finding "WARN" "$file" "$lineno" "apt-get install without --no-install-recommends — increases image size"
      record_warn "$file"
      if $AUTO_FIX; then
        sed -i "${lineno}s/apt-get install/apt-get install --no-install-recommends/" "$file"
        emit_finding "INFO" "$file" "$lineno" "AUTO-FIXED: added --no-install-recommends"
        record_fixed
      fi
    fi

  done < "$file"

  if [[ -z "${FILE_STATUS[$file]:-}" ]]; then record_pass "$file"; fi
  return 0
}

check_js_file() {
  local file="$1"
  local ln msg

  while IFS=: read -r ln msg; do
    emit_finding "ERROR" "$file" "$ln" "eval() usage — high XSS/injection risk"
    record_error "$file"
  done < <(grep -nE '\beval\s*\(' "$file" 2>/dev/null || true)

  while IFS=: read -r ln msg; do
    emit_finding "WARN" "$file" "$ln" "innerHTML concatenation — potential XSS; use textContent or DOMPurify"
    record_warn "$file"
  done < <(grep -nE 'innerHTML\s*=\s*[^;]+\+' "$file" 2>/dev/null || true)

  while IFS=: read -r ln msg; do
    emit_finding "ERROR" "$file" "$ln" "Hardcoded credential — move to environment variable"
    record_error "$file"
  done < <(grep -nE "(password|secret|token|api_key)\s*[:=]\s*[\"'][^\$\{][\"']{3,}" "$file" 2>/dev/null || true)

  while IFS=: read -r ln msg; do
    emit_finding "ERROR" "$file" "$ln" "Math.random() used for security token — use crypto.randomBytes()"
    record_error "$file"
  done < <(grep -nE 'Math\.random\(\).*(token|secret|key)' "$file" 2>/dev/null || true)

  while IFS=: read -r ln msg; do
    emit_finding "WARN" "$file" "$ln" "Possible credential logging via console — remove before production"
    record_warn "$file"
  done < <(grep -nE 'console\.(log|debug|info)\s*\(.*(password|token|secret)' "$file" 2>/dev/null || true)

  if [[ -z "${FILE_STATUS[$file]:-}" ]]; then record_pass "$file"; fi
  return 0
}

_run_eslint_once() {
  $HAS_ESLINT || return 0

  local eslint_bin=""
  [[ -f "${ROOT_DIR}/backend/node_modules/.bin/eslint" ]] && \
    eslint_bin="${ROOT_DIR}/backend/node_modules/.bin/eslint"
  [[ -f "${ROOT_DIR}/frontend/node_modules/.bin/eslint" ]] && \
    eslint_bin="${ROOT_DIR}/frontend/node_modules/.bin/eslint"
  [[ -z "$eslint_bin" ]] && return 0

  local js_dirs=()
  [[ -d "${ROOT_DIR}/backend/src" ]]    && js_dirs+=("${ROOT_DIR}/backend/src")
  [[ -d "${ROOT_DIR}/backend/tests" ]]  && js_dirs+=("${ROOT_DIR}/backend/tests")
  [[ -d "${ROOT_DIR}/frontend/src" ]]   && js_dirs+=("${ROOT_DIR}/frontend/src")
  [[ ${#js_dirs[@]} -eq 0 ]] && return 0

  local has_config=false
  for d in "${js_dirs[@]}"; do
    local cfg_root="${d%/src}"; cfg_root="${cfg_root%/tests}"
    if [[ -f "$cfg_root/.eslintrc" || -f "$cfg_root/.eslintrc.js" || \
          -f "$cfg_root/.eslintrc.json" || -f "$cfg_root/.eslintrc.yml" || \
          -f "$cfg_root/.eslintrc.yaml" ]]; then
      has_config=true && break
    fi
    if [[ -f "$cfg_root/package.json" ]] && \
       python3 - "$cfg_root/package.json" <<'PYEOF' 2>/dev/null; then
import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if 'eslintConfig' in d else 1)
PYEOF
      has_config=true && break
    fi
  done

  if ! $has_config; then
    warn "eslint: no .eslintrc config found — skipping eslint (run 'npm init @eslint/config' in backend/ or frontend/)"
    return 0
  fi

  section "ESLint"
  for dir in "${js_dirs[@]}"; do
    local el_out el_exit=0
    el_out=$("$eslint_bin" --format compact "$dir" 2>&1) || el_exit=$?
    if [[ $el_exit -ne 0 ]]; then
      if echo "$el_out" | grep -q "couldn't find a configuration file"; then
        warn "eslint: no config for $dir — run 'npm init @eslint/config' in $(dirname "$dir")"
        continue
      fi
      while IFS= read -r el_line; do
        [[ -z "$el_line" ]] && continue
        echo "$el_line" | grep -qE '^/.+: line [0-9]+' || continue
        local el_file el_ln msg severity="WARN"
        el_file=$(echo "$el_line" | grep -oP '^[^:]+')
        el_ln=$(echo "$el_line" | grep -oP 'line \K[0-9]+' | head -1 || echo "")
        msg=$(echo "$el_line" | sed 's/.*col [0-9]*: //' | cut -c1-120)
        echo "$el_line" | grep -q 'Error -' && severity="ERROR"
        emit_finding "$severity" "$el_file" "$el_ln" "eslint: $msg"
        [[ "$severity" == "ERROR" ]] && record_error "$el_file" || record_warn "$el_file"
      done <<< "$el_out"

      if $AUTO_FIX; then
        "$eslint_bin" --fix "$dir" 2>/dev/null && {
          log "eslint --fix applied in $dir"
          record_fixed
        } || true
      fi
    fi
  done
  return 0
}

scan_secrets() {
  section "Secret Scan"

  if $HAS_GITLEAKS; then
    log "Running gitleaks on working tree..."
    local gl_out gl_exit=0
    gl_out=$(gitleaks detect --source "$ROOT_DIR" --no-git \
      --redact --report-format=json --report-path=/tmp/gitleaks-report.json 2>&1) || gl_exit=$?

    if [[ $gl_exit -ne 0 ]] && [[ -f /tmp/gitleaks-report.json ]]; then
      local count
      count=$(python3 -c "import json,sys; d=json.load(open('/tmp/gitleaks-report.json')); print(len(d))" 2>/dev/null || echo "?")
      emit_finding "ERROR" "$ROOT_DIR" "" "gitleaks: $count potential secret(s) detected — see /tmp/gitleaks-report.json"
      ISSUES_ERROR=$(( ISSUES_ERROR + 1 ))

      python3 - <<'PYEOF' 2>/dev/null || true
import json, os
root = os.environ.get("ROOT_DIR", "")
try:
    findings = json.load(open("/tmp/gitleaks-report.json"))
    for f in findings[:20]:
        short = f.get("File","").replace(root+"/","")
        line  = f.get("StartLine","?")
        rule  = f.get("RuleID","unknown")
        print(f"  \033[0;31m[SECRET]\033[0m {short}:{line} — {rule}")
except Exception:
    pass
PYEOF
    else
      success "gitleaks: no secrets detected"
    fi
  else
    log "gitleaks unavailable — running grep-based secret pattern scan..."
    local secret_patterns=(
      'password\s*=\s*"[^$][^"]{4,}"'
      'passwd\s*=\s*"[^$][^"]{4,}"'
      'secret\s*=\s*"[^$][^"]{4,}"'
      'api_key\s*=\s*"[^$][^"]{4,}"'
      'token\s*=\s*"[^$][^"]{4,}"'
      'ghp_[A-Za-z0-9]{36}'
      'AKIA[0-9A-Z]{16}'
      'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}'
      '-----BEGIN (RSA|EC|OPENSSH) PRIVATE KEY-----'
    )

    local found_any=false
    for pat in "${secret_patterns[@]}"; do
      while IFS=: read -r fname lineno match; do
        [[ -z "$fname" ]] && continue
        emit_finding "ERROR" "$fname" "$lineno" "Potential secret — pattern '$pat' matched"
        record_error "$fname"
        found_any=true
      done < <(grep -rniE "$pat" "${SOURCE_DIRS[@]}" \
        --include="*.sh" --include="*.js" --include="*.ts" \
        --include="*.yaml" --include="*.yml" 2>/dev/null || true)
    done

    $found_any || success "Grep secret scan: no obvious hardcoded credentials found"
  fi
}

SOURCE_DIRS=(
  "${ROOT_DIR}/scripts"
  "${ROOT_DIR}/manifests"
  "${ROOT_DIR}/backend/src"
  "${ROOT_DIR}/backend/tests"
  "${ROOT_DIR}/frontend/src"
  "${ROOT_DIR}/policies"
)

collect_files() {
  local -n _sh_files=$1
  local -n _yaml_files=$2
  local -n _docker_files=$3
  local -n _js_files=$4

  local existing_dirs=()
  for d in "${SOURCE_DIRS[@]}"; do
    [[ -d "$d" ]] && existing_dirs+=("$d")
  done
  [[ ${#existing_dirs[@]} -eq 0 ]] && existing_dirs=("$ROOT_DIR")

  while IFS= read -r f; do
    [[ "$f" -ef "${BASH_SOURCE[0]}" ]] && continue
    _sh_files+=("$f")
  done < <(find "${existing_dirs[@]}" -name "*.sh" 2>/dev/null | sort)

  while IFS= read -r f; do
    _yaml_files+=("$f")
  done < <(find "${existing_dirs[@]}" \( -name "*.yaml" -o -name "*.yml" \) 2>/dev/null | sort)

  while IFS= read -r f; do
    _docker_files+=("$f")
  done < <(find "$ROOT_DIR" -maxdepth 4 -name "Dockerfile*" \
    -not -path "*/node_modules/*" 2>/dev/null | sort)

  while IFS= read -r f; do
    _js_files+=("$f")
  done < <(find "${existing_dirs[@]}" \( -name "*.js" -o -name "*.ts" \) \
    -not -name "*.test.js" -o -name "*.test.js" 2>/dev/null | sort)
}

print_summary() {
  section "Review Summary"

  local total_files="${#FILE_STATUS[@]}"
  local pass_count=0 warn_count=0 fail_count=0

  for f in "${!FILE_STATUS[@]}"; do
    case "${FILE_STATUS[$f]}" in
      PASS) pass_count=$(( pass_count + 1 )) ;;
      WARN) warn_count=$(( warn_count + 1 )) ;;
      FAIL) fail_count=$(( fail_count + 1 )) ;;
    esac
  done

  echo ""
  echo -e "  ${BOLD}Files reviewed:${NC}  $total_files"
  echo -e "  ${GREEN}${BOLD}PASS${NC}             $pass_count"
  echo -e "  ${YELLOW}${BOLD}WARN${NC}             $warn_count"
  echo -e "  ${RED}${BOLD}FAIL${NC}             $fail_count"
  echo -e "  ${CYAN}${BOLD}Auto-fixed${NC}       $ISSUES_FIXED"
  echo ""

  if [[ $fail_count -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}Failed files:${NC}"
    for f in "${!FILE_STATUS[@]}"; do
      [[ "${FILE_STATUS[$f]}" == "FAIL" ]] && echo -e "    ${RED}✗${NC} ${f#"$ROOT_DIR/"}"
    done
    echo ""
  fi

  if [[ $warn_count -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}Files with warnings:${NC}"
    for f in "${!FILE_STATUS[@]}"; do
      [[ "${FILE_STATUS[$f]}" == "WARN" ]] && echo -e "    ${YELLOW}⚠${NC} ${f#"$ROOT_DIR/"}"
    done
    echo ""
  fi

  {
    echo "DTB Banking Portal — Code Review Report"
    echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "Mode: AUTO_FIX=$AUTO_FIX STRICT=$STRICT"
    echo ""
    echo "SUMMARY"
    echo "  Files:     $total_files"
    echo "  PASS:      $pass_count"
    echo "  WARN:      $warn_count"
    echo "  FAIL:      $fail_count"
    echo "  Fixed:     $ISSUES_FIXED"
    echo ""
    echo "FINDINGS"
    printf '%s\n' "${REPORT_LINES[@]}"
  } > "$REPORT_FILE"

  success "Report written to: $REPORT_FILE"

  if $AUTO_FIX && [[ $ISSUES_FIXED -gt 0 ]]; then
    warn "$ISSUES_FIXED issue(s) were auto-corrected in place — review the diff before committing"
    echo  "  git diff --stat"
  fi

  echo ""
  if [[ $fail_count -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}RESULT: FAIL${NC} — $fail_count file(s) have errors that require manual remediation"
    return 1
  elif [[ $warn_count -gt 0 ]] && $STRICT; then
    echo -e "  ${YELLOW}${BOLD}RESULT: WARN (strict mode)${NC} — $warn_count file(s) have warnings"
    return 1
  else
    echo -e "  ${GREEN}${BOLD}RESULT: PASS${NC}"
    return 0
  fi
}

main() {
  parse_args "$@"

  echo ""
  echo -e "${BOLD}DTB Banking Portal — Enterprise Code Review${NC}"
  $AUTO_FIX && echo -e "${YELLOW}AUTO-FIX MODE — safe corrections will be applied in place${NC}"
  $STRICT   && echo -e "${YELLOW}STRICT MODE — warnings treated as errors${NC}"
  echo ""

  preflight

  local sh_files=() yaml_files=() docker_files=() js_files=()
  collect_files sh_files yaml_files docker_files js_files

  if ! $SKIP_SHELL && [[ ${#sh_files[@]} -gt 0 ]]; then
    section "Shell Scripts (${#sh_files[@]} files)"
    for f in "${sh_files[@]}"; do
      log "Checking: ${f#"$ROOT_DIR/"}"
      check_shell_file "$f"
    done
  fi

  if ! $SKIP_YAML && [[ ${#yaml_files[@]} -gt 0 ]]; then
    section "YAML Manifests (${#yaml_files[@]} files)"
    for f in "${yaml_files[@]}"; do
      log "Checking: ${f#"$ROOT_DIR/"}"
      check_yaml_file "$f"
    done
  fi

  if ! $SKIP_DOCKER && [[ ${#docker_files[@]} -gt 0 ]]; then
    section "Dockerfiles (${#docker_files[@]} files)"
    for f in "${docker_files[@]}"; do
      log "Checking: ${f#"$ROOT_DIR/"}"
      check_dockerfile "$f"
    done
  fi

  if ! $SKIP_JS && [[ ${#js_files[@]} -gt 0 ]]; then
    section "JavaScript/TypeScript — security grep (${#js_files[@]} files)"
    for f in "${js_files[@]}"; do
      log "Checking: ${f#"$ROOT_DIR/"}"
      check_js_file "$f"
    done
    $SKIP_JS || _run_eslint_once
  fi

  if ! $SKIP_SECRETS; then
    scan_secrets
  fi

  print_summary
}

export ROOT_DIR
main "$@"
