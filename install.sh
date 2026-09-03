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

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}✗ Требуются права root для установки${NC}"
  exit 1
fi

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

# [1/9] Установка зависимостей
echo -e "${BLUE}[1/9]${NC} ${YELLOW}Установка необходимых пакетов...${NC}"
apt update > /dev/null 2>&1
apt install -y ca-certificates curl wget jq qrencode uuid-runtime ufw unzip openssl socat > /dev/null 2>&1
if [[ $? -eq 0 ]]; then
  echo -e "${GREEN}✓ Зависимости установлены${NC}\n"
else
  echo -e "${RED}✗ Ошибка установки зависимостей${NC}"
  exit 1
fi

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
    if ! grep -qx "Configuration OK." <<< "$test_output"; then
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

chmod 644 "${XRAY_DAT_DIR}/geoip.dat" "${XRAY_DAT_DIR}/geosite.dat" 2>/dev/null || true

echo -e "${GREEN}✓ Geo-базы настроены (Loyalsoldier enhanced)${NC}\n"

# [4/9] Создание структуры директорий
echo -e "${BLUE}[4/9]${NC} ${YELLOW}Создание структуры директорий...${NC}"
mkdir -p "$PROFILES_DIR"
mkdir -p "$DATA_DIR"
mkdir -p "$SCRIPTS_DIR"
mkdir -p /var/log/xray
chown xray:xray /var/log/xray
chown -R xray:xray /usr/local/etc/xray/
echo -e "${GREEN}✓ Директории созданы${NC}\n"

# [5/9] Генерация ключей Reality
echo -e "${BLUE}[5/9]${NC} ${YELLOW}Генерация ключей Reality...${NC}"

if [[ ! -x /usr/local/bin/xray ]]; then
  echo -e "${RED}✗ Бинарник /usr/local/bin/xray не найден или не исполняемый${NC}"
  echo -e "${YELLOW}  Установка Xray на шаге [2/9] могла завершиться некорректно${NC}"
  exit 1
fi

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

# Set file ownership for xray user
chown -R xray:xray /usr/local/etc/xray/
chmod 600 "$PRIVATE_KEY_FILE"
chmod 644 "$PUBLIC_KEY_FILE"

# ── VLESS Encryption keys (Phase 6 REQ-A01) ────────────────────
# Генерация PQ decryption/encryption пары через xray vlessenc.
# Требует Xray-core ≥ 25.9.5 (гарантируется install.sh шагом «Установка Xray-core» latest stable).
echo -e "${BLUE}[5b/10]${NC} ${YELLOW}Генерация VLESS Encryption ключей (mlkem768x25519plus.native)...${NC}"

VLESS_DECRYPTION_FILE="/usr/local/etc/xray/.vless_decryption"
VLESS_ENCRYPTION_FILE="/usr/local/etc/xray/.vless_encryption"

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
chmod 600 "$VLESS_DECRYPTION_FILE" "$VLESS_ENCRYPTION_FILE"
chown xray:xray "$VLESS_DECRYPTION_FILE" "$VLESS_ENCRYPTION_FILE" 2>/dev/null || true

echo -e "${GREEN}✓ VLESS Encryption ключи сгенерированы${NC}"
echo -e "${CYAN}  decryption: ${VLESS_DECRYPTION:0:48}...${NC}"

# [6/9] Создание базовой конфигурации
echo -e "${BLUE}[6/9]${NC} ${YELLOW}Создание конфигурации Xray...${NC}"
cat > "$CONFIG_FILE" << 'EOF'
{
  "log": {
    "loglevel": "warning",
    "access": "none"
  },
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "localhost"
    ],
    "queryStrategy": "UseIPv4",
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
        "domainStrategy": "UseIPv4"
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

chown xray:xray "$CONFIG_FILE"
# Mark config as already optimized (skip migration on first launch)
touch /usr/local/etc/xray/.config_optimized
chown xray:xray /usr/local/etc/xray/.config_optimized
chmod 644 "$CONFIG_FILE"
echo -e "${GREEN}✓ Конфигурация создана${NC}\n"

