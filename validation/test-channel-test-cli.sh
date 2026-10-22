#!/bin/bash
# test-channel-test-cli.sh
# Проверяет `xrayebator channel-test` — проверку каналов настоящим клиентом Xray:
#   - чистая часть: клиентский конфиг из записи ссылки (Reality/TLS, flow,
#     grpc serviceName, xhttp path/host/mode, ML-KEM encryption для PQ);
#   - контракт CLI: диспатч, JSON только на stdout (прогресс через exec 3>&1),
#     независимость от Let's Encrypt и от маркеров подписки;
#   - сам сетевой прогон в CI не запускается (нужен живой Xray и интернет):
#     живая матрица 7/7 маршрутов проверена на VPS вручную.
#
# Usage: bash validation/test-channel-test-cli.sh   (нужны jq, bash 4+)

set -euo pipefail

fail() {
  echo "✗ $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORKDIR=$(mktemp -d /tmp/xrayebator-chan.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/xrayebator"

# ─── 1. CLI зарегистрирован ───
grep -q '^    channel-test)' xrayebator || fail "channel-test не зарегистрирован в диспатче"
grep -q 'channel_test_command "\$@"' xrayebator || fail "channel-test не вызывает channel_test_command"
grep -q 'channel_test_command()' xrayebator || fail "нет функции channel_test_command"
grep -q 'sudo xrayebator channel-test' xrayebator || fail "channel-test не описан в помощи"
grep -q '_channel_client_config_pure()' xrayebator || fail "нет чистой функции сборки клиентского конфига"

# ─── 2. Клиентский конфиг: Reality + Vision + flow ───
tcp_record='{"protocol":"vless","name":"tcp-vision","server":"203.0.113.10","port":30690,
 "uuid":"11111111-2222-3333-4444-555555555555","network":"tcp","security":"reality",
 "sni":"www.cloudflare.com","fp":"firefox","pbk":"PUBKEY","sid":"aa11","flow":"xtls-rprx-vision",
 "path":"","host":"","service":"","mode":"","packet_encoding":"","encryption":"none"}'
cfg=$(_channel_client_config_pure "$tcp_record" 12080) || fail "конфиг для tcp не собрался"
jq -e '.inbounds[0].port == 12080 and .inbounds[0].protocol == "socks"' <<<"$cfg" >/dev/null \
  || fail "нет SOCKS-инбаунда на заданном порту"
jq -e '.outbounds[0].protocol == "vless" and .outbounds[0].settings.vnext[0].address == "203.0.113.10"
  and .outbounds[0].settings.vnext[0].port == 30690' <<<"$cfg" >/dev/null \
  || fail "неверный vless-выход"
jq -e '.outbounds[0].settings.vnext[0].users[0].id == "11111111-2222-3333-4444-555555555555"
  and .outbounds[0].settings.vnext[0].users[0].flow == "xtls-rprx-vision"
  and .outbounds[0].settings.vnext[0].users[0].encryption == "none"' <<<"$cfg" >/dev/null \
  || fail "неверный user (id/flow/encryption)"
jq -e '.outbounds[0].streamSettings.network == "tcp"
  and .outbounds[0].streamSettings.security == "reality"
  and .outbounds[0].streamSettings.realitySettings.serverName == "www.cloudflare.com"
  and .outbounds[0].streamSettings.realitySettings.fingerprint == "firefox"
  and .outbounds[0].streamSettings.realitySettings.publicKey == "PUBKEY"
  and .outbounds[0].streamSettings.realitySettings.shortId == "aa11"' <<<"$cfg" >/dev/null \
  || fail "неверные reality-настройки"

# ─── 3. grpc: serviceName; xhttp: path/host/mode ───
grpc_record='{"protocol":"vless","name":"grpc","server":"203.0.113.10","port":31626,
 "uuid":"11111111-2222-3333-4444-555555555555","network":"grpc","security":"reality",
 "sni":"www.cloudflare.com","fp":"chrome","pbk":"PUBKEY","sid":"bb22","flow":"",
 "path":"","host":"","service":"grpc-abcd1234","mode":"","packet_encoding":"","encryption":"none"}'
cfg=$(_channel_client_config_pure "$grpc_record" 12081) || fail "конфиг для grpc не собрался"
jq -e '.outbounds[0].streamSettings.network == "grpc"
  and .outbounds[0].streamSettings.grpcSettings.serviceName == "grpc-abcd1234"
  and (.outbounds[0].settings.vnext[0].users[0] | has("flow") | not)' <<<"$cfg" >/dev/null \
  || fail "grpc: неверный serviceName или лишний flow"

