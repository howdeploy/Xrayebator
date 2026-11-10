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

# Private render is opt-in and leaves the running config and its other profiles alone.
jq '.inbounds = [
  {tag:"legacy-inbound", protocol:"vless"},
  {tag:"private-template", protocol:"vless", listen:"0.0.0.0", port:443,
   settings:{clients:[{id:"33333333-3333-4333-8333-333333333333",email:"template"}],decryption:"none"},
   streamSettings:{network:"xhttp",security:"reality",
     xhttpSettings:{path:"/fixture",mode:"stream-one"},
     realitySettings:{dest:"127.0.0.1:9444",serverNames:["ingress.example.net"]}}}
]' "$CONFIG_FILE" > "$WORKDIR/template.json"
CONFIG_FILE="$WORKDIR/template.json"
cp "$CONFIG_FILE" "$WORKDIR/template.before"

cat > "$WORKDIR/policy.json" <<'JSON'
{
  "inbound_tag": "private-template",
  "client_id": "22222222-2222-4222-8222-222222222222",
  "listen": "0.0.0.0",
  "port": 15443,
  "russia_only_domains": ["full:only.example"],
  "blocked_domains": ["domain:blocked.example"],
  "blocked_ips": ["198.51.100.0/24"]
}
JSON
printf '%s\n' 'vless://11111111-1111-4111-8111-111111111111@[2001:db8::10]:25443?security=reality&type=xhttp&sni=egress.example.net&pbk=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN&sid=abcd1234&mode=stream-one&path=%2Ffixture' > "$WORKDIR/upstream.uri"
chmod 600 "$WORKDIR/policy.json" "$WORKDIR/upstream.uri"

XRAY_BIN="$WORKDIR/xray-test"
cat > "$XRAY_BIN" <<'BASH'
#!/usr/bin/env bash
[[ "$1" == "run" && "$2" == "-test" && "$3" == "-config" && "$4" == *.json ]] &&
  jq -e '.outbounds[0].protocol == "blackhole"' "$4" >/dev/null
BASH
chmod +x "$XRAY_BIN"
output="$WORKDIR/private.json"
render() {
  private_cascade_command render --policy-file "$WORKDIR/policy.json" \
    --upstream-file "$WORKDIR/upstream.uri" --output "$output"
}
render >/dev/null || fail "private cascade render failed"
cmp -s "$CONFIG_FILE" "$WORKDIR/template.before" || fail "live config changed"
[[ "$(stat -c %a "$output")" == 600 ]] || fail "candidate is not private"
jq -e '
  (.inbounds | length) == 1 and
  .inbounds[0].port == 15443 and .inbounds[0].sniffing.routeOnly == false and
  .inbounds[0].settings.clients == [{id:"22222222-2222-4222-8222-222222222222"}] and
  .dns.servers[-1] == "localhost" and
  .routing.domainStrategy == "IPOnDemand" and
  (.routing.rules | map(.outboundTag)) ==
    ["private-cascade-dns","block","direct","cascade-upstream","cascade-upstream","direct","direct","cascade-upstream"] and
  .routing.rules[0].ip == ["192.0.2.53"] and .routing.rules[1].ip == ["geoip:private","::/0"] and
  .outbounds[0].protocol == "blackhole" and
  any(.outbounds[]; .tag == "direct" and .streamSettings.sockopt.domainStrategy == "ForceIPv4") and
  ([.outbounds[] | select(.tag=="cascade-upstream")][0] | .settings.vnext[0].address == "2001:db8::10"
    and .settings.vnext[0].users[0].id == "11111111-1111-4111-8111-111111111111"
    and .streamSettings.realitySettings.shortId == "abcd1234"
    and .streamSettings.xhttpSettings.mode == "stream-one")
' "$output" >/dev/null || fail "private cascade routing or ingress mismatch"
cp "$output" "$WORKDIR/private.before"
if render >/dev/null 2>&1; then fail "private cascade overwrote existing output"; fi
cmp -s "$output" "$WORKDIR/private.before" || fail "existing candidate changed"

output="$WORKDIR/rejected.json"
jq '.client_id = "33333333-3333-4333-8333-333333333333"' "$WORKDIR/policy.json" > "$WORKDIR/reused.json"
chmod 600 "$WORKDIR/reused.json"
if private_cascade_command render --policy-file "$WORKDIR/reused.json" \
    --upstream-file "$WORKDIR/upstream.uri" --output "$output" >/dev/null 2>&1; then
  fail "private cascade reused an existing client"
fi
XRAY_BIN=$(command -v false)
if render >/dev/null 2>&1; then fail "private cascade accepted rejected Xray config"; fi
[[ ! -e "$output" ]] || fail "failed render left a candidate"
XRAY_BIN="$WORKDIR/xray-test"
chmod 644 "$WORKDIR/upstream.uri"
if render >/dev/null 2>&1; then fail "private cascade accepted exposed URI file"; fi
[[ ! -e "$output" ]] || fail "bad permissions left a candidate"

echo "OK: private cascade routing, isolation, permissions and atomic validation"
