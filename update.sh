#!/bin/bash

# ═══════════════════════════════════════════════════════════
# XRAYEBATOR UPDATE SCRIPT v1.3
# Обновление Xrayebator до последней версии
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

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}✗ Требуются права root${NC}"
  exit 1
fi

clear
echo -e "${CYAN}"
echo '╔═══════════════════════════════════════════════════════════╗'
echo '║                                                           ║'
echo '║              XRAYEBATOR UPDATE SCRIPT                    ║'
echo '║                                                           ║'
echo '╚═══════════════════════════════════════════════════════════╝'
echo -e "${NC}\n"

# Выбор ветки для обновления
echo -e "${YELLOW}Выберите версию для обновления:${NC}\n"
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║ 1) Stable (main)                                          ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo -e "   ${CYAN}→${NC} Стабильная версия"
echo -e "   ${CYAN}→${NC} Проверенный код, рекомендуется для продакшена"
echo -e "   ${CYAN}→${NC} Обновления раз в 1-2 месяца"
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║ 2) Dev                                                    ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo -e "   ${CYAN}→${NC} Версия с быстрыми фиксами"
echo -e "   ${CYAN}→${NC} Исправления багов, небольшие улучшения"
echo -e "   ${CYAN}→${NC} Обновления раз в 1-2 недели"
echo -e "   ${YELLOW}⚠${NC}  Может содержать мелкие баги"
echo ""
echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${MAGENTA}║ 3) Experimental                                           ║${NC}"
echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
echo -e "   ${CYAN}→${NC} Экспериментальная версия (вайбкод)"
echo -e "   ${CYAN}→${NC} Новые функции, тестирование, альфа-фичи"
echo -e "   ${CYAN}→${NC} Обновления несколько раз в неделю"
echo -e "   ${RED}⚠${NC}  Может быть нестабильной!"
echo ""
echo -e "${CYAN} 0)${NC} Отмена\n"
echo -n -e "${YELLOW}Ваш выбор: ${NC}"
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

RAW_BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

echo ""
echo -e "${BLUE}Обновление до версии: ${VERSION_COLOR}${VERSION_NAME}${NC}"
echo -e "${BLUE}Ветка GitHub: ${VERSION_COLOR}${GITHUB_BRANCH}${NC}\n"

# Предупреждение для experimental/dev
if [[ "$GITHUB_BRANCH" != "main" ]]; then
  echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║               ⚠ ВНИМАНИЕ ⚠                               ║${NC}"
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
    exit 0
  fi
  echo ""
fi

# Резервная копия текущих настроек
echo -e "${YELLOW}Создание резервной копии...${NC}"
BACKUP_DIR="/usr/local/etc/xray/backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp /usr/local/bin/xrayebator "$BACKUP_DIR/" 2>/dev/null
cp -r /usr/local/etc/xray/profiles "$BACKUP_DIR/" 2>/dev/null
cp /usr/local/etc/xray/config.json "$BACKUP_DIR/" 2>/dev/null
cp /usr/local/etc/xray/.private_key "$BACKUP_DIR/" 2>/dev/null
cp /usr/local/etc/xray/.public_key "$BACKUP_DIR/" 2>/dev/null
echo -e "${GREEN}✓ Резервная копия создана: $BACKUP_DIR${NC}\n"

# Сохранение информации о текущей ветке
echo "$GITHUB_BRANCH" > /usr/local/etc/xray/.current_branch 2>/dev/null

# Обновление основного скрипта
echo -e "${YELLOW}Обновление xrayebator...${NC}"
curl -fsSL "${RAW_BASE_URL}/xrayebator" -o /tmp/xrayebator_new
if [[ $? -eq 0 ]] && [[ -s /tmp/xrayebator_new ]]; then
  chmod +x /tmp/xrayebator_new
  mv /tmp/xrayebator_new /usr/local/bin/xrayebator
  echo -e "${GREEN}✓ xrayebator обновлён${NC}\n"
else
  echo -e "${RED}✗ Ошибка загрузки xrayebator${NC}"
  echo -e "${YELLOW}Возможно, ветка '${GITHUB_BRANCH}' ещё не создана на GitHub${NC}"
  exit 1
fi

# Обновление списка SNI
echo -e "${YELLOW}Обновление списка SNI...${NC}"
curl -fsSL "${RAW_BASE_URL}/sni_list.txt" -o /usr/local/etc/xray/data/sni_list.txt
if [[ $? -eq 0 ]]; then
  echo -e "${GREEN}✓ Список SNI обновлён${NC}\n"
else
  echo -e "${YELLOW}⚠ Не удалось обновить список SNI${NC}\n"
fi

# Обновление ASCII арта (опционально)
curl -fsSL "${RAW_BASE_URL}/ascii_art.txt" -o /usr/local/etc/xray/data/ascii_art.txt 2>/dev/null

