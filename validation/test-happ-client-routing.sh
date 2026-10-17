#!/bin/bash
# Тесты HAPP client routing: split-генератор (PR #23), плейсхолдеры (PR #22),
# nginx-буферы в шаблонах подписки. Static + functional (source-mode).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# shellcheck disable=SC1091
source "$REPO_ROOT/xrayebator"

echo "1) split-генератор: собирает JSON из bypass-наборов с плейсхолдерами"
generated=$(_happ_client_split_routing_json) || fail "генератор вернул ошибку"
[[ "$generated" == *'"GlobalProxy": "true"'* ]] || fail "GlobalProxy != true"
[[ "$generated" == *'{{GEOIP_URL}}'* && "$generated" == *'{{GEOSITE_URL}}'* && "$generated" == *'{{LAST_UPDATED}}'* ]] \
  || fail "нет плейсхолдеров в сгенерированном профиле"
n_direct=$(jq -r '.DirectSites | length' <<<"$generated")
[[ "$n_direct" -ge 200 ]] || fail "DirectSites подозрительно мало: $n_direct"
jq -e '.DirectSites | index("domain:ozon.ru") and index("domain:sberbank.ru") and index("domain:gosuslugi.ru")' <<<"$generated" >/dev/null \
  || fail "ключевые российские домены не в DirectSites"
jq -e '.DirectIp | index("geoip:ru")' <<<"$generated" >/dev/null || fail "нет geoip:ru"
jq -e '(.DirectSites - .DirectSites | length) == 0' <<<"$generated" >/dev/null || fail "дубликаты в DirectSites"
echo "   OK: $n_direct доменов напрямую, плейсхолдеры на месте"

echo "2) nginx-шаблоны подписки: proxy_buffer_size 32k в location /sub/"
grep -Fq 'proxy_buffer_size 32k' "$REPO_ROOT/xrayebator" || fail "нет proxy_buffer_size 32k"
[[ "$(grep -Fc 'proxy_buffer_size 32k' "$REPO_ROOT/xrayebator")" -ge 2 ]] \
  || fail "буферы применены не во всех шаблонах (нужно >= 2 location /sub/)"
echo "   OK: буферы в шаблонах"

echo "3) subhttp: подстановка плейсхолдеров до валидации"
grep -Fq '{{GEOIP_URL}}' "$REPO_ROOT/xrayebator" || fail "нет подстановки GEOIP_URL"
grep -Fq '{{LAST_UPDATED}}' "$REPO_ROOT/xrayebator" || fail "нет подстановки LAST_UPDATED"
grep -Fq '_happ_routing_last_updated' "$REPO_ROOT/xrayebator" || fail "нет вызова _happ_routing_last_updated"
# Порядок: подстановка раньше валидации ВНУТРИ блока переопределения
ln_subst=$(grep -Fn 'routing_custom=${routing_custom//\{\{GEOIP_URL\}\}' "$REPO_ROOT/xrayebator" | head -1 | cut -d: -f1)
[[ -n "$ln_subst" ]] || fail "не найдена строка подстановки"
ln_val=$(grep -Fn '_happ_validate_routing_json' "$REPO_ROOT/xrayebator" | awk -F: -v s="$ln_subst" '$1 > s {print $1; exit}')
[[ -n "$ln_val" ]] || fail "после подстановки нет валидации"
echo "   OK: подстановка (строка $ln_subst) до валидации (строка $ln_val)"

echo "4) меню: пункт 7 маршрутизации клиента в HAPP-меню"
grep -Fq 'happ_client_routing_menu' "$REPO_ROOT/xrayebator" || fail "нет happ_client_routing_menu"
grep -Fq 'Маршрутизация клиента (split для российских сервисов)' "$REPO_ROOT/xrayebator" || fail "нет пункта 7 в меню"
grep -Fq '7) happ_client_routing_menu ;;' "$REPO_ROOT/xrayebator" || fail "нет case 7"
echo "   OK: меню подключено"

echo "OK: HAPP client routing — все проверки пройдены"
