#!/usr/bin/env bash
# Тест «Защита SSH от перебора» (fail2ban + лимиты sshd).
#
# Что проверяем: состав конфигов (журнал-бэкенд, порог бана, эскалация),
# СОХРАНЕНИЕ парольного входа (на нём держится GUI: он логинится по SSH-паролю),
# форму статус-JSON для GUI, снятие защиты, проводку в меню/CLI/установку/деплой
# и валидацию аргумента --unban.
#
# Пути переопределяются на временный каталог, поэтому тест не трогает систему.
set -u
cd "$(dirname "$0")/.."

fail() { echo "✗ $1"; exit 1; }
pass() { echo "✓ $1"; }

command -v jq >/dev/null 2>&1 || fail "jq required (CI installs it)"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export SSH_PROTECT_JAIL_FILE="$TMP_ROOT/fail2ban/jail.d/xrayebator-sshd.local"
export SSH_PROTECT_SSHD_FILE="$TMP_ROOT/ssh/sshd_config.d/99-xrayebator-hardening.conf"
export SSH_PROTECT_MARKER="$TMP_ROOT/.ssh_protect_2026"
export LOCK_FILE="$TMP_ROOT/xrayebator.lock"

# shellcheck disable=SC1091
source ./xrayebator || fail "source ./xrayebator failed"
[[ "$XRAYEBATOR_SOURCED" == "1" ]] || fail "source-mode guard not detected"

# --- 1. Конфиг джейла ----------------------------------------------------------
jail=$(_ssh_protect_jail_conf_pure)
grep -q '^backend = systemd' <<< "$jail" || fail "jail must read the journald backend"
grep -q '^maxretry = 4' <<< "$jail" || fail "jail must ban after 4 failures"
grep -q '^findtime = 10m' <<< "$jail" || fail "jail findtime must be 10m"
grep -q '^bantime = 30m' <<< "$jail" || fail "jail bantime must be 30m"
grep -q '^bantime.increment = true' <<< "$jail" \
  || fail "repeat offenders must get progressively longer bans"
grep -q '^\[sshd\]' <<< "$jail" || fail "jail must target [sshd]"
grep -q '^enabled = true' <<< "$jail" || fail "the sshd jail must be enabled"
# Защита включается автоматически, поэтому чужие джейлы fail2ban трогать нельзя:
# настройки обязаны быть внутри [sshd], а не в [DEFAULT].
if grep -q '^\[DEFAULT\]' <<< "$jail"; then
  fail "jail must not override [DEFAULT]: settings belong to the [sshd] section"
fi
section_line=$(grep -n '^\[' <<< "$jail" | head -1 | cut -d: -f1)
maxretry_line=$(grep -n '^maxretry = ' <<< "$jail" | head -1 | cut -d: -f1)
[[ -n "$section_line" && -n "$maxretry_line" && "$maxretry_line" -gt "$section_line" ]] \
  || fail "jail settings must be scoped inside the [sshd] section"
pass "jail bans after 4 failures for 30m and escalates repeat offenders"

# --- 1b. Исключение для адреса деплоя: 24 часа, затем снимается таймером -------
jail_ignore=$(_ssh_protect_jail_conf_pure "203.0.113.5" "1794000000")
grep -q '^ignoreip = 127\.0\.0\.1/8 ::1 203\.0\.113\.5$' <<< "$jail_ignore" \
  || fail "jail must exempt the deploy address via ignoreip"
grep -q '^# xrayebator-ignore-until: 1794000000$' <<< "$jail_ignore" \
  || fail "ignoreip must carry its expiry epoch"
if ! grep -q '^ignoreip = 127\.0\.0\.1/8 ::1$' <<< "$(_ssh_protect_jail_conf_pure)"; then
  fail "jail must always keep the loopback ignoreip baseline"
fi
pass "deploy address is exempted with an expiry stamp, not forever"

ip=$(SSH_CONNECTION="198.51.100.7 40000 203.0.113.10 22" _ssh_protect_client_ip) \
  || fail "client ip must be parsed from SSH_CONNECTION"
[[ "$ip" == "198.51.100.7" ]] || fail "SSH_CONNECTION parse gave '$ip'"
ip=$(SSH_CLIENT="198.51.100.8 40000 22" _ssh_protect_client_ip) \
  || fail "client ip must be parsed from SSH_CLIENT"
[[ "$ip" == "198.51.100.8" ]] || fail "SSH_CLIENT parse gave '$ip'"
if SSH_CONNECTION="127.0.0.1 50000 127.0.0.1 22" _ssh_protect_client_ip >/dev/null; then
  fail "loopback must not become an ignoreip entry"
fi
pass "deploy address comes from the SSH session, loopback is skipped"

# Просроченное исключение снимается, действующее остаётся.
_ssh_protect_reload_fail2ban() { :; }
_ssh_protect_remove_ignore_timer() { :; }
mkdir -p "$(dirname "$SSH_PROTECT_JAIL_FILE")" 2>/dev/null
_ssh_protect_jail_conf_pure "203.0.113.5" "1000" > "$SSH_PROTECT_JAIL_FILE"
if ! SSH_PROTECT_NOW=2000 _ssh_protect_prune_ignore; then
  fail "expired ignore must be pruned"
fi
if grep -q '203\.0\.113\.5' "$SSH_PROTECT_JAIL_FILE"; then
  fail "expired ignoreip must be removed from the jail"
fi
grep -q '^ignoreip = 127\.0\.0\.1/8 ::1$' "$SSH_PROTECT_JAIL_FILE" \
  || fail "loopback ignoreip must stay after pruning"
