#!/usr/bin/env bash
# test-profile-revoke-expire-cli.sh
# Тестирует CLI revoke/expire из xrayebator:
#   profile-revoke (токен / --full с ротацией uuid), profile-expire (дата/epoch/none,
#   немедленное принуждение), expire-check (пакетное идемпотентное принуждение),
#   bypass groups (JSON-описание групп bundle), profile-create --expire.
# Гарантии:
#   - stdout CLI содержит ТОЛЬКО JSON (статусы helpers не протекают);
#   - revoke --full меняет uuid во всех inbound'ах портов профиля, чужие клиенты
#     на общем порте не затрагиваются;
#   - expire реально выключает клиента и возвращает его при продлении (со снимком
#     flow), expire-check без изменений не рестартует xray.
#
# Usage:  bash validation/test-profile-revoke-expire-cli.sh
# Requires: jq, uuidgen, openssl, bash 4+.

set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORKDIR=$(mktemp -d /tmp/xrayebator-revoke-expire.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

source "$REPO_ROOT/xrayebator"

CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"
XRAY_BACKUPS_DIR="$WORKDIR/backups"
mkdir -p "$PROFILES_DIR" "$XRAY_BACKUPS_DIR"

RESTART_LOG="$WORKDIR/restarts.log"
: > "$RESTART_LOG"
# Счётчик через файл: safe_restart_xray вызывается в подшеллах $(...),
# инкремент переменной в подшелле наружу не виден.
safe_restart_xray() { echo restart >> "$RESTART_LOG"; return 0; }
restarts_now() { wc -l < "$RESTART_LOG" | tr -d ' '; }
fix_xray_permissions() { return 0; }
systemctl() { return 0; }

# 7-портовый multi-route профиль friend + чужой профиль other на общем порту 443.
FRIEND_UUID="11111111-1111-4111-8111-111111111111"
OTHER_UUID="22222222-2222-4222-8222-222222222222"
FRIEND_PORTS='[443, 2053, 2083, 8443, 34521, 34522, 34523]'

jq -n --arg uuid "$FRIEND_UUID" --argjson ports "$FRIEND_PORTS" '{
  name: "friend", uuid: $uuid, schema_version: 3, multi_route: true,
  sub_token: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  transport: "xhttp", port: 443,
  routes: [
    {label:"xhttp-legacy", transport:"xhttp", port:443, sni:"a.example", fingerprint:"chrome"},
    {label:"xhttp-pq", transport:"xhttp", port:2053, sni:"a.example", fingerprint:"chrome"},
    {label:"tcp-mux", transport:"tcp-mux", port:2083, sni:"b.example", fingerprint:"chrome"},
    {label:"grpc", transport:"grpc", port:8443, sni:"c.example", fingerprint:"chrome"},
    {label:"tcp-vision", transport:"tcp", port:34521, sni:"d.example", fingerprint:"chrome"},
    {label:"tcp-utls", transport:"tcp-utls", port:34522, sni:"d.example", fingerprint:"firefox"},
    {label:"tcp-xudp", transport:"tcp-xudp", port:34523, sni:"e.example", fingerprint:"chrome"}
  ]
}' > "$PROFILES_DIR/friend.json"

jq -n --arg uuid "$OTHER_UUID" '{
  name: "other", uuid: $uuid, transport: "tcp", port: 443, sni: "a.example",
  sub_token: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
}' > "$PROFILES_DIR/other.json"

