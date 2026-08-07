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
echo -e "${BLUE}[1/7]${NC} ${YELLOW}Остановка сервисов (Xray + HAPP subscription)...${NC}"
systemctl stop xray > /dev/null 2>&1
systemctl disable xray > /dev/null 2>&1
systemctl stop xrayebator-sub.service > /dev/null 2>&1
systemctl disable xrayebator-sub.service > /dev/null 2>&1
echo -e "${GREEN}✓ Сервисы остановлены${NC}\n"

echo -e "${BLUE}[2/7]${NC} ${YELLOW}Удаление Xray-core...${NC}"
# Скачиваем XTLS installer в файл, проверяем что он реально получен (непустой + shebang).
# Иначе bash -c "$(curl ...)" при офлайне выполнял пустую строку с кодом 0 → ложный успех.
XTLS_REMOVE_SCRIPT=$(mktemp /tmp/xray-install-remove.XXXXXX.sh)
if curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$XTLS_REMOVE_SCRIPT" \
   && head -n 1 "$XTLS_REMOVE_SCRIPT" | grep -q "^#!/bin/bash"; then
    if bash "$XTLS_REMOVE_SCRIPT" @ remove > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Xray-core удален (по штатному скрипту XTLS)${NC}\n"
    else
        echo -e "${YELLOW}⚠ Официальный скрипт XTLS не отработал — удаляю бинарь вручную${NC}\n"
    fi
else
    echo -e "${YELLOW}⚠ Не удалось скачать скрипт XTLS (сеть?) — удаляю бинарь вручную${NC}\n"
fi
rm -f "$XTLS_REMOVE_SCRIPT"
# Явная зачистка на случай, если скрипт XTLS не отработал
rm -f /usr/local/bin/xray
rm -rf /usr/local/share/xray

echo -e "${BLUE}[3/7]${NC} ${YELLOW}Удаление конфигураций и профилей...${NC}"
# P2-fix: снимки root-owned манифестов ДО удаления /usr/local/etc/xray (см. [6/7]).
# certbot-names и ufw-правила читаются из снапшотов, а не из удаляемого каталога —
# иначе manifest исчезал бы раньше, чем его успели обработать.
CERTBOT_SNAPSHOT=""
UFW_SNAPSHOT=""
if [[ -f "${CERTBOT_MANIFEST:-/usr/local/etc/xray/.certbot_owned}" ]]; then
    CERTBOT_SNAPSHOT=$(mktemp /tmp/xrayebator-certbot-owned.XXXXXX)
    cat "${CERTBOT_MANIFEST:-/usr/local/etc/xray/.certbot_owned}" > "$CERTBOT_SNAPSHOT"
fi
if [[ -f "${UFW_OWNED_MANIFEST:-/usr/local/etc/xray/.ufw_owned}" ]]; then
    UFW_SNAPSHOT=$(mktemp /tmp/xrayebator-ufw-owned.XXXXXX)
    cat "${UFW_OWNED_MANIFEST:-/usr/local/etc/xray/.ufw_owned}" > "$UFW_SNAPSHOT"
fi
# Собираем динамические порты инбаундов и маршрутов ДО удаления конфига,
# чтобы затем вычистить их из UFW (иначе пользовательские порты останутся открытыми).
ALL_XRAY_PORTS=""
if command -v jq > /dev/null 2>&1 && [[ -f /usr/local/etc/xray/config.json ]]; then
    ALL_XRAY_PORTS=$(jq -r '[.inbounds[].port] | unique | .[]' /usr/local/etc/xray/config.json 2>/dev/null || true)
