#!/usr/bin/env bash
# test-traffic-limit-cli.sh
# Тестирует учёт трафика профилей и лимиты (срез F1):
#   traffic-check (накопление .traffic.used дельтами от watermark .traffic.last,
#   бан при превышении лимита, разбан при поднятии/сбросе), profile-limit
#   (--limit/--reset, немедленное включение/отключение), кросс-гард с expire,
#   миграцию traffic_stats_2026 (stats/api/api-inbound/routing rule/email)
#   и статические инварианты handler'а подписки.
# Гарантии:
#   - stdout CLI содержит ТОЛЬКО JSON;
#   - рестарт xray только когда реально изменён config.json;
#   - счётчики Xray сбрасываются при рестарте: cur < last → дельта = cur;
#   - снимок .traffic_clients хранит flow клиентов по портам;
#   - чужие клиенты на общем порту не затрагиваются.
#
# Usage:  bash validation/test-traffic-limit-cli.sh
# Requires: jq, bash 4+.

set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORKDIR=$(mktemp -d /tmp/xrayebator-traffic-limit.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

source "$REPO_ROOT/xrayebator"

CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"
XRAY_BACKUPS_DIR="$WORKDIR/backups"
LOCK_FILE="$WORKDIR/.xrayebator.lock"
mkdir -p "$PROFILES_DIR" "$XRAY_BACKUPS_DIR"

RESTART_LOG="$WORKDIR/restarts.log"
: > "$RESTART_LOG"
safe_restart_xray() { echo restart >> "$RESTART_LOG"; return 0; }
restarts_now() { wc -l < "$RESTART_LOG" | tr -d ' '; }
fix_xray_permissions() { return 0; }
systemctl() { return 0; }

# Стаб Xray: отдаёт statsquery JSON из stats.json; нет файла — ошибка API.
STATS_FILE="$WORKDIR/stats.json"
XRAY_BIN="$WORKDIR/xray-stub"
cat > "$XRAY_BIN" << 'STUBEOF'
#!/usr/bin/env bash
if [[ -f "${STATS_STUB_FILE:?}" ]]; then
  cat "$STATS_STUB_FILE"
  exit 0
fi
echo "stub xray: api unavailable" >&2
exit 1
STUBEOF
chmod +x "$XRAY_BIN"
export STATS_STUB_FILE="$STATS_FILE"

write_stats() {
  # $1=friend total, $2=other total (целочисленно: uplink = total-1, downlink = 1)
  jq -n --argjson f "$1" --argjson o "$2" '{
    stat: [
      {name: "user>>>friend>>>traffic>>>uplink", value: ($f - 1)},
      {name: "user>>>friend>>>traffic>>>downlink", value: 1},
      {name: "user>>>other>>>traffic>>>uplink", value: ($o - 1)},
      {name: "user>>>other>>>traffic>>>downlink", value: 1},
      {name: "inbound>>>inbound-443>>>traffic>>>uplink", value: 424242}
    ]
  }' > "$STATS_FILE"
}

# --- Фикстуры: multi-route профиль friend (xhttp 443, tcp-vision 34521, grpc 8443)
# и однопортовый чужой профиль other на общем порту 443. ---
FRIEND_UUID="11111111-1111-4111-8111-111111111111"
OTHER_UUID="22222222-2222-4222-8222-222222222222"

jq -n --arg uuid "$FRIEND_UUID" '{
  name: "friend", uuid: $uuid, schema_version: 3, multi_route: true,
  sub_token: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  transport: "xhttp", port: 443,
  routes: [
    {label:"xhttp-legacy", transport:"xhttp", port:443, sni:"a.example", fingerprint:"chrome"},
    {label:"tcp-vision", transport:"tcp", port:34521, sni:"d.example", fingerprint:"chrome"},
    {label:"grpc", transport:"grpc", port:8443, sni:"c.example", fingerprint:"chrome"}
  ]
}' > "$PROFILES_DIR/friend.json"

