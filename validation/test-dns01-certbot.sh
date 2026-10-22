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
# Пути состояния/сертификатов — тоже в песочницу: dns01-status иначе читал бы
# /usr/local/etc/xray и /etc/letsencrypt живой машины.
DNS01_STATE_DIR="$WORKDIR/state"
DNS01_RENEWAL_DIR="$WORKDIR/renewal"
DNS01_LIVE_DIR="$WORKDIR/live"
ACME_STAGING_MARKER_FILE="$DNS01_STATE_DIR/.acme_staging"
DNS01_TEST_LOG="$WORKDIR/certbot-dns01-test.log"
mkdir -p "$DNS01_STATE_DIR" "$DNS01_RENEWAL_DIR" "$DNS01_LIVE_DIR"
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
assert_json "$out" '.ok == true and .provider == "" and .domain == "" and .days_left == 0 and .deploy_hook == false and .staging == false' \
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

# Идемпотентность: повторный quickstart --pq (обновление, повторный прогон визарда)
# не должен плодить PQ-маршруты и порты — проверка наличия маршрута обязана стоять
# ДО вызова _pq_add_route_for_profile. Живой прогон давал два tcp-pq маршрута.
dup_line=$(grep -n 'any((\.routes // \[\])\[\]; \.pq_enabled == true and \.transport == "tcp")' xrayebator | head -1 | cut -d: -f1)
[[ -n "$dup_line" ]] || fail "quickstart --pq не проверяет уже существующий PQ-маршрут (дубли портов)"
pq_call_line=$(grep -n '_pq_add_route_for_profile "$PROFILES_DIR/$HAPP_DEFAULT_PROFILE.json" tcp' xrayebator | head -1 | cut -d: -f1)
[[ -n "$pq_call_line" ]] || fail "не найден вызов _pq_add_route_for_profile в quickstart"
(( pq_call_line > dup_line )) || fail "проверка существующего PQ-маршрута должна идти до добавления нового"

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

# ═══════════ 8. staging-контур ACME (--staging) ═══════════
# Прод-квота LE — «5 сертификатов на точный набор идентификаторов за 168 ч» — была
# выжжена отладочными выпусками досуха (на живом сервере: retry after 2026-10-19
# 02:02:28 UTC), поэтому у ACME-путей есть проверочный контур. Тесты держат ровно два
# инварианта: staging реально уходит в --test-cert, а боевой выпуск ВСЕГДА называет
# прод-эндпоинт явно — иначе повторный выпуск с тем же --cert-name унаследовал бы
# сервер из renewal-конфига и «боевой» прогон молча остался бы в staging.
_acme_staging_on true || fail "флаг --staging должен включать контур"
_acme_staging_on "" "1" || fail "XRAYEBATOR_ACME_STAGING=1 должен включать контур"
_acme_staging_on "" "TRUE" || fail "значение переменной регистронезависимо"
_acme_staging_on "" "on" || fail "значение on должно включать контур"
if _acme_staging_on "false" ""; then
  fail "без флага и без переменной контур выключен"
fi
if _acme_staging_on "" "0"; then
  fail "значение 0 не должно включать контур"
fi
if _acme_staging_on "" "no"; then
  fail "значение no не должно включать контур"
fi

stage_args=$(_dns01_certbot_args_pure cloudflare sub.example.com "" "$DNS01_CLOUDFLARE_INI" true) \
  || fail "сборка staging-аргументов"
grep -qx -- "--test-cert" <<<"$stage_args" || fail "staging должен давать --test-cert"
if grep -qx -- "--server" <<<"$stage_args"; then
  fail "в staging не должно быть явного прод-сервера (certbot отвергнет два указания)"
fi

prod_args=$(_dns01_certbot_args_pure cloudflare sub.example.com "" "$DNS01_CLOUDFLARE_INI" false) \
  || fail "сборка боевых аргументов"
