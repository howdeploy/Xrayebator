#!/bin/bash
# Регрессия: update_all_profiles_on_port / update_all_profiles_port_reference
# роняли jq на легаси-профиле без поля routes ("Invalid path expression with
# result []"), safe_jq_write глушит stderr — профиль молча оставался со старым SNI.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

WORKDIR=$(mktemp -d /tmp/xrayebator-legacy-sync.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/xrayebator"

PROFILES_DIR="$WORKDIR/profiles"
mkdir -p "$PROFILES_DIR"

# Легаси-профиль: один маршрут, .port/.sni в корне, поля routes нет.
cat > "$PROFILES_DIR/legacy.json" <<'JSON'
{"name":"legacy","uuid":"11111111-1111-1111-1111-111111111111","transport":"tcp","port":443,"sni":"old.example"}
JSON

# Multi-route профиль: маршрут на 443 обновляется, маршрут на 8443 — нет.
cat > "$PROFILES_DIR/multi.json" <<'JSON'
{"name":"multi","uuid":"22222222-2222-2222-2222-222222222222","routes":[{"label":"a","port":443,"sni":"old.example"},{"label":"b","port":8443,"sni":"untouched.example"}]}
JSON

echo "Проверка синхронизации SNI по порту"
update_all_profiles_on_port 443 "sni" "new.example" >/dev/null ||
  fail "update_all_profiles_on_port вернул ошибку"

[[ "$(jq -r '.sni' "$PROFILES_DIR/legacy.json")" == "new.example" ]] ||
  fail "легаси-профиль без routes не получил новый SNI"
[[ "$(jq -r '.routes[0].sni' "$PROFILES_DIR/multi.json")" == "new.example" ]] ||
  fail "маршрут на порту 443 не получил новый SNI"
[[ "$(jq -r '.routes[1].sni' "$PROFILES_DIR/multi.json")" == "untouched.example" ]] ||
  fail "маршрут на другом порту не должен был меняться"

echo "Проверка переноса порта"
update_all_profiles_port_reference 443 2053 >/dev/null ||
  fail "update_all_profiles_port_reference вернул ошибку"

[[ "$(jq -r '.port' "$PROFILES_DIR/legacy.json")" == "2053" ]] ||
  fail "легаси-профиль без routes не получил новый порт"
[[ "$(jq -r '.routes[0].port' "$PROFILES_DIR/multi.json")" == "2053" ]] ||
  fail "маршрут на порту 443 не получил новый порт"
[[ "$(jq -r '.routes[1].port' "$PROFILES_DIR/multi.json")" == "8443" ]] ||
  fail "маршрут на другом порту не должен был меняться"

echo "OK: легаси-профили без routes синхронизируются"
