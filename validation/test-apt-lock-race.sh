#!/bin/bash
# Regression test: гонка apt-lock в quickstart (2026-09-23, Ubuntu 22.04).
# Корень: unattended-upgrades на свежеподнятом VPS вызывает dpkg отдельно на
# каждый пакет (~90 пакетов, ~10 минут); flock между пакетами свободен секунды,
# quickstart-овый apt стартовал в зазор и падал с «apt-get install nginx failed».
# Контракты:
#  1) существует APT_LOCK_OPTS с DPkg::Lock::Timeout и он подключён ко всем
#     `apt-get install` в xrayebator;
#  2) _apt_wait_lock учитывает активный процесс /usr/bin/unattended-upgrade
#     (по полному пути в cmdline, НЕ по comm — comm обрезается ядром до 15
#     символов и не отличает воркер от резидентного shutdown-helper'а);
#  3) бюджет первого ожидания в quickstart >= 12 минут (покрывает наблюдённый
#     прогон ~10 минут);
#  4) внешний timeout вокруг apt-install >= DPkg::Lock::Timeout (иначе kill
#     обрывает ожидание lock внутри apt и воспроизводит баг).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "✗ FAIL: $*" >&2
  exit 1
}

source_text=$(tr -d '\r' < xrayebator)

# 1) APT_LOCK_OPTS определён и подключён к каждой установке пакета.
grep -Fq 'APT_LOCK_OPTS=(-o "DPkg::Lock::Timeout=' <<< "$source_text" \
  || fail "APT_LOCK_OPTS с DPkg::Lock::Timeout не определён"

# Каждая строка фактического вызова «apt-get ... install» обязана нести
# "${APT_LOCK_OPTS[@]}" (echo-сообщения с текстом «apt-get install» не считаем).
while IFS= read -r line; do
  lineno=${line%%:*}
  grep -Fq -- '"${APT_LOCK_OPTS[@]}"' <<< "$line" \
    || fail "apt-get install без APT_LOCK_OPTS на строке $lineno: $line"
done < <(grep -n 'apt-get .*install' <<< "$source_text" | grep -v 'echo ' | grep -v ':\s*#')

# 2) Детект рабочего процесса unattended-upgrade по полному пути.
grep -Fq "pgrep -f '/usr/bin/unattended-upgrade" <<< "$source_text" \
  || fail "_apt_wait_lock не учитывает активный процесс unattended-upgrade"
if grep -Fq 'pgrep -x unattended-upgrade' <<< "$source_text"; then
  fail "найден pgrep -x unattended-upgrade: comm обрезается до 15 символов и не работает"
fi

# 3) quickstart: бюджет ожидания до первой установки nginx >= 720 секунд.
quickstart_block=$(sed -n '/^quickstart_command() {$/,/^happ_setup_command() {$/p' <<< "$source_text")
[[ -n "$quickstart_block" ]] || fail "quickstart_command block not found"
first_wait=$(grep -oE '_apt_wait_lock [0-9]+' <<< "$quickstart_block" | head -1 | grep -oE '[0-9]+')
[[ -n "$first_wait" && "$first_wait" -ge 720 ]] \
  || fail "quickstart: бюджет первого _apt_wait_lock = '${first_wait:-нет}' < 720 (прогон unattended ~10 мин)"

# 4) Внешний timeout вокруг обязательных nginx-install >= 300
#    (DPkg::Lock::Timeout=180 + время закачки/настройки; snapd-резервы не считаем).
while IFS=: read -r lineno line; do
  tmo=$(grep -oE 'timeout [0-9]+' <<< "$line" | grep -oE '[0-9]+' || true)
  [[ -n "$tmo" && "$tmo" -ge 300 ]] \
    || fail "строка $lineno: внешний timeout='${tmo:-нет}' < 300 обрезает Lock::Timeout=180: $line"
done < <(grep -n 'timeout [0-9]* apt-get .*install -y nginx' <<< "$quickstart_block")

echo "✓ apt-install защищены от гонки unattended-upgrades (опция+процесс+бюджет 12 мин)"
