#!/usr/bin/env bash
# test-alerts-monitor.sh
# Тестирует Telegram-алерты мониторинга сервера (срез F2):
#   alerts-setup (валидация токена/chat_id, getMe, тестовая доставка ДО
#   сохранения конфига, установка таймера), alerts-status/enable/disable,
#   monitor-check (детекция сервисов, агрегаты сроков и лимитов трафика,
#   edge-триггер перезагрузки, дедупликация, напоминания, восстановления,
#   повтор при ошибке отправки) и статические инварианты (регистрации
#   миграции, unit'ы, uninstall, пункт меню 14).
# Гарантии:
#   - stdout CLI содержит ТОЛЬКО JSON; токен не печатается;
#   - конфиг alerts.json не сохраняется, если тестовая доставка не прошла;
#   - при ошибке отправки состояние события не фиксируется (retry);
#   - повторный алерт об одном событии — только по ALERTS_REMIND_SEC.
#
# Usage:  bash validation/test-alerts-monitor.sh
# Requires: jq, bash 4+.

set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORKDIR=$(mktemp -d /tmp/xrayebator-alerts.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

source "$REPO_ROOT/xrayebator"

# --- Изоляция путей ---
BACKENDS_ROOT="$WORKDIR/neutral"
BACKENDS_REGISTRY_FILE="$WORKDIR/neutral/backends.json"
ALERTS_FILE="$WORKDIR/alerts.json"
ALERTS_STATE_FILE="$WORKDIR/monitor-state.json"
PROFILES_DIR="$WORKDIR/profiles"
MONITOR_SERVICE_FILE="$WORKDIR/systemd/xrayebator-monitor.service"
MONITOR_TIMER_FILE="$WORKDIR/systemd/xrayebator-monitor.timer"
mkdir -p "$PROFILES_DIR" "$WORKDIR/systemd" "$BACKENDS_ROOT"
TELEGRAM_API_BASE="http://telegram.stub"

# --- Изоляция подписки и бэкендов (точки подмены монитора) ---
SUB_STATE_DIR="$WORKDIR/xray-state"
XRAY_SUB_INSTALLED="$SUB_STATE_DIR/.subscription_installed"
XRAY_SUB_MODE_FILE="$SUB_STATE_DIR/.subscription_mode"
mkdir -p "$SUB_STATE_DIR"
_monitor_sub_dir() { echo "$SUB_STATE_DIR"; }
AWG_UP_FILE="$WORKDIR/awg-up"
_monitor_awg_up() { [[ -f "$AWG_UP_FILE" ]]; }
SNI_OK_FILE="$WORKDIR/sni-ok"
SNI_PROBE_LOG="$WORKDIR/sni-probe.log"
: > "$SNI_OK_FILE"
: > "$SNI_PROBE_LOG"
_monitor_sni_reachable() {
  echo "$1" >> "$SNI_PROBE_LOG"
  grep -qx "$1" "$SNI_OK_FILE" 2>/dev/null
}
SUB_PROBE_FAIL=""

# --- Стаб systemctl: состояние сервисов в SVC_STATE ("active/dot" строки) ---
SVC_STATE="$WORKDIR/svc-state"
: > "$SVC_STATE"
FAIL_SYSTEMCTL=""
chown() { return 0; }
systemctl() {
  local sub="${1:-}"
  shift || true
  [[ "${1:-}" == "--quiet" ]] && shift
  case "$sub" in
    is-active) grep -qx "active ${1:-}" "$SVC_STATE" 2>/dev/null ;;
    is-enabled) grep -qx "enabled ${1:-}" "$SVC_STATE" 2>/dev/null ;;
    daemon-reload) [[ -z "$FAIL_SYSTEMCTL" ]] ;;
    *) return 0 ;;
  esac
}
# svc_set unit on|off [enabled]
svc_set() {
  local unit="$1" act="$2" en="${3:-}"
  grep -v -e "^active $unit\$" -e "^enabled $unit\$" "$SVC_STATE" > "$SVC_STATE.tmp" || true
  mv "$SVC_STATE.tmp" "$SVC_STATE"
  [[ "$act" == "on" ]] && echo "active $unit" >> "$SVC_STATE"
  [[ "$en" == "enabled" ]] && echo "enabled $unit" >> "$SVC_STATE"
  return 0
}

