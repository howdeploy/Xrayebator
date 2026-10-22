#!/bin/bash
# test-subscription-formats.sh
# Проверяет форматы подписки Clash/mihomo (YAML) и sing-box (JSON), которые строятся
# из одного нормализованного представления ссылок профиля:
#   - _subscription_links_json: разбор vless:// (все транспорты менеджера) и
#     hysteria2://, флаги поддержки клиентами, причины пропуска;
#   - _subscription_render_clash_pure: proxies/proxy-groups/rules, reality-opts,
#     flow Vision, packet-encoding xudp, grpc-opts, hysteria2, опциональный xhttp;
#   - _subscription_render_singbox_pure: outbounds, tls.reality, utls, transport grpc,
#     selector/urltest/direct, route.final;
#   - пропуск транспортов, которые клиент не умеет (PQ VLESS Encryption, xhttp в sing-box),
#     вместо отдачи нерабочего конфига; edge-case «нет живых маршрутов» и IPv6/percent-decode.
#
# Usage:  bash validation/test-subscription-formats.sh
# Requires: jq, bash 4+. PyYAML используется, если установлен (в CI может отсутствовать).

set -euo pipefail

fail() {
  echo "✗ $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORKDIR=$(mktemp -d /tmp/xrayebator-subfmt.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/xrayebator"

CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"
PUBLIC_KEY_FILE="$WORKDIR/.public_key"
PRIVATE_KEY_FILE="$WORKDIR/.private_key"
VLESS_ENCRYPTION_FILE="$WORKDIR/.vless_encryption"
# Изоляция: geo-маркер не должен влиять на имена маршрутов.
SERVER_COUNTRY_FILE="$WORKDIR/.server_country"
printf '' > "$SERVER_COUNTRY_FILE"
XRAYEBATOR_SERVER_ADDR_OVERRIDE="203.0.113.10"
HY2_URI='hysteria2://sample:deadbeef@203.0.113.10:8443/?sni=www.ozon.ru&insecure=1#sample-hysteria2'

mkdir -p "$PROFILES_DIR"
printf '%s' 'test-public-key' > "$PUBLIC_KEY_FILE"
printf '%s' 'test-private-key' > "$PRIVATE_KEY_FILE"
printf '%s' 'mlkem768x25519plus.native.test-encryption' > "$VLESS_ENCRYPTION_FILE"

cat > "$CONFIG_FILE" <<'JSON'
{
  "inbounds": [
    {
      "port": 10001, "protocol": "vless",
      "settings": {"clients": [{"id": "11111111-2222-3333-4444-555555555555", "flow": "xtls-rprx-vision"}], "decryption": "none"},
      "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"privateKey": "test-private-key", "shortIds": ["aa11"], "serverNames": ["www.ozon.ru"]}}
    },
    {
      "port": 10002, "protocol": "vless",
      "settings": {"clients": [{"id": "11111111-2222-3333-4444-555555555555", "flow": "xtls-rprx-vision"}], "decryption": "none"},
      "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"privateKey": "test-private-key", "shortIds": ["aa22"], "serverNames": ["www.cloudflare.com"]}}
    },
    {
      "port": 10003, "protocol": "vless",
      "settings": {"clients": [{"id": "11111111-2222-3333-4444-555555555555", "flow": "xtls-rprx-vision"}], "decryption": "none"},
      "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"privateKey": "test-private-key", "shortIds": ["aa33"], "serverNames": ["www.ozon.ru"]}}
    },
    {
      "port": 10004, "protocol": "vless",
      "settings": {"clients": [{"id": "11111111-2222-3333-4444-555555555555", "flow": ""}], "decryption": "none"},
      "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"privateKey": "test-private-key", "shortIds": ["aa44"], "serverNames": ["www.ozon.ru"]}}
    },
    {
      "port": 10005, "protocol": "vless",
      "settings": {"clients": [{"id": "11111111-2222-3333-4444-555555555555", "flow": ""}], "decryption": "none"},
      "streamSettings": {"network": "grpc", "security": "reality", "grpcSettings": {"serviceName": "svc-test"},
        "realitySettings": {"privateKey": "test-private-key", "shortIds": ["aa55"], "serverNames": ["www.cloudflare.com"]}}
    },
    {
      "port": 10006, "protocol": "vless",
      "settings": {"clients": [{"id": "11111111-2222-3333-4444-555555555555", "flow": ""}], "decryption": "none"},
      "streamSettings": {"network": "xhttp", "security": "reality", "xhttpSettings": {"path": "/xhttp-test", "host": "www.ozon.ru"},
        "realitySettings": {"privateKey": "test-private-key", "shortIds": ["aa66"], "serverNames": ["www.ozon.ru"]}}
    },
    {
      "port": 10007, "protocol": "vless",
      "settings": {"clients": [{"id": "11111111-2222-3333-4444-555555555555", "flow": ""}], "decryption": "mlkem768x25519plus.native.test-decryption"},
      "streamSettings": {"network": "xhttp", "security": "reality", "xhttpSettings": {"path": "/xhttp-pq", "host": "www.ozon.ru"},
        "realitySettings": {"privateKey": "test-private-key", "shortIds": ["aa77"], "serverNames": ["www.ozon.ru"]}}
    }
  ]
}
JSON

cat > "$PROFILES_DIR/sample.json" <<'JSON'
{
  "name": "sample",
  "uuid": "11111111-2222-3333-4444-555555555555",
  "routes": [
    {"label": "tcp-vision", "transport": "tcp", "port": 10001, "sni": "www.ozon.ru", "fingerprint": "firefox"},
    {"label": "tcp-utls", "transport": "tcp-utls", "port": 10002, "sni": "www.cloudflare.com", "fingerprint": "chrome"},
    {"label": "tcp-xudp", "transport": "tcp-xudp", "port": 10003, "sni": "www.ozon.ru", "fingerprint": "chrome"},
    {"label": "tcp-mux", "transport": "tcp-mux", "port": 10004, "sni": "www.ozon.ru", "fingerprint": "chrome"},
    {"label": "grpc", "transport": "grpc", "port": 10005, "sni": "www.cloudflare.com", "fingerprint": "chrome", "grpc_service_name": "svc-test"},
    {"label": "xhttp-legacy", "transport": "xhttp", "port": 10006, "sni": "www.ozon.ru", "fingerprint": "chrome", "xhttp_path": "/xhttp-test"},
    {"label": "xhttp-pq", "transport": "xhttp", "port": 10007, "sni": "www.ozon.ru", "fingerprint": "chrome", "pq_enabled": true, "xhttp_path": "/xhttp-pq"}
  ]
}
JSON

# ═══════════ 1. Нормализованные записи ═══════════
links=$(_subscription_links_json "$PROFILES_DIR/sample.json" "$HY2_URI") || fail "links json failed"
[[ "$(jq 'length' <<<"$links")" == "8" ]] || fail "ссылок должно быть 8 (7 VLESS + hysteria2): $links"

jq -e '.[] | select(.name == "sample-tcp-vision") |
  .flow == "xtls-rprx-vision" and .network == "tcp" and .pbk == "test-public-key" and
  .sid == "aa11" and .fp == "firefox" and .clash == true and .singbox == true' <<<"$links" >/dev/null \
  || fail "tcp-vision record wrong: $(jq -c '.[] | select(.name == "sample-tcp-vision")' <<<"$links")"

jq -e '.[] | select(.name == "sample-tcp-xudp") | .packet_encoding == "xudp" and .flow == "xtls-rprx-vision"' \
  <<<"$links" >/dev/null || fail "tcp-xudp must carry packetEncoding=xudp"

jq -e '.[] | select(.name == "sample-tcp-mux") | .flow == "" and .clash == true' <<<"$links" >/dev/null \
  || fail "tcp-mux must map to plain tcp without flow"

jq -e '.[] | select(.name == "sample-grpc") | .network == "grpc" and .service == "svc-test"' <<<"$links" >/dev/null \
  || fail "grpc record must carry service name"

jq -e '.[] | select(.name == "sample-xhttp-legacy") |
  .xhttp == true and .clash == true and .singbox == false and .encryption == "none"' <<<"$links" >/dev/null \
  || fail "legacy xhttp: Clash — только по ?xhttp=1, sing-box не поддержан"

jq -e '.[] | select(.name == "sample-xhttp-pq") |
  .clash == false and .singbox == false and (.reason | test("post-quantum"))' <<<"$links" >/dev/null \
  || fail "PQ route must be skipped for both clients with a reason"

# reason — общая причина (в шапку Clash уходит как есть), поэтому xhttp-специфичная
# причина sing-box в неё не дописывается; иначе Clash-клиент видит чужую причину.
jq -e '.[] | select(.name == "sample-xhttp-pq") | (.reason | test("sing-box") | not)' <<<"$links" >/dev/null \
  || fail "reason PQ+xhttp не должен упоминать sing-box"
jq -e '.[] | select(.name == "sample-xhttp-legacy") | (.reason | test("sing-box") | not)' <<<"$links" >/dev/null \
  || fail "reason legacy xhttp не должен упоминать sing-box"

jq -e '.[] | select(.protocol == "hysteria2") |
  .auth == "sample:deadbeef" and .sni == "www.ozon.ru" and .insecure == true and
  .port == 8443 and .clash == true and .singbox == true' <<<"$links" >/dev/null \
  || fail "hysteria2 record wrong"

# IPv6 в скобках и percent-decoding имени
IFS='|' read -r _u h p _q f <<< "$(_url_split 'vless://id@[2001:db8::1]:443?type=tcp#n%20ame' vless)"
[[ "$h" == "2001:db8::1" && "$p" == "443" && "$f" == "n ame" ]] \
  || fail "IPv6/percent-decode broken: host=$h port=$p frag=$f"

# ═══════════ 2. Clash/mihomo YAML ═══════════
clash=$(_subscription_render_clash_pure "$PROFILES_DIR/sample.json" "$HY2_URI" false "sample") \
  || fail "clash render failed"

grep -q '^proxies:$' <<<"$clash" || fail "clash: нет секции proxies"
grep -q '    type: vless' <<<"$clash" || fail "clash: нет vless-прокси"
grep -q '    flow: xtls-rprx-vision' <<<"$clash" || fail "clash: нет flow Vision"
grep -q '    client-fingerprint: firefox' <<<"$clash" || fail "clash: нет client-fingerprint"
grep -q '    packet-encoding: xudp' <<<"$clash" || fail "clash: нет packet-encoding xudp"
grep -q '    network: grpc' <<<"$clash" || fail "clash: нет network grpc"
grep -q 'grpc-service-name: "svc-test"' <<<"$clash" || fail "clash: нет grpc-service-name"
grep -q 'public-key: "test-public-key"' <<<"$clash" || fail "clash: нет reality public-key"
grep -q 'short-id: "aa11"' <<<"$clash" || fail "clash: нет reality short-id"
grep -q '    type: hysteria2' <<<"$clash" || fail "clash: нет hysteria2"
grep -q 'password: "sample:deadbeef"' <<<"$clash" || fail "clash: auth-строка hysteria2 не целиком"
grep -q 'skip-cert-verify: true' <<<"$clash" || fail "clash: нет skip-cert-verify для self-signed"
grep -q 'xhttp: нужен ?xhttp=1' <<<"$clash" || fail "clash: legacy xhttp должен быть пропущен с пояснением"
grep -q 'post-quantum' <<<"$clash" || fail "clash: PQ должен быть пропущен с пояснением"
grep -q 'MATCH,PROXY' <<<"$clash" || fail "clash: нет финального правила"
grep -q 'xhttp-pq' <<<"$clash" || fail "clash: имя PQ-маршрута должно упоминаться в пропуске"
if grep -q '    type: xhttp' <<<"$clash"; then
  fail "clash: xhttp не должен попадать в конфиг без ?xhttp=1"
fi

if python3 -c 'import yaml' 2>/dev/null; then
  python3 - "$clash" <<'PY' || fail "clash YAML не парсится PyYAML"
import sys, yaml
doc = yaml.safe_load(sys.argv[1])
assert doc["mixed-port"] == 7890
assert any(p["type"] == "vless" for p in doc["proxies"]), "no vless proxy"
assert any(p["type"] == "hysteria2" for p in doc["proxies"]), "no hysteria2 proxy"
assert doc["proxy-groups"][0]["name"] == "PROXY"
assert doc["rules"][-1] == "MATCH,PROXY"
assert "AUTO" in doc["proxy-groups"][0]["proxies"]
PY
fi

# ?xhttp=1 — маршрут xhttp-legacy становится доступен для mihomo ≥ 1.19
clash_x=$(_subscription_render_clash_pure "$PROFILES_DIR/sample.json" "" true "sample") \
  || fail "clash render (xhttp) failed"
grep -q '    network: xhttp' <<<"$clash_x" || fail "clash ?xhttp=1: нет network xhttp"
grep -q '    xhttp-opts:' <<<"$clash_x" || fail "clash ?xhttp=1: нет xhttp-opts"
grep -q 'path: "/xhttp-test"' <<<"$clash_x" || fail "clash ?xhttp=1: path не decoded"
if grep -q 'post-quantum' <<<"$clash_x"; then :; else
  fail "clash ?xhttp=1: PQ-маршрут всё равно должен быть пропущен"
fi

# ═══════════ 3. sing-box JSON ═══════════
sb=$(_subscription_render_singbox_pure "$PROFILES_DIR/sample.json" "$HY2_URI" "sample") \
  || fail "sing-box render failed"

jq -e '.' <<<"$sb" >/dev/null || fail "sing-box: невалидный JSON"
jq -e '.inbounds[0].type == "mixed"' <<<"$sb" >/dev/null || fail "sing-box: нет mixed inbound"
jq -e '[.outbounds[] | select(.type == "vless")] | length == 5' <<<"$sb" >/dev/null \
  || fail "sing-box: ожидалось 5 vless-outbound (оба xhttp пропускаются)"
jq -e '[.outbounds[] | select(.type == "vless")] | all(.tls.reality.public_key == "test-public-key")' \
  <<<"$sb" >/dev/null || fail "sing-box: reality public_key"
jq -e '[.outbounds[] | select(.type == "vless" and .flow == "xtls-rprx-vision")] | length == 3' <<<"$sb" >/dev/null \
  || fail "sing-box: flow Vision ожидался у трёх маршрутов"
jq -e '[.outbounds[] | select(.type == "vless" and .packet_encoding == "xudp")] | length == 1' <<<"$sb" >/dev/null \
  || fail "sing-box: packet_encoding xudp"
jq -e '[.outbounds[] | select(.type == "vless" and .transport.type == "grpc" and .transport.service_name == "svc-test")] | length == 1' \
  <<<"$sb" >/dev/null || fail "sing-box: grpc transport"
jq -e '[.outbounds[] | select(.type == "vless")] | all(.tls.utls.fingerprint != null)' <<<"$sb" >/dev/null \
  || fail "sing-box: utls fingerprint"
jq -e '[.outbounds[] | select(.type == "hysteria2")] | .[0] |
  .password == "sample:deadbeef" and .tls.insecure == true and .tls.server_name == "www.ozon.ru" and .server_port == 8443' \
  <<<"$sb" >/dev/null || fail "sing-box: hysteria2 outbound"
jq -e '.outbounds[] | select(.type == "selector") | .tag == "proxy" and (.outbounds | index("auto")) != null' \
  <<<"$sb" >/dev/null || fail "sing-box: selector proxy"
jq -e '.outbounds[] | select(.type == "urltest") | .tag == "auto"' <<<"$sb" >/dev/null || fail "sing-box: urltest auto"
jq -e '.outbounds[] | select(.type == "direct") | .tag == "direct"' <<<"$sb" >/dev/null || fail "sing-box: direct"
jq -e '.route.final == "proxy" and (.route.rules | length) == 1 and .route.rules[0].ip_is_private == true' \
  <<<"$sb" >/dev/null || fail "sing-box: route"
jq -e '[.outbounds[] | select(.tag | test("xhttp"))] | length == 0' <<<"$sb" >/dev/null \
  || fail "sing-box: xhttp-маршруты не должны попадать в outbounds"

# ═══════════ 4. Edge cases ═══════════
# Профиль без живых маршрутов: рендер обязан упасть, а не отдать пустой конфиг.
jq '.routes = [] | .transport = "tcp" | .port = 10099 | .sni = "www.ozon.ru"' \
  "$PROFILES_DIR/sample.json" > "$PROFILES_DIR/dead.json"
if _subscription_render_clash_pure "$PROFILES_DIR/dead.json" "" false "dead" >/dev/null 2>&1; then
  fail "clash: профиль без живых маршрутов должен возвращать ошибку"
fi
if _subscription_render_singbox_pure "$PROFILES_DIR/dead.json" "" "dead" >/dev/null 2>&1; then
  fail "sing-box: профиль без живых маршрутов должен возвращать ошибку"
fi

# Только PQ-маршрут: YAML валиден, группа не пустая (DIRECT), PQ объяснён в комментарии.
jq -n '{name: "pqonly", uuid: "11111111-2222-3333-4444-555555555555",
        routes: [{label: "xhttp-pq", transport: "xhttp", port: 10007, sni: "www.ozon.ru",
                  fingerprint: "chrome", pq_enabled: true, xhttp_path: "/xhttp-pq"}]}' \
  > "$PROFILES_DIR/pqonly.json"
