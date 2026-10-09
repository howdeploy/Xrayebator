#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "✗ $*" >&2
  exit 1
}

menu_block=$(sed -n '/^main_menu() {$/,/^# Меню создания профиля$/p' xrayebator)
[[ -n "$menu_block" ]] || fail "main_menu block not found"

mapfile -t displayed_numbers < <(
  sed -n 's/.*${CYAN} *\([0-9][0-9]*\))${NC}.*/\1/p' <<< "$menu_block"
)
[[ "${displayed_numbers[*]}" == "1 2 3 4 5 6 7 8 9 10 11 12 13" ]] \
  || fail "displayed main-menu actions are not consecutive: ${displayed_numbers[*]}"

expected_dispatch=(
  "1) create_profile_menu ;;"
  "2) delete_profile_menu ;;"
  "3) connect_profile_menu ;;"
  "4) manage_profile_menu ;;"
  "5) upgrade_profile_to_pq_menu ;;"
  "6) happ_subscription_menu ;;"
  "7) bypass_routing_menu ;;"
  "8) cascade_mode_menu ;;"
  "9) install_selfsteal_stub_menu ;;"
  "10) setup_outbound_server_menu ;;"
  "11) hysteria2_menu ;;"
  "12) awg_menu ;;"
  "13) backend_status_menu ;;"
  "0) exit 0 ;;"
)

for dispatch in "${expected_dispatch[@]}"; do
  grep -Fq "$dispatch" <<< "$menu_block" \
    || fail "main-menu dispatch missing or renumbered incorrectly: $dispatch"
done

echo "✓ Main menu actions are numbered consecutively and match their handlers"