# Обновление скриптов управления (если есть)
curl -fsSL "${RAW_BASE_URL}/update.sh" -o /usr/local/etc/xray/scripts/update.sh 2>/dev/null
chmod +x /usr/local/etc/xray/scripts/update.sh 2>/dev/null

# Проверка версии
echo -e "${YELLOW}Проверка установленной версии...${NC}"
VERSION_INFO=$(grep -m 1 "XRAYEBATOR v" /usr/local/bin/xrayebator | sed 's/.*XRAYEBATOR //' | sed 's/ .*//')
echo -e "${GREEN}✓ Установлена версия: ${VERSION_INFO}${NC}\n"

# Перезапуск Xray (если требуется)
if systemctl is-active --quiet xray; then
  echo -e "${YELLOW}Перезапуск Xray...${NC}"
  systemctl restart xray
  sleep 2
  if systemctl is-active --quiet xray; then
    echo -e "${GREEN}✓ Xray успешно перезапущен${NC}\n"
  else
    echo -e "${RED}✗ Ошибка перезапуска Xray${NC}"
    echo -e "${YELLOW}Проверьте логи: journalctl -u xray -n 50${NC}\n"
  fi
fi

# Финальное сообщение
clear
echo -e "${VERSION_COLOR}"
echo '╔═══════════════════════════════════════════════════════════╗'
echo '║                                                           ║'
echo '║              ✓ ОБНОВЛЕНИЕ ЗАВЕРШЕНО!                    ║'
echo '║                                                           ║'
echo '╚═══════════════════════════════════════════════════════════╝'
echo -e "${NC}\n"

echo -e "${CYAN}Версия: ${VERSION_COLOR}${VERSION_NAME}${NC}"
echo -e "${CYAN}Ветка: ${VERSION_COLOR}${GITHUB_BRANCH}${NC}"
echo -e "${CYAN}Релиз: ${VERSION_COLOR}${VERSION_INFO}${NC}"
echo -e "${CYAN}Резервная копия: ${GREEN}${BACKUP_DIR}${NC}\n"

# Специфичная информация по ветке
case $GITHUB_BRANCH in
  main)
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Вы используете стабильную версию${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}Рекомендации:${NC}"
    echo -e "  ${GREEN}✓${NC} Используйте для продакшен-серверов"
    echo -e "  ${GREEN}✓${NC} Проверенный и надёжный код"
    echo -e "  ${GREEN}✓${NC} Следующее обновление через 1-2 месяца"
    echo ""
    ;;

  dev)
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Вы используете Dev версию${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}Что нового:${NC}"
    echo -e "  ${GREEN}✓${NC} Свежие исправления багов"
    echo -e "  ${GREEN}✓${NC} Небольшие улучшения производительности"
    echo -e "  ${GREEN}✓${NC} Оптимизация кода"
    echo ""
    echo -e "${YELLOW}Внимание:${NC}"
    echo -e "  ${YELLOW}⚠${NC} При возникновении проблем откатитесь на Stable:"
    echo -e "     ${CYAN}sudo xrayebator-update${NC} → выберите ${GREEN}Stable${NC}"
    echo ""
    ;;

  experimental)
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}  ⚡ ВЫ ИСПОЛЬЗУЕТЕ ЭКСПЕРИМЕНТАЛЬНУЮ ВЕРСИЮ ⚡${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}Новые функции:${NC}"
    echo -e "  ${GREEN}✓${NC} Индивидуальная смена SNI для каждого профиля"
    echo -e "  ${GREEN}✓${NC} Индивидуальная смена fingerprint"
    echo -e "  ${GREEN}✓${NC} Меню с топ-20 SNI и описаниями"
    echo -e "  ${GREEN}✓${NC} Автоподбор рабочих связок (BETA)"
    echo -e "  ${GREEN}✓${NC} Улучшенная диагностика соединений"
    echo ""
    echo -e "${RED}⚠ ВАЖНО:${NC}"
    echo -e "  ${RED}•${NC} Эта версия может быть нестабильной"
    echo -e "  ${RED}•${NC} Используйте только для тестирования"
    echo -e "  ${RED}•${NC} Сообщайте о багах: ${CYAN}https://github.com/howdeploy/Xrayebator/issues${NC}"
    echo ""
    echo -e "${YELLOW}Для отката на стабильную версию:${NC}"
    echo -e "  ${CYAN}sudo xrayebator-update${NC} → выберите ${GREEN}Stable${NC}"
    echo ""
    ;;
esac

echo -e "${BLUE}Для запуска используйте:${NC} ${GREEN}sudo xrayebator${NC}"
echo ""

# Дополнительная информация
echo -e "${CYAN}Полезные команды:${NC}"
echo -e "  ${YELLOW}sudo xrayebator${NC}           - запустить менеджер"
echo -e "  ${YELLOW}sudo xrayebator-update${NC}    - обновить версию"
echo -e "  ${YELLOW}systemctl status xray${NC}     - статус сервиса"
echo -e "  ${YELLOW}journalctl -u xray -f${NC}     - логи в реальном времени"
echo ""
