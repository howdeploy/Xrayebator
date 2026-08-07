#!/bin/bash

# ═══════════════════════════════════════════════════════════
# XRAYEBATOR UPDATE SCRIPT v3.0
# Обновление Xrayebator до последней версии
# GitHub: https://github.com/howdeploy/Xrayebator
# ═══════════════════════════════════════════════════════════

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# GitHub репозиторий
GITHUB_USER="howdeploy"
GITHUB_REPO="Xrayebator"

# ═══ Детекция IPv6-only VPS (shared helper) ═══
# Используется при выборе dns.queryStrategy/freedom.domainStrategy.
# На IPv6-only VPS Xray не сможет резолвить A-records через UseIPv4 →
# весь клиентский трафик встанет. Проверяем наличие global-scope IPv4
# address или маршрута до IPv4-адреса; если ни одного нет → UseIP.
#
# Использование: if _detect_ipv6_only; then queryStrategy="UseIP"; fi
_detect_ipv6_only() {
  if ip -4 addr show scope global 2>/dev/null | grep -q 'inet '; then
    return 1
  fi
  if ip route get 1.1.1.1 2>/dev/null | grep -q .; then
    return 1
  fi
  return 0
}

# Возвращает строку для Xray dns.queryStrategy / freedom.domainStrategy.
# Использование: QUERY_STRATEGY=$(_ipv6_query_strategy)
_ipv6_query_strategy() {
  if _detect_ipv6_only; then
    echo "UseIP"
  else
    echo "UseIPv4"
  fi
}

# ═══════════════════════════════════════════════════════════
# ADGUARD HOME CLEANUP (legacy deprecated component — Plan 8.3)
# ═══════════════════════════════════════════════════════════
# AdGuard Home убирается как deprecated. CRITICAL ORDERING:
# DNS rollback ДО stop AdGuard, иначе возникает DNS black-hole window.
# Wrapped в функцию: `local` нельзя использовать на top-level update.sh.
_adguard_force_uninstall_if_present() {
  if [[ ! -f /opt/AdGuardHome/AdGuardHome ]]; then
    return 0
  fi

  echo ""
  echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${YELLOW}Обнаружен устаревший AdGuard Home${NC}"
  echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}AdGuard Home убирается как deprecated (в прошлых релизах${NC}"
  echo -e "${CYAN}были баги в DNS-фильтрах). Автоматическое удаление...${NC}"
  echo ""

  local cfg="${CONFIG_FILE:-/usr/local/etc/xray/config.json}"
  if [[ -f "$cfg" ]]; then
    echo -e "${CYAN}Шаг 1/5: Восстановление Xray DNS (до остановки AdGuard)...${NC}"
    # IPv6-only: если нет публичного IPv4, Xray не резолвит A-records через UseIPv4.
    local query_strategy
    query_strategy=$(_ipv6_query_strategy)
    # P1-ipv6-fix: единый family-aware DoH. Раньше жёстко 1.1.1.1 — на IPv6-only
    # хосте недоступно, и после удаления AdGuard Xray оставался без DNS.
    local dns_doh_server
    if _detect_ipv6_only; then
      dns_doh_server="https+local://dns.google/dns-query"
    else
      dns_doh_server="https+local://1.1.1.1/dns-query"
    fi
    local _tmp
    _tmp=$(mktemp /tmp/xray-cfg.XXXXXX) || {
      echo -e "${RED}  mktemp failed — DNS rollback пропущен${NC}"
      _tmp=""
    }
    if [[ -n "$_tmp" ]] && jq --arg qs "$query_strategy" --arg doh "$dns_doh_server" '.dns = {
      "servers": [
        $doh,
        "localhost"
      ],
      "queryStrategy": $qs,
      "disableCache": false
    }' "$cfg" > "$_tmp" 2>/dev/null \
       && [[ -s "$_tmp" ]] \
       && xray run -test -config "$_tmp" 2>&1 | grep -q "^Configuration OK\\.$"; then
      mv "$_tmp" "$cfg"
      chmod 644 "$cfg"
      chown root:root "$cfg" 2>/dev/null || true
      echo -e "${GREEN}  DNS rollback -> DoH Local ($dns_doh_server)${NC}"
    else
      rm -f "$_tmp"
      echo -e "${YELLOW}  DNS rollback пропущен (validation failed)${NC}"
    fi
  fi

  echo -e "${CYAN}Шаг 2/5: Остановка AdGuard Home...${NC}"
  systemctl stop AdGuardHome 2>/dev/null || true
  systemctl disable AdGuardHome 2>/dev/null || true
  /opt/AdGuardHome/AdGuardHome -s uninstall 2>/dev/null || true
  echo -e "${GREEN}  Служба остановлена${NC}"

  echo -e "${CYAN}Шаг 3/5: Удаление файлов /opt/AdGuardHome/...${NC}"
  rm -rf /opt/AdGuardHome/
  rm -f /etc/systemd/resolved.conf.d/adguardhome.conf
  echo -e "${GREEN}  Файлы удалены${NC}"

  echo -e "${CYAN}Шаг 4/5: Восстановление systemd-resolved...${NC}"
  # AdGuard Home перенастраивал resolv.conf на localhost (127.0.0.1:53).
  # Восстанавливаем стандартный stub-resolv.conf ТОЛЬКО если:
  #   (a) systemd-resolved будет запущен (иначе stub — dangling symlink → DNS сломан),
  #   (b) stub-файл реально существует,
  #   (c) текущий resolv.conf выглядит как AdGuard-managed (symlink или 127.0.0.1).
  # Не трогаем управляемые вручную статические resolv.conf.
  systemctl restart systemd-resolved 2>/dev/null || true
  local stub="/run/systemd/resolve/stub-resolv.conf"
  if systemctl is-active --quiet systemd-resolved 2>/dev/null && [[ -f "$stub" ]]; then
    local replace=0
    if [[ -L /etc/resolv.conf ]]; then
      replace=1
    elif [[ -f /etc/resolv.conf ]] && grep -qE '^\s*nameserver\s+127\.' /etc/resolv.conf 2>/dev/null; then
      replace=1
    fi
    if [[ "$replace" -eq 1 ]]; then
      ln -sf "$stub" /etc/resolv.conf 2>/dev/null || true
      echo -e "${GREEN}  resolv.conf восстановлен на systemd-resolved stub${NC}"
    else
      echo -e "${YELLOW}  resolv.conf выглядит пользовательским — не трогаю${NC}"
    fi
  else
    echo -e "${YELLOW}  systemd-resolved неактивен — resolv.conf не меняю${NC}"
  fi

  echo -e "${CYAN}Шаг 5/5: UFW cleanup (порт 53)...${NC}"
  if command -v ufw &>/dev/null; then
    ufw delete allow 53/tcp >/dev/null 2>&1
    ufw delete allow 53/udp >/dev/null 2>&1
    ufw delete allow 3000/tcp >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
  fi
  echo -e "${GREEN}  UFW проверен${NC}"

  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║  AdGuard Home удален. Xray DNS -> DoH Local (1.1.1.1)    ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""

  if [[ -f "$cfg" ]] && systemctl is-active --quiet xray; then
    if xray run -test -config "$cfg" 2>&1 | grep -q "^Configuration OK\\.$"; then
      if systemctl restart xray; then
        sleep 1
      fi
      if systemctl is-active --quiet xray; then
        echo -e "${GREEN}Xray перезапущен с новым DNS${NC}"
      else
        echo -e "${RED}Xray не поднялся после переключения DNS${NC}"
        return 1
      fi
    else
      echo -e "${YELLOW}Xray DNS validation failed — restart пропущен${NC}"
      return 1
    fi
  fi
  echo ""
}

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}✗ Требуются права root${NC}"
  exit 1
