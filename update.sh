#!/bin/bash

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# GitHub репозиторий
GITHUB_USER="howdeploy"
GITHUB_REPO="Xrayebator"
GITHUB_BRANCH="main"
RAW_BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}✗ Этот скрипт должен быть запущен с правами root${NC}" 
   echo -e "${YELLOW}Используйте: sudo bash update.sh${NC}"
   exit 1
fi

clear
echo -e "${CYAN}"
echo '═══════════════════════════════════════════════════════════'
echo '              ОБНОВЛЕНИЕ XRAYEBATOR                        '
echo '═══════════════════════════════════════════════════════════'
echo -e "${NC}\n"

# Проверка установки Xrayebator
if [[ ! -f /usr/local/bin/xrayebator ]]; then
    echo -e "${RED}✗ Xrayebator не установлен${NC}"
    echo -e "${YELLOW}Используйте install.sh для установки${NC}"
    exit 1
fi

echo -e "${YELLOW}Что будет обновлено:${NC}"
echo -e "  ${BLUE}•${NC} Приложение xrayebator"
echo -e "  ${BLUE}•${NC} Список SNI доменов"
echo -e "  ${BLUE}•${NC} ASCII арт"
echo ""
echo -e "${CYAN}Ваши профили и конфигурации будут сохранены${NC}"
echo ""
echo -n -e "${YELLOW}Продолжить обновление? (y/N): ${NC}"
read confirmation

if [[ ! "$confirmation" =~ ^[yYдД]$ ]]; then
    echo -e "${CYAN}✓ Обновление отменено${NC}"
    exit 0
fi

echo ""

# Создание резервной копии
echo -e "${BLUE}[1/5]${NC} ${YELLOW}Создание резервной копии...${NC}"
BACKUP_DIR="/root/xrayebator_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -r /usr/local/etc/xray "$BACKUP_DIR/" 2>/dev/null || true
cp /usr/local/bin/xrayebator "$BACKUP_DIR/" 2>/dev/null || true
echo -e "${GREEN}✓ Резервная копия создана: $BACKUP_DIR${NC}\n"

# Обновление приложения xrayebator
echo -e "${BLUE}[2/5]${NC} ${YELLOW}Обновление приложения xrayebator...${NC}"
curl -fsSL "${RAW_BASE_URL}/xrayebator" -o /usr/local/bin/xrayebator.new

if [[ $? -eq 0 ]] && [[ -s /usr/local/bin/xrayebator.new ]]; then
    mv /usr/local/bin/xrayebator.new /usr/local/bin/xrayebator
    chmod +x /usr/local/bin/xrayebator
    echo -e "${GREEN}✓ Приложение обновлено${NC}\n"
else
    echo -e "${RED}✗ Ошибка загрузки приложения${NC}"
    rm -f /usr/local/bin/xrayebator.new
    exit 1
fi

# Обновление списка SNI
echo -e "${BLUE}[3/5]${NC} ${YELLOW}Обновление списка SNI доменов...${NC}"
curl -fsSL "${RAW_BASE_URL}/sni_list.txt" -o /usr/local/etc/xray/data/sni_list.txt.new

if [[ $? -eq 0 ]] && [[ -s /usr/local/etc/xray/data/sni_list.txt.new ]]; then
    mv /usr/local/etc/xray/data/sni_list.txt.new /usr/local/etc/xray/data/sni_list.txt
    echo -e "${GREEN}✓ Список SNI обновлен${NC}\n"
else
    echo -e "${YELLOW}⚠ Не удалось обновить список SNI${NC}\n"
    rm -f /usr/local/etc/xray/data/sni_list.txt.new
fi

# Обновление ASCII арта
echo -e "${BLUE}[4/5]${NC} ${YELLOW}Обновление ASCII арта...${NC}"
curl -fsSL "${RAW_BASE_URL}/ascii_art.txt" -o /usr/local/etc/xray/data/ascii_art.txt.new

if [[ $? -eq 0 ]] && [[ -s /usr/local/etc/xray/data/ascii_art.txt.new ]]; then
    mv /usr/local/etc/xray/data/ascii_art.txt.new /usr/local/etc/xray/data/ascii_art.txt
    echo -e "${GREEN}✓ ASCII арт обновлен${NC}\n"
else
    echo -e "${YELLOW}⚠ Не удалось обновить ASCII арт${NC}\n"
    rm -f /usr/local/etc/xray/data/ascii_art.txt.new
fi

# Обновление Xray-core (опционально)
echo -n -e "${YELLOW}[5/5] Обновить Xray-core до последней версии? (y/N): ${NC}"
read update_xray

if [[ "$update_xray" =~ ^[yYдД]$ ]]; then
    echo -e "${YELLOW}Обновление Xray-core...${NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1
    
    if [[ $? -eq 0 ]]; then
        systemctl restart xray
        echo -e "${GREEN}✓ Xray-core обновлен и перезапущен${NC}\n"
    else
        echo -e "${RED}✗ Ошибка обновления Xray-core${NC}\n"
    fi
else
    echo -e "${CYAN}✓ Xray-core не обновлялся${NC}\n"
fi

clear
echo -e "${GREEN}"
echo '═══════════════════════════════════════════════════════════'
echo '           ✓ ОБНОВЛЕНИЕ ЗАВЕРШЕНО УСПЕШНО!                 '
echo '═══════════════════════════════════════════════════════════'
echo -e "${NC}\n"

echo -e "${CYAN}Что было обновлено:${NC}"
echo -e "  ${GREEN}✓${NC} Приложение xrayebator"
echo -e "  ${GREEN}✓${NC} Список SNI доменов"
echo -e "  ${GREEN}✓${NC} ASCII арт"
if [[ "$update_xray" =~ ^[yYдД]$ ]]; then
    echo -e "  ${GREEN}✓${NC} Xray-core"
fi
echo ""
echo -e "${BLUE}Резервная копия сохранена в: ${YELLOW}$BACKUP_DIR${NC}"
echo ""
echo -e "${CYAN}Запустите xrayebator для использования:${NC}"
echo -e "${YELLOW}sudo xrayebator${NC}\n"

