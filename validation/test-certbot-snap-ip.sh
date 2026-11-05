#!/usr/bin/env bash
# Тест «certbot для IP-сертификатов через snap».
#
# Живой баг первого прогона на Ubuntu 24.04: quickstart ставил certbot своим
# дублем кода — `timeout 300 snap install --classic certbot 2>/dev/null || true`.
# На свежем образе snapd доигрывает seed/refresh и перезапускается сам, поэтому
# установка обрывалась мгновенно, ошибка глоталась, и quickstart отвечал
# «Certbot с --ip-address и --preferred-profile не найден» при полностью рабочем
# snap (ручной `snap install --classic certbot` в тот же момент ставил 5.9.0).
# Вдобавок прогресс snap уходил в stdout и ломал разбор JSON у GUI.
#
# Что проверяем:
#  - единственная реализация `_ensure_certbot_ip_tls`, quickstart её вызывает и
#    больше не содержит своего `snap install`;
#  - ожидание готовности snapd (`snap wait system seed.loaded`) и повтор установки;
#  - результат проверяется по возможностям certbot, а не по коду возврата snap;
#  - вывод snap уходит в лог-файлы, а не в stdout CLI;
#  - функционально: `_certbot_supports_ip_address` отличает certbot 5.4+ от apt-версии.
set -u
cd "$(dirname "$0")/.."

fail() { echo "✗ $1"; exit 1; }
pass() { echo "✓ $1"; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export LOCK_FILE="$TMP_ROOT/xrayebator.lock"
# shellcheck disable=SC1091
source ./xrayebator || fail "source ./xrayebator failed"

grep -q '^_ensure_certbot_ip_tls() {' xrayebator || fail "нет _ensure_certbot_ip_tls"
grep -q '^_wait_snapd_ready() {' xrayebator || fail "нет _wait_snapd_ready"

# Быстрый путь в quickstart обязан переиспользовать общий помощник.
quickstart_body=$(sed -n '/^quickstart_command() {/,/^}/p' xrayebator)
[[ -n "$quickstart_body" ]] || fail "не найдено тело quickstart_command"
case "$quickstart_body" in
  *_ensure_certbot_ip_tls*) ;;
  *) fail "quickstart не вызывает _ensure_certbot_ip_tls" ;;
esac
if printf '%s' "$quickstart_body" | grep -qE 'snap install'; then
  fail "quickstart снова ставит certbot своим дублем (snap install внутри quickstart)"
fi

# Ожидание готовности snapd и повтор установки.
grep -q 'snap wait system seed.loaded' xrayebator || fail "_wait_snapd_ready не ждёт seed.loaded"
helpers=$(sed -n '/^_ensure_certbot_ip_tls() {/,/^}/p' xrayebator)
printf '%s' "$helpers" | grep -q 'for attempt in 1 2 3' || fail "нет повтора установки snap"
printf '%s' "$helpers" | grep -q '_wait_snapd_ready' || fail "повтор не дожидается snapd"
# Результат — по возможностям certbot, а не по коду возврата snap.
printf '%s' "$helpers" | grep -q '_certbot_supports_ip_address "\$candidate"' \
  || fail "установка не проверяет возможности certbot по факту"
# Вывод snap не должен попадать в stdout CLI: реальные вызовы пишут в лог-файл
# (комментарии и текст сообщений об ошибке — не в счёт).
if printf '%s\n' "$helpers" | grep -vE '^[[:space:]]*#' | grep -v 'echo' \
     | grep -E 'snap (install|refresh)' | grep -vq '/tmp/snap'; then
  fail "snap install/refresh пишет не в лог-файл (засорит stdout CLI)"
fi
grep -q '"--ip-address"' xrayebator || grep -q -- "'--ip-address'" xrayebator \
  || fail "_certbot_supports_ip_address не проверяет --ip-address"
grep -q -- '--preferred-profile' xrayebator || fail "нет проверки --preferred-profile"
pass "статика: один путь установки, ожидание snapd, повтор, проверка по факту"

# Функционально: различаем apt-certbot и certbot 5.4+.
mk_stub() { # <файл> <да/нет ip-address> <да/нет preferred-profile>
  {
    echo '#!/usr/bin/env bash'
    echo 'case "$1" in'
    echo '  --help)'
    echo '    echo "usage: certbot [options]"'
    [[ "$2" == "да" ]] && echo '    echo "  --ip-address IP   Request a certificate for an IP"'
    [[ "$3" == "да" ]] && echo '    echo "  --preferred-profile NAME"'
    echo '    ;;'
    echo '  --version) echo "certbot 5.9.0" ;;'
    echo 'esac'
  } > "$1"
  chmod +x "$1"
}

modern="$TMP_ROOT/certbot-new"
old="$TMP_ROOT/certbot-apt"
half="$TMP_ROOT/certbot-half"
mk_stub "$modern" да да
mk_stub "$old" нет нет
mk_stub "$half" да нет

_certbot_supports_ip_address "$modern" || fail "certbot 5.4+ не распознан"
_certbot_supports_ip_address "$old" && fail "apt-certbot ошибочно признан поддерживающим IP"
_certbot_supports_ip_address "$half" && fail "половинчатый certbot (без --preferred-profile) принят"
pass "функционально: certbot 5.4+ отличается от apt-версии и от половинчатого"

echo "✓ Certbot для IP через snap: единый путь, ожидание snapd, повтор, лог вместо stdout — OK"