fi

ensure_xray_runtime_user() {
  if getent passwd xray >/dev/null 2>&1; then
    return 0
  fi

  local nologin="/usr/sbin/nologin"
  [[ -x "$nologin" ]] || nologin="/sbin/nologin"
  [[ -x "$nologin" ]] || nologin="/bin/false"

  echo -e "${YELLOW}Пользователь xray отсутствует — создаю runtime user...${NC}"
  if ! getent group xray >/dev/null 2>&1; then
    groupadd -r xray 2>/dev/null || true
  fi
  if getent group xray >/dev/null 2>&1; then
    useradd -r -g xray -s "$nologin" -M -d /nonexistent xray
  else
    useradd -r -s "$nologin" -M -d /nonexistent xray
  fi
  if ! getent passwd xray >/dev/null 2>&1; then
    echo -e "${RED}✗ Не удалось создать пользователя xray${NC}"
    return 1
  fi
  echo -e "${GREEN}✓ Пользователь xray создан${NC}"
  return 0
}

ensure_xray_runtime_user || exit 1

# ═══════════════════════════════════════════════════════════
# ОБРАБОТКА АРГУМЕНТОВ И ВОССТАНОВЛЕНИЕ СЕССИИ
# ═══════════════════════════════════════════════════════════
UPDATE_SESSION_FILE="/tmp/.xrayebator_update_session"

# Удаляем старые файлы сессии (старше 5 минут)
if [[ -f "$UPDATE_SESSION_FILE" ]]; then
  file_age=$(($(date +%s) - $(stat -c %Y "$UPDATE_SESSION_FILE" 2>/dev/null || echo 0)))
  if [[ $file_age -gt 300 ]]; then
    rm -f "$UPDATE_SESSION_FILE" "$UPDATE_SESSION_FILE.warned"
  fi
fi

# Если скрипт запущен с аргументом (ветка передана при restart)
if [[ -n "$1" ]]; then
  GITHUB_BRANCH="$1"
  echo -e "${CYAN}Продолжаю обновление после рестарта скрипта...${NC}"
  echo -e "${BLUE}Выбранная ветка: ${MAGENTA}$GITHUB_BRANCH${NC}\n"
  sleep 1
# Если есть файл сессии (скрипт был перезапущен через exec, в течение 5 минут)
elif [[ -f "$UPDATE_SESSION_FILE" ]]; then
  GITHUB_BRANCH=$(cat "$UPDATE_SESSION_FILE")
  echo -e "${CYAN}Восстанавливаю прерванное обновление...${NC}"
  echo -e "${BLUE}Ветка из сессии: ${MAGENTA}$GITHUB_BRANCH${NC}\n"
  sleep 1
else
  # Первый запуск - показываем меню выбора ветки
  clear
  echo -e "${CYAN}"
  echo '╔═══════════════════════════════════════════════════════════╗'
  echo '║                                                           ║'
  echo '║              XRAYEBATOR UPDATE SCRIPT v3.0                ║'
  echo '║              Обновление & Смена версии                    ║'
  echo '║                                                           ║'
  echo '╚═══════════════════════════════════════════════════════════╝'
  echo -e "${NC}\n"

  # Показываем текущую ветку если она установлена
  if [[ -f /usr/local/etc/xray/.current_branch ]]; then
    CURRENT_BRANCH=$(cat /usr/local/etc/xray/.current_branch 2>/dev/null || echo "unknown")
    echo -e "${YELLOW}Текущая ветка: ${CYAN}$CURRENT_BRANCH${NC}\n"
  fi

  # Меню выбора ветки
  echo -e "${YELLOW}Выберите версию для установки/обновления:${NC}\n"

  echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║  1) Stable (main) - Стабильная версия                      ║${NC}"
  echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
  echo -e "   ${CYAN}→${NC} Проверенный код для продакшена"
  echo -e "   ${CYAN}→${NC} Обновления раз в 1-2 месяца"
  echo -e "   ${GREEN}✓${NC} Рекомендуется для серверов"
  echo ""

  echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║  2) Dev - Версия с быстрыми фиксами                        ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
  echo -e "   ${CYAN}→${NC} Свежие исправления багов"
  echo -e "   ${CYAN}→${NC} Обновления раз в 1-2 недели"
  echo -e "   ${YELLOW}⚠${NC} Может содержать мелкие баги"
  echo ""

  echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${MAGENTA}║  3) Experimental - Экспериментальная (для тестирования)    ║${NC}"
  echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
  echo -e "   ${CYAN}→${NC} Новые функции и альфа-фичи"
  echo -e "   ${CYAN}→${NC} Автоподбор связок, расширенная диагностика"
  echo -e "   ${CYAN}→${NC} Обновления несколько раз в неделю"
  echo -e "   ${RED}⚠${NC} Может быть нестабильной!"
  echo ""

  echo -e "${CYAN}  0)${NC} Отмена\n"

  echo -n -e "${YELLOW}Ваш выбор [1-3]: ${NC}"
  read branch_choice

  case $branch_choice in
    1)
      GITHUB_BRANCH="main"
      VERSION_NAME="Stable"
      VERSION_COLOR="${GREEN}"
      ;;
    2)
      GITHUB_BRANCH="dev"
      VERSION_NAME="Dev"
      VERSION_COLOR="${BLUE}"
      ;;
    3)
      GITHUB_BRANCH="experimental"
      VERSION_NAME="Experimental"
      VERSION_COLOR="${MAGENTA}"
      ;;
    0)
      echo -e "${CYAN}Отменено${NC}"
      exit 0
      ;;
    *)
      echo -e "${RED}✗ Неверный выбор${NC}"
      exit 1
      ;;
  esac

  # СОХРАНЯЕМ выбранную ветку В ФАЙЛ СЕССИИ СРАЗУ!
  echo "$GITHUB_BRANCH" > "$UPDATE_SESSION_FILE"