pq_clash=$(_subscription_render_clash_pure "$PROFILES_DIR/pqonly.json" "" false "pqonly") \
  || fail "clash: PQ-only профиль должен рендериться (без прокси)"
grep -q -- '- DIRECT' <<<"$pq_clash" || fail "clash: пустая группа должна получать DIRECT"
if grep -q 'type: vless' <<<"$pq_clash"; then
  fail "clash: PQ-маршрут не должен превращаться в прокси"
fi
# Причина пропуска в шапке Clash — общая для всех клиентов, поэтому причина
# sing-box в неё попадать не должна: на живом сервере PQ-маршрут помечался
# «VLESS Encryption (post-quantum)…; xhttp не поддержан sing-box», хотя xhttp
# в Clash поддержан (нужен только ?xhttp=1) и пользователь читал чужую причину.
grep -q 'post-quantum' <<<"$pq_clash" || fail "clash: PQ-маршрут должен попасть в skipped с причиной"
if grep '^# skipped:' <<<"$pq_clash" | grep -q 'sing-box'; then
  fail "clash: шапка skipped не должна содержать причину sing-box"
fi
if python3 -c 'import yaml' 2>/dev/null; then
  python3 - "$pq_clash" <<'PY' || fail "clash YAML (PQ-only) не парсится"