jq -n --arg uuid "$OTHER_UUID" '{
  name: "other", uuid: $uuid, transport: "tcp", port: 443, sni: "a.example",
  sub_token: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
}' > "$PROFILES_DIR/other.json"

make_config() {
  jq -n --arg f "$FRIEND_UUID" --arg o "$OTHER_UUID" '{
    inbounds: [
      {port: 10085, listen: "127.0.0.1", protocol: "dokodemo-door",
       settings: {address: "127.0.0.1"}, tag: "api"},
      {port: 443, tag: "inbound-443", settings: {clients: [
        {id: $f, flow: "", email: "friend"}, {id: $o, flow: "xtls-rprx-vision", email: "other"}],
        decryption: "none"}},
      {port: 34521, tag: "inbound-34521", settings: {clients: [
        {id: $f, flow: "xtls-rprx-vision", email: "friend"}], decryption: "none"}},
      {port: 8443, tag: "inbound-8443", settings: {clients: [
        {id: $f, flow: "", email: "friend"}], decryption: "none"}}
    ],
    routing: {rules: [{type: "field", inboundTag: ["api"], outboundTag: "api"}]}
  }' > "$CONFIG_FILE"
}
make_config

assert_json() {
  local json="$1" expr="$2" msg="$3"
  jq -e "$expr" <<< "$json" >/dev/null || fail "$msg: $json"
}

# --- 1. _normalize_traffic_limit: единицы измерения ---
[[ "$(_normalize_traffic_limit 100GB)" == "107374182400" ]] || fail "100GB"
[[ "$(_normalize_traffic_limit 500MB)" == "524288000" ]] || fail "500MB"
[[ "$(_normalize_traffic_limit '500 MB')" == "524288000" ]] || fail "500 MB with space"
[[ "$(_normalize_traffic_limit 1.5GB)" == "1610612736" ]] || fail "1.5GB"
[[ "$(_normalize_traffic_limit 2tb)" == "2199023255552" ]] || fail "2tb"
[[ "$(_normalize_traffic_limit 1234567)" == "1234567" ]] || fail "bare bytes"
[[ "$(_normalize_traffic_limit none)" == "0" ]] || fail "none"
[[ "$(_normalize_traffic_limit NONE)" == "0" ]] || fail "NONE case-insensitive"
[[ "$(_normalize_traffic_limit 0)" == "0" ]] || fail "0"
for bad in "abc" "10XB" "-5" "" "GB"; do
  if _normalize_traffic_limit "$bad" >/dev/null 2>&1; then fail "limit '$bad' accepted"; fi
done

# --- 2. traffic-check: накопление дельтами, JSON-only, без рестарта ---
write_stats 3000 500
out=$(traffic_check_command) || fail "traffic-check #1 failed: $out"
assert_json "$out" '.ok == true and (.disabled | length == 0) and (.enabled | length == 0)' "traffic-check #1 result"
[[ "$(restarts_now)" == "0" ]] || fail "traffic-check accounting must not restart xray"
jq -e '.traffic.used == 3000 and .traffic.last == 3000' "$PROFILES_DIR/friend.json" >/dev/null \
  || fail "friend used/last not accumulated"
jq -e '.traffic.used == 500 and .traffic.last == 500' "$PROFILES_DIR/other.json" >/dev/null \
  || fail "other used/last not accumulated"

# Повтор с теми же счётчиками: дельта 0 — used не двигается, рестарта нет.
out=$(traffic_check_command) || fail "traffic-check #2 failed: $out"
jq -e '.traffic.used == 3000' "$PROFILES_DIR/friend.json" >/dev/null || fail "used moved without delta"
[[ "$(restarts_now)" == "0" ]] || fail "idempotent accounting must not restart"