fi

# Устанавливаем VERSION_NAME и VERSION_COLOR если они не установлены
if [[ -z "$VERSION_NAME" ]]; then
  case $GITHUB_BRANCH in
    main)
      VERSION_NAME="Stable"
      VERSION_COLOR="${GREEN}"
      ;;
    dev)
      VERSION_NAME="Dev"
      VERSION_COLOR="${BLUE}"
      ;;
    experimental)
      VERSION_NAME="Experimental"
      VERSION_COLOR="${MAGENTA}"
      ;;
  esac
fi

RAW_BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

echo ""
echo -e "${BLUE}Обновление до версии: ${VERSION_COLOR}${VERSION_NAME}${NC}"
echo -e "${BLUE}Ветка GitHub: ${VERSION_COLOR}${GITHUB_BRANCH}${NC}\n"

# Предупреждение для experimental/dev (показываем один раз)
if [[ "$GITHUB_BRANCH" != "main" ]] && [[ ! -f "$UPDATE_SESSION_FILE.warned" ]]; then
  echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║                    ⚠ ВНИМАНИЕ ⚠                          ║${NC}"
  echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo -e "${YELLOW}Вы устанавливаете ${VERSION_COLOR}${VERSION_NAME}${YELLOW} версию.${NC}"

  if [[ "$GITHUB_BRANCH" == "experimental" ]]; then
    echo -e "${RED}Эта версия может содержать критические баги!${NC}"
    echo -e "${YELLOW}Используйте только для тестирования.${NC}"
  else
    echo -e "${YELLOW}Эта версия содержит свежие исправления.${NC}"
    echo -e "${CYAN}При проблемах откатитесь на Stable.${NC}"
  fi

  echo ""
  echo -n -e "${YELLOW}Продолжить установку? (y/N): ${NC}"
  read confirm_install

  if [[ ! "$confirm_install" =~ ^[yYдД]$ ]]; then
    echo -e "${CYAN}✓ Отменено${NC}"
    rm -f "$UPDATE_SESSION_FILE" "$UPDATE_SESSION_FILE.warned"
    exit 0
  fi

  # Отмечаем что предупреждение показано
  touch "$UPDATE_SESSION_FILE.warned"
  echo ""
fi

# Резервная копия текущих настроек
echo -e "${YELLOW}Создание резервной копии...${NC}"
# Единая директория бэкапов с xrayebator (XRAY_BACKUPS_DIR=/usr/local/etc/xray/backups).
# Отдельный /usr/local/etc/xray/backup_<ts> рос вечно и не подчинялся ротации backup_config().
BACKUP_DIR="/usr/local/etc/xray/backups/update_$(date +%Y%m%d_%H%M%S)"
if ! mkdir -p "$BACKUP_DIR"; then
  echo -e "${RED}✗ Не удалось создать каталог резервной копии${NC}"
  exit 1
fi
chmod 700 "$BACKUP_DIR"
cp /usr/local/bin/xrayebator "$BACKUP_DIR/" 2>/dev/null
cp -r /usr/local/etc/xray/profiles "$BACKUP_DIR/" 2>/dev/null
UPDATE_CONFIG_BACKUP=""
if [[ -f /usr/local/etc/xray/config.json ]]; then
  UPDATE_CONFIG_BACKUP="$BACKUP_DIR/config.json"
  if ! cp /usr/local/etc/xray/config.json "$UPDATE_CONFIG_BACKUP"; then
    echo -e "${RED}✗ Не удалось сохранить config.json — update прерван${NC}"
    exit 1
  fi
fi
cp /usr/local/etc/xray/.private_key "$BACKUP_DIR/" 2>/dev/null
cp /usr/local/etc/xray/.public_key "$BACKUP_DIR/" 2>/dev/null
cp /usr/local/etc/xray/scripts/update.sh "$BACKUP_DIR/update.sh.bak" 2>/dev/null
echo -e "${GREEN}✓ Резервная копия: $BACKUP_DIR${NC}\n"

_restore_update_config_backup() {
  if [[ -z "$UPDATE_CONFIG_BACKUP" || ! -s "$UPDATE_CONFIG_BACKUP" ]]; then
    echo -e "${RED}✗ Session backup config.json отсутствует: ${UPDATE_CONFIG_BACKUP:-не создан}${NC}"
    return 1
  fi
  if ! cp "$UPDATE_CONFIG_BACKUP" /usr/local/etc/xray/config.json; then
    echo -e "${RED}✗ Не удалось восстановить session backup config.json${NC}"
    return 1
  fi
  chown root:xray /usr/local/etc/xray/config.json 2>/dev/null || true
  chmod 640 /usr/local/etc/xray/config.json
  echo -e "${GREEN}✓ config.json восстановлен из $UPDATE_CONFIG_BACKUP${NC}"
}

# Сохранение информации о текущей ветке
echo "$GITHUB_BRANCH" > /usr/local/etc/xray/.current_branch 2>/dev/null

# ═══════════════════════════════════════════════════════════
# ОБНОВЛЕНИЕ СКРИПТА update.sh
# ═══════════════════════════════════════════════════════════
echo -e "${YELLOW}Проверка обновлений update.sh...${NC}"
UPDATE_TMP=$(mktemp /tmp/update_new_XXXXXX.sh)
curl -fsSL --connect-timeout 10 --max-time 30 "${RAW_BASE_URL}/update.sh" -o "$UPDATE_TMP"

if [[ $? -eq 0 ]] && [[ -s "$UPDATE_TMP" ]]; then
  chmod 755 "$UPDATE_TMP"

  # Проверяем что скрипт валидный
  if head -n 1 "$UPDATE_TMP" | grep -q "^#!/bin/bash" && bash -n "$UPDATE_TMP"; then
    mkdir -p /usr/local/etc/xray/scripts
    chmod 755 /usr/local/etc/xray/scripts 2>/dev/null || true
    chown root:root /usr/local/etc/xray/scripts 2>/dev/null || true

    # Сравниваем с текущей версией
    if ! cmp -s "$UPDATE_TMP" /usr/local/etc/xray/scripts/update.sh 2>/dev/null; then
      chmod 755 "$UPDATE_TMP"
      chown root:root "$UPDATE_TMP"
      mv "$UPDATE_TMP" /usr/local/etc/xray/scripts/update.sh
      echo -e "${GREEN}✓ Скрипт update.sh обновлён${NC}"
      echo -e "${YELLOW}⚠ Перезапуск для применения изменений${NC}"
      sleep 2

      # ИСПРАВЛЕНИЕ: Передаем ветку через аргумент
      exec /usr/local/etc/xray/scripts/update.sh "$GITHUB_BRANCH"
      exit 0
    else
      echo -e "${GREEN}✓ update.sh актуален${NC}"
      rm -f "$UPDATE_TMP"
    fi
  else
    echo -e "${YELLOW}⚠ Скачанный скрипт некорректен${NC}"
    rm -f "$UPDATE_TMP"
  fi
