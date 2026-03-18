#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

API_URL="${API_URL:-http://localhost:5000}"

info "Seeding demo accounts at ${API_URL}..."

create_account() {
  local first="$1" last="$2" email="$3" phone="$4" pin="$5" deposit="$6"
  local response
  response=$(curl -sf -X POST "${API_URL}/api/accounts" \
    -H "Content-Type: application/json" \
    -d "{\"firstName\":\"${first}\",\"lastName\":\"${last}\",\"email\":\"${email}\",\"phone\":\"${phone}\",\"pin\":\"${pin}\",\"initialDeposit\":${deposit}}" \
    2>&1) || { error "Failed to create ${first} ${last}: ${response}"; return 1; }

  local acc_num
  acc_num=$(echo "$response" | grep -o '"accountNumber":"[^"]*"' | cut -d'"' -f4)
  success "Created: ${first} ${last} — Account: ${acc_num} | PIN: ${pin} | Balance: ${deposit}"
}

create_account "Alice"   "Wanjiku"  "alice.wanjiku@demo.dtb"  "+254700000001" "1234" "50000"
create_account "Brian"   "Ochieng"  "brian.ochieng@demo.dtb"  "+254711000002" "2345" "25000"
create_account "Carol"   "Muthoni"  "carol.muthoni@demo.dtb"  "+254722000003" "3456" "100000"
create_account "David"   "Kamau"    "david.kamau@demo.dtb"    "+254733000004" "4567" "5000"

echo ""
success "Seeding complete! Use the account numbers above to log in."
