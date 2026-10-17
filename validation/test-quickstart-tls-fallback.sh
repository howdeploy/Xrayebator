#!/bin/bash
# Regression test: graceful-degradation quickstart при блокировке http-01.
# Root cause (живой VPS 150.241.65.101, 2026-10-08): Let's Encrypt validation
# получает "Connection reset by peer" на http://IP/.well-known/acme-challenge/ —
# порт 80 фильтруется UPSTREAM хостера (RST инжектится до нашего стека; ufw
# открыт, nginx отвечает 200 тем, чьи SYN доходят). Раньше quickstart на этом
# падал с ok:false и сервер оставался полусобранным. Теперь:
#  1) certbot fail + нет действующего серта → fallback SUB_TLS_MODE=http_tls;
#  2) vhost становится HTTP-only (ACME-challenge на :80 сохраняется);
#  3) маркеры пишутся в режиме http_tls (URL http://IP:8080/sub/<token>);
#  4) renew-таймер НЕ ставится (в http_tls нет серта — certbot renew падал бы);
#  5) итоговый JSON несёт degraded:true, tls_mode, certbot_reason;
#  6) ip_tls-путь не изменён (degraded отсутствует, таймер ставится).
# Статический уровень (по паттерну test-quickstart-email-and-inspect.sh): блок
# quickstart_command проверяется на структуру fallback-ветки.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "✗ FAIL: $*" >&2
  exit 1
}

# CRLF-safe извлечение блока quickstart_command
quickstart_block=$(tr -d '\r' < xrayebator | sed -n '/^quickstart_command() {$/,/^happ_setup_command() {$/p')
[[ -n "$quickstart_block" ]] || fail "quickstart_command block not found"

# 1) Fallback-переменная и обе ветки существуют
grep -q 'local SUB_TLS_MODE="ip_tls"' <<< "$quickstart_block" \
  || fail "SUB_TLS_MODE не инициализирован в ip_tls"
grep -q 'SUB_TLS_MODE="http_tls"' <<< "$quickstart_block" \
  || fail "certbot-fallback не переключает SUB_TLS_MODE в http_tls"
grep -q 'SUB_TLS_MODE="ip_tls"' <<< "$quickstart_block" \
  || fail "успешный certbot не возвращает SUB_TLS_MODE в ip_tls"

# 2) Self-signed fallback: ключ+серт создаются в /etc/letsencrypt/selfsigned/<ip>
grep -q '/etc/letsencrypt/selfsigned/${server_ip}/privkey.pem' <<< "$quickstart_block" \
  || fail "self-signed fallback: privkey не создаётся"
grep -q '/etc/letsencrypt/selfsigned/${server_ip}/fullchain.pem' <<< "$quickstart_block" \
  || fail "self-signed fallback: fullchain не создаётся"

# 3) HTTP-only vhost для http_tls (ACME-challenge сохранён для апгрейда)
grep -q 'NGINXHTTPSUB' <<< "$quickstart_block" \
  || fail "http_tls-ветка nginx-конфига отсутствует"
http_vhost=$(sed -n '/cat > "\$NGINX_SITES_AVAILABLE\/xrayebator-sub" << NGINXHTTPSUB/,/^NGINXHTTPSUB$/p' <<< "$quickstart_block")
[[ -n "$http_vhost" ]] || fail "NGINXHTTPSUB heredoc не найден"
grep -q 'location ^~ /.well-known/acme-challenge/' <<< "$http_vhost" \
  || fail "http_tls vhost потерял ACME-challenge location"
if grep -q 'ssl_certificate' <<< "$http_vhost"; then
  fail "http_tls vhost не должен слушать ssl"
fi
if grep -q 'proxy_pass' <<< "$http_vhost"; then
  fail "http_tls vhost не должен проксировать: handler 8080 открыт напрямую"
fi

# 4) Маркеры пишутся с переменной режима (не хардкод "ip_tls")
grep -q '_subscription_write_markers "8443" "$server_ip" "$server_ip" "$SUB_TLS_MODE"' <<< "$quickstart_block" \
  || fail "маркеры должны писаться с \$SUB_TLS_MODE"

# 5) Renew-таймер только в ip_tls
if grep -q 'if \[\[ "$SUB_TLS_MODE" == "ip_tls" \]\]; then' <<< "$quickstart_block"; then
  timer_guard=$(grep -A1 'if \[\[ "$SUB_TLS_MODE" == "ip_tls" \]\]; then' <<< "$quickstart_block" | grep '_install_ip_cert_renew_timer' || true)
  [[ -n "$timer_guard" ]] || fail "renew-таймер не под guard'ом ip_tls"
else
  fail "guard ip_tls для renew-таймера отсутствует"
fi

# 6) Итоговый JSON несёт degraded-метаданные
grep -q 'degraded:true' <<< "$quickstart_block" \
  || fail "http_tls-итог не содержит degraded:true"
grep -q 'tls_mode:"http_tls"' <<< "$quickstart_block" \
  || fail "http_tls-итог не содержит tls_mode"
grep -q 'certbot_reason' <<< "$quickstart_block" \
  || fail "http_tls-итог не передаёт certbot_reason"
# ip_tls-итог (финальный echo) не должен содержать degraded — degraded живёт
# только в jq-ветке http_tls; финальный echo — предпоследняя строка блока.
ip_tls_result=$(printf '%s' "$quickstart_block" | grep -F 'echo "{\"' | tail -1)
[[ -n "$ip_tls_result" ]] || fail "ip_tls-итоговый echo не найден"
if grep -q 'degraded' <<< "$ip_tls_result"; then
  fail "ip_tls-итог не должен содержать degraded"
fi

echo "✓ quickstart graceful-degradation (http_tls fallback) guards ok"
