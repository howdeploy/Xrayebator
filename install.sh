#!/bin/bash

# ═══════════════════════════════════════════════════════════
# XRAYEBATOR INSTALLER v3.0
# Автоматическая установка Xray Reality VPN
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
GITHUB_BRANCH="main"
RAW_BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

# Пути
CONFIG_FILE="/usr/local/etc/xray/config.json"
PROFILES_DIR="/usr/local/etc/xray/profiles"
DATA_DIR="/usr/local/etc/xray/data"
SCRIPTS_DIR="/usr/local/etc/xray/scripts"
PRIVATE_KEY_FILE="/usr/local/etc/xray/.private_key"
PUBLIC_KEY_FILE="/usr/local/etc/xray/.public_key"
APT_LOG="/tmp/xrayebator-apt.log"

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

# ═══ Префлайт проверки (DPI, OS, systemd) ═══
# Без этого блока 30% реальных сбоев дают нечитаемые ошибки
# (например, apt: command not found на CentOS как "bash: apt: command not found").
if [[ -z "$BASH_VERSION" ]]; then
  echo "Запустите через bash: curl ... | sudo bash" >&2
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}✗ Требуются права root для установки${NC}" >&2
  echo -e "${YELLOW}Запустите:${NC} ${CYAN}sudo bash $0${NC}" >&2
  exit 1
fi

# ОС: только Debian/Ubuntu (apt-based)
if [[ ! -f /etc/debian_version ]] && ! command -v apt-get >/dev/null 2>&1; then
  echo -e "${RED}✗ Xrayebator поддерживает только Debian/Ubuntu (apt-based)${NC}" >&2
  [[ -f /etc/os-release ]] && head -3 /etc/os-release
  echo -e "${CYAN}Для CentOS/RHEL используйте docker исходник или ручную установку Xray.${NC}" >&2
  exit 1
fi

# systemd обязательно (без него systemctl упадут на OpenVZ/LXC/Docker)
if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
  echo -e "${RED}✗ systemd не обнаружен (OpenVZ/LXC/Docker окружение)${NC}" >&2
  echo -e "${YELLOW}Xrayebator требует systemd. Возьмите KVM-VPS.${NC}" >&2
  exit 1
fi

# === Install state machine: --check / --resume / --fresh ===
STEP_DIR="/usr/local/etc/xray"
STEP_ORDER=(1 2 3 35 4 5 6 7 8 9)
declare -A STEP_LABELS=(
  [1]="apt packages" [2]="Xray-core" [3]="systemd unit" [35]="GeoIP/GeoSite"
  [4]="Directories" [5]="Reality + VLESS keys" [6]="Base config.json"
  [7]="UFW firewall" [8]="sni_list + ascii_art" [9]="bin + start Xray"
)
_step_marker() { echo "${STEP_DIR}/.install_step_$1_ok"; }
_step_done()  { [[ -f "$(_step_marker "$1")" ]]; }
_step_mark()  { mkdir -p "$STEP_DIR" 2>/dev/null; touch "$(_step_marker "$1")"; }

# P2-fix: регистрируем правило UFW, открытое именно Xrayebator, в root-owned манифесте
# /usr/local/etc/xray/.ufw_owned. uninstall.sh удалит ТОЛЬКО порты отсюда и динамические
# порты из config.json — чужие правила 443/8443/8080 не затрагиваются.
# Аргументы: $1=string "port/proto". Идемпотентно.
_ufw_own_entry() {
  local entry="$1"
  local manifest="${UFW_OWNED_MANIFEST:-/usr/local/etc/xray/.ufw_owned}"
  mkdir -p /usr/local/etc/xray 2>/dev/null || true
  if [[ ! -f "$manifest" ]]; then
    printf '%s\n' "$entry" > "$manifest"
  else
    grep -qxF "$entry" "$manifest" 2>/dev/null || printf '%s\n' "$entry" >> "$manifest"
  fi
  chmod 644 "$manifest" 2>/dev/null || true
  chown root:root "$manifest" 2>/dev/null || true
}

_first_pending_step() {
  local s
  for s in "${STEP_ORDER[@]}"; do
    _step_done "$s" || { echo "$s"; return 0; }
  done
  return 1
}

INSTALL_MODE="auto"
RESUME_FROM=""
for _arg in "$@"; do
  case "$_arg" in
    --check)
      echo "=== Xrayebator install status ==="
      for s in "${STEP_ORDER[@]}"; do
        if _step_done "$s"; then printf '  [OK]   [%s] %s\n' "$s" "${STEP_LABELS[$s]}"; else printf '  [TODO] [%s] %s\n' "$s" "${STEP_LABELS[$s]}"; fi
      done
      next=$(_first_pending_step || true)
      if [[ -n "$next" ]]; then printf '\nNext step to resume: %s (%s)\n' "$next" "${STEP_LABELS[$next]}"; else printf '\nAll steps done.\n'; fi
      exit 0
      ;;
    --resume)
      INSTALL_MODE="resume"
      next=$(_first_pending_step || true)
      if [[ -z "$next" ]]; then echo "Nothing to install -- all steps done." >&2; exit 0; fi
      RESUME_FROM="$next"
      echo "Resume: continue from step $next (${STEP_LABELS[$next]})..." >&2
      ;;
    --fresh)
      INSTALL_MODE="fresh"
      rm -f "${STEP_DIR}"/.install_step_*_ok 2>/dev/null || true
      RESUME_FROM=""
      echo "Fresh: markers cleared, installing from scratch." >&2
      ;;
  esac
done

