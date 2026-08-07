#!/usr/bin/env bash
# test-cascade-routing.sh
# Phase 9: тестирует РЕАЛЬНЫЕ cascade-функции из xrayebator (`_cascade_build_outbound_json`,
# `_cascade_build_fragment_outbound_json`, `_cascade_apply_current_upstream`) вместо ручной
# копии jq-логики. Если прод-код разойдётся с ожидаемым поведением — тест упадёт.
# D5-fix.
#
# Usage:  bash validation/test-cascade-routing.sh
# Requires: jq, bash 4+.

set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORKDIR=$(mktemp -d /tmp/xrayebator-cascade.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# source реального скрипта (вызывает определения функций, но не main — guard XRAYEBATOR_SOURCED).
source "$REPO_ROOT/xrayebator"

# Логируем в свою директорию: конфиг, профили, бэкапы, upstreams, active-маркер.
CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"
XRAY_BACKUPS_DIR="$WORKDIR/backups"
UPSTREAMS_DIR="$WORKDIR/upstreams"
CASCADE_ACTIVE_FILE="$WORKDIR/.cascade_active"
mkdir -p "$PROFILES_DIR" "$XRAY_BACKUPS_DIR" "$UPSTREAMS_DIR"

# Стабим side-effects, которые трогают реальную систему (systemd, права, рестарт Xray).
# safe_restart_xray: в проде валидирует конфиг новым бинарём и делает systemctl restart.
# В тесте конфиг уже одобрен — просто говорим, что рестарт прошёл.
safe_restart_xray() { return 0; }
fix_xray_permissions() { return 0; }
systemctl() { return 0; }

# Исходный конфиг: содержит operator-правило udp/443, catch-all tcp,udp повторён (для дедупликации),
# freedom outbound с fragment. Cascade должен их сохранить/нормализовать.
cat > "$CONFIG_FILE" <<'JSON'
{
  "routing": {
    "rules": [
      {"type":"field","domain":["domain:example.ru"],"outboundTag":"direct"},
      {"type":"field","network":"udp","port":443,"inboundTag":["operator-custom"],"outboundTag":"block"},
      {"type":"field","network":"tcp,udp","outboundTag":"direct"},
      {"type":"field","network":"tcp,udp","outboundTag":"direct"}
    ]
  },
  "outbounds": [
    {"protocol":"freedom","settings":{"domainStrategy":"UseIPv4","fragment":{"packets":"tlshello"}},"tag":"direct"},
    {"protocol":"blackhole","tag":"block"}
  ]
}
JSON

cat > "$UPSTREAMS_DIR/cascade.json" <<'JSON'
{
  "version": 1,
  "tag": "cascade-upstream",
  "address": "203.0.113.10",
  "port": 443,
  "uuid": "11111111-1111-4111-8111-111111111111",
  "transport": "tcp",
  "sni": "front.example.com",
  "fingerprint": "chrome",
  "public_key": "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN",
  "short_id": "abcd1234",
  "flow": "xtls-rprx-vision"
}
JSON

upstream_file="$UPSTREAMS_DIR/cascade.json"

# --- 1. Вызов реальной _cascade_build_outbound_json ---
outbound_json=$(_cascade_build_outbound_json "$upstream_file") || fail "cascade outbound build failed"
jq -e '.tag == "cascade-upstream" and .protocol == "vless"' <<< "$outbound_json" >/dev/null \
  || fail "cascade outbound build produced wrong tag/protocol"
jq -e '.settings.vnext[0].users[0].id == "11111111-1111-4111-8111-111111111111"' <<< "$outbound_json" >/dev/null \
  || fail "cascade outbound uuid mismatch"
jq -e '.streamSettings.sockopt.dialerProxy == "cascade-fragment" and .streamSettings.sockopt.tcpFastOpen == true and .streamSettings.sockopt.tcpNoDelay == true' <<< "$outbound_json" >/dev/null \
  || fail "cascade tcp outbound missing dialerProxy/tcpFastOpen/tcpNoDelay"
! jq -e '.settings.vnext[0].users[0].packetEncoding' <<< "$outbound_json" >/dev/null \
  || fail "plain tcp upstream unexpectedly has packetEncoding"
jq -e '.streamSettings.realitySettings.serverName == "front.example.com" and .streamSettings.realitySettings.fingerprint == "chrome"' <<< "$outbound_json" >/dev/null \
  || fail "cascade reality settings mismatch (sni/fingerprint)"

# --- 2. Вызов реальной _cascade_build_fragment_outbound_json ---
fragment_json=$(_cascade_build_fragment_outbound_json) || fail "cascade fragment build failed"
jq -e '.tag == "cascade-fragment" and .protocol == "freedom" and .settings.fragment.packets == "tlshello"' <<< "$fragment_json" >/dev/null \
  || fail "cascade fragment outbound mismatch"

# --- 3. Вызов реальной _cascade_apply_current_upstream (enable) ---
_cascade_apply_current_upstream "cascade_test_enable" >/dev/null 2>&1 \
  || fail "cascade apply (enable) failed"

jq -e '.outbounds[] | select(.tag == "cascade-upstream" and .protocol == "vless")' "$CONFIG_FILE" >/dev/null \
  || fail "cascade outbound missing after apply"
jq -e '.outbounds[] | select(.tag == "cascade-fragment" and .protocol == "freedom" and .settings.fragment.packets == "tlshello")' "$CONFIG_FILE" >/dev/null \
  || fail "cascade fragment outbound missing after apply"
jq -e '.outbounds[] | select(.tag == "cascade-upstream").streamSettings.sockopt | select(.dialerProxy == "cascade-fragment" and .tcpFastOpen == true and .tcpNoDelay == true)' "$CONFIG_FILE" >/dev/null \
  || fail "cascade outbound does not use cascade-fragment dialerProxy"
jq -e '.outbounds[] | select(.tag == "direct" and .settings.fragment.packets == "tlshello")' "$CONFIG_FILE" >/dev/null \
  || fail "direct outbound was clobbered"
jq -e '.routing.rules[0] | select(.outboundTag == "direct" and .ip[0] == "203.0.113.10")' "$CONFIG_FILE" >/dev/null \
  || fail "upstream direct IP exception missing"
jq -e '.routing.rules[] | select(.network == "udp" and (.port|tostring) == "443" and .inboundTag == ["operator-custom"] and .outboundTag == "block")' "$CONFIG_FILE" >/dev/null \
  || fail "cascade enable removed or rewrote an operator-managed udp/443 rule"
jq -e '.routing.rules[] | select(.network == "tcp,udp" and .outboundTag == "cascade-upstream")' "$CONFIG_FILE" >/dev/null \
  || fail "catch-all was not switched to cascade"
[[ "$(jq '[.routing.rules[] | select(.network == "tcp,udp" and (.domain // null) == null and (.ip // null) == null and (.port // null) == null)] | length' "$CONFIG_FILE")" == "1" ]] \
  || fail "catch-all rules were not normalized (dedup)"
jq -e '.routing.rules[] | select(.domain[0] == "domain:example.ru" and .outboundTag == "direct")' "$CONFIG_FILE" >/dev/null \
  || fail "existing bypass direct rule was not preserved"
[[ -f "$CASCADE_ACTIVE_FILE" ]] || fail "cascade active marker not set after enable"

# --- 4. Вызов реальной _cascade_apply_current_upstream на ещё раз (идемпотентность) ---
_cascade_apply_current_upstream "cascade_test_reapply" >/dev/null 2>&1 \
  || fail "cascade re-apply failed"
[[ "$(jq '[.outbounds[]? | select(.tag == "cascade-upstream")] | length' "$CONFIG_FILE")" == "1" ]] \
  || fail "cascade re-apply duplicated cascade-upstream outbound"
[[ "$(jq '[.outbounds[]? | select(.tag == "cascade-fragment")] | length' "$CONFIG_FILE")" == "1" ]] \
  || fail "cascade re-apply duplicated cascade-fragment outbound"

echo "OK: cascade routing (real _cascade_* functions)"