# Рестарт Xray: счётчики сброшены (cur < last) → дельта = cur.
write_stats 700 500
traffic_check_command >/dev/null || fail "traffic-check after restart failed"
jq -e '.traffic.used == 3700 and .traffic.last == 700' "$PROFILES_DIR/friend.json" >/dev/null \
  || fail "reset detection wrong (used should be 3700)"

# --- 3. profile-limit: поднятие лимита выше used — без применения ---
out=$(profile_limit_command --name friend --limit 100KB) || fail "profile-limit 100KB failed: $out"
assert_json "$out" '.ok == true and .traffic_limit == 102400 and .traffic_used == 3700 and .traffic_disabled == false' \
  "profile-limit 100KB result"
[[ "$(restarts_now)" == "0" ]] || fail "limit above used must not restart"
jq -e '.traffic.limit == 102400' "$PROFILES_DIR/friend.json" >/dev/null || fail "limit not written"

# --- 4. profile-limit: лимит ниже used — немедленный бан ---
out=$(profile_limit_command --name friend --limit 3KB) || fail "profile-limit 3KB failed: $out"
assert_json "$out" '.ok == true and .traffic_limit == 3072 and .traffic_disabled == true' "profile-limit 3KB result"
[[ "$(restarts_now)" == "1" ]] || fail "immediate disable must restart once"
jq -e --arg u "$FRIEND_UUID" 'all(.inbounds[]; all(.settings.clients[]?; .id != $u))' \
  "$CONFIG_FILE" >/dev/null || fail "banned client still in config"
jq -e --arg o "$OTHER_UUID" '
  (.inbounds[] | select(.port == 443) | any(.settings.clients[]?; .id == $o and .flow == "xtls-rprx-vision"))
' "$CONFIG_FILE" >/dev/null || fail "foreign client on shared port damaged"
jq -e --arg u "$FRIEND_UUID" '
  .traffic_disabled == true and
  (.traffic_clients | length == 3) and
  (any(.traffic_clients[]; .port == 34521 and .client.flow == "xtls-rprx-vision")) and
  (any(.traffic_clients[]; .port == 443 and .client.flow == "")) and
  (all(.traffic_clients[]; .client.id == $u))
' "$PROFILES_DIR/friend.json" >/dev/null || fail "traffic snapshot missing/incorrect"
# Inbound'ы не удаляются: разбан не должен менять shortId.
jq -e '.inbounds | length == 4' "$CONFIG_FILE" >/dev/null || fail "traffic ban deleted inbounds"

# --- 5. traffic-check: бан активен → повторный бан не нужен (нет изменений конфига) ---
write_stats 20000 500
out=$(traffic_check_command) || fail "traffic-check while banned failed: $out"
assert_json "$out" '.ok == true and (.disabled | length == 0) and (.enabled | length == 0)' \
  "already-banned profile must be no-op"
[[ "$(restarts_now)" == "1" ]] || fail "already-banned must not restart"
# Счётчик продолжает накапливаться даже при бане (cur 20000 < last 700? нет: 20000 > 700).
jq -e '.traffic.used == (3700 + 19300)' "$PROFILES_DIR/friend.json" >/dev/null \
  || fail "accounting must continue while banned"

# --- 6. profile-limit: лимит выше used → разбан со снимком (flow сохранён) ---
out=$(profile_limit_command --name friend --limit 100KB) || fail "unban failed: $out"
assert_json "$out" '.ok == true and .traffic_disabled == false' "unban result"
[[ "$(restarts_now)" == "2" ]] || fail "unban must restart once"
jq -e --arg u "$FRIEND_UUID" '
  (.inbounds[] | select(.port == 443) | any(.settings.clients[]?; .id == $u and .flow == "")) and
  (.inbounds[] | select(.port == 34521) | any(.settings.clients[]?; .id == $u and .flow == "xtls-rprx-vision")) and
  (.inbounds[] | select(.port == 8443) | any(.settings.clients[]?; .id == $u and .flow == ""))