if [[ "$INSTALL_MODE" == "auto" ]]; then
  next=$(_first_pending_step || true)
  if [[ -z "$next" ]]; then
    echo "All steps are already marked done."
    echo "To reinstall from scratch: sudo bash install.sh --fresh"
    exit 0
  fi
  if [[ "$next" != "1" ]]; then
    RESUME_FROM="$next"
    echo "Resuming from step $next (${STEP_LABELS[$next]})."
    echo "(To start over: sudo bash install.sh --fresh)"
    sleep 2
  fi
fi

_should_run() {
  [[ -z "${RESUME_FROM:-}" ]] && return 0
  [[ "$1" == "${RESUME_FROM}" ]] && return 0
  local target_idx="" me_idx="" i
  for i in "${!STEP_ORDER[@]}"; do
    [[ "${STEP_ORDER[i]}" == "${RESUME_FROM}" ]] && target_idx=$i
    [[ "${STEP_ORDER[i]}" == "$1" ]] && me_idx=$i
  done
  [[ -n "$me_idx" && -n "$target_idx" ]] || return 0
  [[ $me_idx -ge $target_idx ]]
}

clear
echo -e "${CYAN}"
echo '╔═══════════════════════════════════════════════════════════╗'
echo '║                                                           ║'
echo '║              XRAYEBATOR INSTALLER v3.0                   ║'
echo '║       Автоматическая установка Xray Reality VPN          ║'
echo '║                                                           ║'
echo '╚═══════════════════════════════════════════════════════════╝'
echo -e "${NC}\n"
echo -e "${YELLOW}Начало установки...${NC}\n"
sleep 2

if _should_run 1; then

# [1/9] Установка зависимостей
echo -e "${BLUE}[1/9]${NC} ${YELLOW}Установка необходимых пакетов...${NC}"

# Диагностика DNS до apt: если резолв не работает, apt упадёт с непонятной ошибкой.
# A2-fix: проверяем резолв через getent (не привязываясь к Ubuntu-зеркалам), а при
# подмене resolv.conf заменяем симлинк реальным файлом (иначе printf пишет сквозь
# symlink systemd-resolved в /run/systemd/resolve/stub-resolv.conf и бэкап неверен).
# DNS-бустреп перед apt: если IPv4-резолверы недоступны (IPv6-only VPS), используем
# IPv6-совместимые. P1-ipv6-fix: раньше жёстко писался 1.1.1.1/9.9.9.9, на IPv6-only
# хосте bootstrap мог сорвать apt. Теперь resolver выбирается family-aware.
if ! getent hosts archive.ubuntu.com >/dev/null 2>&1 && ! getent hosts deb.debian.org >/dev/null 2>&1; then
  if _detect_ipv6_only; then
    echo -e "${YELLOW}⚠ DNS не резолвит зеркала (IPv6-only) — подменяю /etc/resolv.conf на IPv6-резолверы${NC}"
    local_v6_resolvers="nameserver 2606:4700:4700::1111\nnameserver 2001:4860:4860::8888\n"
    if [[ -L /etc/resolv.conf ]]; then
      # Не пишем сквозь symlink systemd-resolved: сохраняем target отдельно, заменяем сам symlink.
      local_resolv_target="$(readlink /etc/resolv.conf)"
      cp -a "/etc/resolv.conf" "/etc/resolv.conf.bak.xrayebator" 2>/dev/null || true
      echo -e "${YELLOW}  (symlink → ${local_resolv_target}; заменяю файлом, резерв: /etc/resolv.conf.bak.xrayebator)${NC}"
      rm -f /etc/resolv.conf
    else
      cp /etc/resolv.conf /etc/resolv.conf.bak.xrayebator 2>/dev/null || true
    fi
    printf '%b' "$local_v6_resolvers" > /etc/resolv.conf
  else
    echo -e "${YELLOW}⚠ DNS не резолвит пакетные зеркала — подменяю /etc/resolv.conf на 1.1.1.1${NC}"
    if [[ -L /etc/resolv.conf ]]; then
      # Не пишем сквозь symlink systemd-resolved: сохраняем target отдельно, заменяем сам symlink.
      local_resolv_target="$(readlink /etc/resolv.conf)"
      cp -a "/etc/resolv.conf" "/etc/resolv.conf.bak.xrayebator" 2>/dev/null || true
      echo -e "${YELLOW}  (symlink → ${local_resolv_target}; заменяю файлом, резерв: /etc/resolv.conf.bak.xrayebator)${NC}"
      rm -f /etc/resolv.conf
    else
      cp /etc/resolv.conf /etc/resolv.conf.bak.xrayebator 2>/dev/null || true
    fi
    printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > /etc/resolv.conf
  fi
  if ! getent hosts archive.ubuntu.com >/dev/null 2>&1 && ! getent hosts deb.debian.org >/dev/null 2>&1; then
    echo -e "${YELLOW}  ⚠ Всё ещё нет резолва — продолжаю, apt может не сработать${NC}"
  fi
fi

echo -e "${CYAN}  → apt update...${NC}"
if ! apt update >"$APT_LOG" 2>&1; then
  echo -e "${RED}✗ apt update не прошёл. Проверьте /etc/resolv.conf:${NC}"
  tail -5 "$APT_LOG"
  cat /etc/resolv.conf 2>/dev/null
  echo -e "${YELLOW}Попробуйте: echo 'nameserver 1.1.1.1' > /etc/resolv.conf${NC}"
  exit 1
fi
if ! apt install -y ca-certificates curl wget jq qrencode uuid-runtime ufw unzip openssl socat >"$APT_LOG" 2>&1; then
  echo -e "${RED}✗ Ошибка установки зависимостей${NC}"
  tail -10 "$APT_LOG"
  exit 1
fi
echo -e "${GREEN}✓ Зависимости установлены${NC}\n"