grep -qx -- "--server" <<<"$prod_args" || fail "боевой выпуск обязан называть ACME-сервер явно"
grep -q -- "$ACME_PRODUCTION_URL" <<<"$prod_args" || fail "боевой сервер — прод-эндпоинт LE"
if grep -qx -- "--test-cert" <<<"$prod_args"; then
  fail "в боевом выпуске не должно быть --test-cert"
fi

# Маркер контура: ставится на staging-выпуске и снимается боевым.
_acme_staging_mark true || fail "установка маркера staging"
_acme_staging_marked || fail "маркер staging не виден"
_acme_staging_mark false || fail "снятие маркера staging"
if _acme_staging_marked; then
  fail "боевой выпуск должен снимать маркер staging"
fi

# Аргументы проверочного выпуска: staging, отдельное имя линии, без deploy-hook
# (проверка не должна перезагружать nginx и не должна трогать боевую линию).
test_args=$(_dns01_test_certbot_args_pure cloudflare sub.example.com "" "$DNS01_CLOUDFLARE_INI" xrayebator-dns01-test-1) \
  || fail "сборка аргументов dns01-test"
grep -qx -- "--test-cert" <<<"$test_args" || fail "dns01-test обязан идти в staging"
test_cert_name=$(grep -A1 -x -- "--cert-name" <<<"$test_args" | tail -1)
[[ "$test_cert_name" == "xrayebator-dns01-test-1" ]] \
  || fail "проверочная линия должна иметь своё имя, а не домен (иначе перезапишет боевой серт): $test_cert_name"
if grep -q -- "deploy-hook" <<<"$test_args"; then
  fail "проверочному выпуску не нужен deploy-hook"
fi
if _dns01_test_certbot_args_pure cloudflare sub.example.com "" "$DNS01_CLOUDFLARE_INI" "" >/dev/null 2>&1; then
  fail "пустое имя проверочной линии должно отклоняться"
fi

# Порт: явный → текущий порт подписки → 443. Раньше GUI-кнопка «Настроить DNS-01»
# молча уводила подписку с :8443 на :443 (URL менялся без спроса).
[[ "$(_dns01_resolve_port 8443 9000)" == "8443" ]] || fail "явный порт имеет приоритет"
[[ "$(_dns01_resolve_port "" 8443)" == "8443" ]] || fail "нужен текущий порт подписки"
[[ "$(_dns01_resolve_port "" "")" == "443" ]] || fail "без подписки порт по умолчанию 443"
[[ "$(_dns01_resolve_port "" "abc")" == "443" ]] || fail "мусор в маркере порта — откат на 443"
[[ "$(_dns01_resolve_port "" "70000")" == "443" ]] || fail "порт вне диапазона — откат на 443"

# ═══════════ 9. dns01-test: проверочный выпуск (CLI-валидация) ═══════════
out=$(dns01_test_command --domain 203.0.113.10 --provider cloudflare --token "$CF_TOKEN" --without-email) || true
assert_json "$out" '.ok == false and (.error | test("--domain"))' "dns01-test: IP вместо домена"
out=$(dns01_test_command --domain sub.example.com --provider digitalocean --token "$CF_TOKEN" --without-email) || true
assert_json "$out" '.ok == false and (.error | test("cloudflare"))' "dns01-test: неизвестный провайдер"
out=$(dns01_test_command --domain sub.example.com --provider cloudflare --token short --without-email) || true
assert_json "$out" '.ok == false and (.error | test("--token"))' "dns01-test: короткий токен"
out=$(dns01_test_command --domain sub.example.com --provider route53 --without-email) || true
assert_json "$out" '.ok == false and (.error | test("aws"))' "dns01-test: route53 без ключей"
out=$(dns01_test_command --domain sub.example.com --provider cloudflare --token "$CF_TOKEN") || true
assert_json "$out" '.ok == false and (.error | test("--email"))' "dns01-test: без email и без --without-email"
[[ ! -f "$DNS01_MARKER_FILE" ]] || fail "dns01-test не должен писать маркер провайдера"
# Временные креды проверочного выпуска не должны переживать ошибку валидации
# (боевой cloudflare.ini из секции 3 существует и к dns01-test отношения не имеет).
[[ ! -f "$DNS01_CREDS_DIR/xrayebator-dns01-test.ini" ]] \
  || fail "dns01-test не должен оставлять временные credentials"