' "$CONFIG_FILE" >/dev/null || fail "unban lost clients/flows"
jq -e --arg o "$OTHER_UUID" '
  (.inbounds[] | select(.port == 443) | any(.settings.clients[]?; .id == $o))
' "$CONFIG_FILE" >/dev/null || fail "unban damaged foreign client"
jq -e '.traffic_disabled == false and ((.traffic_clients // []) | length == 0)' \
  "$PROFILES_DIR/friend.json" >/dev/null || fail "unban left flag/snapshot"

# --- 7. profile-limit none → безлимит; --reset → сброс счётчика ---
out=$(profile_limit_command --name friend --limit none) || fail "limit none failed: $out"
assert_json "$out" '.ok == true and .traffic_limit == 0 and .traffic_disabled == false' "limit none result"
[[ "$(restarts_now)" == "2" ]] || fail "limit none must not restart (no action)"
jq -e '.traffic.limit == 0' "$PROFILES_DIR/friend.json" >/dev/null || fail "limit none not written"

out=$(profile_limit_command --name friend --reset) || fail "reset failed: $out"
assert_json "$out" '.ok == true and .traffic_used == 0' "reset result"
[[ "$(restarts_now)" == "2" ]] || fail "reset must not restart"
jq -e '.traffic.used == 0' "$PROFILES_DIR/friend.json" >/dev/null || fail "used not reset"

# --- 8. traffic-check: превышение лимита в таймере → бан ---
write_stats 1500 500
traffic_check_command >/dev/null || fail "accumulate before ban failed"   # used: 0+1500=1500
out=$(profile_limit_command --name friend --limit 1000) || fail "limit 1000 failed: $out"
assert_json "$out" '.traffic_disabled == true' "immediate ban with used 1500 vs limit 1000"
[[ "$(restarts_now)" == "3" ]] || fail "immediate ban must restart once"
out=$(profile_limit_command --name friend --limit none) || fail "unban after timer-rule failed: $out"
assert_json "$out" '.traffic_disabled == false' "unban after limit none"
[[ "$(restarts_now)" == "4" ]] || fail "unban must restart once"
jq -e --arg u "$FRIEND_UUID" '[.inbounds[].settings.clients[]?.id] | index($u) != null' \
  "$CONFIG_FILE" >/dev/null || fail "client not restored after unban"
jq -e --arg u "$FRIEND_UUID" \
  '(.inbounds[] | select(.port == 34521) | .settings.clients[] | select(.id == $u) | .flow) == "xtls-rprx-vision"' \
  "$CONFIG_FILE" >/dev/null || fail "restore lost vision flow"

# --- 9. Кросс-гард expire × traffic: бан по сроку не разбанивается лимитом ---
jq '.traffic = ((.traffic // {}) + {limit: 1}) | .traffic_disabled = true | .expire = 1000 | .expire_disabled = true' \
  "$PROFILES_DIR/friend.json" > "$WORKDIR/f.tmp" && mv "$WORKDIR/f.tmp" "$PROFILES_DIR/friend.json"
jq --arg u "$FRIEND_UUID" '.inbounds |= map(.settings.clients = ((.settings.clients // []) | map(select(.id != $u))))' \
  "$CONFIG_FILE" > "$WORKDIR/c.tmp" && mv "$WORKDIR/c.tmp" "$CONFIG_FILE"
restarts_before=$(restarts_now)
out=$(profile_limit_command --name friend --limit none) || fail "cross-guard unban failed: $out"
assert_json "$out" '.ok == true and .traffic_limit == 0 and .traffic_disabled == false' "cross-guard result"
[[ "$(restarts_now)" == "$restarts_before" ]] || fail "cross-guard must not restart"
jq -e '.expire_disabled == true and .traffic_disabled == false' "$PROFILES_DIR/friend.json" >/dev/null \
  || fail "cross-guard wrong flags"
jq -e --arg u "$FRIEND_UUID" 'all(.inbounds[]; all(.settings.clients[]?; .id != $u))' \
  "$CONFIG_FILE" >/dev/null || fail "cross-guard must not restore client while expired"