# [7/9] Настройка Firewall
echo -e "${BLUE}[7/9]${NC} ${YELLOW}Настройка firewall...${NC}"
if ! ufw status | grep -q "Status: active"; then
  ufw --force enable > /dev/null 2>&1
fi

UFW_ERRORS=0
for ufw_port in 22 80 443 8443 2053 2083 2087 8080 2096 8880 9443; do
  if ! ufw allow "${ufw_port}/tcp" > /dev/null 2>&1; then
    echo -e "${YELLOW}  ⚠ Не удалось открыть порт ${ufw_port}/tcp${NC}"
    ((UFW_ERRORS++))
  fi
done

ufw reload > /dev/null 2>&1
echo -e "${GREEN}✓ Firewall настроен${NC}"
echo -e "${CYAN}  Открытые порты: 443, 2053, 2096, 8080, 8443, 8880, 9443${NC}\n"

# [8/9] Загрузка данных
echo -e "${BLUE}[8/9]${NC} ${YELLOW}Загрузка данных приложения...${NC}"
curl -fsSL "${RAW_BASE_URL}/sni_list.txt" -o "${DATA_DIR}/sni_list.txt"
if [[ $? -eq 0 ]] && [[ -s "${DATA_DIR}/sni_list.txt" ]]; then
  echo -e "${GREEN}✓ Список SNI загружен${NC}"
else
  echo -e "${YELLOW}⚠ Не удалось загрузить список SNI, создаю базовый...${NC}"
  cat > "${DATA_DIR}/sni_list.txt" << 'EOF'
# Аварийный список: не удалось скачать sni_list.txt из репозитория.
# Порядок по замеру 03.09.2026 (MegaFon, Москва) — перепроверьте: probe test.
api-maps.yandex.ru|yandex_cdn|1
yandex.ru|yandex_cdn|1
www.samsung.com|foreign|1
dl.google.com|foreign|1
swcdn.apple.com|foreign|1
gateway.icloud.com|foreign|1
www.cloudflare.com|foreign|1
www.lovelive-anime.jp|foreign|1
speller.yandex.net|yandex_cdn|2
www.gosuslugi.ru|ru_whitelist|2
EOF
fi

curl -fsSL "${RAW_BASE_URL}/ascii_art.txt" -o "${DATA_DIR}/ascii_art.txt" 2>/dev/null
if [[ -s "${DATA_DIR}/ascii_art.txt" ]]; then
  echo -e "${GREEN}✓ ASCII арт загружен${NC}\n"
else
  echo -e "${CYAN}✓ ASCII арт недоступен (не критично)${NC}\n"
fi

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

# Скрипты управления
UPDATE_TMP=$(mktemp /tmp/xrayebator_update_install_XXXXXX.sh)
if curl -fsSL --connect-timeout 10 --max-time 30 "${RAW_BASE_URL}/update.sh" -o "$UPDATE_TMP" 2>/dev/null \
   && [[ -s "$UPDATE_TMP" ]] \
   && head -n 1 "$UPDATE_TMP" | grep -q "^#!/bin/bash" \
   && bash -n "$UPDATE_TMP"; then
  chmod 755 "$UPDATE_TMP"
  mv "$UPDATE_TMP" "${SCRIPTS_DIR}/update.sh"
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
  mv "$UNINSTALL_TMP" "${SCRIPTS_DIR}/uninstall.sh"
else
  echo -e "${YELLOW}⚠ uninstall.sh не загружен или невалиден${NC}"
  rm -f "$UNINSTALL_TMP"
fi
ln -sf "${SCRIPTS_DIR}/update.sh" /usr/local/bin/xrayebator-update 2>/dev/null
ln -sf "${SCRIPTS_DIR}/uninstall.sh" /usr/local/bin/xrayebator-uninstall 2>/dev/null
echo "$GITHUB_BRANCH" > /usr/local/etc/xray/.current_branch
chown xray:xray /usr/local/etc/xray/.current_branch 2>/dev/null || true
echo -e "${GREEN}✓ Скрипты установлены${NC}\n"

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

systemctl restart xray > /dev/null 2>&1
if systemctl is-active --quiet xray; then
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
