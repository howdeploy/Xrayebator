#!/bin/bash
# test-dns01-certbot.sh
# Проверяет DNS-01-путь (Cloudflare/Route53): сертификат и HTTPS-подписка по домену
# БЕЗ порта 80 — то, что снимает http_tls-деградацию у хостеров, фильтрующих :80.
#   - pure-часть тестируется функционально: валидация домена/провайдера, сборка
#     аргументов certbot, запись credentials (0600), nginx-vhost без listen 80;
#   - CLI-валидация — герметично: до системных вызовов команда обязана вернуть
#     {"ok":false} и ничего не записать;
#   - серверная проводка (меню, диспатчер, firewall, маркеры, plugin-пакеты,
#     cleanup в uninstall) — статически, потому что живые DNS-API и certbot в CI
#     недоступны.
#
# Usage:  bash validation/test-dns01-certbot.sh
# Requires: jq, bash 4+.

set -euo pipefail

fail() {
  echo "✗ $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORKDIR=$(mktemp -d /tmp/xrayebator-dns01.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/xrayebator"

# Изоляция: ни один тест не должен трогать /etc/letsencrypt и маркеры сервера.
DNS01_CREDS_DIR="$WORKDIR/creds"
mkdir -p "$DNS01_CREDS_DIR"
DNS01_CLOUDFLARE_INI="$DNS01_CREDS_DIR/cloudflare.ini"
DNS01_AWS_INI="$DNS01_CREDS_DIR/aws.ini"
DNS01_MARKER_FILE="$WORKDIR/provider"
CF_TOKEN="abcdefghijklmnopqrstuvwxyz0123456789"

assert_json() {
  local json="$1" expr="$2" msg="$3"
  jq -e "$expr" <<< "$json" >/dev/null || fail "$msg: $json"
}

# ═══════════ 1. Валидация домена и провайдера ═══════════
for good in sub.example.com example.com a.b.c.example.org my-host.example.com; do
  _dns01_validate_domain "$good" || fail "домен должен быть валиден: $good"
done
for bad in "" "localhost" "1.2.3.4" "203.0.113.10" "-bad.example.com" "bad-.example.com" "bad..example.com" "exa mple.com"; do
  if _dns01_validate_domain "$bad"; then
    fail "домен должен быть отклонён: '$bad'"
  fi
done

_dns01_provider_supported cloudflare || fail "cloudflare должен поддерживаться"
_dns01_provider_supported route53 || fail "route53 должен поддерживаться"
if _dns01_provider_supported digitalocean; then
  fail "неподдержанный провайдер не должен проходить"
fi

# ═══════════ 2. Аргументы certbot ═══════════
cf_args=$(_dns01_certbot_args_pure cloudflare sub.example.com ops@example.com "$DNS01_CLOUDFLARE_INI") \
  || fail "сборка аргументов cloudflare"
grep -qx -- "certonly" <<<"$cf_args" || fail "certonly отсутствует"
grep -qx -- "--cert-name" <<<"$cf_args" || fail "--cert-name отсутствует"
grep -qx -- "sub.example.com" <<<"$cf_args" || fail "домен отсутствует в аргументах"
grep -qx -- "--dns-cloudflare" <<<"$cf_args" || fail "--dns-cloudflare отсутствует"
grep -qx -- "--dns-cloudflare-credentials" <<<"$cf_args" || fail "credentials-флаг отсутствует"
grep -qx -- "$DNS01_CLOUDFLARE_INI" <<<"$cf_args" || fail "путь credentials отсутствует"
grep -qx -- "--dns-cloudflare-propagation-seconds" <<<"$cf_args" || fail "propagation-seconds отсутствует"
grep -qx -- "30" <<<"$cf_args" || fail "значение propagation-seconds"
grep -qx -- "systemctl reload nginx" <<<"$cf_args" || fail "deploy-hook отсутствует"
grep -qx -- "-m" <<<"$cf_args" || fail "-m отсутствует при заданном email"
grep -qx -- "ops@example.com" <<<"$cf_args" || fail "email отсутствует"
if grep -qx -- "--register-unsafely-without-email" <<<"$cf_args"; then
  fail "при заданном email не должно быть регистрации без email"
fi

no_mail_args=$(_dns01_certbot_args_pure cloudflare sub.example.com "" "$DNS01_CLOUDFLARE_INI") \
  || fail "сборка аргументов cloudflare без email"
grep -qx -- "--register-unsafely-without-email" <<<"$no_mail_args" \
  || fail "без email нужна явная регистрация без уведомлений"
if grep -qx -- "-m" <<<"$no_mail_args"; then
  fail "без email не должно быть -m"
fi

r53_args=$(_dns01_certbot_args_pure route53 vpn.example.com "" "$DNS01_AWS_INI") \
  || fail "сборка аргументов route53"
grep -qx -- "--dns-route53" <<<"$r53_args" || fail "route53-флаг отсутствует"
if grep -q -- "cloudflare" <<<"$r53_args"; then
  fail "route53-аргументы не должны содержать cloudflare-флагов"
fi

if _dns01_certbot_args_pure digitalocean sub.example.com "" "$DNS01_CREDS_DIR/x.ini" >/dev/null 2>&1; then
  fail "неподдержанный провайдер должен возвращать ошибку"
fi

# ═══════════ 3. Credentials-файл ═══════════
_dns01_credentials_write cloudflare "$DNS01_CLOUDFLARE_INI" "$CF_TOKEN" || fail "запись cloudflare-credentials"
[[ -f "$DNS01_CLOUDFLARE_INI" ]] || fail "cloudflare ini не создан"
[[ "$(stat -c '%a' "$DNS01_CLOUDFLARE_INI")" == "600" ]] || fail "cloudflare ini должен быть 0600"
grep -qx -- "dns_cloudflare_api_token = $CF_TOKEN" "$DNS01_CLOUDFLARE_INI" \
  || fail "в cloudflare ini нет api-token"

_dns01_credentials_write route53 "$DNS01_AWS_INI" "" AKIAEXAMPLE SECRETEXAMPLE || fail "запись aws-credentials"
[[ "$(stat -c '%a' "$DNS01_AWS_INI")" == "600" ]] || fail "aws ini должен быть 0600"
grep -qxF -- "[default]" "$DNS01_AWS_INI" || fail "в aws ini нет профиля default"
grep -qx -- "aws_access_key_id = AKIAEXAMPLE" "$DNS01_AWS_INI" || fail "в aws ini нет access key"
grep -qx -- "aws_secret_access_key = SECRETEXAMPLE" "$DNS01_AWS_INI" || fail "в aws ini нет secret key"

# Пустые креды и неизвестный провайдер — ошибка, файл не создаётся.
EMPTY_INI="$DNS01_CREDS_DIR/empty.ini"
if _dns01_credentials_write cloudflare "$EMPTY_INI" ""; then
  fail "пустой cloudflare-token должен отклоняться"
fi
if _dns01_credentials_write route53 "$EMPTY_INI" "" "" ""; then
  fail "пустые AWS-ключи должны отклоняться"
fi
if _dns01_credentials_write digitalocean "$EMPTY_INI" "x"; then
  fail "неизвестный провайдер должен отклоняться"
fi
[[ ! -f "$EMPTY_INI" ]] || fail "при ошибке credentials-файл создаваться не должен"

# ═══════════ 4. nginx-vhost: без порта 80 ═══════════
vhost=$(_dns01_nginx_vhost_pure sub.example.com 8443 "/etc/letsencrypt/live/sub.example.com") \
  || fail "рендер vhost"
grep -q -- "listen 8443 ssl http2;" <<<"$vhost" || fail "в vhost нет TLS-порта"
grep -q -- "server_name sub.example.com;" <<<"$vhost" || fail "в vhost нет server_name"
grep -q -- "ssl_certificate /etc/letsencrypt/live/sub.example.com/fullchain.pem;" <<<"$vhost" \
  || fail "в vhost нет пути сертификата"
grep -q -- "proxy_pass http://127.0.0.1:8080;" <<<"$vhost" || fail "в vhost нет proxy на handler"
grep -q -- "proxy_buffer_size 32k;" <<<"$vhost" || fail "в vhost нет увеличенных буферов"
grep -q -- "location /sub/" <<<"$vhost" || fail "в vhost нет location /sub/"
if grep -q -- "listen 80" <<<"$vhost"; then
  fail "DNS-01-vhost не должен слушать 80: в этом весь смысл режима"
fi
if grep -q -- "acme-challenge" <<<"$vhost"; then
  fail "DNS-01-vhost не должен содержать ACME-location"
fi
[[ "$(grep -c '^server {' <<<"$vhost")" == "1" ]] || fail "vhost должен содержать ровно один server-блок"

# ═══════════ 5. CLI: валидация до системных вызовов ═══════════
out=$(dns01_setup_command --domain 203.0.113.10 --provider cloudflare --token "$CF_TOKEN" --without-email) || true
assert_json "$out" '.ok == false and (.error | test("--domain"))' "IP вместо домена отвергается"

out=$(dns01_setup_command --domain sub.example.com --provider digitalocean --token "$CF_TOKEN" --without-email) || true
assert_json "$out" '.ok == false and (.error | test("cloudflare"))' "неизвестный провайдер отвергается"

out=$(dns01_setup_command --domain sub.example.com --provider cloudflare --token "$CF_TOKEN") || true
assert_json "$out" '.ok == false and (.error | test("--email"))' "без email и без --without-email — ошибка"

out=$(dns01_setup_command --domain sub.example.com --provider cloudflare --without-email) || true
assert_json "$out" '.ok == false and (.error | test("--token"))' "cloudflare без токена — ошибка"

out=$(dns01_setup_command --domain sub.example.com --provider route53 --without-email) || true
assert_json "$out" '.ok == false and (.error | test("aws"))' "route53 без AWS-ключей — ошибка"

out=$(dns01_setup_command --domain sub.example.com --provider cloudflare --token "$CF_TOKEN" --without-email --port 70000) || true
assert_json "$out" '.ok == false and (.error | test("--port"))' "некорректный порт — ошибка"

# Ни один неуспешный вызов не должен создать credentials/маркер.
[[ ! -f "$DNS01_MARKER_FILE" ]] || fail "маркер провайдера не должен появляться при ошибках валидации"

out=$(dns01_status_command) || true
assert_json "$out" '.ok == true and .provider == "" and .domain == "" and .days_left == 0 and .deploy_hook == false' \
  "dns01-status на ненастроенном сервере"

# ═══════════ 6. Проводка (статически: живые DNS-API в CI недоступны) ═══════════
grep -qE '^\s+dns01-setup\)' xrayebator || fail "нет диспатчера dns01-setup"
grep -qE '^\s+dns01-status\)' xrayebator || fail "нет диспатчера dns01-status"
grep -q '8) install_subscription_dns01 ;;' xrayebator || fail "нет пункта меню 8 в меню подписки"
grep -q 'Подписка по домену через DNS-01' xrayebator || fail "нет строки меню DNS-01"
grep -q 'python3-certbot-dns-cloudflare' xrayebator || fail "нет пакета cloudflare-плагина"
grep -q 'python3-certbot-dns-route53' xrayebator || fail "нет пакета route53-плагина"
grep -q 'limit_firewall_port "$port" tcp' xrayebator || fail "DNS-01 не открывает TLS-порт"
grep -q '_subscription_write_markers "$port" "$domain" "$server_ip" "domain_tls"' xrayebator \
  || fail "DNS-01 не пишет маркеры доменного режима"
grep -q '_certbot_register "$domain"' xrayebator || fail "cert не попадает в manifest (uninstall не удалит)"
grep -q 'AWS_SHARED_CREDENTIALS_FILE' xrayebator || fail "route53 не передаёт профиль AWS в certbot"
grep -q 'xrayebator-dns01-cloudflare.ini' uninstall.sh || fail "uninstall не удаляет cloudflare-credentials"
grep -q 'xrayebator-dns01-aws.ini' uninstall.sh || fail "uninstall не удаляет AWS-credentials"
grep -q 'dns01-setup --domain sub.example.com' xrayebator || fail "нет help-строки dns01-setup"

# ═══════════ 7. repair-dns01: замена http_tls-подписки на DNS-01 (A3) ═══════════
grep -q '^repair_dns01_command() {' xrayebator || fail "нет функции repair_dns01_command"
grep -q 'repair-dns01)' xrayebator || fail "нет диспатчера repair-dns01"
grep -q 'Подписка уже на HTTPS' xrayebator || fail "repair-dns01 без no-op для ip_tls/domain_tls"
grep -q 'подписка осталась в http_tls' xrayebator || fail "repair-dns01 без честной ошибки при неудаче"
grep -q '_dns01_install "$domain" "$provider" "$email" "$token" "$aws_key" "$aws_secret" "$port"' xrayebator \
  || fail "repair-dns01 не вызывает _dns01_install с полным набором аргументов"

# Функционально: валидация срабатывает ДО системных вызовов и ничего не пишет.
out=$(repair_dns01_command --domain 203.0.113.10 --provider cloudflare --token "$CF_TOKEN") || true
assert_json "$out" '.ok == false and (.error | test("--domain"))' "repair-dns01: IP вместо домена"
out=$(repair_dns01_command --domain sub.example.com --provider digitalocean --token "$CF_TOKEN") || true
assert_json "$out" '.ok == false and (.error | test("cloudflare"))' "repair-dns01: неизвестный провайдер"
out=$(repair_dns01_command --domain sub.example.com --provider cloudflare --token "short") || true
assert_json "$out" '.ok == false and (.error | test("--token"))' "repair-dns01: короткий токен"
out=$(repair_dns01_command --domain sub.example.com --provider route53) || true
assert_json "$out" '.ok == false and (.error | test("aws"))' "repair-dns01: route53 без ключей"
[[ ! -f "$DNS01_MARKER_FILE" ]] || fail "repair-dns01 не должен писать маркер при ошибках валидации"

# A2/A4: quickstart умеет выбирать PQ при развёртывании (флаг парсится и влияет на профиль)
grep -q -- '--pq) deploy_pq=true' xrayebator || fail "quickstart не парсит --pq"
grep -q -- '--without-pq) deploy_pq=false' xrayebator || fail "quickstart не парсит --without-pq"
grep -q 'if \[\[ "$deploy_pq" == "true" \]\]' xrayebator || fail "quickstart не использует deploy_pq"
grep -q '_pq_add_route_for_profile "$PROFILES_DIR/$HAPP_DEFAULT_PROFILE.json" tcp' xrayebator \
  || fail "quickstart --pq не добавляет PQ-маршрут managed-профилю"

# Регрессия: PQ-блок обязан стоять ПОСЛЕ создания HAPP-профиля. Одно время он был
# вложен в ветку провала _happ_ensure_default_multiroute_profile — маршрут добавлялся
# к несуществующему профилю, а деплой всё равно заканчивался return 1, то есть --pq
# был мёртвым кодом (и никто бы этого не заметил без проверки порядка строк).
qs_start=$(grep -n '^quickstart_command() {' xrayebator | cut -d: -f1)
resume_line=$(grep -n 'if ! _happ_ensure_default_multiroute_profile >/dev/null 2>&1; then' xrayebator | head -1 | cut -d: -f1)
profile_line=$(grep -n 'local profile_file="\$PROFILES_DIR/\${HAPP_DEFAULT_PROFILE}.json"' xrayebator | head -1 | cut -d: -f1)
pq_line=$(grep -n 'if \[\[ "$deploy_pq" == "true" \]\]' xrayebator | head -1 | cut -d: -f1)
[[ -n "$resume_line" && -n "$profile_line" && -n "$pq_line" ]] || fail "не найдены якоря порядка строк в quickstart"
(( resume_line > qs_start )) || fail "якорь HAPP-профиля вне quickstart_command"
(( profile_line > resume_line )) || fail "профиль создаётся не в ожидаемом порядке"
(( pq_line > profile_line )) || fail "PQ-блок стоит до создания профиля — --pq снова мёртвый код"

# B1: DNS-01 как фолбэк развёртывания — флаги парсятся и валидируются ДО системных вызовов.
grep -q -- '--dns01-domain) dns01_domain=' xrayebator || fail "quickstart не парсит --dns01-domain"
grep -q -- '--dns01-provider) dns01_provider=' xrayebator || fail "quickstart не парсит --dns01-provider"
grep -q -- '--dns01-token) dns01_token=' xrayebator || fail "quickstart не парсит --dns01-token"
grep -q 'dns01_requested=true' xrayebator || fail "quickstart не различает «DNS-01 запрошен»"
grep -q '"error":"DNS-01: укажите --dns01-domain' xrayebator || fail "quickstart не валидирует DNS-01-домен"
grep -q '_dns01_install "$dns01_domain" "$dns01_provider" "$email" "$dns01_token"' xrayebator \
  || fail "quickstart не вызывает _dns01_install в фолбэке"
grep -q 'SUB_TLS_MODE="domain_tls"' xrayebator || fail "quickstart не переключается в domain_tls"

# Порядок в фолбэке: DNS-01 пробуется ДО деградации в http_tls (иначе он бесполезен).
dns01_line=$(grep -n '_dns01_install "$dns01_domain" "$dns01_provider" "$email" "$dns01_token"' xrayebator | head -1 | cut -d: -f1)
http_tls_line=$(grep -n 'SUB_TLS_MODE="http_tls"' xrayebator | head -1 | cut -d: -f1)
[[ -n "$dns01_line" && -n "$http_tls_line" ]] || fail "не найдены якоря порядка DNS-01/http_tls"
(( http_tls_line > dns01_line )) || fail "http_tls-деградация идёт раньше DNS-01-фолбэка"

# domain_tls не должен перетираться шаблонами ip_tls: ни nginx-vhost'ом, ни маркерами.
grep -q 'if \[\[ "$SUB_TLS_MODE" == "domain_tls" \]\]; then' xrayebator \
  || fail "quickstart не пропускает перерисовку nginx для domain_tls"
grep -q 'if \[\[ "$SUB_TLS_MODE" != "domain_tls" \]\]; then' xrayebator \
  || fail "quickstart перетирает маркеры подписки в domain_tls (GUI получил бы URL с IP)"

echo "✓ DNS-01 (Cloudflare/Route53): валидация, аргументы certbot, credentials 0600, vhost без :80, CLI-ошибки, repair-dns01, quickstart --pq/DNS-01-фолбэк, проводка — OK"