[[ ! -f "$ACME_STAGING_MARKER_FILE" ]] || fail "dns01-test не трогает маркер контура подписки"

grep -qE '^\s+dns01-test\)' xrayebator || fail "нет диспатчера dns01-test"
grep -q 'dns01-test --domain sub.example.com' xrayebator || fail "нет help-строки dns01-test"
# --staging должен парситься всеми тремя входами: dns01-setup, repair-dns01, quickstart.
[[ "$(grep -c -- '--staging) staging_flag=true; shift ;;' xrayebator)" -ge 3 ]] \
  || fail "не все входы (dns01-setup/repair-dns01/quickstart) парсят --staging"
grep -q -- '--without-staging) staging_flag=false; shift' xrayebator || fail "quickstart не парсит --without-staging"
grep -q 'certbot_server_args=(--test-cert)' xrayebator || fail "quickstart не переводит IP-выпуск в staging"
grep -q 'certbot_server_args=(--server "\$ACME_PRODUCTION_URL")' xrayebator \
  || fail "quickstart не называет прод-эндпоинт явно (унаследует staging из renewal-конфига)"
grep -q '_dns01_install "\$dns01_domain" "\$dns01_provider" "\$email" "\$dns01_token"' xrayebator || fail "нет вызова _dns01_install в фолбэке"
grep -q '"8443" "\$acme_staging" || _dns_rc=\$?' xrayebator || fail "quickstart не передаёт контур в DNS-01-фолбэк"
grep -q '_acme_staging_mark "\$acme_staging"' xrayebator || fail "quickstart не помечает staging-выпуск"

# ═══════════ 10. deploy_hook: certbot пишет renew_hook, а не deploy-hook ═══════════
# Живой renewal-конфиг содержит `renew_hook = systemctl reload nginx`; грепать только
# «deploy-hook» значило бы показывать false на корректно настроенном домене.
printf 'renew_hook = systemctl reload nginx\n' > "$DNS01_RENEWAL_DIR/hooked.example.com.conf"
_dns01_renewal_has_hook hooked.example.com || fail "renew_hook не распознан как deploy-hook"
printf 'deploy-hook = systemctl reload nginx\n' > "$DNS01_RENEWAL_DIR/legacy.example.com.conf"
_dns01_renewal_has_hook legacy.example.com || fail "deploy-hook не распознан"
printf '[renewalparams]\naccount = abc\n' > "$DNS01_RENEWAL_DIR/plain.example.com.conf"
if _dns01_renewal_has_hook plain.example.com; then
  fail "без хука deploy_hook должен быть false"
fi
if _dns01_renewal_has_hook ""; then
  fail "пустой домен не должен давать deploy_hook"
fi

# Функционально: dns01-status собирает состояние из маркеров и renewal-конфига.
printf 'domain_tls' > "$DNS01_STATE_DIR/.subscription_mode"
printf 'sub.example.com' > "$DNS01_STATE_DIR/.subscription_domain"
printf '8443' > "$DNS01_STATE_DIR/.subscription_port"
printf 'cloudflare\n' > "$DNS01_MARKER_FILE"
printf 'renew_hook = systemctl reload nginx\n' > "$DNS01_RENEWAL_DIR/sub.example.com.conf"
out=$(dns01_status_command) || true
assert_json "$out" '.ok == true and .provider == "cloudflare" and .tls_mode == "domain_tls"
  and .domain == "sub.example.com" and .port == 8443 and .deploy_hook == true and .staging == false' \
  "dns01-status на доменной подписке"
