#!/bin/bash

# ═══════════════════════════════════════════════════════════
#  XRAYEBATOR INSTALLER v1.0
#  Автоматическая установка Xray Reality VPN
#  GitHub: https://github.com/howdeploy/Xrayebator
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
CURRENT_SNI_FILE="/usr/local/etc/xray/.current_sni"

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}✗ Требуются права root для установки${NC}"
   exit 1
fi

clear
echo -e "${CYAN}"
echo '╔═══════════════════════════════════════════════════════════╗'
echo '║                                                           ║'
echo '║              XRAYEBATOR INSTALLER v1.0                    ║'
echo '║         Автоматическая установка Xray Reality VPN         ║'
echo '║                                                           ║'
echo '╚═══════════════════════════════════════════════════════════╝'
echo -e "${NC}\n"

echo -e "${YELLOW}Начало установки...${NC}\n"
sleep 2

# ═══════════════════════════════════════════════════════════
# [1/9] Установка зависимостей
# ═══════════════════════════════════════════════════════════
echo -e "${BLUE}[1/9]${NC} ${YELLOW}Установка необходимых пакетов...${NC}"
apt update > /dev/null 2>&1
apt install -y curl wget jq qrencode uuid-runtime > /dev/null 2>&1

if [[ $? -eq 0 ]]; then
    echo -e "${GREEN}✓ Зависимости установлены${NC}\n"
else
    echo -e "${RED}✗ Ошибка установки зависимостей${NC}"
    exit 1
fi

# ═══════════════════════════════════════════════════════════
# [2/9] Установка Xray-core
# ═══════════════════════════════════════════════════════════
echo -e "${BLUE}[2/9]${NC} ${YELLOW}Установка Xray-core...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1

if [[ $? -eq 0 ]]; then
    echo -e "${GREEN}✓ Xray-core установлен${NC}\n"
else
    echo -e "${RED}✗ Ошибка установки Xray-core${NC}"
    exit 1
fi

# ═══════════════════════════════════════════════════════════
# [3/9] Создание структуры директорий
# ═══════════════════════════════════════════════════════════
echo -e "${BLUE}[3/9]${NC} ${YELLOW}Создание структуры директорий...${NC}"
mkdir -p "$PROFILES_DIR"
mkdir -p "$DATA_DIR"
mkdir -p "$SCRIPTS_DIR"
echo -e "${GREEN}✓ Директории созданы${NC}\n"

# ═══════════════════════════════════════════════════════════
# [4/9] Генерация ключей Reality
# ═══════════════════════════════════════════════════════════
echo -e "${BLUE}[4/9]${NC} ${YELLOW}Генерация ключей Reality...${NC}"
KEYS=$(/usr/local/bin/xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | awk '{print $3}')

echo "$PRIVATE_KEY" > "$PRIVATE_KEY_FILE"
echo "$PUBLIC_KEY" > "$PUBLIC_KEY_FILE"
chmod 600 "$PRIVATE_KEY_FILE"
chmod 644 "$PUBLIC_KEY_FILE"

echo -e "${GREEN}✓ Ключи сгенерированы${NC}\n"

# ═══════════════════════════════════════════════════════════
# [5/9] Создание базовой конфигурации
# ═══════════════════════════════════════════════════════════
echo -e "${BLUE}[5/9]${NC} ${YELLOW}Создание конфигурации Xray...${NC}"

cat > "$CONFIG_FILE" << 'EOF'
{
  "log": {
    "loglevel": "warning"
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
      }
    ]
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

echo -e "${GREEN}✓ Конфигурация создана${NC}\n"

# Установка начального SNI
echo "www.microsoft.com" > "$CURRENT_SNI_FILE"

# ═══════════════════════════════════════════════════════════
# [6/9] Оптимизация TCP (BBR)
# ═══════════════════════════════════════════════════════════
echo -e "${BLUE}[6/9]${NC} ${YELLOW}Настройка BBR TCP Congestion Control...${NC}"

# Проверка, не включен ли уже BBR
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    cat >> /etc/sysctl.conf << 'EOF'

# BBR TCP Congestion Control Optimization
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_max_tw_buckets=2000000
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_syncookies=1
net.core.netdev_max_backlog=16384
net.ipv4.tcp_max_syn_backlog=8192
EOF
    sysctl -p > /dev/null 2>&1
    echo -e "${GREEN}✓ BBR включен и настроен${NC}\n"
else
    echo -e "${CYAN}✓ BBR уже настроен${NC}\n"
fi

# ═══════════════════════════════════════════════════════════
# [7/9] Загрузка данных (ASCII, SNI список)
# ═══════════════════════════════════════════════════════════
echo -e "${BLUE}[7/9]${NC} ${YELLOW}Загрузка данных приложения...${NC}"

# Загрузка списка SNI
curl -fsSL "${RAW_BASE_URL}/sni_list.txt" -o "${DATA_DIR}/sni_list.txt"

if [[ $? -eq 0 ]] && [[ -s "${DATA_DIR}/sni_list.txt" ]]; then
    echo -e "${GREEN}✓ Список SNI загружен${NC}"
else
    echo -e "${YELLOW}⚠ Не удалось загрузить список SNI, создаю базовый...${NC}"
    cat > "${DATA_DIR}/sni_list.txt" << 'EOF'
www.microsoft.com
www.cloudflare.com
github.com
www.apple.com
aws.amazon.com
stats.vk-portal.net
ozone.ru
splitter.wb.ru
www.kinopoisk.ru
speller.yandex.net
EOF
fi