else
  echo -e "${YELLOW}⚠ Не удалось обновить update.sh${NC}"
  rm -f "$UPDATE_TMP"
fi
echo ""

# ═══════════════════════════════════════════════════════════
# ОБНОВЛЕНИЕ ОСНОВНЫХ ФАЙЛОВ
# ═══════════════════════════════════════════════════════════

# Обновление xrayebator
echo -e "${YELLOW}Обновление xrayebator...${NC}"
XRAY_TMP=$(mktemp /tmp/xrayebator_new_XXXXXX)
curl -fsSL --connect-timeout 10 --max-time 60 "${RAW_BASE_URL}/xrayebator" -o "$XRAY_TMP"

if [[ $? -eq 0 ]] && [[ -s "$XRAY_TMP" ]]; then
  chmod 755 "$XRAY_TMP"
  chown root:root "$XRAY_TMP"
  if bash -n "$XRAY_TMP"; then
    mv "$XRAY_TMP" /usr/local/bin/xrayebator
    echo -e "${GREEN}✓ xrayebator обновлён${NC}\n"
  else
    echo -e "${RED}✗ Скачанный xrayebator не проходит bash -n${NC}"
    rm -f "$XRAY_TMP" "$UPDATE_SESSION_FILE" "$UPDATE_SESSION_FILE.warned"
    exit 1
  fi
else
  echo -e "${RED}✗ Ошибка загрузки xrayebator${NC}"
  echo -e "${YELLOW}Проверьте доступность ветки '${GITHUB_BRANCH}' на GitHub${NC}"
  rm -f "$XRAY_TMP" "$UPDATE_SESSION_FILE" "$UPDATE_SESSION_FILE.warned"
  exit 1
fi

# Обновление uninstall.sh и восстановление symlink'ов команд.
echo -e "${YELLOW}Обновление служебных скриптов...${NC}"
mkdir -p /usr/local/etc/xray/scripts
chmod 755 /usr/local/etc/xray/scripts 2>/dev/null || true
chown root:root /usr/local/etc/xray/scripts 2>/dev/null || true
UNINSTALL_TMP=$(mktemp /tmp/xrayebator_uninstall_new_XXXXXX.sh)
if curl -fsSL --connect-timeout 10 --max-time 30 "${RAW_BASE_URL}/uninstall.sh" -o "$UNINSTALL_TMP" \
   && [[ -s "$UNINSTALL_TMP" ]] \
   && head -n 1 "$UNINSTALL_TMP" | grep -q "^#!/bin/bash" \
   && bash -n "$UNINSTALL_TMP"; then
  chmod 755 "$UNINSTALL_TMP"
  chown root:root "$UNINSTALL_TMP"
  mv "$UNINSTALL_TMP" /usr/local/etc/xray/scripts/uninstall.sh
  echo -e "${GREEN}✓ uninstall.sh обновлён${NC}"
else
  echo -e "${YELLOW}⚠ Не удалось обновить uninstall.sh${NC}"
  rm -f "$UNINSTALL_TMP"
fi
chmod 755 /usr/local/bin/xrayebator 2>/dev/null || true
chmod 755 /usr/local/etc/xray/scripts/update.sh 2>/dev/null || true
chmod 755 /usr/local/etc/xray/scripts/uninstall.sh 2>/dev/null || true
chown root:root /usr/local/bin/xrayebator /usr/local/etc/xray/scripts/update.sh /usr/local/etc/xray/scripts/uninstall.sh 2>/dev/null || true
ln -sf /usr/local/etc/xray/scripts/update.sh /usr/local/bin/xrayebator-update 2>/dev/null || true
ln -sf /usr/local/etc/xray/scripts/uninstall.sh /usr/local/bin/xrayebator-uninstall 2>/dev/null || true
echo -e "${GREEN}✓ Команды xrayebator-update / xrayebator-uninstall проверены${NC}\n"

# Load the freshly installed runtime once. Besides exposing subscription helpers,
# this applies state-only migrations to existing installations immediately.
XRAYEBATOR_RUNTIME_LOADED=false
if source /usr/local/bin/xrayebator; then
  XRAYEBATOR_RUNTIME_LOADED=true
  echo -e "${YELLOW}Удаление legacy BBR/TCP tuning...${NC}"
  if migrate_remove_legacy_tcp_tuning_v3; then
    echo -e "${GREEN}✓ Legacy BBR/TCP tuning отключён${NC}\n"
  else
    echo -e "${YELLOW}⚠ Не удалось завершить BBR migration${NC}"
    echo -e "${YELLOW}  Повтор: sudo xrayebator${NC}\n"
  fi
  echo -e "${YELLOW}Проверка client-side fingerprint state...${NC}"
  if migrate_client_fingerprint_state_2026; then
    echo -e "${GREEN}✓ Fingerprint state актуален; restart Xray не требовался${NC}\n"
  else
    echo -e "${YELLOW}⚠ Не удалось завершить fingerprint migration${NC}"
    echo -e "${YELLOW}  Повтор: sudo xrayebator${NC}\n"
  fi
else
  echo -e "${YELLOW}⚠ Не удалось загрузить обновлённый xrayebator для runtime migrations${NC}\n"
fi

# Обновление списка SNI
echo -e "${YELLOW}Обновление списка SNI...${NC}"
mkdir -p /usr/local/etc/xray/data
curl -fsSL --connect-timeout 10 --max-time 30 "${RAW_BASE_URL}/sni_list.txt" -o /usr/local/etc/xray/data/sni_list.txt

if [[ $? -eq 0 ]] && [[ -s /usr/local/etc/xray/data/sni_list.txt ]]; then
  echo -e "${GREEN}✓ Список SNI обновлён${NC}\n"
else
  echo -e "${YELLOW}⚠ Не удалось обновить SNI список${NC}\n"
fi

# Обновление ASCII арта (опционально)
curl -fsSL --connect-timeout 10 --max-time 30 "${RAW_BASE_URL}/ascii_art.txt" -o /usr/local/etc/xray/data/ascii_art.txt 2>/dev/null

# Проверка версии
echo -e "${YELLOW}Проверка установленной версии...${NC}"
VERSION_INFO=$(grep -m 1 "XRAYEBATOR v" /usr/local/bin/xrayebator | sed 's/.*XRAYEBATOR //' | sed 's/ .*//')
echo -e "${GREEN}✓ Версия: ${VERSION_INFO}${NC}\n"