make_config() {
  jq -n --arg f "$FRIEND_UUID" --arg o "$OTHER_UUID" '{
    inbounds: [
      {port: 443, tag: "inbound-443", settings: {clients: [
        {id: $f, flow: ""}, {id: $o, flow: "xtls-rprx-vision"}], decryption: "none"}},
      {port: 2053, tag: "inbound-2053", settings: {clients: [{id: $f, flow: ""}], decryption: "none"}},
      {port: 2083, tag: "inbound-2083", settings: {clients: [{id: $f, flow: ""}], decryption: "none"}},
      {port: 8443, tag: "inbound-8443", settings: {clients: [{id: $f, flow: ""}], decryption: "none"}},
      {port: 34521, tag: "inbound-34521", settings: {clients: [{id: $f, flow: "xtls-rprx-vision"}], decryption: "none"}},
      {port: 34522, tag: "inbound-34522", settings: {clients: [{id: $f, flow: "xtls-rprx-vision"}], decryption: "none"}},
      {port: 34523, tag: "inbound-34523", settings: {clients: [{id: $f, flow: "xtls-rprx-vision"}], decryption: "none"}}
    ],
    routing: {rules: []}
  }' > "$CONFIG_FILE"
}
make_config

# --- 1. Revoke токена: sub_token меняется, uuid НЕ трогаем ---
out=$(profile_revoke_command --name friend) || fail "revoke token failed: $out"
jq -e '.ok == true and .full == false' <<< "$out" >/dev/null || fail "revoke bad JSON: $out"
new_token=$(jq -r '.sub_token' <<< "$out")
[[ "$new_token" =~ ^[a-f0-9]{32}$ ]] && [[ "$new_token" != "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]] ||
  fail "revoke did not rotate token: $out"
jq -e '.sub_token == "'"$new_token"'" and .uuid == "'"$FRIEND_UUID"'"' \
  "$PROFILES_DIR/friend.json" >/dev/null || fail "profile JSON not updated with token"
jq -e '[.inbounds[].settings.clients[].id] | index("'"$FRIEND_UUID"'") != null' \
  "$CONFIG_FILE" >/dev/null || fail "token-only revoke must NOT touch uuids"

# --- 2. Revoke --full: uuid меняется везде, чужой клиент на 443 цел ---
out=$(profile_revoke_command --name friend --full) || fail "revoke --full failed: $out"
jq -e '.ok == true and .full == true' <<< "$out" >/dev/null || fail "revoke full bad JSON: $out"
full_token=$(jq -r '.sub_token' <<< "$out")
[[ "$full_token" =~ ^[a-f0-9]{32}$ && "$full_token" != "$new_token" ]] ||
  fail "revoke --full must rotate token too"
rotated_uuid=$(jq -r '.uuid' <<< "$out")
[[ "$rotated_uuid" =~ ^[0-9a-fA-F-]{36}$ ]] && [[ "$rotated_uuid" != "$FRIEND_UUID" ]] ||
  fail "revoke --full did not rotate uuid: $out"
jq -e --arg old "$FRIEND_UUID" --arg other "$OTHER_UUID" '
  ([.inbounds[].settings.clients[].id] | index($old)) == null and
  ([.inbounds[].settings.clients[].id] | index($other)) != null
' "$CONFIG_FILE" >/dev/null || fail "revoke --full left old uuid or killed other client"
jq -e '[.inbounds[] | select(.port != 443) | .settings.clients | length] == [1,1,1,1,1,1]' \
  "$CONFIG_FILE" >/dev/null || fail "revoke --full lost clients on solo ports"
# flow Vision-маршрутов обязан сохраниться (замена id, не пересборка клиента)
jq -e --arg u "$rotated_uuid" '
  (.inbounds[] | select(.port == 34521) | .settings.clients[] | select(.id == $u) | .flow) == "xtls-rprx-vision" and
  (.inbounds[] | select(.port == 443) | .settings.clients[] | select(.id == $u) | .flow) == ""
' "$CONFIG_FILE" >/dev/null || fail "revoke --full lost per-route flow"
jq -e '.uuid == "'"$rotated_uuid"'" and .sub_token == "'"$full_token"'"' \
  "$PROFILES_DIR/friend.json" >/dev/null || fail "profile JSON not updated with rotated uuid"

# --- 2b. Revoke --full на SINGLE-ROUTE профиле: у него routes отсутствуют —
# прежнее выражение (.routes // []) |= map(...) было невалидным path в jq
# («Invalid path expression with result []») и роняло полный отзыв.
cp "$CONFIG_FILE" "$WORKDIR/config.before-solo.json"
SOLO_UUID="33333333-3333-4333-8333-333333333333"
jq -n --arg uuid "$SOLO_UUID" '{
  name: "solo", uuid: $uuid, transport: "xhttp", port: 9955,
  sub_token: "cccccccccccccccccccccccccccccccc"
}' > "$PROFILES_DIR/solo.json" || fail "fixture solo"
jq -n --arg uuid "$SOLO_UUID" '{
  inbounds: [{port: 9955, tag: "inbound-9955", settings: {clients: [{id: $uuid, flow: ""}], decryption: "none"}}],
  routing: {rules: []}
}' > "$CONFIG_FILE" || fail "fixture solo config"
out=$(profile_revoke_command --name solo --full) || fail "revoke --full (single-route) failed: $out"
jq -e '.ok == true and .full == true' <<< "$out" >/dev/null || fail "single-route full bad JSON: $out"
solo_uuid=$(jq -r '.uuid' <<< "$out")
[[ "$solo_uuid" =~ ^[0-9a-fA-F-]{36}$ && "$solo_uuid" != "$SOLO_UUID" ]] ||
  fail "single-route revoke --full did not rotate uuid: $out"
