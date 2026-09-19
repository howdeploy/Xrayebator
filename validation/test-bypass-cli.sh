#!/usr/bin/env bash
# test-bypass-cli.sh
# Тестирует CLI bypass-команды (`bypass list|add|remove|reset|bundle`) из xrayebator.
# Гарантии:
#   - stdout CLI содержит ТОЛЬКО JSON (статусы helpers не протекают в stdout);
#   - add/remove/reset/bundle реально мутируют routing.rules config.json;
#   - add блокирует домен, используемый как Reality SNI (конфликт handshake).
#
# Usage:  bash validation/test-bypass-cli.sh
# Requires: jq, bash 4+.

set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORKDIR=$(mktemp -d /tmp/xrayebator-bypass-cli.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

source "$REPO_ROOT/xrayebator"

CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"
XRAY_BACKUPS_DIR="$WORKDIR/backups"
mkdir -p "$PROFILES_DIR" "$XRAY_BACKUPS_DIR"

# Стабим side-effects (systemd, права, рестарт Xray) — тестируем jq-логику.
safe_restart_xray() { return 0; }
fix_xray_permissions() { return 0; }
systemctl() { return 0; }

cat > "$CONFIG_FILE" <<'JSON'
{
  "routing": {
    "rules": [
      {"type":"field","ip":["geoip:private"],"outboundTag":"block"},
      {"type":"field","domain":["geosite:category-ads-all"],"outboundTag":"block"},
      {"type":"field","network":"tcp,udp","outboundTag":"direct"}
    ]
  },
  "outbounds": [
    {"protocol":"freedom","tag":"direct"},
    {"protocol":"blackhole","tag":"block"}
  ]
}
JSON

# Профиль со SNI, который нельзя добавлять в bypass (конфликт handshake).
jq -n '{
  name: "sni-conflict",
  uuid: "22222222-2222-4222-8222-222222222222",
  transport: "xhttp",
  port: 443,
  sni: "conflict.example",
  fingerprint: "firefox"
}' > "$PROFILES_DIR/sni-conflict.json"

list_json() {
  _bypass_cli_list
}

# --- 1. Пустой список ---
out=$(list_json) || fail "bypass list failed on empty rules"
[[ "$out" == '{"ok":true,"domains":[]}' ]] ||
  fail "empty bypass list unexpected: $out"

# --- 2. Add — stdout содержит ТОЛЬКО JSON, правило появилось в config ---
out=$(_bypass_cli_add --domain steamcontent.com) || fail "bypass add failed"
jq -e '.ok == true and .domain == "steamcontent.com"' <<< "$out" >/dev/null ||
  fail "bypass add bad JSON: $out"