# Если HAPP subscription уже установлен, его handler — сгенерированный файл.
# После обновления основного xrayebator нужно перегенерировать subhttp.sh, иначе
# активная подписка останется на старой логике до ручного запуска меню.
if [[ -f /usr/local/etc/xray/.subscription_installed ]]; then
  echo -e "${YELLOW}Обновление HAPP subscription handler...${NC}"
  if [[ "$XRAYEBATOR_RUNTIME_LOADED" == "true" ]] && install_subscription_server >/dev/null 2>&1; then
    if declare -F _subscription_restart_service >/dev/null 2>&1; then
      if _subscription_restart_service; then
        echo -e "${GREEN}✓ subhttp.sh обновлён, xrayebator-sub.service запущен${NC}"
      else
        echo -e "${YELLOW}⚠ subhttp.sh обновлён, но xrayebator-sub.service не запустился${NC}"
        echo -e "${YELLOW}  Проверьте: systemctl status xrayebator-sub --no-pager -l${NC}"
      fi
    else
      systemctl reset-failed xrayebator-sub.service 2>/dev/null || true
      systemctl enable xrayebator-sub.service >/dev/null 2>&1 || true
      if systemctl restart xrayebator-sub.service; then
        echo -e "${GREEN}✓ subhttp.sh обновлён, xrayebator-sub.service запущен${NC}"
      else
        echo -e "${YELLOW}⚠ subhttp.sh обновлён, но xrayebator-sub.service не запустился${NC}"
        echo -e "${YELLOW}  Проверьте: systemctl status xrayebator-sub --no-pager -l${NC}"
      fi
    fi
  else
    echo -e "${YELLOW}⚠ Не удалось регенерировать HAPP handler. Запустите: sudo xrayebator → Подписка HAPP${NC}"
  fi
  echo ""
fi

# Обновление geo-баз (Loyalsoldier enhanced)
echo -e "${YELLOW}Обновление geo-баз (Loyalsoldier)...${NC}"
XRAY_DAT_DIR="/usr/local/share/xray"
LOYALSOLDIER_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
GEO_UPDATED=false

mkdir -p "$XRAY_DAT_DIR"

# Update geoip.dat
if curl -fsSL --connect-timeout 10 "${LOYALSOLDIER_URL}/geoip.dat" -o "${XRAY_DAT_DIR}/geoip.dat.tmp" 2>/dev/null; then
  if [[ -s "${XRAY_DAT_DIR}/geoip.dat.tmp" ]]; then
    mv "${XRAY_DAT_DIR}/geoip.dat.tmp" "${XRAY_DAT_DIR}/geoip.dat"
    echo -e "${GREEN}  ✓ geoip.dat обновлен${NC}"
    GEO_UPDATED=true
  else
    rm -f "${XRAY_DAT_DIR}/geoip.dat.tmp"
    echo -e "${YELLOW}  ⚠ geoip.dat: пустой ответ${NC}"
  fi
else
  rm -f "${XRAY_DAT_DIR}/geoip.dat.tmp"
  echo -e "${YELLOW}  ⚠ geoip.dat: недоступен (GitHub?)${NC}"
fi

# Update geosite.dat
if curl -fsSL --connect-timeout 10 "${LOYALSOLDIER_URL}/geosite.dat" -o "${XRAY_DAT_DIR}/geosite.dat.tmp" 2>/dev/null; then
  if [[ -s "${XRAY_DAT_DIR}/geosite.dat.tmp" ]]; then
    mv "${XRAY_DAT_DIR}/geosite.dat.tmp" "${XRAY_DAT_DIR}/geosite.dat"
    echo -e "${GREEN}  ✓ geosite.dat обновлен${NC}"
    GEO_UPDATED=true
  else
    rm -f "${XRAY_DAT_DIR}/geosite.dat.tmp"
    echo -e "${YELLOW}  ⚠ geosite.dat: пустой ответ${NC}"
  fi
else
  rm -f "${XRAY_DAT_DIR}/geosite.dat.tmp"
  echo -e "${YELLOW}  ⚠ geosite.dat: недоступен (GitHub?)${NC}"
fi

if [[ "$GEO_UPDATED" == "true" ]]; then
  echo -e "${GREEN}✓ Geo-базы обновлены${NC}\n"
else
  echo -e "${YELLOW}⚠ Geo-базы не обновлены (используются существующие)${NC}\n"
fi

# ═══════════════════════════════════════════════════════════
# ОПРЕДЕЛЕНИЕ update_xray_core (REQ-B01) — БЕЗ автоматического вызова.
# Trigger обновления = CLI `xrayebator update` (см. xrayebator dispatcher).
# Функция определена здесь для sync-test parity с install.sh / xrayebator.
# ═══════════════════════════════════════════════════════════

