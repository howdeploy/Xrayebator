#!/usr/bin/env bash
# Тест «Защита ядра» (CVE-2026-98432: MPTCP и пакеты с IPv4-опциями).
#
# Что проверяем:
#  - состав sysctl-файла (MPTCP выключается, ключ именно net.mptcp.enabled);
#  - nft-правило дословно из рекомендации Ubuntu Security Team (IHL > 5, приоритет
#    -310, hook input) и то, что в юните НЕТ `flush ruleset` — иначе автозагрузка
#    снесла бы правила UFW;
#  - определение «на диске есть ядро новее запущенного» (сигнал, что фикс ядра
#    установлен, но не активен) без захардкоженных таблиц версий;
#  - сравнение версий Xray-core (10#, чтобы «26.08.1» не читалось как восьмеричное);
#  - включение/выключение защиты на подставных nft/sysctl (систему не трогаем);
#  - JSON-контракт `kernel-guard --status` (stdout — только JSON);
#  - проводку: меню/диспетчер/миграцию в main_menu и quickstart/uninstall.
#
# Пути и бинарники переопределяются на временный каталог, поэтому тест безопасен
# и на живой машине.
set -u
cd "$(dirname "$0")/.."

fail() { echo "✗ $1"; exit 1; }
pass() { echo "✓ $1"; }

command -v jq >/dev/null 2>&1 || fail "jq required (CI installs it)"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export LOCK_FILE="$TMP_ROOT/xrayebator.lock"
export NETGUARD_MPTCP_SYSCTL_FILE="$TMP_ROOT/sysctl.d/99-xrayebator-netguard.conf"
export NETGUARD_NFT_DIR="$TMP_ROOT/xrayebator/netguard"
export NETGUARD_NFT_FILE="$TMP_ROOT/xrayebator/netguard/cve-2026-98432.nft"
export NETGUARD_UNIT_FILE="$TMP_ROOT/systemd/xrayebator-netguard.service"
export NETGUARD_PROC_ROOT="$TMP_ROOT/proc"
export NETGUARD_BOOT_DIR="$TMP_ROOT/boot"
mkdir -p "$NETGUARD_PROC_ROOT/net/mptcp" "$NETGUARD_BOOT_DIR" "$TMP_ROOT/systemd"
printf '1\n' > "$NETGUARD_PROC_ROOT/net/mptcp/enabled"

# shellcheck disable=SC1091
source ./xrayebator || fail "source ./xrayebator failed"
[[ "$XRAYEBATOR_SOURCED" == "1" ]] || fail "source-mode guard not detected"

# --- 1. sysctl: MPTCP выключается ------------------------------------------------
conf=$(_netguard_mptcp_conf_pure)
grep -q '^net\.mptcp\.enabled = 0$' <<< "$conf" \
  || fail "sysctl-файл должен выключать net.mptcp.enabled"
grep -q 'CVE-2026-98432' <<< "$conf" || fail "в sysctl-файле должна быть причина (CVE)"
pass "sysctl выключает MPTCP и объясняет причину"

# --- 2. nft-правило: дроп пакетов с IPv4-опциями ---------------------------------
rules=$(_netguard_nft_ruleset_pure)
grep -q 'table inet cve_2026_98432' <<< "$rules" || fail "таблица cve_2026_98432 не объявлена"
grep -q 'type filter hook input priority -310' <<< "$rules" \
  || fail "правило должно стоять до filter-хука UFW (priority -310)"
grep -q 'ip protocol tcp ip hdrlength > 5 counter drop' <<< "$rules" \
  || fail "правило дропа должно быть дословно как у Ubuntu: ip hdrlength > 5"
grep -q 'policy accept' <<< "$rules" \
  || fail "политика цепочки обязана быть accept: мы дропаем только IPv4-опции"
if grep -qi 'flush' <<< "$rules"; then
  fail "в правилах не должно быть flush: он снёс бы чужие таблицы"
fi
pass "nft дропает только IPv4-пакеты с IP-опциями"

# --- 3. Юнит автозагрузки ---------------------------------------------------------
unit=$(_netguard_unit_pure /usr/sbin/nft)
grep -q '^Type=oneshot$' <<< "$unit" || fail "юнит должен быть oneshot"
grep -q '^RemainAfterExit=yes$' <<< "$unit" || fail "юнит должен оставаться активным"
grep -qF "ExecStart=/usr/sbin/nft -f $NETGUARD_NFT_FILE" <<< "$unit" \
  || fail "юнит должен грузить именно наш файл правил"
# Живая находка 2026-11-03: `nft -f` НЕ заменяет существующую таблицу, а
# дописывает правило в неё. Без удаления перед загрузкой активация юнита после
# `kernel-guard --enable` оставляла в цепочке два одинаковых правила дропа.
grep -qF "ExecStartPre=-/usr/sbin/nft delete table inet cve_2026_98432" <<< "$unit" \
  || fail "юнит обязан удалять таблицу перед загрузкой (иначе правило дублируется)"
