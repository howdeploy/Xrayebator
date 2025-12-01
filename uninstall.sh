#!/bin/bash

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}✗ Этот скрипт должен быть запущен с правами root${NC}" 
   echo -e "${YELLOW}Используйте: sudo bash uninstall.sh${NC}"
   exit 1
fi

clear
echo -e "${RED}"
echo '═══════════════════════════════════════════════════════════'
echo '              УДАЛЕНИЕ XRAYEBATOR                          '
echo '═══════════════════════════════════════════════════════════'
echo -e "${NC}\n"

echo -e "${YELLOW}Это действие удалит:${NC}"
echo -e "  ${BLUE}•${NC} Xray-core и все его компоненты"
echo -e "  ${BLUE}•${NC} Все профили и конфигурации"
echo -e "  ${BLUE}•${NC} Приложение xrayebator"
echo -e "  ${BLUE}•${NC} Сгенерированные ключи Reality"
echo ""
echo -e "${RED}⚠ Все данные будут потеряны безвозвратно!${NC}"
echo ""
echo -n -e "${YELLOW}Вы уверены, что хотите удалить Xrayebator? (yes/no): ${NC}"
read confirmation

if [[ "$confirmation" != "yes" ]]; then
    echo -e "${CYAN}✓ Удаление отменено${NC}"
    exit 0
fi

echo ""
echo -e "${BLUE}[1/6]${NC} ${YELLOW}Остановка сервиса Xray...${NC}"
systemctl stop xray > /dev/null 2>&1
systemctl disable xray > /dev/null 2>&1
echo -e "${GREEN}✓ Сервис остановлен${NC}\n"

echo -e "${BLUE}[2/6]${NC} ${YELLOW}Удаление Xray-core...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove > /dev/null 2>&1
echo -e "${GREEN}✓ Xray-core удален${NC}\n"

echo -e "${BLUE}[3/6]${NC} ${YELLOW}Удаление конфигураций и профилей...${NC}"
rm -rf /usr/local/etc/xray
echo -e "${GREEN}✓ Конфигурации удалены${NC}\n"

echo -e "${BLUE}[4/6]${NC} ${YELLOW}Удаление приложения xrayebator...${NC}"
rm -f /usr/local/bin/xrayebator
echo -e "${GREEN}✓ Приложение удалено${NC}\n"

echo -e "${BLUE}[5/6]${NC} ${YELLOW}Очистка systemd...${NC}"
rm -f /etc/systemd/system/xray.service
rm -f /etc/systemd/system/xray@.service
systemctl daemon-reload > /dev/null 2>&1
echo -e "${GREEN}✓ Systemd очищен${NC}\n"

echo -e "${BLUE}[6/6]${NC} ${YELLOW}Очистка логов...${NC}"
journalctl --rotate > /dev/null 2>&1
journalctl --vacuum-time=1s > /dev/null 2>&1
echo -e "${GREEN}✓ Логи очищены${NC}\n"

# Опционально: удаление BBR настроек
echo -n -e "${YELLOW}Удалить настройки BBR из sysctl.conf? (y/N): ${NC}"
read remove_bbr

if [[ "$remove_bbr" =~ ^[yYдД]$ ]]; then
    sed -i '/# BBR TCP Congestion Control Optimization/,/net.ipv4.tcp_wmem=4096 65536 2500000/d' /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
    echo -e "${GREEN}✓ Настройки BBR удалены${NC}\n"
else
    echo -e "${CYAN}✓ Настройки BBR оставлены${NC}\n"
fi

clear
echo -e "${GREEN}"
echo '═══════════════════════════════════════════════════════════'
echo '           ✓ УДАЛЕНИЕ ЗАВЕРШЕНО УСПЕШНО!                   '
echo '═══════════════════════════════════════════════════════════'
echo -e "${NC}\n"

echo -e "${CYAN}Xrayebator полностью удален с вашего сервера.${NC}"
echo -e "${BLUE}Спасибо за использование!${NC}\n"