import sys, yaml
doc = yaml.safe_load(sys.argv[1])
assert doc["rules"][-1] == "MATCH,PROXY"
assert doc["proxy-groups"][0]["proxies"] == ["DIRECT"]
PY
fi

pq_sb=$(_subscription_render_singbox_pure "$PROFILES_DIR/pqonly.json" "" "pqonly") \
  || fail "sing-box: PQ-only профиль должен рендериться"
jq -e '[.outbounds[] | select(.type == "vless" or .type == "hysteria2")] | length == 0' <<<"$pq_sb" >/dev/null \
  || fail "sing-box: PQ-маршрут не должен попадать в outbounds"
jq -e '.outbounds[] | select(.type == "selector") | .default == "direct"' <<<"$pq_sb" >/dev/null \
  || fail "sing-box: без прокси selector должен указывать на direct"

# ═══════════ 5. Хендлер подписки: content negotiation ═══════════
SUBHTTP_TMP=$(mktemp /tmp/xrayebator-subfmt-handler.XXXXXX)
trap 'rm -f "$SUBHTTP_TMP"; rm -rf "$WORKDIR"' EXIT
awk '/cat > \/usr\/local\/bin\/subhttp\.sh << '\''SUBHTTP_EOF'\''/{flag=1; next} /^SUBHTTP_EOF$/{flag=0} flag' \
  xrayebator > "$SUBHTTP_TMP"