# update_xray_core
# Скачивает и атомарно устанавливает свежий Xray-core с GitHub Releases.
# Использует: GitHub API → fallback redirect, SHA-256 verify, self-test нового binary,
# atomic install -m 755, rollback бинарника на неудачу.
#
# Returns:
#   0 — успешно обновлено (или уже на latest)
#   1 — пропущено пользователем (y/N → N)
#   2 — критическая ошибка (network / SHA / arch unsupported)
#   3 — config несовместим с новой версией (rollback применен, Xray на старой)
update_xray_core() {
  local CURRENT_VERSION TARGET_TAG TARGET_VERSION MACHINE
  local TMPDIR ZIP_URL DGST_URL ZIP_PATH DGST_PATH

  # ── Step 1: Architecture detection ──────────────────────────────
  case "$(uname -m)" in
    x86_64|amd64)  MACHINE="64" ;;
    aarch64|arm64) MACHINE="arm64-v8a" ;;
    armv7l)        MACHINE="arm32-v7a" ;;
    armv6l)        MACHINE="arm32-v6" ;;
    *)
      echo -e "${RED}✗ Архитектура $(uname -m) не поддерживается${NC}"
      return 2
      ;;
  esac

  # ── Step 2: Получить current version ───────────────────────────
  if [[ -x /usr/local/bin/xray ]]; then
    CURRENT_VERSION=$(/usr/local/bin/xray version 2>/dev/null | head -1 | awk '{print $2}')
  fi
  CURRENT_VERSION="${CURRENT_VERSION:-неустановлено}"

  # ── Step 3: Получить latest tag (API → fallback redirect) ──────
  TARGET_TAG=$(_fetch_latest_tag) || {
    echo -e "${RED}✗ GitHub недоступен (API + redirect провалились)${NC}"
    _print_manual_install_hint "$MACHINE"
    return 2
  }
  TARGET_VERSION="${TARGET_TAG#v}"

  # ── Step 4: Compare versions ────────────────────────────────────
  if [[ "$CURRENT_VERSION" == "$TARGET_VERSION" ]]; then
    echo -e "${GREEN}✓ Xray $CURRENT_VERSION — уже на latest${NC}"
    return 0
  fi

  # Защита от downgrade: если текущая > целевой — пропускаем
  if [[ "$CURRENT_VERSION" != "неустановлено" ]]; then
    local cv_major cv_minor cv_patch tv_major tv_minor tv_patch
    cv_major=$(echo "$CURRENT_VERSION" | awk -F. '{print $1+0}')
    cv_minor=$(echo "$CURRENT_VERSION" | awk -F. '{print $2+0}')
    cv_patch=$(echo "$CURRENT_VERSION" | awk -F. '{print $3+0}')
    tv_major=$(echo "$TARGET_VERSION" | awk -F. '{print $1+0}')
    tv_minor=$(echo "$TARGET_VERSION" | awk -F. '{print $2+0}')
    tv_patch=$(echo "$TARGET_VERSION" | awk -F. '{print $3+0}')
    if [[ $cv_major -gt $tv_major ]] || \
       [[ $cv_major -eq $tv_major && $cv_minor -gt $tv_minor ]] || \
       [[ $cv_major -eq $tv_major && $cv_minor -eq $tv_minor && $cv_patch -gt $tv_patch ]]; then
      echo -e "${GREEN}✓ Xray $CURRENT_VERSION новее доступной $TARGET_VERSION — пропускаем${NC}"
      return 0
    fi
  fi

  # ── Step 5: Confirmation prompt (CONTEXT.md decision 2) ────────
  echo -e "${CYAN}Доступно обновление Xray-core:${NC}"
  echo -e "  ${YELLOW}Текущая:${NC} $CURRENT_VERSION"
  echo -e "  ${GREEN}Новая:${NC}    $TARGET_VERSION"
  echo -e "  ${CYAN}Размер:${NC}   ~6.5MB (zip)"
  echo -e "  ${CYAN}Downtime:${NC} ~5 секунд"
  echo ""
  if [[ "${INSTALL_MODE:-0}" != "1" ]]; then
    echo -n -e "${YELLOW}Continue? [y/N]: ${NC}"
    read confirm
    [[ ! "$confirm" =~ ^[yYдД]$ ]] && {
      echo -e "${CYAN}Отменено пользователем${NC}"
      return 1
    }
  fi

  # ── Step 6: Download zip + dgst (с --progress-bar) ─────────────
  TMPDIR=$(mktemp -d /tmp/xray_update.XXXXXX)
  trap "rm -rf '$TMPDIR'" RETURN

  ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/${TARGET_TAG}/Xray-linux-${MACHINE}.zip"
  DGST_URL="${ZIP_URL}.dgst"
  ZIP_PATH="${TMPDIR}/xray.zip"
  DGST_PATH="${ZIP_PATH}.dgst"

  echo -e "${CYAN}Скачивание $TARGET_TAG...${NC}"
  if [[ -n "${XRAY_LOCAL_ZIP:-}" || -n "${XRAY_LOCAL_DGST:-}" ]]; then
    if [[ ! -f "${XRAY_LOCAL_ZIP:-}" || ! -f "${XRAY_LOCAL_DGST:-}" ]]; then
      echo -e "${RED}✗ XRAY_LOCAL_ZIP и XRAY_LOCAL_DGST должны указывать на существующие файлы${NC}"
      return 2
    fi
    cp "$XRAY_LOCAL_ZIP" "$ZIP_PATH"
    cp "$XRAY_LOCAL_DGST" "$DGST_PATH"
    echo -e "${GREEN}  ✓ Использованы локальные release-файлы${NC}"
  else
    local curl_args=(-fL --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 30 --max-time 600 --http1.1)
    [[ "${XRAY_FORCE_IPV4:-0}" == "1" ]] && curl_args+=(-4)
    [[ -n "${XRAY_DOWNLOAD_PROXY:-}" ]] && curl_args+=(--proxy "$XRAY_DOWNLOAD_PROXY")

    if ! curl "${curl_args[@]}" --progress-bar -o "$ZIP_PATH" "$ZIP_URL"; then
      echo -e "${RED}✗ Не удалось скачать $ZIP_URL${NC}"
      echo -e "${YELLOW}  Можно указать SOCKS/HTTP proxy через XRAY_DOWNLOAD_PROXY или локальные XRAY_LOCAL_ZIP/XRAY_LOCAL_DGST.${NC}"
      return 2
    fi

    if ! curl "${curl_args[@]}" -sS -o "$DGST_PATH" "$DGST_URL"; then
      echo -e "${RED}✗ Не удалось скачать .dgst (SHA-256 manifest обязателен)${NC}"
      echo -e "${YELLOW}  Проверка SHA не отключается; загрузите ZIP и .dgst через другой канал и передайте локальные пути.${NC}"
      return 2
    fi
  fi

  # ── Step 7: SHA-256 verify (mandatory) ─────────────────────────
  echo -e "${CYAN}Verifying SHA256...${NC}"
  local expected actual
  expected=$(awk -F '= *' '/^(SHA2-)?256=|^SHA256=/ {print $2; exit}' "$DGST_PATH" | tr -d '[:space:]')
  actual=$(sha256sum "$ZIP_PATH" | awk '{print $1}')

  if [[ -z "$expected" ]]; then
    echo -e "${RED}✗ .dgst файл не содержит SHA256 (формат изменился?)${NC}"
    return 2
  fi
  if [[ "$expected" != "$actual" ]]; then
    echo -e "${RED}✗ SHA256 mismatch — отмена${NC}"
    echo -e "${YELLOW}  Ожидалось: $expected${NC}"
    echo -e "${YELLOW}  Получено:  $actual${NC}"
    return 2
  fi
  echo -e "${GREEN}  ✓ SHA256 ok${NC}"

  # ── Step 8: Unzip ──────────────────────────────────────────────
  if ! unzip -q "$ZIP_PATH" -d "${TMPDIR}/extract"; then
    echo -e "${RED}✗ Ошибка распаковки${NC}"
    return 2
  fi
  if [[ ! -x "${TMPDIR}/extract/xray" ]]; then
    echo -e "${RED}✗ Бинарник xray отсутствует в zip-архиве${NC}"
    return 2
  fi

  # ── Step 9: Self-test нового бинарника ─────────────────────────
  if ! "${TMPDIR}/extract/xray" version >/dev/null 2>&1; then
    echo -e "${RED}✗ Новый бинарник не запускается (binary corrupt / arch mismatch)${NC}"
    return 2
  fi

  # ── Step 10: Pre-validate config с НОВЫМ binary (catch breaking) ──
  # Skip если config.json отсутствует — install mode
  local CONFIG_FILE="/usr/local/etc/xray/config.json"
  if [[ -f "$CONFIG_FILE" ]]; then
    local test_output
    test_output=$("${TMPDIR}/extract/xray" run -test -config "$CONFIG_FILE" 2>&1)
    if ! grep -q "Configuration OK" <<< "$test_output"; then
      echo -e "${RED}✗ config.json не валиден против $TARGET_VERSION${NC}"
      echo -e "${YELLOW}Подробности:${NC}"
      echo "$test_output" | head -10
      echo -e "${YELLOW}Update прерван — Xray продолжает работать на $CURRENT_VERSION${NC}"
      return 3
    fi
  else
    echo -e "${CYAN}  → config.json отсутствует (install mode), pre-validate пропущен${NC}"
  fi

  # ── Step 11: Backup старого binary ─────────────────────────────
  local backup_path="/usr/local/bin/xray.bak.$(date +%s)"
  if [[ -x /usr/local/bin/xray ]]; then
    cp /usr/local/bin/xray "$backup_path"
    chmod 755 "$backup_path"
    echo -e "${CYAN}  → Бекап: $(basename "$backup_path")${NC}"
  fi

  # ── Step 12: Atomic install ────────────────────────────────────
  if ! install -m 755 -o root -g root \
       "${TMPDIR}/extract/xray" /usr/local/bin/xray; then
    echo -e "${RED}✗ Ошибка install -m 755${NC}"
    [[ -f "$backup_path" ]] && {
      mv "$backup_path" /usr/local/bin/xray
      echo -e "${YELLOW}  → Откат к $CURRENT_VERSION${NC}"
    }
    return 2
  fi

  # ── Step 13: Restart с systemd-unit-guard (skip в install mode) ──
  # safe_restart_xray в update.sh недоступна (определена в xrayebator).
  # Используем прямой systemctl + проверка is-active.
  if systemctl list-unit-files xray.service >/dev/null 2>&1 && [[ -f /etc/systemd/system/xray.service.d/security.conf ]]; then
    systemctl restart xray
    sleep 2
    if systemctl is-active --quiet xray; then
      echo -e "${GREEN}✓ Xray-core обновлен: $CURRENT_VERSION → $TARGET_VERSION${NC}"
      _cleanup_xray_backups
      return 0
    else
      echo -e "${RED}✗ Xray не запустился после установки $TARGET_VERSION${NC}"
      if [[ -f "$backup_path" ]]; then
        mv "$backup_path" /usr/local/bin/xray
        systemctl restart xray
        sleep 2
        if systemctl is-active --quiet xray; then
          echo -e "${YELLOW}  → Откат binary к $CURRENT_VERSION выполнен${NC}"
        else
          echo -e "${RED}  ✗ Откат не помог — ручное вмешательство${NC}"
        fi
      fi
      return 3
    fi
  else
    # Install mode: systemd unit будет создан позже в [3/9].
    echo -e "${CYAN}  → Xray-core установлен. Сервис настроен в [3/9].${NC}"
    _cleanup_xray_backups
    return 0
  fi
}

