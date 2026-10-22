#!/bin/bash
# test-sni-reachability.sh
# Проверяет выбор дефолтного SNI с учётом доступности С ЭТОГО сервера:
#   - недоступный пер-транспортный дефолт (или первая строка sni_list.txt)
#     заменяется первым доступным кандидатом;
#   - если недоступны ВСЕ кандидаты (нет сети/DNS) — возвращается прежний дефолт,
#     чтобы проба не ломала развёртывание на изолированном хосте;
#   - результат кэшируется: одна проба на SNI за запуск менеджера.
#
# Мотивация (живой VPS, Германия, 2026-10-17): дефолтный www.ozon.ru был недоступен
# с сервера, и 5 из 7 маршрутов свежего деплоя не работали — Reality отдаёт клиенту
# сертификат, полученный у dest, поэтому недоступный dest = висящее рукопожатие.
# Проверка каналов клиентом Xray показала таймауты; после смены SNI на доступный
# заработали все 7 маршрутов (включая PQ).
#
# Usage: bash validation/test-sni-reachability.sh   (нужны bash 4+, grep, cut)

set -euo pipefail

fail() {
  echo "✗ $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORKDIR=$(mktemp -d /tmp/xrayebator-sni.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/xrayebator"

# Изолируем окружение: свой список SNI, без self-steal домена и без реальных проб.
SNI_LIST="$WORKDIR/sni_list.txt"
SELFSTEAL_DOMAIN_FILE="$WORKDIR/.selfsteal_domain"
printf '%s\n' \
  '# комментарий' \
  'www.ozon.ru|маркетплейс|1' \
  'www.cloudflare.com|cdn|2' > "$SNI_LIST"

PROBE_LOG="$WORKDIR/probes"
: > "$PROBE_LOG"

reset_cache() {
  unset _SNI_REACH_CACHE
  # declare -gA, а не declare -A: внутри функции declare создаёт ЛОКАЛЬНУЮ
  # переменную, и хелпер получил бы обычный массив (индекс как арифметика).
  declare -gA _SNI_REACH_CACHE=()
}

# Пробы в тесте обязаны быть безсетевыми: сценарии подменяют _monitor_sni_reachable,
# но _sni_reachable_from_here дополнительно спрашивает curl — без заглушки результат
# зависел бы от того, отвечает ли хост из CI. По умолчанию «сайт отвечает 200».
curl() { printf '%s' "200"; }

# Доступен только cloudflare (ozon недоступен — как на живом сервере).
only_cloudflare() {
  echo "$1" >> "$PROBE_LOG"
  [[ "$1" != "www.ozon.ru" ]]
}

# ─── 1. Недоступная первая строка списка заменяется доступным кандидатом ───
reset_cache
: > "$PROBE_LOG"
_monitor_sni_reachable() { only_cloudflare "$1"; }
res=$(_default_sni_for_transport tcp)
[[ "$res" == "www.cloudflare.com" ]] \
  || fail "недоступный SNI из sni_list.txt не заменён доступным (получено: '$res')"
grep -q 'www.ozon.ru' "$PROBE_LOG" || fail "недоступный SNI даже не был проверен"

# ─── 2. Доступный пер-транспортный дефолт остаётся на месте ───
reset_cache
res=$(_default_sni_for_transport grpc)
[[ "$res" == "www.cloudflare.com" ]] || fail "grpc-дефолт должен остаться cloudflare (получено: '$res')"
reset_cache
res=$(_default_sni_for_transport tcp-xudp)
[[ "$res" == "api-maps.yandex.ru" ]] || fail "tcp-xudp-дефолт должен остаться yandex (получено: '$res')"

# ─── 3. Все кандидаты недоступны → прежний дефолт (деплой не ломается) ───
reset_cache
_monitor_sni_reachable() { echo "$1" >> "$PROBE_LOG"; return 1; }
res=$(_default_sni_for_transport tcp)
[[ "$res" == "www.ozon.ru" ]] \
  || fail "при полной недоступности должен остаться прежний дефолт (получено: '$res')"
res=$(_default_sni_for_transport grpc)
[[ "$res" == "www.cloudflare.com" ]] \
  || fail "при полной недоступности grpc-дефолт должен сохраниться (получено: '$res')"

# ─── 4. Кэш: повторный вызов не пробует те же SNI заново ───
reset_cache
: > "$PROBE_LOG"
_monitor_sni_reachable() { only_cloudflare "$1"; }
_default_sni_for_transport tcp >/dev/null
first=$(wc -l < "$PROBE_LOG")
_default_sni_for_transport tcp >/dev/null
second=$(wc -l < "$PROBE_LOG")
[[ "$first" == "$second" ]] \
  || fail "повторный вызов снова пробует SNI (кэш не работает: $first → $second проб)"

# ─── 5. self-steal домен имеет приоритет и не пробуется ───
reset_cache
printf '%s' 'steal.example.com' > "$SELFSTEAL_DOMAIN_FILE"
: > "$PROBE_LOG"
res=$(_default_sni_for_transport tcp)
rm -f "$SELFSTEAL_DOMAIN_FILE"
[[ "$res" == "steal.example.com" ]] || fail "self-steal домен должен иметь приоритет (получено: '$res')"
[[ ! -s "$PROBE_LOG" ]] || fail "при self-steal домене проба SNI не нужна"

# ─── 6. Критерий пробы: «Verify return code: 0» САМ ПО СЕБЕ не доказательство ───
# Живой дефект 2026-10-20: openssl печатает «Verify return code: 0 (ok)» даже когда
# рукопожатие не состоялось (проверять нечего). Из-за этого проба объявляла доступными
# online.vtb.ru (TLS 1.2 only — Reality требует 1.3) и splitter.wb.ru (alert 40), и
# свежие профили получали мёртвый SNI: 4 из 6 PQ-маршрутов отдавали http 000, а смена
# SNI на www.cloudflare.com на том же порту — 200.
# Фикстуры сняты с РЕАЛЬНОГО вывода Ubuntu 22.04 (OpenSSL 3.0), а не придуманы.
# Первая редакция пробы требовала строку `Protocol  : TLSv1.3`, которой OpenSSL 3.0
# при -tls1_3 не печатает вовсе: версия видна только в «New, TLSv1.3, Cipher is …».
# Из-за этого живые www.cloudflare.com, www.google.com и api-maps.yandex.ru были
# отбракованы, перебор уходил в хвост списка, и создание профиля занимало 67–84 с.
good_out='CONNECTED(00000003)
depth=0 CN = www.cloudflare.com
verify return:1
---
Certificate chain
 0 s:CN = www.cloudflare.com
---
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
Secure Renegotiation IS NOT supported
---
Verify return code: 0 (ok)
---'
_sni_tls_output_ok_pure "$good_out" || fail "годный ответ TLS1.3 с проверенным сертификатом отклонён"
# Старые сборки openssl печатают блок Protocol: — эта форма тоже обязана приниматься.
_sni_tls_output_ok_pure 'Protocol  : TLSv1.3
Cipher    : TLS_AES_128_GCM_SHA256
Verify return code: 0 (ok)' || fail "форма ответа со строкой Protocol: TLSv1.3 отклонена"

# TLS1.3-хост недоступен: alert + «нет сертификата», но Verify return code: 0 всё равно печатается
alert_out='4047FE17F77F0000:error:0A000410:SSL routines:ssl3_read_bytes:sslv3 alert handshake failure
CONNECTED(00000003)
---
no peer certificate available
---
No client certificate CA names sent
---
SSL handshake has read 7 bytes and written 247 bytes
Verification: OK
---
New, (NONE), Cipher is (NONE)
---
Verify return code: 0 (ok)
---'
if _sni_tls_output_ok_pure "$alert_out"; then
  fail "проба считает доступным хост с alert handshake failure (нет сертификата) — это же и был живой дефект"
fi

# Успешный, но TLS 1.2-хост: Reality требует именно 1.3.
tls12_out='CONNECTED(00000003)
---
Certificate chain
 0 s:CN = example.org
---
New, TLSv1.2, Cipher is ECDHE-RSA-AES256-GCM-SHA384
---
Verify return code: 0 (ok)
---'
if _sni_tls_output_ok_pure "$tls12_out"; then
  fail "проба принимает TLS 1.2-хост, а Reality требует TLS 1.3"
fi

# Сертификат не проверен (self-signed в цепочке)
badcert_out='---
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
---
Verify return code: 19 (self-signed certificate in certificate chain)
---'
if _sni_tls_output_ok_pure "$badcert_out"; then
  fail "проба принимает хост с непроверенным сертификатом"
fi

# Пустой вывод (таймаут/нет сети) — не доказательство
if _sni_tls_output_ok_pure ""; then
  fail "пустой вывод openssl не должен считаться доступностью"
fi

# ─── 6b. Флапающий хост: одно успешное рукопожатие из двух — не доступность ───
# Живой splitter.wb.ru проходил пробу в одном замере и падал (alert 40) в другом;
# Reality на таком dest рвёт рукопожатие у клиента, поэтому проба делает два замера.
reset_cache
flap_counter=0
_monitor_sni_reachable() {
  flap_counter=$((flap_counter + 1))
  # 1-й замер проходит, 2-й падает — ровно поведение флапающего хоста.
  [[ "$flap_counter" -eq 1 ]]
}
if _sni_reachable_from_here "flap.example"; then
  fail "одно успешное рукопожатие из двух не должно считаться доступностью"
fi
[[ "$flap_counter" -ge 2 ]] || fail "проба обязана делать второй замер, а сделала $(flap_counter) замер(ов)"

# Стабильный хост: два замера подряд — доступен.
reset_cache
stable_counter=0
_monitor_sni_reachable() { stable_counter=$((stable_counter + 1)); return 0; }
curl() { printf '%s' "200"; }   # сайт отвечает по HTTP
_sni_reachable_from_here "stable.example" || fail "стабильный хост отклонён"
[[ "$stable_counter" -eq 2 ]] || fail "успешный SNI должен проверяться дважды (замеров: $stable_counter)"

# ─── 6c. TLS состоялся, но сайт не отвечает по HTTP — тоже негодный dest ───
# Живой www.wildberries.ru: рукопожатие за 1.7 с, curl даёт 000, и маршрут с таким
# SNI висел 10 с. Reality шлёт реальный ClientHello и ждёт продолжения сессии.
reset_cache
_monitor_sni_reachable() { return 0; }
curl() { printf '%s' "000"; }
if _sni_reachable_from_here "tarpit.example"; then
  fail "хост с TLS-рукопожатием без HTTP-ответа не должен считаться доступным"
fi
# А вот код ответа не важен: 403 — нормальная практика, такой dest годится.
reset_cache
curl() { printf '%s' "403"; }
_sni_reachable_from_here "forbidden.example" || fail "хост с HTTP 403 должен приниматься (важен факт ответа)"
# Возвращаем заглушку по умолчанию, чтобы не влиять на дальнейшие сценарии.
curl() { printf '%s' "200"; }

# ─── 7. Порядок кандидатов: голова списка → глобальные фолбэки → хвост списка ───
# Иначе на зарубежном VPS весь мёртвый ru_whitelist съедал по таймауту на строку.
WORKDIR_LONG=$(mktemp -d "$WORKDIR/long.XXXXXX")
{ printf '%s\n' '# комментарий'
  for i in 1 2 3 4 5 6 7 8 9 10; do printf 'dead%s.example|test|1\n' "$i"; done
} > "$WORKDIR_LONG/sni_list.txt"
SNI_LIST="$WORKDIR_LONG/sni_list.txt"
SNI_REACH_HEAD_MAX=4
reset_cache
: > "$PROBE_LOG"
_monitor_sni_reachable() { echo "$1" >> "$PROBE_LOG"; return 1; }
_default_sni_for_transport tcp >/dev/null
[[ -s "$PROBE_LOG" ]] || fail "проба не вызвана — сценарий порядка кандидатов не отработал"
grep -q 'www.cloudflare.com' "$PROBE_LOG" \
  || fail "глобальные фолбэки должны пробоваться раньше хвоста списка"
fallback_line=$(grep -n 'www.cloudflare.com' "$PROBE_LOG" | head -1 | cut -d: -f1)
tail_line=$(grep -n 'dead10.example' "$PROBE_LOG" | head -1 | cut -d: -f1)
[[ "$fallback_line" -lt "$tail_line" ]] \
  || fail "фолбэк cloudflare должен идти до хвоста списка ($fallback_line vs $tail_line)"

echo "✓ SNI-достижимость: недоступный дефолт заменяется доступным кандидатом, полная недоступность оставляет прежний дефолт, результат кэшируется, критерий требует состоявшийся TLS 1.3, порядок кандидатов ограничен — OK"