[[ -s "$SUBHTTP_TMP" ]] || fail "subhttp heredoc not found"
bash -n "$SUBHTTP_TMP" || fail "generated subhttp heredoc is not valid bash"

grep -q 'target=clash' "$SUBHTTP_TMP" || fail "хендлер не понимает ?target=clash"
grep -q 'target=singbox' "$SUBHTTP_TMP" || fail "хендлер не понимает ?target=singbox"
grep -q 'target=v2ray' "$SUBHTTP_TMP" || fail "хендлер не понимает ?target=v2ray"
grep -q '_subscription_render_clash_pure' "$SUBHTTP_TMP" || fail "хендлер не зовёт Clash-билдер"
grep -q '_subscription_render_singbox_pure' "$SUBHTTP_TMP" || fail "хендлер не зовёт sing-box билдер"
grep -q 'text/yaml; charset=utf-8' "$SUBHTTP_TMP" || fail "нет content-type для Clash"
grep -q 'application/json; charset=utf-8' "$SUBHTTP_TMP" || fail "нет content-type для sing-box"
grep -q 'xrayebator-${short_token}.yaml' "$SUBHTTP_TMP" || fail "нет имени файла .yaml"
grep -q 'xrayebator-${short_token}.json' "$SUBHTTP_TMP" || fail "нет имени файла .json"
grep -qE '^printf .subscription-userinfo' "$SUBHTTP_TMP" \
  || fail "subscription-userinfo должен отдаваться всем форматам (не только HAPP)"