_step_mark 1
fi

if _should_run 2; then

# [2/9] Установка Xray-core (REQ-B03 single source of truth)
echo -e "${BLUE}[2/9]${NC} ${YELLOW}Установка Xray-core...${NC}"

# Inline-копия update_xray_core() (синхронизирована с update.sh / xrayebator через
# validation/test-update-xray-core-sync.sh).
# На свежей установке /usr/local/bin/xray отсутствует → CURRENT_VERSION="неустановлено"
# → flow становится «download + install», без compare/confirmation branch.
# INSTALL_MODE=1 bypass'ит confirmation prompt и активирует install-mode guards
# на Step 10 (config.json может отсутствовать) и Step 13 (systemd unit еще не настроен).

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

INSTALL_MODE=1 update_xray_core
UPDATE_RC=$?
if [[ $UPDATE_RC -ne 0 ]]; then
  echo -e "${RED}✗ Не удалось установить Xray-core (код $UPDATE_RC)${NC}"
  echo -e "${YELLOW}  Ручная установка: https://github.com/XTLS/Xray-core/releases/latest${NC}"
  exit 1
fi

# Проверка что бинарник появился
if [[ ! -x /usr/local/bin/xray ]]; then
  echo -e "${RED}✗ Бинарник Xray не найден после установки${NC}"
  exit 1
fi
XRAY_VERSION=$(/usr/local/bin/xray version 2>/dev/null | head -1)
echo -e "${GREEN}✓ Xray-core установлен${NC}"
echo -e "${CYAN}  ${XRAY_VERSION}${NC}\n"

_step_mark 2
fi

if _should_run 3; then

# [3/9] Настройка Xray сервиса (non-root с capabilities)
echo -e "${BLUE}[3/9]${NC} ${YELLOW}Настройка Xray сервиса...${NC}"

# Create xray system user if not exists
if ! getent passwd xray >/dev/null 2>&1; then
  NOLOGIN_SHELL="/usr/sbin/nologin"
  [[ -x "$NOLOGIN_SHELL" ]] || NOLOGIN_SHELL="/sbin/nologin"
  [[ -x "$NOLOGIN_SHELL" ]] || NOLOGIN_SHELL="/bin/false"
  if ! getent group xray >/dev/null 2>&1; then
    groupadd -r xray 2>/dev/null || true
  fi
  if getent group xray >/dev/null 2>&1; then
    useradd -r -g xray -s "$NOLOGIN_SHELL" -M -d /nonexistent xray
  else
    useradd -r -s "$NOLOGIN_SHELL" -M -d /nonexistent xray
  fi
  if ! getent passwd xray >/dev/null 2>&1; then
    echo -e "${RED}✗ Не удалось создать пользователя xray${NC}"
    exit 1
  fi
  echo -e "${GREEN}  ✓ Пользователь xray создан${NC}"
fi

# Create base systemd unit if the Xray package/zip install did not provide one.
if ! systemctl cat xray.service >/dev/null 2>&1; then
  cat > /etc/systemd/system/xray.service <<'SVCEOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
User=xray
Group=xray
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SVCEOF
  chmod 644 /etc/systemd/system/xray.service
  echo -e "${GREEN}  ✓ xray.service создан${NC}"
else
  echo -e "${CYAN}  → xray.service уже существует${NC}"
fi

# Create systemd drop-in for non-root with capabilities
mkdir -p /etc/systemd/system/xray.service.d
cat > /etc/systemd/system/xray.service.d/security.conf << 'SVCEOF'
[Service]
User=xray
Group=xray
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
SVCEOF

systemctl daemon-reload
echo -e "${GREEN}✓ Сервис настроен (User=xray, CAP_NET_BIND_SERVICE)${NC}\n"

_step_mark 3
fi

if _should_run 35; then

# [3.5/10] Загрузка расширенных geo-баз (Loyalsoldier)
echo -e "${BLUE}[3.5/10]${NC} ${YELLOW}Загрузка расширенных geo-баз...${NC}"
XRAY_DAT_DIR="/usr/local/share/xray"
LOYALSOLDIER_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"

mkdir -p "$XRAY_DAT_DIR"

# Download geoip.dat
echo -e "${CYAN}  → Загрузка geoip.dat...${NC}"
if curl -fsSL "${LOYALSOLDIER_URL}/geoip.dat" -o "${XRAY_DAT_DIR}/geoip.dat.tmp"; then
  if [[ -s "${XRAY_DAT_DIR}/geoip.dat.tmp" ]]; then
    mv "${XRAY_DAT_DIR}/geoip.dat.tmp" "${XRAY_DAT_DIR}/geoip.dat"
    echo -e "${GREEN}  ✓ geoip.dat загружен${NC}"
  else
    rm -f "${XRAY_DAT_DIR}/geoip.dat.tmp"
    echo -e "${YELLOW}  ⚠ geoip.dat пустой, используется стандартный${NC}"
  fi
else
  echo -e "${YELLOW}  ⚠ Не удалось загрузить geoip.dat, используется стандартный${NC}"
fi

# Download geosite.dat
echo -e "${CYAN}  → Загрузка geosite.dat...${NC}"
if curl -fsSL "${LOYALSOLDIER_URL}/geosite.dat" -o "${XRAY_DAT_DIR}/geosite.dat.tmp"; then
  if [[ -s "${XRAY_DAT_DIR}/geosite.dat.tmp" ]]; then
    mv "${XRAY_DAT_DIR}/geosite.dat.tmp" "${XRAY_DAT_DIR}/geosite.dat"
    echo -e "${GREEN}  ✓ geosite.dat загружен${NC}"
  else
    rm -f "${XRAY_DAT_DIR}/geosite.dat.tmp"
    echo -e "${YELLOW}  ⚠ geosite.dat пустой, используется стандартный${NC}"
  fi