grep -qF "ExecReload=-/usr/sbin/nft delete table inet cve_2026_98432" <<< "$unit" \
  || fail "reload тоже должен удалять таблицу перед загрузкой"
if grep -q '^ExecStartPre=[^-]' <<< "$unit"; then
  fail "ExecStartPre для delete обязана быть с минусом: на свежей загрузке таблицы ещё нет"
fi
grep -q '^Before=network-pre.target' <<< "$unit" \
  || fail "правило должно вставать до сети, иначе окно без фильтра"
if grep -qi 'flush' <<< "$unit"; then
  fail "юнит не должен делать flush ruleset (снёс бы правила UFW при загрузке)"
fi
pass "автозагрузка поднимает только нашу таблицу, без flush"

# --- 4. Ядро новее запущенного ----------------------------------------------------
if printf '5.15.0-198-generic\n5.15.0-203-generic\n' \
     | _netguard_newer_kernel_pure "5.15.0-198-generic"; then
  pass "ядро новее запущенного определяется"
else
  fail "должно определяться установленное, но не загруженное ядро"
fi
if printf '5.15.0-198-generic\n' | _netguard_newer_kernel_pure "5.15.0-198-generic"; then
  fail "единственное запущенное ядро не является «новее»"
fi
if printf '\n' | _netguard_newer_kernel_pure "5.15.0-198-generic"; then
  fail "пустой список ядер не должен давать «новее»"
fi
pass "список ядер не даёт ложного «ребут нужен»"

# --- 5. Сравнение версий ----------------------------------------------------------
_xray_version_at_least_pure "26.10.31" "26.10.31" || fail "равные версии должны проходить"
_xray_version_at_least_pure "26.10.32" "26.10.31" || fail "более новая версия должна проходить"
_xray_version_at_least_pure "27.0.0" "26.10.31" || fail "мажор должен проходить"
if _xray_version_at_least_pure "26.3.27" "26.10.31"; then
  fail "26.3.27 не может считаться свежее 26.10.31"
fi
if _xray_version_at_least_pure "" "26.10.31"; then
  fail "пустая версия не может проходить сравнение"
fi
# Ведущий ноль: без 10# bash прочитал бы 08 как восьмеричное и уронил сравнение.
_xray_version_at_least_pure "26.08.1" "26.7.28" || fail "ведущий ноль в версии ломает сравнение"
pass "версии сравниваются как десятичные числа"

# --- 6. Подставные nft/sysctl: включение и выключение ------------------------------
cat > "$TMP_ROOT/nft" <<'EOF'
#!/usr/bin/env bash
last="${!#}"
case "$1" in
  list)  [[ -f "$FAKE_NFT_STATE" ]] && echo "table inet cve_2026_98432"; exit 0 ;;
  -c)    [[ -f "$last" ]] || exit 1
         grep -q 'hdrlength > 5 counter drop' "$last" || exit 1
         exit 0 ;;
  -f)    cp "$last" "$FAKE_NFT_STATE" ;;
  delete) rm -f "$FAKE_NFT_STATE" ;;
esac
exit 0
EOF
cat > "$TMP_ROOT/sysctl" <<'EOF'
#!/usr/bin/env bash
last="${!#}"
case "$last" in
  net.mptcp.enabled=*) printf '%s\n' "${last#*=}" > "$FAKE_MPTCP_PROC" ;;
esac
exit 0
EOF
chmod +x "$TMP_ROOT/nft" "$TMP_ROOT/sysctl"
export NETGUARD_NFT_BIN="$TMP_ROOT/nft"
export NETGUARD_SYSCTL_BIN="$TMP_ROOT/sysctl"
export FAKE_NFT_STATE="$TMP_ROOT/nft.table"
export FAKE_MPTCP_PROC="$NETGUARD_PROC_ROOT/net/mptcp/enabled"

_netguard_disable_mptcp || fail "выключение MPTCP должно проходить"
[[ "$(_netguard_mptcp_value)" == "0" ]] || fail "MPTCP должен стать 0"
[[ -f "$NETGUARD_MPTCP_SYSCTL_FILE" ]] || fail "sysctl-файл должен появиться"

_netguard_apply_nft || fail "nft-правило должно примениться на подставном nft"
[[ -f "$NETGUARD_NFT_FILE" ]] || fail "файл правил должен быть записан"
_netguard_nft_table_present || fail "таблица должна считаться загруженной"
[[ -f "$NETGUARD_UNIT_FILE" ]] || fail "юнит автозагрузки должен быть создан"