grep -q '\*mihomo\*' "$SUBHTTP_TMP" || fail "нет UA-детекта mihomo"
grep -q '\*sing-box\*' "$SUBHTTP_TMP" || fail "нет UA-детекта sing-box"
grep -q '\*hiddify\*' "$SUBHTTP_TMP" || fail "нет UA-детекта hiddify"
# HAPP-метаданные остаются только у HAPP-тела.
grep -q 'if \[\[ "$sub_format" == "happ" \]\]' "$SUBHTTP_TMP" \
  || fail "HAPP-заголовки должны отдаваться только happ-формату"

# ═══════════ 6. Миграция и CLI-контракт ═══════════
grep -q '_migrate_subhttp_formats_2026' xrayebator || fail "нет функции миграции форматов"
formats_regs=$(grep -c 'run_migration "subhttp_formats_2026"' xrayebator || true)
[[ "$formats_regs" -ge 3 ]] || fail "subhttp_formats_2026 зарегистрирована ${formats_regs} раз (<3: main/quickstart/happ-setup)"

# ═══════════ 5b. Тело подписки: base64 для ?target=v2ray и PQ-xhttp в HAPP ═══════════
# Обе находки живого прогона 2026-10-20, обе видны только в реальном ответе:
#  - ветка base64 стояла под $universal_sub (флаг из User-Agent), поэтому явный
#    ?target=v2ray уходил в HAPP-ветку и отдавал plaintext со всеми маршрутами;
#  - HAPP-ветка выбрасывала любой xhttp без encryption=none, если был legacy xhttp,
#    и теряла рабочий xhttp-pq (7 ссылок в теле против 8 рабочих маршрутов).
grep -Fq 'elif [[ "$sub_format" == "v2ray" ]]' "$SUBHTTP_TMP" \
  || fail "тело base64 должно выбираться по sub_format, а не по UA-флагу universal_sub"