jq -e --arg u "$solo_uuid" '[.inbounds[].settings.clients[].id] | index($u) != null' \
  "$CONFIG_FILE" >/dev/null || fail "single-route full revoke: new uuid missing in config"
jq -e --arg old "$SOLO_UUID" '[.inbounds[].settings.clients[].id] | index($old) == null' \
  "$CONFIG_FILE" >/dev/null || fail "single-route full revoke: old uuid still in config"
# восстанавливаем состояние секции 2 для последующих проверок
rm -f "$PROFILES_DIR/solo.json"
cp "$WORKDIR/config.before-solo.json" "$CONFIG_FILE"

# --- 3. profiles JSON: календарная дата приходит из часового пояса сервера ---
# Сервер в UTC-7 называет момент окончания 30 сентября, хотя в UTC и у клиента
# в Москве это уже 1 октября. GUI должен показывать серверную календарную дату.
expire_epoch=$(TZ=America/Los_Angeles date -d "2030-10-01 06:59:59 UTC" +%s)
TZ=America/Los_Angeles _normalize_expire_value "2030-09-30" >/dev/null || fail "server-local September date rejected"
# Build a minimal test profile and verify profiles_command returns the server's date.
jq -n --argjson expire "$expire_epoch" '{uuid:"33333333-3333-4333-8333-333333333333",transport:"tcp",port:443,expire:$expire}' > "$PROFILES_DIR/tz-test.json"
profiles_json=$(
  _profile_cli_subscription_url() { return 1; }
  _subscription_base_url() { printf 'https://example.invalid'; }
  TZ=America/Los_Angeles profiles_command 2>/dev/null
) || fail "profiles command failed for timezone test"
server_date=$(jq -r '.[] | select(.name == "tz-test") | .expire_date // empty' <<< "$profiles_json")
[[ "$server_date" == "2030-09-30" ]] || fail "profiles JSON expire_date wrong (got '$server_date', expected server-local 2030-09-30)"

