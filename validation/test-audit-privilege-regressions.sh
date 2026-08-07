#!/bin/bash
# Regression-тесты аудита HowDeploy (P0/P1): certbot-manifest, privilege boundary,
# quickstart nginx rollback, happ-setup без мёртвых маркеров, IPv6-only DNS.
#
# P0-certbot-fix: uninstall удаляет ТОЛЬКО серты из root-owned манифеста
#   /usr/local/etc/xray/.certbot_owned, никогда чужие. Manifest защищён от
#   path-traversal (case: */*|*..*|*\\* → пропуск).
# P0-privilege-fix: config/state/скрипты — root:root, приватные ключи 600,
#   НЕ выполняем chown -R xray:xray (была бы escalation через подмену root-скриптов).
# P1-nginx-fix: quickstart делает бэкап default-сайта и на любом failure-пути
#   (nginx -t, certbot, reload, занятый 8443) восстанавливает его через
#   _qs_nginx_rollback.
# P1-happ-fix: happ-setup НЕ фабрикует маркеры подписки на свежем VPS — если
#   публичный TLS endpoint не подтверждён, возвращает ok:false, а не мёртвый URL.
# P1-ipv6-fix: install.sh пишет IPv6-DNS в resolv.conf на IPv6-only VPS.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "✗ FAIL: $*" >&2
  exit 1
}

CRLF_FILE=$(mktemp /tmp/xrayebator-audit.XXXXXX)
trap 'rm -f "$CRLF_FILE"' EXIT
tr -d '\r' < xrayebator > "$CRLF_FILE"

echo "── P0: certbot manifest (xrayebator) ──"
grep -q '^_certbot_register()' xrayebator || fail "missing _certbot_register helper"
grep -q 'certbot delete --cert-name' uninstall.sh || fail "uninstall must use certbot delete"
grep -q '${CERTBOT_MANIFEST:-/usr/local/etc/xray/.certbot_owned}' uninstall.sh || \
  fail "uninstall must read root-owned certbot manifest"
# path-traversal guard присутствует в uninstall (проверяем по fixed-string, CRLF-safe).
UNINSTALL_CRLF=$(tr -d '\r' < uninstall.sh)
grep -Fq '*..*' <<< "$UNINSTALL_CRLF" || fail "uninstall missing path-traversal guard on manifest cert-names"

echo "── P0: privilege boundary (fix_xray_permissions) ──"
grep -q '^fix_xray_permissions()' "$CRLF_FILE" || fail "missing fix_xray_permissions"
grep -q '\.private_key.*600' "$CRLF_FILE" || fail "private keys must be 600"
grep -q 'chown root:root' "$CRLF_FILE" || fail "fix_xray_permissions must chown root:root"
grep -q 'chown xray:xray /var/log/xray' "$CRLF_FILE" || \
  fail "only /var/log/xray may stay xray:xray"

# Запрет: где-либо chown -R xray:xray на /usr/local/etc/xray (root-скрипты подменяемы).
if grep -nE '^\s*chown -R xray:xray|;\s*chown -R xray:xray|\s+chown -R xray:xray\s' "$CRLF_FILE" install.sh update.sh 2>/dev/null; then
  fail "chown -R xray:xray forbidden (privilege escalation)"
fi
# Запрет: xrayebator/install/update не должны chown xray:xray конфиг-пути.
if grep -nE 'chown[^#]*(xray:xray)[^#]*/usr/local/etc/xray' "$CRLF_FILE" install.sh update.sh 2>/dev/null; then
  fail "config path must not be chowned to xray:xray"
fi

echo "── P0: install.sh атомарная установка скриптов ──"
grep -q 'mktemp' install.sh || fail "install.sh must install scripts via mktemp"
grep -q 'chown root:root' install.sh || fail "install.sh must chown root:root config paths"
grep -q 'chown root:root' update.sh || fail "update.sh must chown root:root config paths"

echo "── P1: quickstart nginx rollback ──"
grep -q 'default.xrayebator.bak' "$CRLF_FILE" || fail "quickstart must back up default site"
grep -q '_qs_nginx_rollback()' "$CRLF_FILE" || fail "missing _qs_nginx_rollback helper"
grep -q 'QS_NGINX_MODIFIED=true' "$CRLF_FILE" || fail "missing nginx modified flag"
grep -q '_qs_nginx_rollback' "$CRLF_FILE" || fail "nginx rollback must be wired into quickstart"
# rollback должен перезагрузить nginx после восстановления default
grep -q 'systemctl reload nginx' "$CRLF_FILE" || fail "rollback must reload nginx"
# uninstall также восстанавливает default из бэкапа
grep -q 'default.xrayebator.bak' uninstall.sh || fail "uninstall must restore default site backup"

echo "── P1: happ-setup не фабрикует мёртвые маркеры ──"
grep -q '_subscription_public_tls_endpoint_verified' "$CRLF_FILE" || \
  fail "missing TLS endpoint verification helper"
grep -Fq 'Публичный TLS endpoint подписки не подтверждён' "$CRLF_FILE" || \
  fail "happ-setup must return clear error on unverified endpoint"

echo "── P1: IPv6-only DNS (install.sh) ──"
INSTALL_CRLF=$(tr -d '\r' < install.sh)
grep -Fq '2606:4700:4700::1111' <<< "$INSTALL_CRLF" || \
  fail "install.sh must write IPv6 DNS (Cloudflare) on IPv6-only VPS"
grep -Fq '2001:4860:4860::8888' <<< "$INSTALL_CRLF" || \
  fail "install.sh must write IPv6 DNS (Google) on IPv6-only VPS"

echo "✓ audit P0/P1 regressions passed"