else
  echo -e "${YELLOW}  ⚠ Не удалось загрузить geosite.dat, используется стандартный${NC}"
fi

echo -e "${GREEN}✓ Geo-базы настроены (Loyalsoldier enhanced)${NC}\n"

_step_mark 35
fi

if _should_run 4; then

# [4/9] Создание структуры директорий
echo -e "${BLUE}[4/9]${NC} ${YELLOW}Создание структуры директорий...${NC}"
mkdir -p "$PROFILES_DIR"
mkdir -p "$DATA_DIR"
mkdir -p "$SCRIPTS_DIR"
mkdir -p /var/log/xray
chown xray:xray /var/log/xray
# Privilege boundary (P0-fix): /usr/local/etc/xray принадлежит root:root,
# xray получает только чтение. Root-скрипты и markers не подменяемы xray.
chown root:root /usr/local/etc/xray/ /usr/local/etc/xray/profiles /usr/local/etc/xray/data /usr/local/etc/xray/scripts
chmod 755 /usr/local/etc/xray/ /usr/local/etc/xray/profiles /usr/local/etc/xray/data /usr/local/etc/xray/scripts
echo -e "${GREEN}✓ Директории созданы${NC}\n"

_step_mark 4
fi

if _should_run 5; then

# [5/9] Генерация ключей Reality
echo -e "${BLUE}[5/9]${NC} ${YELLOW}Генерация ключей Reality...${NC}"

if [[ ! -x /usr/local/bin/xray ]]; then
  echo -e "${RED}✗ Бинарник /usr/local/bin/xray не найден или не исполняемый${NC}"
  echo -e "${YELLOW}  Установка Xray на шаге [2/9] могла завершиться некорректно${NC}"
  exit 1
fi

# Идемпотентность: повторный запуск install.sh НЕ должен перегенерировать ключи —
# они уже могут использоваться существующими профилями.
if [[ -s "$PRIVATE_KEY_FILE" && -s "$PUBLIC_KEY_FILE" ]]; then
  echo -e "${CYAN}  → Ключи уже существуют, перегенерация пропущена${NC}\n"
else

KEYS_OUTPUT=$(/usr/local/bin/xray x25519 2>&1)
KEYS_EXIT=$?

if [[ $KEYS_EXIT -ne 0 ]]; then
  echo -e "${RED}✗ Команда xray x25519 завершилась с ошибкой (код $KEYS_EXIT)${NC}"
  echo "Вывод:"
  echo "$KEYS_OUTPUT"
  exit 1
fi

# Парсинг всех форматов вывода xray x25519:
#   Старый (до v25.8):     Private key: ... / Public key: ...
#   Средний (v25.8-v26.3): PrivateKey: ...  / Password: ...
#   Новый (v26.3.27+):     PrivateKey: ...  / Password (PublicKey): ...
# Layer 1: known field names (поддерживает все 3 формата вывода xray x25519:
#   Старый (до v25.8):     Private key: ... / Public key: ...
#   Средний (v25.8-v26.3): PrivateKey: ...  / Password: ...
#   Новый (v26.3.27+):     PrivateKey: ...  / Password (PublicKey): ...
PRIVATE_KEY=$(echo "$KEYS_OUTPUT" | awk -F': ' '/^Private [Kk]ey:/ || /^PrivateKey:/ {print $2; exit}')
PUBLIC_KEY=$(echo "$KEYS_OUTPUT" | awk -F': ' '/^Public [Kk]ey:/ || /^Password/ {print $2; exit}')

# Layer 2 (fallback): если field-name parser не сработал — найти строки base64 shape.
# x25519 keys = 32 байта = 43 символа base64.RawURLEncoding (без padding, алфавит [A-Za-z0-9_-])
# ИЛИ 44 символа base64.StdEncoding (с одним '=' padding, алфавит [A-Za-z0-9+/=]).
# Расширенный regex покрывает оба алфавита: [A-Za-z0-9_+/=-] длиной 43-44.
if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
  echo -e "${YELLOW}⚠ Field-based парсер не нашёл ключи, пробую base64-shape fallback${NC}"
  KEY_CANDIDATES=$(echo "$KEYS_OUTPUT" | grep -oE '[A-Za-z0-9_+/=-]{43,44}' | head -2)
  PRIVATE_KEY=$(echo "$KEY_CANDIDATES" | sed -n '1p')
  PUBLIC_KEY=$(echo "$KEY_CANDIDATES" | sed -n '2p')
fi

# Layer 3 (validator): оба ключа должны быть base64 (RawURL или Std) длиной 43-44.
# RawURL (Xray default): 43 chars, алфавит [A-Za-z0-9_-]
# Std (legacy/edge): 44 chars (с '=' padding), алфавит [A-Za-z0-9+/=]
# Объединённый regex покрывает оба варианта.
validate_x25519_key() {
  local key="$1"
  [[ "$key" =~ ^[A-Za-z0-9_+/=-]{43,44}$ ]]
}

if ! validate_x25519_key "$PRIVATE_KEY" || ! validate_x25519_key "$PUBLIC_KEY"; then
  echo -e "${RED}✗ Ключи не прошли base64-валидацию (ожидаются 43-44 символа base64-url или base64-std)${NC}"
  echo -e "${YELLOW}Вывод команды:${NC}"
  echo "$KEYS_OUTPUT"
  echo -e "${YELLOW}Распарсено:${NC}"
  echo -e "  Private (${#PRIVATE_KEY} chars): ${PRIVATE_KEY:0:20}..."
  echo -e "  Public  (${#PUBLIC_KEY} chars): ${PUBLIC_KEY:0:20}..."
  exit 1