# --- 3. profile-expire: валидация нормализации ---
[[ "$(_normalize_expire_value 1000000000000)" == "1000000000" ]] || fail "ms not normalized"
[[ "$(_normalize_expire_value 1785000000)" == "1785000000" ]] || fail "sec epoch changed"
if _normalize_expire_value "2030-13-01" 2>/dev/null; then fail "month 13 accepted"; fi
if _normalize_expire_value "abc" 2>/dev/null; then fail "garbage accepted"; fi
FUTURE_EPOCH=$(date -d "2030-01-01 12:30" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M" "2030-01-01 12:30" +%s)
[[ "$(_normalize_expire_value "2030-01-01 12:30")" == "$FUTURE_EPOCH" ]] || fail "datetime normalization mismatch"
# Дата без времени — ВКЛЮЧИТЕЛЬНО: срок истекает в 23:59:59 выбранного дня.
# Иначе «до 30 сентября» отключало профиль в 00:00 30-го, то есть на сутки раньше.
END_OF_DAY=$(date -d "2030-01-01 23:59:59" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "2030-01-01 23:59:59" +%s)
got=$(_normalize_expire_value "2030-01-01")
[[ "$got" == "$END_OF_DAY" ]] \
  || fail "дата без времени должна быть концом суток (получено $got, ожидалось $END_OF_DAY)"
# Проверка на сдвиг: дата в ISO должна соответствовать выбранной в той же зоне.
[[ "$(date -d "@$got" +%Y-%m-%d)" == "2030-01-01" ]] \
  || fail "нормализованная дата не совпадает с выбранной"
# Регрессия: bash читает "09" как восьмеричное число, и валидация месяца/дня/часа
# падала с "value too great for base" — любые даты с 08/09 не принимались
# (включая сентябрь). Защита — префикс 10#. Проверяем все проблемные разряды.
for probe in "2030-09-30" "2030-08-08" "2030-09-09 08:09" "2030-10-09 09:08"; do
  _normalize_expire_value "$probe" >/dev/null 2>&1 \
    || fail "дата '$probe' не принята (восьмеричная ловушка bash?)"
done
sep_epoch=$(_normalize_expire_value "2030-09-30")
[[ "$(date -d "@$sep_epoch" +%m-%d)" == "09-30" ]] \
  || fail "сентябрь нормализован неверно: $(date -d "@$sep_epoch" +%m-%d)"

# --- 4. profile-expire: будущее → поле есть, профиль жив, рестарта нет ---
restarts_before=$(restarts_now)
out=$(profile_expire_command --name friend --expire "2030-01-01") || fail "profile-expire future failed: $out"
jq -e '.ok == true and .expired == false' <<< "$out" >/dev/null || fail "expire future bad JSON: $out"
[[ "$(restarts_now)" == "$restarts_before" ]] || fail "future expire must not restart xray"
jq -e '.expire == '"$(_normalize_expire_value "2030-01-01")"' and .expire_disabled != true' \
  "$PROFILES_DIR/friend.json" >/dev/null || fail "expire field not written"

# --- 5. profile-expire: прошедшая дата → клиент удалён из конфига, снимок с flow ---
out=$(profile_expire_command --name friend --expire "2020-01-01") || fail "profile-expire past failed: $out"
jq -e '.ok == true and .expired == true' <<< "$out" >/dev/null || fail "expire past bad JSON: $out"
jq -e --arg u "$rotated_uuid" 'all(.inbounds[].settings.clients[]?; .id != $u)' \
  "$CONFIG_FILE" >/dev/null || fail "expired profile client still in config"
# Inbound'ы обязаны выжить (иначе продление не восстановит маршруты с короткими id).
jq -e '.inbounds | length == 7' "$CONFIG_FILE" >/dev/null || fail "expire deleted inbounds"
jq -e --arg u "$rotated_uuid" '
  .expire_disabled == true and
  (.expire_clients | length == 7) and
  (all(.expire_clients[]; .client.id == $u)) and
  (any(.expire_clients[]; .port == 34521 and .client.flow == "xtls-rprx-vision")) and
  (any(.expire_clients[]; .port == 443 and .client.flow == ""))
' "$PROFILES_DIR/friend.json" >/dev/null || fail "expire snapshot missing/incorrect"
jq -e --arg o "$OTHER_UUID" '.inbounds[] | select(.port == 443) | any(.settings.clients[]?; .id == $o)' \
  "$CONFIG_FILE" >/dev/null || fail "expire removed foreign client on shared port"

# --- 6. profile-expire: продление → клиент вернулся с flow, снимок удалён ---
out=$(profile_expire_command --name friend --expire "2031-06-01") || fail "renew failed: $out"
jq -e --arg u "$rotated_uuid" '
  (.inbounds[] | select(.port == 34521) | .settings.clients[] | select(.id == $u) | .flow) == "xtls-rprx-vision" and
  ([.inbounds[].settings.clients[].id] | index($u)) != null
' "$CONFIG_FILE" >/dev/null || fail "renew did not restore client with flow"
jq -e '.expire_disabled == false and ((.expire_clients // []) | length == 0)' \
  "$PROFILES_DIR/friend.json" >/dev/null || fail "renew did not clear snapshot"

# --- 7. profile-expire none → вечный ---
out=$(profile_expire_command --name friend --expire none) || fail "expire none failed: $out"
jq -e 'has("expire") | not' "$PROFILES_DIR/friend.json" >/dev/null || fail "expire not deleted"

# --- 8. expire-check: пакетное принуждение + идемпотентность ---
# friend: срок прошёл, но профиль включён вручную (нет флага) → будет забанен.
jq '.expire = 1000 | del(.expire_disabled) | del(.expire_clients)' "$PROFILES_DIR/friend.json" > "$WORKDIR/f.tmp" && mv "$WORKDIR/f.tmp" "$PROFILES_DIR/friend.json"
jq --arg u "$rotated_uuid" '.inbounds |= map(if .port == 443 then .settings.clients += [{id: $u, flow: ""}] else . end)' "$CONFIG_FILE" > "$WORKDIR/c.tmp" && mv "$WORKDIR/c.tmp" "$CONFIG_FILE"
# other: бессрочный — не трогаем
restarts_before=$(restarts_now)
out=$(expire_check_command) || fail "expire-check failed: $out"
jq -e '.ok == true and (.disabled | index("friend") != null) and ((.enabled | index("other")) == null)' \
  <<< "$out" >/dev/null || fail "expire-check wrong result: $out"
[[ "$(restarts_now)" == "$((restarts_before + 1))" ]] || fail "expire-check must restart once"
jq -e --arg u "$rotated_uuid" 'all(.inbounds[].settings.clients[]?; .id != $u)' \
  "$CONFIG_FILE" >/dev/null || fail "expire-check left client enabled"
# Идемпотентность: второй прогон — пусто и БЕЗ рестарта (иначе таймер ронял бы Xray каждые 10 мин).
restarts_before=$(restarts_now)
out=$(expire_check_command) || fail "expire-check rerun failed: $out"
jq -e '.ok == true and (.disabled | length == 0) and (.enabled | length == 0)' \
  <<< "$out" >/dev/null || fail "expire-check not idempotent: $out"
[[ "$(restarts_now)" == "$restarts_before" ]] || fail "idempotent expire-check must not restart"

# --- 9. expire-check: enable без снимка → rebuild из routes-метаданных ---
# Флаг остаётся (клиент по-прежнему забанен), expire уходит в будущее, снимок потерян —
# enable должен восстановить клиентов rebuild-путём с правильными flow.
jq 'del(.expire_clients) | .expire = 4102444800' "$PROFILES_DIR/friend.json" > "$WORKDIR/f.tmp" && mv "$WORKDIR/f.tmp" "$PROFILES_DIR/friend.json"
out=$(expire_check_command) || fail "expire-check enable pass failed: $out"
jq -e '.enabled | index("friend") != null' <<< "$out" >/dev/null || fail "expire-check did not re-enable: $out"
jq -e --arg u "$rotated_uuid" '
  all(.inbounds[]; select(.port != 443) | any(.settings.clients[]?; .id == $u)) and
  (.inbounds[] | select(.port == 34521) | .settings.clients[] | select(.id == $u) | .flow) == "xtls-rprx-vision" and
  (.inbounds[] | select(.port == 8443) | .settings.clients[] | select(.id == $u) | .flow) == ""
' "$CONFIG_FILE" >/dev/null || fail "rebuild restore lost flows"
jq -e '.expire_disabled == false' "$PROFILES_DIR/friend.json" >/dev/null || fail "enable left flag"

# --- 10. revoke --full на отключённом по сроку → отказ ---
jq '.expire = 1000 | .expire_disabled = true' "$PROFILES_DIR/friend.json" > "$WORKDIR/f.tmp" && mv "$WORKDIR/f.tmp" "$PROFILES_DIR/friend.json"
if out=$(profile_revoke_command --name friend --full); then
  fail "revoke --full on disabled profile unexpectedly succeeded"
fi
jq -e '.ok == false' <<< "$out" >/dev/null || fail "revoke-on-expired did not return ok:false: $out"

# --- 11. revoke невалидные аргументы / отсутствующий профиль ---
if out=$(profile_revoke_command --name "bad name!"); then fail "revoke bad name accepted"; fi
jq -e '.ok == false' <<< "$out" >/dev/null || fail "revoke bad name: $out"
if out=$(profile_revoke_command --name nosuch); then fail "revoke missing profile accepted"; fi
jq -e '.ok == false' <<< "$out" >/dev/null || fail "revoke missing profile: $out"

# --- 12. profile-create --expire: поле попадает в профиль (add_inbound застабан) ---
add_inbound() { return 0; }
build_transport_defaults() { echo "34999|svc|/xp"; }
reserve_port() { return 0; }
open_firewall_port() { return 0; }
out=$(profile_create_command --name kid --transport tcp --expire "2030-05-05") || fail "create --expire failed: $out"
jq -e '.ok == true and (.names | index("kid") != null)' <<< "$out" >/dev/null || fail "create --expire bad JSON: $out"
jq -e '.expire == '"$(_normalize_expire_value "2030-05-05")" "$PROFILES_DIR/kid.json" >/dev/null ||
  fail "created profile missing expire"
out=$(profile_create_command --name late --transport tcp --expire "2000-01-01") && fail "create past expire accepted"
jq -e '.ok == false' <<< "$out" >/dev/null || fail "create past expire: $out"

# --- 13. Истёкший профиль не отдаёт маршруты: subhttp отвечает 410 ---
# Логика продублирована из heredoc-обработчика проверкой условий:
#   expire_disabled == true  ИЛИ  expire > 0 и expire <= now
# Тест держит инвариант на исходнике (сам subhttp.sh генерируется на сервере).
jq -e 'del(.expire) | del(.expire_disabled)' "$PROFILES_DIR/kid.json" > "$WORKDIR/k.tmp" \
  && mv "$WORKDIR/k.tmp" "$PROFILES_DIR/kid.json"
grep -q 'emit_410_expired' xrayebator || fail "нет emit_410_expired в subhttp"
grep -q 'Profile expired or disabled' xrayebator || fail "нет тела 410-ответа"
# Длина тела должна совпадать с content-length (иначе клиент зависнет на чтении).
body_len=$(printf 'Profile expired or disabled\n' | wc -c | tr -d ' ')
header_len=$(grep -A5 'emit_410_expired() {' xrayebator | grep -o 'content-length: [0-9]*' | head -1 | grep -o '[0-9]*')
[[ "$body_len" == "$header_len" ]] \
  || fail "content-length ($header_len) не совпадает с телом ($body_len)"
# Проверка ветки отдачи: 410 должен стоять ПОСЛЕ поиска профиля и ДО генерации URL.
grim_line=$(grep -n 'emit_410_expired$' xrayebator | head -1 | cut -d: -f1)
gen_line=$(grep -n 'vless_urls=\$(_generate_vless_urls_for_profile' xrayebator | head -1 | cut -d: -f1)
[[ -n "$grim_line" && -n "$gen_line" && "$grim_line" -lt "$gen_line" ]] \
  || fail "410-проверка должна идти до генерации маршрутов"
# Миграция регенерации subhttp на существующих установках зарегистрирована.
grep -q 'run_migration "subhttp_expired_410_2026"' xrayebator \
  || fail "нет миграции subhttp_expired_410_2026 (на старых серверах 410 не появится)"

echo "PASS: revoke/expire CLI rotate secrets correctly, enforce expiry and stay JSON-clean"