# Возвращаем профиль в рабочее состояние.
jq 'del(.expire) | del(.expire_disabled)' "$PROFILES_DIR/friend.json" > "$WORKDIR/f.tmp" && mv "$WORKDIR/f.tmp" "$PROFILES_DIR/friend.json"

# --- 10. Ошибки CLI: валидация ---
if out=$(profile_limit_command --name friend --limit 10XB); then fail "bad limit accepted"; fi
assert_json "$out" '.ok == false' "bad limit error"
if out=$(profile_limit_command --name friend); then fail "no --limit/--reset accepted"; fi
assert_json "$out" '.ok == false' "missing args error"
if out=$(profile_limit_command --name "bad name!" --limit 1GB); then fail "bad name accepted"; fi
assert_json "$out" '.ok == false' "bad name error"
if out=$(profile_limit_command --name nosuch --limit 1GB); then fail "missing profile accepted"; fi
assert_json "$out" '.ok == false' "missing profile error"

# --- 11. Stats API недоступен → ok:false, stdout — только JSON ---
rm -f "$STATS_FILE"
if out=$(traffic_check_command); then fail "traffic-check succeeded without API"; fi
assert_json "$out" '.ok == false and (.error | test("Stats API"))' "API unavailable error"
jq -e '.error | test("traffic_stats_2026")' <<< \
  "$(jq -e 'del(.inbounds[] | select(.tag == "api"))' "$CONFIG_FILE" > "$WORKDIR/c.tmp" \
     && mv "$WORKDIR/c.tmp" "$CONFIG_FILE" \
     && (traffic_check_command || true))" >/dev/null \
  || fail "no-api-inbound error must mention migration name"
make_config
write_stats 1500 500

# --- 12. Миграция traffic_stats_2026: stats/api/inbound/rule/email ---
MIG_CFG="$WORKDIR/mig-config.json"
jq -n --arg f "$FRIEND_UUID" --arg o "$OTHER_UUID" '{
  inbounds: [
    {port: 443, tag: "inbound-443", settings: {clients: [
      {id: $f, flow: ""}, {id: $o, flow: "xtls-rprx-vision"}], decryption: "none"}},
    {port: 34521, tag: "inbound-34521", settings: {clients: [{id: $f, flow: "xtls-rprx-vision"}], decryption: "none"}},
    {port: 8443, tag: "inbound-8443", settings: {clients: [{id: $f, flow: ""}], decryption: "none"}}
  ],
  routing: {rules: []}
}' > "$MIG_CFG"
SAVED_CFG="$CONFIG_FILE"
CONFIG_FILE="$MIG_CFG"
rc=0; _migrate_traffic_stats_2026 >/dev/null 2>&1 || rc=$?
[[ "$rc" == "0" ]] || fail "traffic_stats_2026 first run must return 0 (changed), got $rc"
jq -e 'has("stats") and .api.tag == "api" and (.api.services | index("StatsService") != null)' "$MIG_CFG" >/dev/null \
  || fail "stats/api section missing"
jq -e '.inbounds | any(.tag == "api" and .port == 10085 and .listen == "127.0.0.1" and .protocol == "dokodemo-door")' \
  "$MIG_CFG" >/dev/null || fail "api inbound missing/wrong"
jq -e '.routing.rules[0] == {"type": "field", "inboundTag": ["api"], "outboundTag": "api"}' "$MIG_CFG" >/dev/null \
  || fail "api routing rule must be first"
jq -e '.policy.system.statsInboundUplink == true and .policy.system.statsInboundDownlink == true' "$MIG_CFG" >/dev/null \
  || fail "policy.system stats flags missing"
jq -e --arg f "$FRIEND_UUID" --arg o "$OTHER_UUID" '
  (all(.inbounds[].settings.clients[]? | select(.id == $f); .email == "friend")) and
  (all(.inbounds[].settings.clients[]? | select(.id == $o); .email == "other")) and
  ([.inbounds[].settings.clients[]?.email] | index("friend") != null)