# --- Стаб curl: логирует ТОЛЬКО отправки в чат (лог = «что реально ушло»);
# CURL_FAIL_MATCH — что «ломать»; поддержаны -o/-w (проба подписки);
# SUB_PROBE_FAIL — имитация упавшего loopback-хендлера подписки.
CURL_LOG="$WORKDIR/curl.log"
: > "$CURL_LOG"
CURL_FAIL_MATCH=""
curl() {
  local -a argv=("$@")
  local a url="" text="" out_file="" fmt="" body="" code="200" i
  for ((i = 0; i < ${#argv[@]}; i++)); do
    a="${argv[i]}"
    case "$a" in
      text=*) text="${a#text=}" ;;
      -o) out_file="${argv[i + 1]:-}" ;;
      -w) fmt="${argv[i + 1]:-}" ;;
      http*) url="$a" ;;
    esac
  done
  if [[ -n "$CURL_FAIL_MATCH" && "$url" == *"$CURL_FAIL_MATCH"* ]]; then
    echo '{"ok":false,"error_code":400,"description":"stub failure"}'
    return 0
  fi
  [[ -n "$text" ]] && printf '%s\t%s\n' "$url" "$text" >> "$CURL_LOG"
  case "$url" in
    */getMe) body='{"ok":true,"result":{"username":"test_bot"}}' ;;
    */sendMessage) body='{"ok":true,"result":{"message_id":1}}' ;;
    */sub/*)
      if [[ -n "$SUB_PROBE_FAIL" ]]; then
        code="503"
        body='{"error":"handler down"}'
      else
        body='vless://11111111-2222-3333-4444-555555555555@203.0.113.10:443?type=tcp#p'
      fi
      ;;
    *)
      code="404"
      body='{"ok":false,"description":"not found"}'
      ;;
  esac
  if [[ -n "$out_file" ]]; then
    printf '%s\n' "$body" > "$out_file"
  else
    printf '%s\n' "$body"
  fi
  [[ -n "$fmt" ]] && printf '%s' "$code"
  return 0
}

# --- Стаб boot_id (эмуляция перезагрузки) ---
BOOT_ID_FILE="$WORKDIR/boot_id"
echo "boot-1" > "$BOOT_ID_FILE"
_monitor_boot_id() { cat "$BOOT_ID_FILE"; }

assert_json() {
  local json="$1" expr="$2" msg="$3"
  jq -e "$expr" <<< "$json" >/dev/null || fail "$msg: $json"
}
assert_no_ansi() {
  [[ "$1" != *$'\033'* ]] || fail "stdout содержит ANSI-цвета: $2"
}
assert_log() {
  grep -qF -- "$1" "$CURL_LOG" || fail "нет в логе отправок: $1 ($2)"
}
assert_log_absent() {
  ! grep -qF -- "$1" "$CURL_LOG" || fail "неожиданно в логе отправок: $1 ($2)"
}

TOKEN="123456789:AAHtesttoken0123456789abcdefghij"
CHAT_ID="-1001234567890"

# ═══════════ 1. Статические инварианты ═══════════
[[ "$(grep -c 'run_migration "alerts_monitor_2026"' xrayebator)" == "3" ]] \
  || fail "alerts_monitor_2026 должен быть зарегистрирован в main_menu+quickstart+happ-setup"
grep -qF '14) telegram_alerts_menu ;;' xrayebator || fail "нет пункта меню 14"
grep -qF '${CYAN}14)${NC} Уведомления в Telegram' xrayebator || fail "нет отображения пункта 14"
grep -qF 'ExecStart=/usr/local/bin/xrayebator monitor-check' xrayebator || fail "нет ExecStart монитора"
grep -qF 'OnUnitActiveSec=15min' xrayebator || fail "нет 15-минутного интервала монитора"
grep -qF 'xrayebator-monitor.timer' uninstall.sh || fail "uninstall не снимает monitor-timer"
grep -qF 'rm -rf /usr/local/etc/xrayebator' uninstall.sh || fail "uninstall не чистит нейтральный корень (токен!)"
grep -qF 'alerts-setup --token T --chat-id C' xrayebator || fail "нет help-строки alerts-setup"

# ═══════════ 2. monitor-check до настройки ═══════════
OUT=$(monitor_check_command)
assert_no_ansi "$OUT" "monitor-check (не настроен)"
assert_json "$OUT" '.ok == true and .enabled == false and .skipped == true' \
  "monitor-check без настройки должен быть skipped"

OUT=$(alerts_status_command)
assert_json "$OUT" '.ok == true and .configured == false and .timer_installed == false' \
  "alerts-status до настройки"

# ═══════════ 3. alerts-setup: валидация ═══════════
OUT=$(alerts_setup_command --token "bad" --chat-id "$CHAT_ID") || true
assert_json "$OUT" '.ok == false and (.error | length > 0)' "невалидный токен"

OUT=$(alerts_setup_command --token "$TOKEN" --chat-id "not-a-number") || true
assert_json "$OUT" '.ok == false' "невалидный chat_id"

OUT=$(alerts_setup_command --token "$TOKEN") || true
assert_json "$OUT" '.ok == false' "без chat-id"

CURL_FAIL_MATCH="getMe"
OUT=$(alerts_setup_command --token "$TOKEN" --chat-id "$CHAT_ID") || true
assert_json "$OUT" '.ok == false' "getMe fail должен отклонять настройку"
CURL_FAIL_MATCH=""

# Тестовая доставка не прошла → конфиг НЕ сохраняется
CURL_FAIL_MATCH="sendMessage"
OUT=$(alerts_setup_command --token "$TOKEN" --chat-id "$CHAT_ID") || true
assert_json "$OUT" '.ok == false and (.error | length > 0)' "send fail должен отклонять настройку"
[[ ! -f "$ALERTS_FILE" ]] || fail "alerts.json не должен сохраняться при недоставленном тесте"
CURL_FAIL_MATCH=""

# Успешная настройка
OUT=$(alerts_setup_command --token "$TOKEN" --chat-id "$CHAT_ID") || true
assert_no_ansi "$OUT" "alerts-setup"
assert_json "$OUT" '.ok == true and .test_sent == true and .timer_installed == true and .bot_username == "test_bot" and .chat_id == "-1001234567890"' \
  "alerts-setup успех"
[[ "$OUT" != *"$TOKEN"* ]] || fail "токен не должен печататься в stdout"
[[ -f "$ALERTS_FILE" ]] || fail "alerts.json не создан"
[[ "$(stat -c '%a' "$ALERTS_FILE")" == "600" ]] || fail "alerts.json должен быть 0600"
assert_json "$(cat "$ALERTS_FILE")" '.enabled == true and .token == "'"$TOKEN"'" and .chat_id == "-1001234567890"' \
  "содержимое alerts.json"

# ═══════════ 4. Unit'ы таймера ═══════════
[[ -f "$MONITOR_SERVICE_FILE" && -f "$MONITOR_TIMER_FILE" ]] || fail "unit-файлы не созданы"
grep -qF 'ExecStart=/usr/local/bin/xrayebator monitor-check' "$MONITOR_SERVICE_FILE" || fail "service ExecStart"
grep -qF 'TimeoutStartSec=300' "$MONITOR_SERVICE_FILE" || fail "service TimeoutStartSec (SNI-проба длиннее дефолтных 90 с)"
grep -qF 'OnBootSec=5min' "$MONITOR_TIMER_FILE" || fail "timer OnBootSec"
grep -qF 'OnUnitActiveSec=15min' "$MONITOR_TIMER_FILE" || fail "timer OnUnitActiveSec"

RC=0; _install_monitor_timer || RC=$?
[[ $RC -eq 0 ]] || fail "повторный _install_monitor_timer без enabled должен переустанавливать (rc=0), got $RC"
svc_set xrayebator-monitor.timer on enabled
RC=0; _install_monitor_timer || RC=$?
[[ $RC -eq 1 ]] || fail "no-op при установленном+включённом таймере (rc=1), got $RC"
RC=0; _migrate_alerts_monitor_2026 || RC=$?
[[ $RC -eq 1 ]] || fail "миграция при готовом таймере — no-op (rc=1), got $RC"

FAIL_SYSTEMCTL="1"
svc_set xrayebator-monitor.timer off
rm -f "$MONITOR_TIMER_FILE"
RC=0; _install_monitor_timer || RC=$?
[[ $RC -eq 2 ]] || fail "фалл daemon-reload → rc=2, got $RC"
RC=0; _migrate_alerts_monitor_2026 || RC=$?
[[ $RC -eq 2 ]] || fail "миграция при фалле — rc=2, got $RC"
FAIL_SYSTEMCTL=""
# Восстанавливаем таймер для дальнейших проверок
RC=0; _install_monitor_timer || RC=$?
[[ $RC -le 1 ]] || fail "восстановление таймера, got $RC"
svc_set xrayebator-monitor.timer on enabled

# ═══════════ 5. alerts-status после настройки; enable/disable ═══════════
OUT=$(alerts_status_command)
assert_json "$OUT" '.configured == true and .enabled == true and .bot_username == "test_bot" and .chat_id == "-1001234567890" and .timer_installed == true and .timer_active == true' \
  "alerts-status после настройки"
[[ "$OUT" != *"$TOKEN"* ]] || fail "alerts-status не должен показывать токен"

OUT=$(alerts_disable_command)
assert_json "$OUT" '.ok == true and .enabled == false' "alerts-disable"
assert_json "$(cat "$ALERTS_FILE")" '.enabled == false' "alerts.json после disable"

OUT=$(monitor_check_command)
assert_json "$OUT" '.skipped == true' "monitor-check при выключенных алертах"

OUT=$(alerts_enable_command)
assert_json "$OUT" '.ok == true and .enabled == true' "alerts-enable"

# ═══════════ 6. monitor-check: сервис упал и восстановился ═══════════
: > "$CURL_LOG"
svc_set xray.service off
OUT=$(monitor_check_command)
assert_no_ansi "$OUT" "monitor-check (svc down)"
assert_json "$OUT" '.sent | index("svc_xray") != null' "падение xray должно быть в sent"
assert_json "$OUT" '.recovered == [] and .failed == []' "без recovered/failed"
assert_log "xray.service не работает" "текст bad-алерта"
assert_json "$(cat "$ALERTS_STATE_FILE")" '.events.svc_xray.state == "bad"' "состояние svc_xray"
[[ "$(jq -r '.boot_id' "$ALERTS_STATE_FILE")" == "boot-1" ]] || fail "boot_id должен фиксироваться"

# Дедупликация: то же состояние — тишина
: > "$CURL_LOG"
OUT=$(monitor_check_command)
assert_json "$OUT" '.sent == [] and .recovered == [] and .failed == []' "дедуп: повтор не шлётся"
[[ ! -s "$CURL_LOG" ]] || fail "при дедупе не должно быть отправок"

# Напоминание по ALERTS_REMIND_SEC
ALERTS_REMIND_SEC=0
OUT=$(monitor_check_command)
ALERTS_REMIND_SEC=86400
assert_json "$OUT" '.sent | index("svc_xray") != null' "напоминание должно отправляться"
assert_log "напоминание" "текст напоминания"

# Восстановление
: > "$CURL_LOG"
svc_set xray.service on
OUT=$(monitor_check_command)
assert_json "$OUT" '.recovered | index("svc_xray") != null' "восстановление xray"
assert_log "xray.service снова работает" "текст recovery"

# nginx: не включён — не отслеживается; включён и упал — отслеживается
: > "$CURL_LOG"
svc_set nginx.service off
OUT=$(monitor_check_command)
assert_json "$OUT" '.sent == [] and .recovered == []' "выключенный nginx не отслеживается"
svc_set nginx.service off enabled
OUT=$(monitor_check_command)
assert_json "$OUT" '.sent | index("svc_nginx") != null' "включённый nginx отслеживается"
: > "$CURL_LOG"
svc_set nginx.service on enabled
OUT=$(monitor_check_command)
assert_json "$OUT" '.recovered | index("svc_nginx") != null' "восстановление nginx"

# ═══════════ 7. Профили: сроки (агрегат) ═══════════
NOW=$(date +%s)
jq -n --argjson e "$((NOW + 86400))" '{name:"p_soon", expire:$e}' > "$PROFILES_DIR/p_soon.json"
: > "$CURL_LOG"
OUT=$(monitor_check_command)
assert_json "$OUT" '.sent | index("profiles_expiry") != null' "истекающий профиль"
assert_log "p_soon" "имя профиля в алерте сроков"
assert_log "истекают" "заголовок алерта сроков"

# Агрегат: смена подписи (добавился отключённый) → новый алерт
jq -n --argjson e "$((NOW - 3600))" '{name:"p_old", expire:$e, expire_disabled:true}' > "$PROFILES_DIR/p_old.json"
: > "$CURL_LOG"
OUT=$(monitor_check_command)
assert_json "$OUT" '.sent | index("profiles_expiry") != null' "смена подписи → повторный алерт"
assert_log "p_old" "отключённый по сроку в алерте"
assert_log "отключены по сроку" "заголовок expired"

# Всё вернулось в норму → recovery
: > "$CURL_LOG"
rm -f "$PROFILES_DIR/p_soon.json" "$PROFILES_DIR/p_old.json"
OUT=$(monitor_check_command)
assert_json "$OUT" '.recovered | index("profiles_expiry") != null' "recovery сроков"
assert_log "сроки профилей в порядке" "текст recovery сроков"

# ═══════════ 8. Профили: лимиты трафика (агрегат) ═══════════
jq -n '{name:"p_lim", traffic_disabled:true}' > "$PROFILES_DIR/p_lim.json"
: > "$CURL_LOG"
OUT=$(monitor_check_command)
assert_json "$OUT" '.sent | index("traffic_limited") != null' "отключённый по лимиту"
assert_log "p_lim" "имя профиля в алерте лимитов"
: > "$CURL_LOG"
jq -n '{name:"p_lim", traffic_disabled:false}' > "$PROFILES_DIR/p_lim.json"
OUT=$(monitor_check_command)
assert_json "$OUT" '.recovered | index("traffic_limited") != null' "recovery лимитов"
assert_log "лимиты трафика в порядке" "текст recovery лимитов"
rm -f "$PROFILES_DIR/p_lim.json"

# ═══════════ 9. Перезагрузка сервера (edge-триггер) ═══════════
echo "boot-2" > "$BOOT_ID_FILE"
: > "$CURL_LOG"
OUT=$(monitor_check_command)
assert_json "$OUT" '.sent | index("reboot") != null' "смена boot_id → reboot-алерт"
assert_log "сервер перезапущен" "текст reboot"
: > "$CURL_LOG"
OUT=$(monitor_check_command)
assert_json "$OUT" '.sent == []' "повторный запуск после reboot — тишина"
[[ ! -s "$CURL_LOG" ]] || fail "reboot не должен повторяться"

# ═══════════ 10. Ошибка отправки → failed + retry на следующем запуске ═══════════
svc_set nginx.service off enabled
CURL_FAIL_MATCH="sendMessage"
OUT=$(monitor_check_command)
assert_json "$OUT" '.failed | index("svc_nginx") != null' "фалл отправки должен попасть в failed"
assert_json "$(cat "$ALERTS_STATE_FILE")" '.events.svc_nginx.state != "bad"' "состояние НЕ фиксируется при ошибке отправки"
CURL_FAIL_MATCH=""
: > "$CURL_LOG"
OUT=$(monitor_check_command)
assert_json "$OUT" '.sent | index("svc_nginx") != null' "retry отправляет событие повторно"
assert_log "nginx.service не работает" "текст после retry"

# ═══════════ 11. Бэкенды: hysteria2 (systemd) и AWG (интерфейс) ═══════════
# Реестр пуст → бэкендов нет → несуществующий юнит/интерфейс не даёт вечных алертов.
: > "$CURL_LOG"
OUT=$(monitor_check_command)
assert_json "$OUT" '.sent == [] and .recovered == []' "без установленных бэкендов hysteria/awg не отслеживаются"

jq -n '{hysteria2:{installed:true}}' > "$BACKENDS_REGISTRY_FILE"
: > "$CURL_LOG"
OUT=$(monitor_check_command)
assert_json "$OUT" '.sent | index("svc_hysteria2") != null' "падение hysteria2"
assert_log "Hysteria 2" "текст алерта hysteria2"
svc_set hysteria-server.service on
: > "$CURL_LOG"
OUT=$(monitor_check_command)
assert_json "$OUT" '.recovered | index("svc_hysteria2") != null' "восстановление hysteria2"

jq -n '{hysteria2:{installed:true},awg:{installed:true}}' > "$BACKENDS_REGISTRY_FILE"
: > "$CURL_LOG"
OUT=$(monitor_check_command)
assert_json "$OUT" '.sent | index("svc_awg") != null' "AWG-интерфейс не поднят"
assert_log "AmneziaWG" "текст алерта awg"
touch "$AWG_UP_FILE"
: > "$CURL_LOG"
OUT=$(monitor_check_command)
assert_json "$OUT" '.recovered | index("svc_awg") != null' "восстановление AWG"

# ═══════════ 12. Подписка: loopback-хендлер и деградация TLS ═══════════
# Без маркера .subscription_installed проверки подписки не выполняются вовсе.
: > "$CURL_LOG"
OUT=$(monitor_check_command)
assert_json "$OUT" '.sent == [] and .recovered == []' "без подписки её проверки пропускаются"

SUB_TOKEN="abcdef0123456789abcdef0123456789"
jq -n --arg t "$SUB_TOKEN" '{name:"p_sub", sub_token:$t}' > "$PROFILES_DIR/p_sub.json"
touch "$XRAY_SUB_INSTALLED"
echo "ip_tls" > "$XRAY_SUB_MODE_FILE"
: > "$CURL_LOG"
OUT=$(monitor_check_command)
assert_json "$OUT" '.sent == [] and .recovered == []' "живая подписка в ip_tls — тишина"

SUB_PROBE_FAIL=1
: > "$CURL_LOG"
OUT=$(monitor_check_command)
assert_json "$OUT" '.sent | index("sub_handler") != null' "упавший хендлер подписки"
assert_log "подписка не отвечает" "текст алерта подписки"
SUB_PROBE_FAIL=""
: > "$CURL_LOG"
OUT=$(monitor_check_command)
assert_json "$OUT" '.recovered | index("sub_handler") != null' "подписка снова отвечает"

echo "http_tls" > "$XRAY_SUB_MODE_FILE"
: > "$CURL_LOG"
OUT=$(monitor_check_command)
assert_json "$OUT" '.sent | index("sub_tls") != null' "деградация подписки до http_tls"
assert_log "деградировала до HTTP" "текст алерта деградации"
echo "ip_tls" > "$XRAY_SUB_MODE_FILE"
: > "$CURL_LOG"
OUT=$(monitor_check_command)
assert_json "$OUT" '.recovered | index("sub_tls") != null' "возврат подписки на HTTPS"

# ═══════════ 13. SNI: probe-test по расписанию ═══════════
jq -n '{name:"p_sni", sni:"a.example.com", routes:[{sni:"a.example.com"},{sni:"b.example.com"}]}' \
  > "$PROFILES_DIR/p_sni.json"
printf 'a.example.com\nb.example.com\n' > "$SNI_OK_FILE"
: > "$CURL_LOG"
: > "$SNI_PROBE_LOG"
OUT=$(monitor_check_command --force-sni)
assert_json "$OUT" '.sni.checked == 2 and .sni.ok == 2 and .sni.bad == 0 and .sni.unavailable == []' \
  "SNI-проба: оба SNI доступны"
assert_json "$OUT" '.sent == []' "первая здоровая проба — без алерта"
[[ "$(wc -l < "$SNI_PROBE_LOG")" == "2" ]] || fail "проба должна обойти оба уникальных SNI"

printf 'a.example.com\n' > "$SNI_OK_FILE"
: > "$CURL_LOG"
OUT=$(monitor_check_command --force-sni)
assert_json "$OUT" '.sni.ok == 1 and .sni.bad == 1' "частичная недоступность SNI"
assert_json "$OUT" '.sent | index("sni_reach") != null' "алерт о частичной недоступности"
assert_log "часть SNI недоступна" "текст частичного алерта"

: > "$SNI_OK_FILE"
: > "$CURL_LOG"
OUT=$(monitor_check_command --force-sni)
assert_json "$OUT" '.sni.ok == 0 and .sni.bad == 2' "полная недоступность SNI"
assert_json "$OUT" '.sent | index("sni_reach") != null' "смена подписи (оба SNI) → новый алерт"
assert_log "SNI недоступны" "текст полного алерта"

printf 'a.example.com\nb.example.com\n' > "$SNI_OK_FILE"
: > "$CURL_LOG"
OUT=$(monitor_check_command --force-sni)
assert_json "$OUT" '.recovered | index("sni_reach") != null' "восстановление доступности SNI"

# Интервал: без --force-sni дорогой probe не повторяется, берётся кэш состояния.
: > "$CURL_LOG"
: > "$SNI_PROBE_LOG"
OUT=$(monitor_check_command)
assert_json "$OUT" '.sni.checked == 2 and .sni.ok == 2' "SNI-состояние из кэша"
assert_json "$OUT" '.sent == [] and .recovered == []' "внутри интервала проба не идёт"
[[ ! -s "$SNI_PROBE_LOG" ]] || fail "внутри интервала SNI не должны пробоваться повторно"

# Retry недоставленного алерта: повтор на следующем тике БЕЗ повторной пробы.
: > "$SNI_OK_FILE"
CURL_FAIL_MATCH="sendMessage"
OUT=$(monitor_check_command --force-sni)
assert_json "$OUT" '.failed | index("sni_reach") != null' "недоставленный SNI-алерт → failed"
assert_json "$(cat "$ALERTS_STATE_FILE")" '.events.sni_reach.state != "bad"' \
  "состояние SNI-события не фиксируется при ошибке отправки"
CURL_FAIL_MATCH=""
: > "$CURL_LOG"
: > "$SNI_PROBE_LOG"
OUT=$(monitor_check_command)
assert_json "$OUT" '.sent | index("sni_reach") != null' "retry SNI-алерта"
assert_log "SNI недоступны" "текст после retry"
[[ ! -s "$SNI_PROBE_LOG" ]] || fail "retry не должен повторно пробовать SNI (результат уже в состоянии)"

# ═══════════ 14. Перезагрузка: недоставленный алерт не теряется ═══════════
echo "boot-3" > "$BOOT_ID_FILE"
CURL_FAIL_MATCH="sendMessage"
OUT=$(monitor_check_command)
assert_json "$OUT" '.failed | index("reboot") != null' "недоставленный reboot-алерт → failed"
[[ "$(jq -r '.boot_id' "$ALERTS_STATE_FILE")" == "boot-2" ]] \
  || fail "boot_id не должен обновляться при недоставленном reboot-алерте"
CURL_FAIL_MATCH=""
: > "$CURL_LOG"
OUT=$(monitor_check_command)
assert_json "$OUT" '.sent | index("reboot") != null' "retry reboot-алерта на следующем тике"
assert_log "сервер перезапущен" "текст reboot после retry"
[[ "$(jq -r '.boot_id' "$ALERTS_STATE_FILE")" == "boot-3" ]] \
  || fail "boot_id обновляется после доставки reboot-алерта"

# Итоговый статус: события видны в status, токен — нет
OUT=$(alerts_status_command)
assert_json "$OUT" '.events.svc_xray.state == "ok" and .events.svc_nginx.state == "bad"' "events в alerts-status"
assert_json "$OUT" '.sni.checked == 2 and .sni.ok == 0 and .sni.bad == 2' "SNI-состояние в alerts-status"
[[ "$OUT" != *"$TOKEN"* ]] || fail "токен не должен попадать в alerts-status"

echo "✓ Telegram-алерты мониторинга: setup/status/enable/disable/monitor-check/debounce/reboot/бэкенды/подписка/SNI — OK"