if grep -Fq 'has_legacy_xhttp' "$SUBHTTP_TMP"; then
  fail "хендлер снова выбрасывает xhttp-маршруты, если в профиле есть legacy xhttp (теряется xhttp-pq)"
fi

# Функционально: prepare_happ_vless_urls обязан вернуть ОБА xhttp-маршрута и mode=auto.
HAPP_FN_TMP=$(mktemp /tmp/xrayebator-happfn.XXXXXX)
awk '/^prepare_happ_vless_urls\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' "$SUBHTTP_TMP" > "$HAPP_FN_TMP"
[[ -s "$HAPP_FN_TMP" ]] || fail "prepare_happ_vless_urls не извлечена из хендлера"
# shellcheck disable=SC1090
source "$HAPP_FN_TMP"
rm -f "$HAPP_FN_TMP"
happ_out=$(printf '%s\n' \
  'vless://u@203.0.113.10:10006?encryption=none&security=reality&type=xhttp&path=%2Fxhttp-test#s-xhttp-legacy' \
  'vless://u@203.0.113.10:10007?encryption=mlkem768x25519plus.native.test&security=reality&type=xhttp&path=%2Fxhttp-pq#s-xhttp-pq' \
  | prepare_happ_vless_urls)
[[ "$(grep -c 'vless://' <<<"$happ_out")" -eq 2 ]] \
  || fail "HAPP-тело обязано сохранять оба xhttp-маршрута, получено: $(grep -c 'vless://' <<<"$happ_out")"