xhttp_record='{"protocol":"vless","name":"xhttp-legacy","server":"203.0.113.10","port":30024,
 "uuid":"11111111-2222-3333-4444-555555555555","network":"xhttp","security":"reality",
 "sni":"www.cloudflare.com","fp":"chrome","pbk":"PUBKEY","sid":"cc33","flow":"",
 "path":"/xhttp-2051c064","host":"www.cloudflare.com","service":"","mode":"auto",
 "packet_encoding":"","encryption":"none"}'
cfg=$(_channel_client_config_pure "$xhttp_record" 12082) || fail "конфиг для xhttp не собрался"
jq -e '.outbounds[0].streamSettings.network == "xhttp"
  and .outbounds[0].streamSettings.xhttpSettings.path == "/xhttp-2051c064"
  and .outbounds[0].streamSettings.xhttpSettings.host == "www.cloudflare.com"
  and .outbounds[0].streamSettings.xhttpSettings.mode == "auto"' <<<"$cfg" >/dev/null \
  || fail "xhttp: неверные path/host/mode"

# ─── 4. PQ-маршрут: ML-KEM encryption доезжает до клиента ───
pq_record='{"protocol":"vless","name":"tcp-pq","server":"203.0.113.10","port":32082,
 "uuid":"11111111-2222-3333-4444-555555555555","network":"tcp","security":"reality",
 "sni":"www.cloudflare.com","fp":"chrome","pbk":"PUBKEY","sid":"dd44","flow":"xtls-rprx-vision",
 "path":"","host":"","service":"","mode":"","packet_encoding":"",
 "encryption":"mlkem768x25519plus.native.600s.AAAA"}'
cfg=$(_channel_client_config_pure "$pq_record" 12083) || fail "конфиг для PQ не собрался"
jq -e '.outbounds[0].settings.vnext[0].users[0].encryption == "mlkem768x25519plus.native.600s.AAAA"' \
  <<<"$cfg" >/dev/null || fail "PQ: encryption не передан клиенту"

# ─── 5. Пустая запись (нет данных ссылки) не роняет сборку ───
cfg=$(_channel_client_config_pure '{"server":"h","port":1,"uuid":"u","network":"tcp","security":"none","sni":"","fp":"","pbk":"","sid":"","flow":"","path":"","host":"","service":"","mode":"","packet_encoding":"","encryption":""}' 12084) \
  || fail "конфиг для записи без Reality не собрался"
jq -e '.outbounds[0].settings.vnext[0].users[0].encryption == "none"
  and (.outbounds[0].streamSettings | has("realitySettings") | not)' <<<"$cfg" >/dev/null \
  || fail "без Reality не должно быть realitySettings, encryption по умолчанию none"

# ─── 6. JSON-гигиена и независимость от LE/маркеров ───
block=$(awk '/^channel_test_command\(\) \{/,/^\}/' xrayebator)
grep -q 'exec 3>&1' <<<"$block" || fail "channel-test не уводит прогресс в stderr (exec 3>&1)"
grep -q '_subscription_links_json' <<<"$block" || fail "channel-test должен брать маршруты из ссылок профиля"
if grep -qE 'subscription_mode|\.subscription_|letsencrypt|certbot' <<<"$block"; then
  fail "channel-test не должен зависеть от Let's Encrypt или маркеров подписки"
fi
grep -q 'XRAY_BIN' <<<"$block" || fail "channel-test должен брать бинарник Xray из XRAY_BIN"
# SOCKS-запрос живёт в хелпере замера — проверяем и сам хелпер, и вызов из команды.
grep -q '_channel_probe()' xrayebator || fail "нет хелпера замера _channel_probe"
grep -q -- '--socks5-hostname' xrayebator || fail "channel-test должен ходить через SOCKS клиента"
grep -q '_channel_probe "\$socks"' <<<"$block" || fail "channel-test не вызывает _channel_probe"

# fd 3 принадлежит channel_test_command (exec 3>&1 … exec 1>&3): ни один хелпер не
# смеет его закрывать. Живой баг: _channel_wait_socks делала `exec 3>&-` в основном
# шелле, последующий `exec 1>&3` не срабатывал, и итоговый JSON уезжал в stderr.
helpers=$(awk '/^# ─+ channel-test/,/^channel_test_command\(\) \{/' xrayebator)
[[ -n "$helpers" ]] || fail "не найден блок хелперов channel-test"
# Комментарии не код: в них эта история описана словами.
if grep -vE '^[[:space:]]*#' <<<"$helpers" | grep -qE 'exec 3[<>]'; then
  fail "хелперы channel-test трогают fd 3 — итоговый JSON уйдёт в stderr"
fi

echo "✓ channel-test: клиентский конфиг (Reality/flow/grpc/xhttp/PQ), диспатч, JSON-гигиена, независимость от LE — OK"