tmp_status=$(_netguard_status_json)
echo "$tmp_status" | jq -e . >/dev/null 2>&1 || fail "статус должен быть валидным JSON"
[[ "$(jq -r '.mptcp_enabled' <<< "$tmp_status")" == "false" ]] \
  || fail "в статусе MPTCP должен быть выключен"
[[ "$(jq -r '.ipv4_options_drop' <<< "$tmp_status")" == "true" ]] \
  || fail "в статусе дроп IPv4-опций должен быть включён"
[[ "$(jq -r '.unit_present' <<< "$tmp_status")" == "true" ]] \
  || fail "юнит должен быть виден в статусе"
pass "включение выключает MPTCP и ставит правило"

_netguard_disable || fail "выключение защиты должно проходить"
[[ "$(_netguard_mptcp_value)" == "1" ]] || fail "MPTCP должен вернуться в 1"
[[ ! -f "$NETGUARD_MPTCP_SYSCTL_FILE" ]] || fail "sysctl-файл должен быть удалён"
[[ ! -f "$NETGUARD_UNIT_FILE" ]] || fail "юнит должен быть удалён"
if _netguard_nft_table_present; then
  fail "таблица должна быть снята"
fi
pass "выключение возвращает дефолты"

# --- 7. Без nft защита честно сообщает о частичном успехе --------------------------
export NETGUARD_NFT_BIN="$TMP_ROOT/nft-missing"
rm -f "$NETGUARD_MPTCP_SYSCTL_FILE"
_netguard_enable
rc=$?
[[ $rc -eq 2 ]] || fail "без nft ожидался код 2 (частично), получен $rc"
json=$(kernel_guard_command --enable 2>/dev/null) || fail "команда --enable не должна падать без nft"
jq -e '.ok == true and .partial == true' <<< "$json" >/dev/null 2>&1 \
  || fail "--enable без nft должен отдавать partial:true: $json"
export NETGUARD_NFT_BIN="$TMP_ROOT/nft"

# --- 8. JSON-контракт CLI ---------------------------------------------------------
_netguard_enable >/dev/null 2>&1 || fail "повторное включение должно проходить"
status_json=$(kernel_guard_command --status 2>/dev/null) || fail "--status вернул ошибку"
jq -e '.ok == true and .cve == "CVE-2026-98432" and .cvss == 9.8' <<< "$status_json" >/dev/null 2>&1 \
  || fail "--status должен отдавать ok/cve/cvss: $status_json"
jq -e 'has("reboot_required") and has("xray_mptcp_safe") and has("xray_mptcp_safe_version")' \
  <<< "$status_json" >/dev/null 2>&1 || fail "в статусе не хватает полей"
# Версия «безопасного» Xray фиксирует нижнюю границу из PR #7291.
[[ "$(jq -r '.xray_mptcp_safe_version' <<< "$status_json")" == "26.10.31" ]] \
  || fail "нижняя безопасная версия Xray-core должна быть 26.10.31"
out=$(kernel_guard_command --status 2>/dev/null | jq -c .)
if echo "$out" | grep -qv '^{'; then
  fail "stdout команды должен содержать только JSON"
fi
if kernel_guard_command --bogus >/dev/null 2>&1; then
  fail "неизвестный аргумент должен отвергаться"
fi
pass "CLI отдаёт только JSON и валидирует аргументы"

# --- 9. Проводка: меню, диспетчер, миграция, uninstall ----------------------------
grep -q 'kernel-guard)' xrayebator || fail "диспетчер не знает команду kernel-guard"
grep -q '^ *16) kernel_guard_menu ;;$' xrayebator || fail "пункт меню 16 не подключён"
grep -q 'Защита ядра (CVE-2026-98432' xrayebator || fail "пункт 16 не описан в меню"
grep -q 'run_migration "netguard_mptcp_2026"' xrayebator \
  || fail "миграция netguard_mptcp_2026 не зарегистрирована"
main_count=$(grep -c 'run_migration "netguard_mptcp_2026"' xrayebator)
[[ "$main_count" -ge 3 ]] \
  || fail "миграция должна быть в main_menu, quickstart и happ-setup (найдено $main_count)"
grep -q 'xrayebator-netguard.service' uninstall.sh || fail "uninstall не снимает юнит защиты ядра"
grep -q 'cve_2026_98432' uninstall.sh || fail "uninstall не снимает nft-таблицу"
grep -q '99-xrayebator-netguard.conf' uninstall.sh || fail "uninstall не удаляет sysctl-файл"
# Миграция не должна дёргать перезапуск Xray: она правит sysctl, а не config.json.
if grep -q 'safe_restart_xray' <<< "$(sed -n '/_migrate_netguard_mptcp_2026()/,/^}/p' xrayebator)"; then
  fail "миграция не должна перезапускать Xray"
fi
pass "меню, диспетчер, миграция и uninstall подключены"

echo "✅ test-kernel-guard: все проверки пройдены"