grep -q 's-xhttp-pq' <<<"$happ_out" || fail "HAPP-тело потеряло PQ-маршрут на xhttp"
[[ "$(grep -c 'mode=auto' <<<"$happ_out")" -eq 2 ]] || fail "оба xhttp-маршрута обязаны получить mode=auto"
# ...и не потеряло ничего из других транспортов.
happ_out2=$(printf '%s\n' \
  'vless://u@ip:1?encryption=none&type=tcp&headerType=none#s-tcp-vision' \
  'vless://u@ip:2?encryption=mlkem768x25519plus.native.test&type=tcp&headerType=none#s-tcp-pq' \
  'vless://u@ip:3?encryption=none&type=grpc&serviceName=g&mode=gun#s-grpc' | prepare_happ_vless_urls)
[[ "$(grep -c 'vless://' <<<"$happ_out2")" -eq 3 ]] || fail "HAPP-тело потеряло tcp/grpc-маршруты"

# Миграция, которая доводит правку до существующих серверов (обработчик — heredoc).
grep -q '_migrate_subhttp_v2ray_pq_2026' xrayebator || fail "нет функции миграции subhttp_v2ray_pq_2026"
v2ray_regs=$(grep -c 'run_migration "subhttp_v2ray_pq_2026"' xrayebator || true)
[[ "$v2ray_regs" -ge 3 ]] || fail "subhttp_v2ray_pq_2026 зарегистрирована ${v2ray_regs} раз (<3: main/quickstart/happ-setup)"

jq '. + {sub_token: "abcdef0123456789abcdef0123456789"}' "$PROFILES_DIR/sample.json" \
  > "$PROFILES_DIR/sample.json.tmp" && mv "$PROFILES_DIR/sample.json.tmp" "$PROFILES_DIR/sample.json"
profiles_json=$(
  _profile_cli_subscription_url() { return 0; }
  _subscription_base_url() { printf 'https://sub.example.com'; }
  profiles_command 2>/dev/null
) || fail "profiles_command failed"
jq -e '.[] | select(.name == "sample") |
  .subscription_url == "https://sub.example.com/sub/abcdef0123456789abcdef0123456789" and
  (.subscription_url_clash | endswith("?target=clash")) and
  (.subscription_url_singbox | endswith("?target=singbox"))' <<<"$profiles_json" >/dev/null \
  || fail "profiles: форматные URL не отдаются в JSON"

echo "✓ Subscription formats: Clash/mihomo YAML + sing-box JSON (links, reality, flow, xudp, grpc, hysteria2, skip PQ/xhttp, handler negotiation, migration, CLI) — OK"
