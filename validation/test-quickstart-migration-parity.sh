#!/bin/bash
# Regression test: quickstart_command must run SAME CRITICAL migrations
# as main_menu. If a new marker-driven migration is added to main_menu
# (for new feature) and forgotten in quickstart, existing VPS that uses
# ./xrayebator quickstart ends up in inconsistent state.
#
# The list is automatically derived from xrayebator source by grepping
# all `run_migration "..."` lines in main_menu region of the file.
#
# CRLF-safe: we use tr -d '\r' to normalize the file before grepping
# because Windows checkouts carry CRLF line endings from .gitattributes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "✗ FAIL: $*" >&2
  exit 1
}

# Extract main_menu + quickstart blocks (CRLF-safe via tr -d '\r')
main_menu_block=$(tr -d '\r' < xrayebator | sed -n '/^main_menu() {$/,/^# 2\. Последовательное детектирование/p')
quickstart_block=$(tr -d '\r' < xrayebator | sed -n '/^quickstart_command() {$/,/^happ_setup_command() {$/p')

[[ -n "$main_menu_block" ]] || fail "main_menu block not found"
[[ -n "$quickstart_block" ]] || fail "quickstart_command block not found"

# Get all migration markers from BOTH blocks
mapfile -t main_migrations < <(
  grep -oE 'run_migration "[a-z0-9_]+"' <<< "$main_menu_block" \
    | sed 's/run_migration "\(.*\)"/\1/' | sort -u
)
mapfile -t quickstart_migrations < <(
  grep -oE 'run_migration "[a-z0-9_]+"' <<< "$quickstart_block" \
    | sed 's/run_migration "\(.*\)"/\1/' | sort -u
)

echo "main_menu migrations (${#main_migrations[@]}):"
printf '  %s\n' "${main_migrations[@]}"
echo "quickstart migrations (${#quickstart_migrations[@]}):"
printf '  %s\n' "${quickstart_migrations[@]}"

# Migrations that are NONINTERACTIVE only (safe to bypass in quickstart)
# We allow skipping: user needs to see them in interactive mode anyway.
# List of migrations that do NOT require root/prompts that the user must see:
skip_in_quickstart=(
  "_migrate_bypass_routing_2026"           # depends on network state
  "_migrate_subscription_tokens_2026"       # backend-token rotation — needs lock
  "migrate_remove_legacy_tcp_tuning_v3"     # TCP tune is host-safe
)

declare -A skip_map
for s in "${skip_in_quickstart[@]}"; do
  skip_map["$s"]=1
done

failed=0
for mig in "${main_migrations[@]}"; do
  # Skip if explicitly allowed to be omitted
  if [[ "${skip_map[$mig]:-}" == "1" ]]; then
    continue
  fi
  found=0
  for q in "${quickstart_migrations[@]}"; do
    if [[ "$q" == "$mig" ]]; then
      found=1
      break
    fi
  done
  if [[ $found -eq 0 ]]; then
    echo "⚠ Migration MISSING in quickstart: $mig"
    failed=1
  fi
done

if [[ $failed -eq 1 ]]; then
  fail "quickstart is missing migrations that main_menu has"
fi

echo "✓ quickstart migration parity covers all critical markers"