fi
if [[ -d /usr/local/etc/xray/profiles ]]; then
    for pf in /usr/local/etc/xray/profiles/*.json; do
        [[ -f "$pf" ]] || continue
        ROUTE_PORTS=$(jq -r '(.routes // []) | .[].port' "$pf" 2>/dev/null || true)
        ALL_XRAY_PORTS=$(printf '%s\n%s\n' "$ALL_XRAY_PORTS" "$ROUTE_PORTS")
    done
fi
# A7-uninstall-fix: останавливаем и удаляем systemd-таймер автопродления IP-сертификата,
# иначе он продолжает стрелять каждые 12ч и долбить systemctl reload nginx после удаления.
if systemctl list-unit-files 'xrayebator-ip-renew.*' > /dev/null 2>&1; then
    systemctl disable --now xrayebator-ip-renew.timer > /dev/null 2>&1 || true
    systemctl stop xrayebator-ip-renew.service > /dev/null 2>&1 || true
    rm -f /etc/systemd/system/xrayebator-ip-renew.service
    rm -f /etc/systemd/system/xrayebator-ip-renew.timer
fi
rm -rf /usr/local/etc/xray
rm -rf /var/log/xray
echo -e "${GREEN}✓ Конфигурации и логи удалены${NC}\n"

echo -e "${BLUE}[4/7]${NC} ${YELLOW}Удаление приложений (xrayebator, update/uninstall, subscription)...${NC}"
rm -f /usr/local/bin/xrayebator
rm -f /usr/local/bin/xrayebator-update
rm -f /usr/local/bin/xrayebator-uninstall
rm -f /usr/local/bin/subhttp.sh
echo -e "${GREEN}✓ Приложения удалены${NC}\n"

echo -e "${BLUE}[5/7]${NC} ${YELLOW}Очистка systemd (юниты + drop-in)...${NC}"
rm -f /etc/systemd/system/xray.service
rm -f /etc/systemd/system/xray@.service
rm -rf /etc/systemd/system/xray.service.d
rm -f /etc/systemd/system/xrayebator-sub.service
systemctl daemon-reload > /dev/null 2>&1
echo -e "${GREEN}✓ Systemd очищен${NC}\n"

echo -e "${BLUE}[6/7]${NC} ${YELLOW}Очистка firewall, nginx-конфигов и пользователя...${NC}"
# A7-uninstall-fix: продукт создаёт nginx vhost'ы xrayebator-sub и xrayebator-selfsteal.
# Без удаления nginx остаётся включённым и слушает 8443, проксируя на мёртвый 8080.
if command -v nginx > /dev/null 2>&1; then
    rm -f /etc/nginx/sites-available/xrayebator-sub
    rm -f /etc/nginx/sites-enabled/xrayebator-sub
    rm -f /etc/nginx/sites-available/xrayebator-selfsteal
    rm -f /etc/nginx/sites-enabled/xrayebator-selfsteal
    # Восстанавливаем default-сайт, если quickstart делал бэкап перед удалением.
    if [[ -e /etc/nginx/sites-enabled/default.xrayebator.bak && ! -e /etc/nginx/sites-enabled/default ]]; then
        cp -a /etc/nginx/sites-enabled/default.xrayebator.bak /etc/nginx/sites-enabled/default 2>/dev/null || true
        rm -f /etc/nginx/sites-enabled/default.xrayebator.bak 2>/dev/null || true
    fi
    if nginx -t > /dev/null 2>&1; then
        systemctl reload nginx > /dev/null 2>&1 || true
    fi
fi
# A7-uninstall-fix: certbot-сертификаты (включая shortlived IP-серты) — удаляем ТОЛЬКО те,
# которые были созданы самим Xrayebator и записаны в root-owned манифест
# /usr/local/etc/xray/.certbot_owned. Чужие сертификаты, Certbot account и глобальное
# состояние Certbot НЕ трогаем — uninstaller не имеет права уничтожать сторонние домены.
# P2-fix: манифест уже удалён на шаге [3/7] вместе с /usr/local/etc/xray — работаем
# по снапшоту CERTBOT_SNAPSHOT, взятому ДО удаления каталога.
if command -v certbot > /dev/null 2>&1 && [[ -n "$CERTBOT_SNAPSHOT" && -f "$CERTBOT_SNAPSHOT" ]]; then
    while IFS= read -r cn; do
        [[ -z "$cn" ]] && continue
        # Защита от path-traversal: манифест могут подделать только root (root:root 644).
        case "$cn" in
            */*|*..*|*\\*) echo -e "${YELLOW}  ⚠ Пропуск подозрительного cert-name из манифеста: $cn${NC}" >&2; continue ;;
        esac
        timeout 60 certbot delete --cert-name "$cn" --non-interactive > /dev/null 2>&1 || true
    done < "$CERTBOT_SNAPSHOT"
fi
rm -f /tmp/xrayebator-certbot-owned.?????? 2>/dev/null || true
rm -rf /var/www/xrayebator-ip-acme /var/www/xrayebator-selfsteal-acme 2>/dev/null
# Убираем и webroot и защищаем: certbot delete уже удалил certs/keys/accounts.
# P2-fix: удаляем UFW-правила ТОЛЬКО двух видов:
#   1) порты из root-owned манифеста .ufw_owned (доказано — открывал Xrayebator);
#   2) динамические порты, собранные из реального config.json/profiles ДО удаления
#      (это фактические инбаунды Xray — они существуют только потому, что Xray их
#      слушал, значит правила под них открывал тоже Xray).
# Ранее тут бездоказательно удалялись общие 443/8443/8080/9443/9444 — чужие веб-сайты
# на 443/8443 после uninstall оставались без доступа. Исправлено.
if command -v ufw > /dev/null 2>&1; then
    UFW_TO_DELETE=""
    if [[ -n "$UFW_SNAPSHOT" && -f "$UFW_SNAPSHOT" ]]; then
        UFW_TO_DELETE=$(cat "$UFW_SNAPSHOT")
    fi
    UFW_TO_DELETE=$(printf '%s\n%s\n' "$UFW_TO_DELETE" "$ALL_XRAY_PORTS")
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        port="${p%%/*}"
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        # Порт в манифесте уже с протоколом (tcp/udp) — тянем и его, и TCP.
        proto="${p#*/}"
        [[ "$proto" == "udp" ]] || proto="tcp"
        ufw delete allow "${port}/${proto}" > /dev/null 2>&1 || true
        ufw delete allow "${port}/tcp" > /dev/null 2>&1 || true
    done <<< "$UFW_TO_DELETE"
fi
rm -f /tmp/xrayebator-ufw-owned.?????? 2>/dev/null || true
if id xray > /dev/null 2>&1; then
    userdel xray > /dev/null 2>&1 || true
fi
echo -e "${GREEN}✓ Firewall и пользователь очищены${NC}\n"

echo -e "${BLUE}[7/7]${NC} ${YELLOW}Очистка журналов Xray...${NC}"
# journalctl vacuum работает по ФАЙЛАМ журнала, а не по юнитам — опция -u
# vacuum не ограничивает, поэтому `--vacuum-time=1s -u xray` затирал бы логи
# ВСЕХ сервисов. Безопасно: только flush + rotate активного журнала.
journalctl --flush > /dev/null 2>&1
journalctl --rotate > /dev/null 2>&1
echo -e "${GREEN}✓ Журналы Xray очищены${NC}\n"

clear
echo -e "${GREEN}"
echo '═══════════════════════════════════════════════════════════'
echo '           ✓ УДАЛЕНИЕ ЗАВЕРШЕНО УСПЕШНО!                   '
echo '═══════════════════════════════════════════════════════════'
echo -e "${NC}\n"

echo -e "${CYAN}Xrayebator полностью удален с вашего сервера.${NC}"
echo -e "${BLUE}Спасибо за использование!${NC}\n"