printf 'staging\n' > "$ACME_STAGING_MARKER_FILE"
out=$(dns01_status_command) || true
assert_json "$out" '.staging == true' "dns01-status показывает staging-контур (запасной путь: серта нет, есть маркер)"
rm -f "$ACME_STAGING_MARKER_FILE" "$DNS01_MARKER_FILE"
rm -f "$DNS01_STATE_DIR/.subscription_mode" "$DNS01_STATE_DIR/.subscription_domain" "$DNS01_STATE_DIR/.subscription_port"
rm -f "$DNS01_RENEWAL_DIR/sub.example.com.conf"

# ═══════════ 10б. Контур staging определяется по самому сертификату ═══════════
# Маркер .acme_staging снимается только нашим выпуском: продление идёт через
# `certbot renew` мимо xrayebator, поэтому после staging-прогона метка устаревает.
# На живом сервере это давало staging:true при боевом серте в live/<ip> — GUI пугал
# бы зря. Источник истины — издатель сертификата, маркер только запасной вариант.
CERTDIR="$DNS01_LIVE_DIR/sub.example.com"
mkdir -p "$CERTDIR"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=(STAGING) Test Issuer" \
  -keyout "$WORKDIR/staging-key.pem" -out "$WORKDIR/staging-cert.pem" >/dev/null 2>&1 \
  || fail "не удалось сгенерировать staging-сертификат для теста"
cp "$WORKDIR/staging-cert.pem" "$CERTDIR/fullchain.pem"
printf 'domain_tls' > "$DNS01_STATE_DIR/.subscription_mode"
printf 'sub.example.com' > "$DNS01_STATE_DIR/.subscription_domain"
printf '8443' > "$DNS01_STATE_DIR/.subscription_port"
out=$(dns01_status_command) || true
assert_json "$out" '.staging == true and .domain == "sub.example.com"' \
  "staging должен определяться по издателю сертификата (без маркера)"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=R11" \
  -keyout "$WORKDIR/prod-key.pem" -out "$WORKDIR/prod-cert.pem" >/dev/null 2>&1 \
  || fail "не удалось сгенерировать боевой сертификат для теста"
cp "$WORKDIR/prod-cert.pem" "$CERTDIR/fullchain.pem"
printf 'staging\n' > "$ACME_STAGING_MARKER_FILE"
out=$(dns01_status_command) || true
assert_json "$out" '.staging == false' \
  "устаревший маркер не должен объявлять боевой сертификат staging-сертификатом"

# Сертификат недоступен — остаётся маркер.
rm -rf "$CERTDIR"
out=$(dns01_status_command) || true
assert_json "$out" '.staging == true' "без сертификата контур берётся из маркера"
rm -f "$ACME_STAGING_MARKER_FILE"
rm -f "$DNS01_STATE_DIR/.subscription_mode" "$DNS01_STATE_DIR/.subscription_domain" "$DNS01_STATE_DIR/.subscription_port"

# ═══════════ 10в. _certbot_failure_reason: человеческая причина отказа ═══════════
# На живом прогоне dns01-test reason оказался служебным «Ask for help or search for
# solutions…», потому что отказ ACME по политике приходит без urn-ссылки. Оператор
# должен видеть причину, а не воду certbot.
FAIL_LOG="$WORKDIR/fail.log"
printf 'too many certificates (5) already issued for this exact set of identifiers in the last 168h0m0s, retry after 2026-10-19 02:02:28 UTC\n' > "$FAIL_LOG"
reason=$(_certbot_failure_reason "$FAIL_LOG")
grep -q "Let's Encrypt rate limit" <<<"$reason" || fail "rate limit не распознан: $reason"
grep -q '2026-10-19 02:02:28 UTC' <<<"$reason" || fail "в причине нет времени повтора: $reason"

printf '[urn:ietf:params:acme:error:unauthorized] Invalid token\n' > "$FAIL_LOG"
reason=$(_certbot_failure_reason "$FAIL_LOG")
grep -q 'unauthorized' <<<"$reason" || fail "urn-ошибка не распознана: $reason"