' "$MIG_CFG" >/dev/null || fail "client emails not set by migration"
rc=0; _migrate_traffic_stats_2026 >/dev/null 2>&1 || rc=$?
[[ "$rc" == "1" ]] || fail "traffic_stats_2026 second run must be no-op (1), got $rc"

# Порт 10085 занят другим inbound → миграция обязана найти 10086.
MIG2_CFG="$WORKDIR/mig2-config.json"
jq '.inbounds += [{port: 10085, tag: "decoy", settings: {}, protocol: "socks"}]' "$MIG_CFG" > "$MIG2_CFG"
jq 'del(.inbounds[] | select(.tag == "api"))' "$MIG2_CFG" > "$WORKDIR/c.tmp" && mv "$WORKDIR/c.tmp" "$MIG2_CFG"
CONFIG_FILE="$MIG2_CFG"
rc=0; _migrate_traffic_stats_2026 >/dev/null 2>&1 || rc=$?
[[ "$rc" == "0" ]] || fail "collision migration must return 0, got $rc"
jq -e '.inbounds | any(.tag == "api" and .port == 10086)' "$MIG2_CFG" >/dev/null \
  || fail "collision: api inbound must use 10086"
CONFIG_FILE="$SAVED_CFG"

# --- 13. profiles JSON: поля трафика для GUI ---
profiles_json=$(
  _profile_cli_subscription_url() { return 1; }
  _subscription_base_url() { printf 'https://example.invalid'; }
  profiles_command 2>/dev/null
) || fail "profiles command failed"
jq -e '. | map(select(.name == "friend")) | .[0] |
  .traffic_supported == true and (.traffic_used | type == "number") and
  (.traffic_limit | type == "number") and (.traffic_disabled | type == "boolean")' \
  <<< "$profiles_json" >/dev/null || fail "profiles JSON missing traffic fields: $profiles_json"

# --- 14. Статические инварианты handler'а подписки и юнитов ---
# Регрессия: голый `exec {FD}>file 2>/dev/null` в _lock_acquire применялся бы
# к шеллу НАВСЕГДА и глушил stderr всего процесса после первого safe_jq_write
# (все последующие ошибки CLI уходили в /dev/null). Ловим поведенчески.
jq -n '{traffic:{}}' > "$WORKDIR/stderr-probe.json"
stderr_probe=$( { safe_jq_write '.traffic.used = 1' "$WORKDIR/stderr-probe.json" >/dev/null; echo "stderr-alive" >&2; } 2>&1 )
[[ "$stderr_probe" == *stderr-alive* ]] \
  || fail "safe_jq_write заглушил stderr процесса (голый exec с 2>/dev/null?)"

grep -q '\.traffic_disabled == true' xrayebator || fail "410-check не учитывает traffic_disabled"
grep -q 'download=\${traffic_used}' xrayebator || fail "subscription-userinfo download не с реальным used"
grep -q 'total=\${traffic_limit}' xrayebator || fail "subscription-userinfo total не с реальным limit"
grep -q 'ExecStart=/usr/local/bin/xrayebator traffic-check' xrayebator || fail "нет unit-а traffic-check"
grep -q 'OnUnitActiveSec=5min' xrayebator || fail "таймер трафика не 5 минут"
grep -q 'xrayebator-traffic.timer' uninstall.sh || fail "uninstall не снимает traffic-timer"
for name in traffic_stats_2026 traffic_timer_2026 subhttp_traffic_2026; do
  count=$(grep -c "run_migration \"$name\"" xrayebator || true)
  [[ "$count" -ge 3 ]] || fail "migration $name зарегистрирована меньше 3 раз (main/quickstart/happ-setup): $count"
done

echo "PASS: traffic accounting accumulates deltas, enforces limits, unban restores flows and stays JSON-clean"