_fetch_latest_tag() {
  # Пробуем GitHub API первым
  local api_json tag
  api_json=$(curl -fsSL --connect-timeout 10 --max-time 20 \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null)
  tag=$(echo "$api_json" | jq -r '.tag_name // ""' 2>/dev/null)
  if [[ -n "$tag" && "$tag" != "null" ]]; then
    echo "$tag"
    return 0
  fi

  # Fallback: 302 redirect parse
  local redirect_url
  redirect_url=$(curl -fso /dev/null -w '%{url_effective}' \
    --connect-timeout 10 --max-time 15 -L --max-redirs 1 \
    "https://github.com/XTLS/Xray-core/releases/latest" 2>/dev/null)
  tag="${redirect_url##*/}"
  if [[ -n "$tag" && "$tag" =~ ^v[0-9]+\. ]]; then
    echo "$tag"
    return 0
  fi

  return 1
}

_print_manual_install_hint() {
  local arch="$1"
  echo -e "${YELLOW}  Ручная установка:${NC}"
  echo -e "${CYAN}    1. https://github.com/XTLS/Xray-core/releases/latest${NC}"
  echo -e "${CYAN}    2. Скачайте Xray-linux-${arch}.zip + .dgst${NC}"
  echo -e "${CYAN}    3. unzip xray.zip && проверьте sha256sum${NC}"
  echo -e "${CYAN}    4. install -m 755 ./xray /usr/local/bin/xray${NC}"
  echo -e "${CYAN}    5. systemctl restart xray${NC}"
}