fi

printf "%s" "$PRIVATE_KEY" > "$PRIVATE_KEY_FILE"
printf "%s" "$PUBLIC_KEY" > "$PUBLIC_KEY_FILE"
chmod 600 "$PRIVATE_KEY_FILE"
chmod 644 "$PUBLIC_KEY_FILE"
echo -e "${GREEN}✓ Ключи сгенерированы${NC}"
echo -e "${CYAN}  Private: ${PRIVATE_KEY:0:16}...${NC}"
echo -e "${CYAN}  Public: ${PUBLIC_KEY:0:16}...${NC}\n"

# Set ownership for root (privilege boundary): приватный ключ — root:root 600,
# публичный — root:root 644. Сервис xray читает ключи из config.json, не из файлов.
chown root:root "$PRIVATE_KEY_FILE" "$PUBLIC_KEY_FILE"
chmod 600 "$PRIVATE_KEY_FILE"
chmod 644 "$PUBLIC_KEY_FILE"

fi  # end keys idempotency guard

# ── VLESS Encryption keys (Phase 6 REQ-A01) ────────────────────
# Генерация PQ decryption/encryption пары через xray vlessenc.
# Требует Xray-core ≥ 25.9.5 (гарантируется install.sh шагом «Установка Xray-core» latest stable).
echo -e "${BLUE}[5b/10]${NC} ${YELLOW}Генерация VLESS Encryption ключей (mlkem768x25519plus.native)...${NC}"

VLESS_DECRYPTION_FILE="/usr/local/etc/xray/.vless_decryption"
VLESS_ENCRYPTION_FILE="/usr/local/etc/xray/.vless_encryption"

# Идемпотентность: как Reality keys (:618), повторный запуск / --resume / --fresh
# НЕ должен перегенерировать ключи — иначе все существующие PQ-профили клиентов
# становятся orphaned (их encryption string больше не соответствует серверному decryption).
if [[ -s "$VLESS_DECRYPTION_FILE" && -s "$VLESS_ENCRYPTION_FILE" ]] \
   && grep -q '^mlkem768x25519plus\.' "$VLESS_DECRYPTION_FILE" 2>/dev/null; then
  echo -e "${CYAN}  → VLESS Encryption ключи уже существуют, перегенерация пропущена${NC}\n"
  _step_mark 5
  # продолжаем к следующему шагу (step 6 обрабатывается следующим if-блоком)
else

VLESSENC_OUTPUT=$(/usr/local/bin/xray vlessenc 2>&1)
VLESSENC_EXIT=$?

if [[ $VLESSENC_EXIT -ne 0 ]]; then
  echo -e "${RED}✗ xray vlessenc завершилась с ошибкой (код $VLESSENC_EXIT)${NC}"
  echo "Вывод:"; echo "$VLESSENC_OUTPUT"
  exit 1
fi

# Layer 1: section-aware parser — берём именно ML-KEM-768 auth pair, не X25519 pair.
VLESS_DECRYPTION=$(echo "$VLESSENC_OUTPUT" | awk -F'"' '
  /^Authentication: ML-KEM-768/ { in_mlkem=1; next }
  in_mlkem && /^"decryption":/ { print $4; exit }
' | tr -d '[:space:]')
VLESS_ENCRYPTION=$(echo "$VLESSENC_OUTPUT" | awk -F'"' '
  /^Authentication: ML-KEM-768/ { in_mlkem=1; next }
  in_mlkem && /^"encryption":/ { print $4; exit }
' | tr -d '[:space:]')

# Layer 2: mlkem-shape fallback. Если Xray в будущей версии уберёт section labels,
# tail -2 выбирает последнюю пару; в current output это ML-KEM-768.
if [[ ! "$VLESS_DECRYPTION" =~ ^mlkem768x25519plus\. ]] || [[ ! "$VLESS_ENCRYPTION" =~ ^mlkem768x25519plus\. ]]; then
  echo -e "${YELLOW}⚠ Section-парсер не нашёл ключи, пробую mlkem-shape fallback${NC}"
  MLKEM_LINES=$(echo "$VLESSENC_OUTPUT" | grep -oE 'mlkem768x25519plus\.[^"[:space:]]+')
  VLESS_DECRYPTION=$(echo "$MLKEM_LINES" | tail -2 | sed -n '1p')
  VLESS_ENCRYPTION=$(echo "$MLKEM_LINES" | tail -1)
fi

# Layer 3: validator
if [[ ! "$VLESS_DECRYPTION" =~ ^mlkem768x25519plus\. ]] || [[ ! "$VLESS_ENCRYPTION" =~ ^mlkem768x25519plus\. ]]; then
  echo -e "${RED}✗ Не удалось распарсить mlkem768x25519plus ключи${NC}"
  echo -e "${YELLOW}  Убедитесь что Xray-core ≥ 25.9.5 установлен${NC}"
  echo -e "${YELLOW}Полный вывод vlessenc:${NC}"; echo "$VLESSENC_OUTPUT"
  exit 1
fi

printf "%s" "$VLESS_DECRYPTION" > "$VLESS_DECRYPTION_FILE"
printf "%s" "$VLESS_ENCRYPTION" > "$VLESS_ENCRYPTION_FILE"
# Privilege boundary (P0-fix): decryption (приватная часть) — root:root 600;
# encryption (публичная часть, читается subhttp для генерации VLESS URL) — root:root 644.
chmod 600 "$VLESS_DECRYPTION_FILE"
chmod 644 "$VLESS_ENCRYPTION_FILE"
chown root:root "$VLESS_DECRYPTION_FILE" "$VLESS_ENCRYPTION_FILE" 2>/dev/null || true

echo -e "${GREEN}✓ VLESS Encryption ключи сгенерированы${NC}"
echo -e "${CYAN}  decryption: ${VLESS_DECRYPTION:0:48}...${NC}"

fi  # end VLESS keys idempotency guard

_step_mark 5
fi

if _should_run 6; then

# [6/9] Создание базовой конфигурации
echo -e "${BLUE}[6/9]${NC} ${YELLOW}Создание конфигурации Xray...${NC}"

# IPv6-only детекция: на VPS без публичного IPv4 указываем queryStrategy/domainStrategy
# как UseIP (иначе Xray не сможет резолвить AAAA и клиентский трафик встанет).
QUERY_STRATEGY=$(_ipv6_query_strategy)
FREEDOM_STRATEGY=$(_ipv6_query_strategy)
if _detect_ipv6_only; then
  echo -e "${CYAN}  IPv4 не обнаружен — DNS/outbound strategy = UseIP (IPv6-compatible)${NC}"
fi

# DNS-бустреп: на IPv6-only VPS нет маршрута до IPv4-резолверов (1.1.1.1),
# поэтому используем IPv6-совместимый DoH (Google) вместе с IPv4 DoH.
dns_main_doh="https+local://1.1.1.1/dns-query"
dns_fallback_doh="localhost"
if _detect_ipv6_only; then
  dns_main_doh="https+local://dns.google/dns-query"
fi

# A1-fix: при переустановке сохраняем существующий конфиг перед перезаписью,
# чтобы не потерять боевые inbound/профили (иначе сервер остаётся без инбаундов).
if [[ -s "$CONFIG_FILE" ]]; then
  local_backup_dir="${BACKUP_DIR:-/usr/local/etc/xray/backups}"
  mkdir -p "$local_backup_dir"
  cp -a "$CONFIG_FILE" "$local_backup_dir/pre-fresh-$(date +%Y%m%d-%H%M%S).json" 2>/dev/null || true
  echo -e "${YELLOW}⚠ Существующий config.json сохранён в $local_backup_dir (бэкап перед переустановкой)${NC}"
fi

cat > "$CONFIG_FILE" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "none"
  },
  "dns": {
    "servers": [
      "${dns_main_doh}",
      "${dns_fallback_doh}"
    ],
    "queryStrategy": "${QUERY_STRATEGY}",
    "disableCache": false
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "direct"
      }
    ]
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "${FREEDOM_STRATEGY}"
      },
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 300,
        "uplinkOnly": 2,
        "downlinkOnly": 5,
        "bufferSize": 4
      }
    }
  }
}
EOF