# Загрузка ASCII арта
curl -fsSL "${RAW_BASE_URL}/ascii_art.txt" -o "${DATA_DIR}/ascii_art.txt" 2>/dev/null

if [[ -s "${DATA_DIR}/ascii_art.txt" ]]; then
    echo -e "${GREEN}✓ ASCII арт загружен${NC}\n"
else
    echo -e "${CYAN}✓ ASCII арт недоступен (не критично)${NC}\n"
fi

# ═══════════════════════════════════════════════════════════
# [8/9] Установка приложения xrayebator
# ═══════════════════════════════════════════════════════════
echo -e "${BLUE}[8/9]${NC} ${YELLOW}Установка управляющего приложения...${NC}"

# Загрузка xrayebator
curl -fsSL "${RAW_BASE_URL}/xrayebator" -o /usr/local/bin/xrayebator

if [[ $? -eq 0 ]] && [[ -s /usr/local/bin/xrayebator ]]; then
    chmod +x /usr/local/bin/xrayebator
    echo -e "${GREEN}✓ Приложение xrayebator установлено${NC}\n"
else
    echo -e "${RED}✗ Ошибка загрузки xrayebator${NC}"
    exit 1
fi

# ═══════════════════════════════════════════════════════════
# [9/9] Установка скриптов управления
# ═══════════════════════════════════════════════════════════
echo -e "${BLUE}[9/9]${NC} ${YELLOW}Установка скриптов управления...${NC}"

# Загрузка update.sh
curl -fsSL "${RAW_BASE_URL}/update.sh" -o "${SCRIPTS_DIR}/update.sh"
if [[ $? -eq 0 ]] && [[ -s "${SCRIPTS_DIR}/update.sh" ]]; then
    chmod +x "${SCRIPTS_DIR}/update.sh"
    echo -e "${GREEN}✓ update.sh установлен${NC}"
else
    echo -e "${YELLOW}⚠ Не удалось загрузить update.sh${NC}"
fi

# Загрузка uninstall.sh
curl -fsSL "${RAW_BASE_URL}/uninstall.sh" -o "${SCRIPTS_DIR}/uninstall.sh"
if [[ $? -eq 0 ]] && [[ -s "${SCRIPTS_DIR}/uninstall.sh" ]]; then
    chmod +x "${SCRIPTS_DIR}/uninstall.sh"
    echo -e "${GREEN}✓ uninstall.sh установлен${NC}"
else
    echo -e "${YELLOW}⚠ Не удалось загрузить uninstall.sh${NC}"
fi

# Загрузка install.sh (самого себя для переустановки)
curl -fsSL "${RAW_BASE_URL}/install.sh" -o "${SCRIPTS_DIR}/install.sh"
if [[ $? -eq 0 ]] && [[ -s "${SCRIPTS_DIR}/install.sh" ]]; then
    chmod +x "${SCRIPTS_DIR}/install.sh"
    echo -e "${GREEN}✓ install.sh сохранен${NC}"
else
    echo -e "${YELLOW}⚠ Не удалось сохранить install.sh${NC}"
fi

# Создание симлинков для удобного доступа
ln -sf "${SCRIPTS_DIR}/update.sh" /usr/local/bin/xrayebator-update
ln -sf "${SCRIPTS_DIR}/uninstall.sh" /usr/local/bin/xrayebator-uninstall

echo -e "${GREEN}✓ Симлинки созданы${NC}\n"

# ═══════════════════════════════════════════════════════════
# Запуск Xray
# ═══════════════════════════════════════════════════════════
systemctl enable xray > /dev/null 2>&1
systemctl restart xray > /dev/null 2>&1

if systemctl is-active --quiet xray; then
    echo -e "${GREEN}✓ Xray успешно запущен${NC}\n"
else
    echo -e "${CYAN}✓ Xray установлен (запустится при создании профиля)${NC}\n"
fi

# ═══════════════════════════════════════════════════════════
# Финальное сообщение
# ═══════════════════════════════════════════════════════════
clear
echo -e "${GREEN}"
echo '╔═══════════════════════════════════════════════════════════╗'
echo '║                                                           ║'
echo '║           ✓ УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!                 ║'
echo '║                                                           ║'
echo '╚═══════════════════════════════════════════════════════════╝'
echo -e "${NC}\n"

echo -e "${CYAN}Для управления профилями используйте команду:${NC}"
echo -e "${YELLOW}╭──────────────────────────╮${NC}"
echo -e "${YELLOW}│   ${GREEN}sudo xrayebator${YELLOW}      │${NC}"
echo -e "${YELLOW}╰──────────────────────────╯${NC}\n"

echo -e "${BLUE}Дополнительные команды:${NC}"
echo -e "  ${CYAN}sudo xrayebator-update${NC}     - обновить Xrayebator"
echo -e "  ${CYAN}sudo xrayebator-uninstall${NC}  - удалить Xrayebator"
echo ""

echo -e "${BLUE}Скрипты находятся в:${NC}"
echo -e "  ${YELLOW}/usr/local/etc/xray/scripts/${NC}"
echo ""

echo -e "${BLUE}GitHub:${NC} https://github.com/${GITHUB_USER}/${GITHUB_REPO}"
echo -e "${BLUE}Версия:${NC} 1.0"
echo ""

echo -e "${MAGENTA}════════════════════════════════════════════════════════════${NC}"