_cleanup_xray_backups() {
  # Оставить 3 последних xray.bak.<timestamp>, остальные удалить.
  local backups
  mapfile -t backups < <(ls -t /usr/local/bin/xray.bak.* 2>/dev/null)

  if [[ ${#backups[@]} -gt 3 ]]; then
    local to_remove=("${backups[@]:3}")
    for f in "${to_remove[@]}"; do
      rm -f "$f"
    done
    echo -e "${CYAN}  → Старые бекапы удалены (оставлено 3)${NC}"
  fi
}

# ═══════════════════════════════════════════════════════════
# КОНЕЦ блока определений update_xray_core
# ═══════════════════════════════════════════════════════════

# Force-uninstall legacy AdGuard Home — должен выполниться ПЕРЕД DNS migration.
if ! _adguard_force_uninstall_if_present; then
  echo -e "${RED}✗ Update остановлен: Xray не принял DNS после удаления AdGuard${NC}"
  exit 1
fi

# ═══════════════════════════════════════════════════════════
# МИГРАЦИЯ DNS (AdGuard для блокировки рекламы)
# ═══════════════════════════════════════════════════════════
CONFIG_FILE="/usr/local/etc/xray/config.json"
if [[ -f "$CONFIG_FILE" ]]; then
  echo -e "${YELLOW}Проверка настроек DNS...${NC}"

  # Проверяем: если DNS -> 127.0.0.1 (AdGuard Home), не трогаем
  CURRENT_DNS=$(jq -r '.dns.servers[0] // ""' "$CONFIG_FILE" 2>/dev/null)
  if [[ "$CURRENT_DNS" == "127.0.0.1" ]]; then
    echo -e "${GREEN}  ✓ DNS -> 127.0.0.1 (AdGuard Home) -- сохранено${NC}"
  elif [[ "$CURRENT_DNS" == "https+local://"* ]]; then
    echo -e "${GREEN}  ✓ DNS -> DoH Local -- сохранено${NC}"
  elif ! grep -q "dns.adguard-dns.com" "$CONFIG_FILE" 2>/dev/null; then
    echo -e "${CYAN}  → Миграция на DoH Local${NC}"

    # IPv6-only: если нет публичного IPv4, Xray не резолвит A-records через UseIPv4.
    query_strategy=$(_ipv6_query_strategy)

    # Создаём новую конфигурацию DNS.
    # IPv6-only: нет маршрута до IPv4-резолверов (1.1.1.1) — используем IPv6-совместимый DoH.
    if _detect_ipv6_only; then
      dns_doh_server="https+local://dns.google/dns-query"
    else
      dns_doh_server="https+local://1.1.1.1/dns-query"
    fi
    NEW_DNS=$(cat <<DNSEOF
{
  "servers": [
    "${dns_doh_server}",
    "localhost"
  ],
  "queryStrategy": "${query_strategy}",
  "disableCache": false
}
DNSEOF
)

    # Обновляем DNS секцию в конфиге.
    # Обновляем только servers/queryStrategy/disableCache, сохраняя пользовательские
    # hosts и прочие кастомные поля DNS (точечные полевые апдейты вместо сброса всего блока).
    TMP_FILE=$(mktemp /tmp/xray-cfg.XXXXXX) || {
      echo -e "${YELLOW}  ⚠ mktemp failed (DNS обновление пропущено)${NC}"
      true
    }
    if [[ -n "$TMP_FILE" ]] && jq --argjson dns "$NEW_DNS" \
       '.dns.servers = $dns.servers | .dns.queryStrategy = $dns.queryStrategy | .dns.disableCache = ($dns.disableCache // false)' \
       "$CONFIG_FILE" > "$TMP_FILE" 2>/dev/null \
       && [[ -s "$TMP_FILE" ]] \
       && xray run -test -config "$TMP_FILE" 2>&1 | grep -q "^Configuration OK\.$"; then
      mv "$TMP_FILE" "$CONFIG_FILE"
      # Restore mode/owner (mktemp создаёт с mode 600, mv наследует root)
      chmod 644 "$CONFIG_FILE"
      chown root:root "$CONFIG_FILE" 2>/dev/null || true
      echo -e "${GREEN}  ✓ DNS обновлён на DoH Local (${dns_doh_server})${NC}"
    else
      rm -f "$TMP_FILE"
      echo -e "${YELLOW}  ⚠ Не удалось обновить DNS (size-check или xray test failed, конфиг без изменений)${NC}"
    fi
  else
    echo -e "${GREEN}  ✓ AdGuard DNS уже настроен${NC}"
  fi

  echo ""
fi

# Перезапуск Xray (если работает)
if systemctl is-active --quiet xray; then
  echo -e "${YELLOW}Проверка config.json перед перезапуском Xray...${NC}"

  # Guard #1: файл существует и не пуст
  if [[ ! -f /usr/local/etc/xray/config.json || ! -s /usr/local/etc/xray/config.json ]]; then
    echo -e "${RED}✗ config.json отсутствует или пуст после миграций${NC}"
    _restore_update_config_backup || true
    echo -e "${RED}Update прерван. Xray продолжает работать на старом конфиге.${NC}"
    exit 1
  fi

  # Guard #2: xray run -test (grep stdout — exit code ненадёжен: возвращает 0 на missing file)
  if ! xray run -test -config /usr/local/etc/xray/config.json 2>&1 | grep -q "^Configuration OK\.$"; then
    echo -e "${RED}✗ config.json не валиден после миграций${NC}"
    echo -e "${YELLOW}Вывод xray:${NC}"
    xray run -test -config /usr/local/etc/xray/config.json 2>&1 | head -20

    if _restore_update_config_backup; then
      echo -e "${RED}Update прерван. Xray продолжает работать на старом конфиге.${NC}"
    else
      echo -e "${RED}Update прерван. Конфиг возможно повреждён, проверьте вручную.${NC}"
    fi
    exit 1
  fi
  echo -e "${GREEN}✓ config.json прошёл validation${NC}"

  echo -e "${YELLOW}Перезапуск Xray...${NC}"
  systemctl restart xray
  sleep 2

  if systemctl is-active --quiet xray; then
    echo -e "${GREEN}✓ Xray перезапущен${NC}\n"
  else
    echo -e "${RED}✗ Ошибка перезапуска Xray${NC}"
    echo -e "${YELLOW}Откат config.json из session backup...${NC}"
    if _restore_update_config_backup; then
      systemctl restart xray
      sleep 2
      if systemctl is-active --quiet xray; then
        echo -e "${YELLOW}✓ Xray восстановлен на config.json до update${NC}"
      else
        echo -e "${RED}✗ Откат не поднял Xray. Логи: journalctl -u xray -n 50${NC}"
      fi
    fi
    exit 1
  fi
fi

# Очистка временных файлов
rm -f "$UPDATE_SESSION_FILE" "$UPDATE_SESSION_FILE.warned"

# ═══════════════════════════════════════════════════════════
# ФИНАЛЬНОЕ СООБЩЕНИЕ
# ═══════════════════════════════════════════════════════════
clear
echo -e "${VERSION_COLOR}"
echo '╔═══════════════════════════════════════════════════════════╗'
echo '║                                                           ║'
echo '║              ✓ ОБНОВЛЕНИЕ ЗАВЕРШЕНО!                     ║'
echo '║                                                           ║'
echo '╚═══════════════════════════════════════════════════════════╝'
echo -e "${NC}\n"

echo -e "${CYAN}Установленная ветка: ${VERSION_COLOR}${VERSION_NAME} (${GITHUB_BRANCH})${NC}"
echo -e "${CYAN}Релиз Xrayebator: ${VERSION_COLOR}${VERSION_INFO}${NC}"
echo -e "${CYAN}Резервная копия: ${GREEN}${BACKUP_DIR}${NC}\n"

# Информация по ветке
case $GITHUB_BRANCH in
  main)
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Стабильная версия установлена${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}✓${NC} Проверенный код"
    echo -e "  ${GREEN}✓${NC} Для продакшен-серверов"
    ;;
  dev)
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Dev версия установлена${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}✓${NC} Свежие исправления"
    echo -e "  ${YELLOW}⚠${NC} Для отката: sudo xrayebator-update → Stable"
    ;;
  experimental)
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}  ⚡ Experimental версия установлена${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}✓${NC} Автоподбор связок с динамическими портами"
    echo -e "  ${GREEN}✓${NC} Индивидуальная настройка SNI/fingerprint"
    echo -e "  ${GREEN}✓${NC} Расширенная диагностика"
    echo -e "  ${RED}⚠${NC} Тестовая версия!"
    echo -e "  ${YELLOW}Для отката: sudo xrayebator-update → Stable${NC}"
    ;;
esac

echo ""
echo -e "${BLUE}Команды:${NC}"
echo -e "  ${YELLOW}sudo xrayebator${NC} - запустить менеджер"
echo -e "  ${YELLOW}sudo xrayebator-update${NC} - сменить/обновить версию"
echo -e "  ${YELLOW}systemctl status xray${NC} - статус сервиса"
echo -e "  ${YELLOW}journalctl -u xray -f${NC} - логи в реальном времени"
echo ""

echo -e "${MAGENTA}За свободу интернета! 🚀${NC}"
echo ""