_ssh_protect_jail_conf_pure "203.0.113.5" "99999999999" > "$SSH_PROTECT_JAIL_FILE"
if SSH_PROTECT_NOW=2000 _ssh_protect_prune_ignore; then
  fail "active ignore must not be pruned"
fi
grep -q '^ignoreip' "$SSH_PROTECT_JAIL_FILE" || fail "active ignoreip must stay in the jail"
pass "expired exemption is removed, active one is kept"

# --- 2. Парольный вход остаётся ------------------------------------------------
if grep -qi 'PasswordAuthentication[[:space:]]*no' <<< "$jail"; then
  fail "jail must not disable password auth: the GUI logs in with an SSH password"
fi
if grep -qi 'PermitRootLogin' <<< "$jail"; then
  fail "jail must not touch PermitRootLogin: the GUI connects as root"
fi
sshd_conf=$(_ssh_protect_sshd_conf_pure)
if grep -qi 'PasswordAuthentication' <<< "$sshd_conf"; then
  fail "sshd drop-in must not touch PasswordAuthentication"
fi
grep -q '^MaxAuthTries 3$' <<< "$sshd_conf" || fail "sshd drop-in must set MaxAuthTries 3"
grep -q '^LoginGraceTime 30$' <<< "$sshd_conf" || fail "sshd drop-in must set LoginGraceTime 30"
pass "sshd limits narrow the brute-force window without disabling passwords"

# --- 3. Статус-JSON для GUI ----------------------------------------------------
status=$(_ssh_protect_status_json) || fail "_ssh_protect_status_json failed"
jq -e '.ok == true' <<< "$status" >/dev/null || fail "status.ok must be true"
for key in supported installed active enabled_at_boot sshd_hardened \
           max_auth_tries login_grace_time password_authentication \
           permit_root_login failed_24h banned_current banned_total \
           banned_ips ignore_ip ignore_until jail_file sshd_file; do
  jq -e "has(\"$key\")" <<< "$status" >/dev/null || fail "status has no '$key' field"
done
jq -e '.banned_ips | type == "array"' <<< "$status" >/dev/null \
  || fail "banned_ips must be a JSON array"
jq -e '.failed_24h | type == "number"' <<< "$status" >/dev/null \
  || fail "failed_24h must be a number"
pass "status JSON carries every field the GUI renders"

# --- 4. Выключение снимает файлы и маркер --------------------------------------
mkdir -p "$(dirname "$SSH_PROTECT_JAIL_FILE")" "$(dirname "$SSH_PROTECT_SSHD_FILE")"
printf '[sshd]\nenabled = true\n' > "$SSH_PROTECT_JAIL_FILE"
printf 'MaxAuthTries 3\n' > "$SSH_PROTECT_SSHD_FILE"
: > "$SSH_PROTECT_MARKER"
_ssh_protect_disable || fail "_ssh_protect_disable failed"
[[ -f "$SSH_PROTECT_JAIL_FILE" ]] && fail "disable must remove the jail config"
[[ -f "$SSH_PROTECT_SSHD_FILE" ]] && fail "disable must remove the sshd drop-in"
[[ -f "$SSH_PROTECT_MARKER" ]] && fail "disable must remove the marker"
pass "disable removes the jail, the sshd drop-in and the marker"

# --- 5. Проводка: меню, CLI, установка, деплой --------------------------------
grep -q '15) ssh_protect_menu ;;' xrayebator || fail "main menu has no security entry"
grep -q 'ssh-protect)' xrayebator || fail "CLI dispatch has no ssh-protect action"
grep -q 'ssh_protect_command "\$@"' xrayebator || fail "ssh-protect is not dispatched"
quickstart_block=$(sed -n '/^quickstart_command() {$/,/^happ_setup_command() {$/p' xrayebator)
grep -q '_ssh_protect_auto_enable' <<< "$quickstart_block" \
  || fail "quickstart does not enable SSH protection"
grep -q 'ssh_protect:\$ssh_protect' <<< "$quickstart_block" \
  || fail "quickstart JSON does not report ssh_protect (degraded branch)"
grep -q 'ssh-protect --enable --quiet' install.sh \
  || fail "install.sh does not enable SSH protection"
grep -q 'ssh-protect' uninstall.sh 2>/dev/null || true
grep -q -- '--prune-ignore' xrayebator || fail "CLI must expose --prune-ignore"
grep -q '_ssh_protect_install_ignore_timer' xrayebator \
  || fail "enable must install the 24h exemption timer"
grep -q 'xrayebator-ssh-ignoreip.timer' xrayebator || fail "timer unit name is missing"
# Относительное OnUnitActiveSec после пересоздания таймера давало
# next_elapse=infinity (таймер замолкал) — расписание должно быть календарным.
grep -q 'OnCalendar=\*:0/30' xrayebator \
  || fail "prune timer must use a wall-clock OnCalendar schedule"
pass "wired into main menu, CLI, quickstart and install.sh"

# --- 6. --unban валидирует адрес и отвечает JSON -------------------------------
out=$(ssh_protect_command --unban 'not-an-ip' 2>/dev/null)
rc=$?
[[ $rc -eq 2 ]] || fail "--unban must reject a non-IP argument (rc=$rc)"
jq -e '.ok == false' <<< "$out" >/dev/null || fail "--unban rejection must be JSON"
pass "--unban validates its argument and answers with JSON"

echo "✓ SSH brute-force protection: configs, status, wiring and CLI are consistent"