jq -e '
  any(.routing.rules[];
    .outboundTag == "direct" and (.domain // [] | index("domain:steamcontent.com") != null))
' "$CONFIG_FILE" >/dev/null ||
  fail "added domain not found in routing rules"
jq -e 'length == 1' <<< "$(jq -c '[.routing.rules[] | select(.outboundTag == "direct") | .domain[]?] | unique' "$CONFIG_FILE")" >/dev/null ||
  fail "unexpected extra domains after add"

# --- 3. Add дубликат — не создаёт новое правило ---
rules_before=$(jq -c '.routing.rules' "$CONFIG_FILE")
out=$(_bypass_cli_add --domain steamcontent.com) || fail "bypass add duplicate failed"
jq -e '.ok == true and .duplicate == true' <<< "$out" >/dev/null ||
  fail "duplicate add not flagged: $out"
[[ "$rules_before" == "$(jq -c '.routing.rules' "$CONFIG_FILE")" ]] ||
  fail "duplicate add mutated routing rules"

# --- 4. Add конфликтующего SNI — ошибка, config не меняется ---
before_hash=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
if out=$(_bypass_cli_add --domain conflict.example); then
  fail "bypass add of Reality SNI unexpectedly succeeded"
fi
jq -e '.ok == false' <<< "$out" >/dev/null ||
  fail "SNI-conflict add did not return ok:false: $out"
[[ "$before_hash" == "$(sha256sum "$CONFIG_FILE" | awk '{print $1}')" ]] ||
  fail "SNI-conflict add mutated config"

# --- 5. Add некорректного домена ---
if out=$(_bypass_cli_add --domain "bad domain!"); then
  fail "bypass add of invalid domain unexpectedly succeeded"
fi
jq -e '.ok == false' <<< "$out" >/dev/null ||
  fail "invalid-domain add did not return ok:false: $out"

# --- 6. Remove — правило удаляется ---
out=$(_bypass_cli_remove --domain steamcontent.com) || fail "bypass remove failed"
jq -e '.ok == true and .domain == "steamcontent.com"' <<< "$out" >/dev/null ||
  fail "bypass remove bad JSON: $out"
jq -e '
  all(.routing.rules[];
    (.domain // []) | index("domain:steamcontent.com") == null)
' "$CONFIG_FILE" >/dev/null ||
  fail "removed domain still present in routing rules"

out=$(list_json) || fail "bypass list failed after remove"
[[ "$out" == '{"ok":true,"domains":[]}' ]] ||
  fail "bypass list not empty after remove: $out"

# --- 7. Bundle — применяет группы, возвращает счётчик доменов ---
out=$(_bypass_cli_bundle --group yandex,steam) || fail "bypass bundle failed"
jq -e '.ok == true and (.domains | type == "number") and .domains > 0' <<< "$out" >/dev/null ||
  fail "bypass bundle bad JSON: $out"
jq -e '
  any(.routing.rules[]; .outboundTag == "direct" and ((.domain // []) | index("domain:kinopoisk.ru") != null))
' "$CONFIG_FILE" >/dev/null ||
  fail "bundle yandex group not applied"
jq -e '
  any(.routing.rules[]; .outboundTag == "direct" and ((.domain // []) | index("domain:steamcontent.com") != null))
' "$CONFIG_FILE" >/dev/null ||
  fail "bundle steam group not applied"
jq -e '
  all(.routing.rules[];
    (.domain // []) | index("domain:sberbank.ru") == null)
' "$CONFIG_FILE" >/dev/null ||
  fail "unselected bundle group (banks) was applied"

# --- 8. Bundle с неизвестной группой — ошибка ---
if out=$(_bypass_cli_bundle --group no-such-group); then
  fail "bypass bundle with unknown group unexpectedly succeeded"
fi
jq -e '.ok == false' <<< "$out" >/dev/null ||
  fail "unknown-group bundle did not return ok:false: $out"

# --- 9. Bundle без --group — применяет ВСЕ группы ---
out=$(_bypass_cli_bundle) || fail "bypass bundle (all) failed"
jq -e '.ok == true' <<< "$out" >/dev/null ||
  fail "full bundle bad JSON: $out"
jq -e '
  any(.routing.rules[]; .outboundTag == "direct" and ((.domain // []) | index("domain:gosuslugi.ru") != null)) and
  any(.routing.rules[]; .outboundTag == "direct" and ((.domain // []) | index("domain:sberbank.ru") != null))
' "$CONFIG_FILE" >/dev/null ||
  fail "full bundle missing groups"

# --- 10. Reset — удаляет ВСЕ domain bypass-правила, дефолтные rules остаются ---
out=$(_bypass_cli_reset) || fail "bypass reset failed"
jq -e '.ok == true' <<< "$out" >/dev/null ||
  fail "bypass reset bad JSON: $out"
jq -e '
  all(.routing.rules[] | select(.outboundTag == "direct"); ((.domain // []) | length) == 0) and
  any(.routing.rules[]; .outboundTag == "block") and
  any(.routing.rules[]; .outboundTag == "direct" and .network == "tcp,udp")
' "$CONFIG_FILE" >/dev/null ||
  fail "reset removed default rules or left bypass domains"

# --- 11. bypass с неизвестной подкомандой ---
if out=$(bypass_command bogus); then
  fail "bypass bogus unexpectedly succeeded"
fi
jq -e '.ok == false' <<< "$out" >/dev/null ||
  fail "bypass bogus did not return ok:false: $out"

echo "PASS: bypass CLI commands are JSON-clean and mutate routing rules correctly"