# Privilege boundary (P0-fix): config.json читается xray (644), владелец root:root.
chown root:root "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"
# Mark config as already optimized (skip migration on first launch)
touch /usr/local/etc/xray/.config_optimized
chown root:root /usr/local/etc/xray/.config_optimized
chmod 644 /usr/local/etc/xray/.config_optimized
echo -e "${GREEN}✓ Конфигурация создана${NC}\n"

_step_mark 6
fi

if _should_run 7; then

# [7/9] Настройка Firewall
echo -e "${BLUE}[7/9]${NC} ${YELLOW}Настройка firewall...${NC}"

# B1-fix: детектируем фактический SSH-порт ДО включения UFW (default policy = deny).
# Если SSH на нестандартном порту и открыть его после enable — заперём себя на VPS.
# P2-fix: разбор ss охватывает и обычные bind-формы вида 0.0.0.0:2222 / [::]:2222,
# и когда порт/правило не удалось определить — НЕ включаем UFW (иначе lockout).
sfw_ssh_port=""
if command -v ss >/dev/null 2>&1; then
  # ss -tlnp построчно: ищем строки с флагом LISTEN и процессом sshd, извлекаем
  # локальный порт из последнего ':'-сегмента адреса (0.0.0.0:2222, *:2222, [::]:2222).
  sfw_ssh_port=$(ss -tlnp 2>/dev/null | awk '
    /LISTEN/ && /sshd/ {
      for (i=1; i<=NF; i++) {
        if ($i ~ /^(\[?\*|\[?[0-9a-fA-F:.]+):[0-9]+$/) {
          split($i, a, ":")
          print a[length(a)]
          exit
        }
      }
    }')
  sfw_ssh_port="${sfw_ssh_port%%[,;]*}"
fi
if [[ -z "$sfw_ssh_port" ]] || ! [[ "$sfw_ssh_port" =~ ^[0-9]+$ ]]; then
  # Fallback: читаем ListenAddress sshd_config.
  sfw_ssh_port=$(grep -h '^Port\s' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}' | head -1)
fi

# Определили ли мы SSH-порт? Если нет и нельзя открыть правило — UFW не включаем
# (default policy = deny, lockout). Лучше оставить UFW выключенным, чем запереть себя.
sfw_ufw_safe=0
if [[ -n "$sfw_ssh_port" ]] && [[ "$sfw_ssh_port" =~ ^[0-9]+$ ]]; then
  if ufw allow "${sfw_ssh_port}/tcp" > /dev/null 2>&1; then
    sfw_ufw_safe=1
    echo -e "${CYAN}  SSH-порт ${sfw_ssh_port}/tcp открыт перед включением UFW${NC}"
  else
    echo -e "${YELLOW}  ⚠ Не удалось открыть SSH-порт ${sfw_ssh_port} — UFW остаётся выключенным${NC}"
  fi
else
  echo -e "${YELLOW}  ⚠ Не удалось определить SSH-порт — UFW не включается (защита от блокировки)${NC}"
fi

if command -v ufw >/dev/null 2>&1; then
if [[ "$sfw_ufw_safe" -eq 1 ]] && ! ufw status | grep -q "Status: active"; then
  ufw --force enable > /dev/null 2>&1
fi
else
  sfw_ufw_safe=0
fi

UFW_ERRORS=0
# P2-fix: регистрируем в root-owned манифесте только правила, открытые ИМЕННО
# Xrayebator (иначе uninstall удалил бы чужое правило на 443/8443). Если правило
# уже существовало ДО нас — не трогаем и не регистрируем.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
for ufw_port in 22 80 443 8443 2053 2083 2087 8080 2096 8880 9443; do
  if ufw status 2>/dev/null | grep -qE "^${ufw_port}/tcp.*ALLOW"; then
    continue  # уже открыто кем-то до нас — чужие правила не присваиваем
  fi
  if ! ufw allow "${ufw_port}/tcp" > /dev/null 2>&1; then
    echo -e "${YELLOW}  ⚠ Не удалось открыть порт ${ufw_port}/tcp${NC}"
    ((UFW_ERRORS++))
  else
    # P2-fix: манифест root:root 644 — только правила, открытые Xrayebator.
    _ufw_own_entry "${ufw_port}/tcp"
  fi
done

ufw reload > /dev/null 2>&1
echo -e "${GREEN}✓ Firewall настроен${NC}"
echo -e "${CYAN}  Открытые порты: 443, 2053, 2096, 8080, 8443, 8880, 9443${NC}\n"
else
echo -e "${YELLOW}  ⚠ UFW не включён — порты не открывались (избегаем блокировки SSH)${NC}"
fi

_step_mark 7
fi

if _should_run 8; then

# [8/9] Загрузка данных
echo -e "${BLUE}[8/9]${NC} ${YELLOW}Загрузка данных приложения...${NC}"
curl -fsSL --connect-timeout 10 --max-time 30 "${RAW_BASE_URL}/sni_list.txt" -o "${DATA_DIR}/sni_list.txt"
if [[ $? -eq 0 ]] && [[ -s "${DATA_DIR}/sni_list.txt" ]]; then
  echo -e "${GREEN}✓ Список SNI загружен${NC}"
else
  echo -e "${YELLOW}⚠ Не удалось загрузить список SNI, создаю базовый...${NC}"
  cat > "${DATA_DIR}/sni_list.txt" << 'EOF'
www.ozon.ru|ru_whitelist|1
wildberries.ru|ru_whitelist|1
sberbank.ru|ru_whitelist|1
nspk.ru|ru_whitelist|1
speller.yandex.net|yandex_cdn|2
gosuslugi.ru|ru_whitelist|1
stats.vk-portal.net|ru_whitelist|1
github.com|foreign|3
cloudflare.com|foreign|3
www.microsoft.com|foreign|3
EOF
fi

curl -fsSL --connect-timeout 10 --max-time 30 "${RAW_BASE_URL}/ascii_art.txt" -o "${DATA_DIR}/ascii_art.txt" 2>/dev/null
if [[ -s "${DATA_DIR}/ascii_art.txt" ]]; then
  echo -e "${GREEN}✓ ASCII арт загружен${NC}\n"
else
  echo -e "${CYAN}✓ ASCII арт недоступен (не критично)${NC}\n"
fi

_step_mark 8
fi

if _should_run 9; then

# [9/9] Установка приложения
echo -e "${BLUE}[9/9]${NC} ${YELLOW}Установка управляющего приложения...${NC}"
XRAYEBATOR_TMP=$(mktemp /tmp/xrayebator_install_XXXXXX)
if curl -fsSL --connect-timeout 10 --max-time 60 "${RAW_BASE_URL}/xrayebator" -o "$XRAYEBATOR_TMP" \
   && [[ -s "$XRAYEBATOR_TMP" ]] \
   && head -n 1 "$XRAYEBATOR_TMP" | grep -q "^#!/bin/bash" \
   && bash -n "$XRAYEBATOR_TMP"; then
  chmod 755 "$XRAYEBATOR_TMP"
  mv "$XRAYEBATOR_TMP" /usr/local/bin/xrayebator
  echo -e "${GREEN}✓ Приложение xrayebator установлено${NC}"
else
  echo -e "${RED}✗ Ошибка загрузки xrayebator${NC}"
  rm -f "$XRAYEBATOR_TMP"
  exit 1
fi

# Скрипты управления (атомарная установка, P0-privilege-boundary-fix):
# mktemp в /tmp + chmod 755 + mv (rename) — файл не бывает «полузаписан».
# После mv проверяем ownership/mode: root:root 755, иначе скрипт подменяем xray.
UPDATE_TMP=$(mktemp /tmp/xrayebator_update_install_XXXXXX.sh)
if curl -fsSL --connect-timeout 10 --max-time 30 "${RAW_BASE_URL}/update.sh" -o "$UPDATE_TMP" 2>/dev/null \
   && [[ -s "$UPDATE_TMP" ]] \
   && head -n 1 "$UPDATE_TMP" | grep -q "^#!/bin/bash" \
   && bash -n "$UPDATE_TMP"; then
  chmod 755 "$UPDATE_TMP"
  chown root:root "$UPDATE_TMP"
  mv "$UPDATE_TMP" "${SCRIPTS_DIR}/update.sh"
  # Проверка: владелец root, права 755 (каталог scripts — root:root 755).
  if ! [[ -O "${SCRIPTS_DIR}/update.sh" && -x "${SCRIPTS_DIR}/update.sh" ]]; then
    echo -e "${RED}✗ update.sh установлен с неверными правами — прерывание${NC}"
    exit 1
  fi
else
  echo -e "${YELLOW}⚠ update.sh не загружен или невалиден${NC}"
  rm -f "$UPDATE_TMP"
fi
UNINSTALL_TMP=$(mktemp /tmp/xrayebator_uninstall_install_XXXXXX.sh)
if curl -fsSL --connect-timeout 10 --max-time 30 "${RAW_BASE_URL}/uninstall.sh" -o "$UNINSTALL_TMP" 2>/dev/null \
   && [[ -s "$UNINSTALL_TMP" ]] \
   && head -n 1 "$UNINSTALL_TMP" | grep -q "^#!/bin/bash" \
   && bash -n "$UNINSTALL_TMP"; then
  chmod 755 "$UNINSTALL_TMP"
  chown root:root "$UNINSTALL_TMP"
  mv "$UNINSTALL_TMP" "${SCRIPTS_DIR}/uninstall.sh"
  if ! [[ -O "${SCRIPTS_DIR}/uninstall.sh" && -x "${SCRIPTS_DIR}/uninstall.sh" ]]; then
    echo -e "${RED}✗ uninstall.sh установлен с неверными правами — прерывание${NC}"
    exit 1
  fi
else
  echo -e "${YELLOW}⚠ uninstall.sh не загружен или невалиден${NC}"
  rm -f "$UNINSTALL_TMP"
fi
ln_created=0
if [[ -f "${SCRIPTS_DIR}/update.sh" ]]; then
  ln -sf "${SCRIPTS_DIR}/update.sh" /usr/local/bin/xrayebator-update 2>/dev/null
  ln_created=$((ln_created+1))
fi
if [[ -f "${SCRIPTS_DIR}/uninstall.sh" ]]; then
  ln -sf "${SCRIPTS_DIR}/uninstall.sh" /usr/local/bin/xrayebator-uninstall 2>/dev/null
  ln_created=$((ln_created+1))
fi
echo "$GITHUB_BRANCH" > /usr/local/etc/xray/.current_branch
chown root:root /usr/local/etc/xray/.current_branch 2>/dev/null || true
chmod 644 /usr/local/etc/xray/.current_branch 2>/dev/null || true
echo -e "${GREEN}✓ Скрипты установлены (${ln_created} shortcuts)${NC}\n"

# Запуск Xray
systemctl enable xray > /dev/null 2>&1

# Pre-validate config перед restart (REQ-D03)
echo -e "${YELLOW}Проверка config.json перед запуском Xray...${NC}"

# Guard #1: файл существует и не пуст
if [[ ! -f /usr/local/etc/xray/config.json || ! -s /usr/local/etc/xray/config.json ]]; then
  echo -e "${RED}✗ config.json отсутствует или пуст${NC}"
  echo -e "${RED}Установка прервана. Проверьте /usr/local/etc/xray/config.json вручную.${NC}"
  exit 1
fi

# Guard #2: xray run -test (grep stdout — exit code ненадёжен: возвращает 0 на missing file)
if ! xray run -test -config /usr/local/etc/xray/config.json 2>&1 | grep -q "^Configuration OK\.$"; then
  echo -e "${RED}✗ config.json не валиден (xray run -test failed)${NC}"
  echo -e "${YELLOW}Вывод xray:${NC}"
  xray run -test -config /usr/local/etc/xray/config.json 2>&1 | head -20
  echo -e "${RED}Установка прервана. Проверьте /usr/local/etc/xray/config.json вручную.${NC}"
  exit 1
fi
echo -e "${GREEN}✓ config.json прошёл validation${NC}"

# B3-fix: systemd может не успеть поднять сервис сразу после restart — даём время
# перед is-active, иначе «не запущен» — ложный failure.
systemctl restart xray > /dev/null 2>&1
sleep 2
# B4-fix: «успешно запущен» только при реально работающем Xray И наличии инбаундов.
# На свежей установке inbounds пуст — Xray стартует, но сервер ещё не готов.
if systemctl is-active --quiet xray && jq -e '.inbounds | length > 0' "$CONFIG_FILE" >/dev/null 2>&1; then
  echo -e "${GREEN}✓ Xray успешно запущен${NC}\n"
else
  echo -e "${CYAN}✓ Xray установлен (запустится при создании профиля)${NC}\n"
fi

# Финальное сообщение
clear
echo -e "${GREEN}"
echo '╔═══════════════════════════════════════════════════════════╗'
echo '║                                                           ║'
echo '║          ✓ УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!                 ║'
echo '║                                                           ║'
echo '╚═══════════════════════════════════════════════════════════╝'
echo -e "${NC}\n"
echo -e "${CYAN}Для управления профилями используйте команду:${NC}"
echo -e "${YELLOW}╭──────────────────────────╮${NC}"
echo -e "${YELLOW}│ ${GREEN}sudo xrayebator${YELLOW}          │${NC}"
echo -e "${YELLOW}╰──────────────────────────╯${NC}\n"
echo -e "${BLUE}Дополнительные команды:${NC}"
echo -e "  ${CYAN}sudo xrayebator-update${NC}    - обновить Xrayebator"
echo -e "  ${CYAN}sudo xrayebator-uninstall${NC} - удалить Xrayebator"
echo ""
echo -e "${BLUE}Открытые порты в firewall:${NC}"
echo -e "  ${GREEN}443/tcp${NC}  - HTTPS (основной)"
echo -e "  ${GREEN}8443/tcp${NC} - Альтернативный порт"
echo ""
echo -e "${BLUE}GitHub:${NC} https://github.com/${GITHUB_USER}/${GITHUB_REPO}"
echo -e "${BLUE}Версия:${NC} 3.0"
echo ""
echo -e "${MAGENTA}════════════════════════════════════════════════════════════${NC}"


_step_mark 9
fi