#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

for file in xrayebator install.sh update.sh; do
  path="$REPO_ROOT/$file"
  grep -q 'XRAY_LOCAL_ZIP' "$path" || fail "$file: local ZIP fallback missing"
  grep -q 'XRAY_LOCAL_DGST' "$path" || fail "$file: local digest fallback missing"
  grep -q 'XRAY_DOWNLOAD_PROXY' "$path" || fail "$file: proxy fallback missing"
  grep -q -- '--retry-all-errors' "$path" || fail "$file: retry-all-errors missing"
  grep -q -- '--http1.1' "$path" || fail "$file: HTTP/1.1 fallback missing"
done

# Собственные drop-in'ы бэкендов (/etc/sysctl.d/99-xrayebator-*.conf) — не
# host-wide тюнинг: uninstall снимает их вместе с Hysteria/AWG.
if grep -Ei \
  'BBR|XRAY_TCP_TUNING|tcp_congestion_control|default_qdisc|/etc/sysctl|(^|[;&|[:space:]])sysctl([[:space:]]|$)' \
  "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh" \
  | grep -Fv '/etc/sysctl.d/99-xrayebator-' >/dev/null; then
  fail "install/uninstall must not configure or remove host-wide TCP/sysctl tuning"
fi
grep -q 'migrate_remove_legacy_tcp_tuning_v3' "$REPO_ROOT/update.sh" \
  || fail "updater must invoke the one-time legacy TCP tuning migration"

echo "PASS: installer network fallbacks and host-network isolation"