cat > "$FAIL_LOG" <<'EOF'
Saving debug log to /var/log/letsencrypt/letsencrypt.log
Requesting a certificate for nope.example.com
An unexpected error occurred:
The server will not issue certificates for the identifier :: Error creating new order :: Cannot issue for "nope.example.com"
Ask for help or search for solutions at https://community.letsencrypt.org. See the logfile
EOF
reason=$(_certbot_failure_reason "$FAIL_LOG")
grep -q 'will not issue certificates' <<<"$reason" || fail "ошибка без urn-ссылки не распознана: $reason"
if grep -q 'Ask for help' <<<"$reason"; then
  fail "служебная вода certbot не должна попадать в reason: $reason"
fi

printf 'Saving debug log to X\nAsk for help or search for solutions at Y. See the logfile Z\n' > "$FAIL_LOG"
reason=$(_certbot_failure_reason "$FAIL_LOG")
if grep -q 'Ask for help' <<<"$reason"; then
  fail "fallback не должен отдавать служебную строку: $reason"
fi

printf '' > "$FAIL_LOG"
reason=$(_certbot_failure_reason "$FAIL_LOG") || fail "пустой лог не должен ломать разбор"
[[ -z "$reason" ]] || fail "пустой лог должен давать пустую причину: $reason"

# ═══════════ 11. apt certbot.timer при snap-продлении ═══════════
# apt-certbot 1.x не умеет --ip-address, а его certbot.timer продлевает все линии —
# включая shortlived IP-линию, которой управляет snap-certbot: каждые 12 часов падение.
# Отключаем только его, помечаем флагом и возвращаем при настройке доменного серта.
APT_CERTBOT_TIMER_FLAG="$WORKDIR/apt_timer_flag"
SYSTEMCTL_LOG="$WORKDIR/systemctl.log"
: > "$SYSTEMCTL_LOG"
FAKE_TIMER_ENABLED_RC=0
systemctl() {
  printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
  case "$*" in
    "is-enabled --quiet certbot.timer") return "$FAKE_TIMER_ENABLED_RC" ;;
    *) return 0 ;;
  esac
}
_apt_certbot_timer_disable || fail "отключение apt certbot.timer"
[[ -f "$APT_CERTBOT_TIMER_FLAG" ]] || fail "флаг отключения таймера не поставлен"
grep -q "disable --now certbot.timer" "$SYSTEMCTL_LOG" || fail "таймер не отключён"
_apt_certbot_timer_enable || fail "возврат apt certbot.timer"
[[ ! -f "$APT_CERTBOT_TIMER_FLAG" ]] || fail "флаг должен сниматься при возврате таймера"
grep -q "enable --now certbot.timer" "$SYSTEMCTL_LOG" || fail "таймер не включён обратно"

# Таймер, выключенный оператором, мы не трогаем и флаг не ставим — включать его назад
# мы не вправе.
: > "$SYSTEMCTL_LOG"
FAKE_TIMER_ENABLED_RC=1
_apt_certbot_timer_disable || fail "повторное отключение не должно падать"
[[ ! -f "$APT_CERTBOT_TIMER_FLAG" ]] || fail "чужое отключение таймера не должно помечаться нашим флагом"
if grep -q "disable --now certbot.timer" "$SYSTEMCTL_LOG"; then
  fail "уже выключенный таймер не нужно отключать повторно"
fi
_apt_certbot_timer_enable || fail "no-op возврат без флага"
FAKE_TIMER_ENABLED_RC=0

# Проводка: отключение — только для snap-продления; возврат — в _dns01_install и uninstall.
grep -q '/snap/\*) _apt_certbot_timer_disable' xrayebator || fail "таймер отключается не только для snap"
grep -q '_apt_certbot_timer_enable || true' xrayebator || fail "_dns01_install не возвращает apt certbot.timer"
grep -q 'apt_certbot_timer_disabled' uninstall.sh || fail "uninstall не возвращает apt certbot.timer"

echo "✓ DNS-01 (Cloudflare/Route53): валидация, аргументы certbot, credentials 0600, vhost без :80, CLI-ошибки, repair-dns01, quickstart --pq/DNS-01-фолбэк, staging-контур, dns01-test, проводка — OK"
