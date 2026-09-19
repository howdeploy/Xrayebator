#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

XRAY_VERSION="v26.7.28"
INSTALL_ROOT="/opt/xrayebator-gui"
CONFIG_ROOT="/etc/xrayebator-gui"
SERVICE_PATH="/etc/systemd/system/xrayebator-gui-helper.service"

die() {
  echo "xrayebator helper: $*" >&2
  exit 1
}

if [[ ${EUID} -ne 0 ]]; then
  die "запустите установщик через pkexec или sudo"
fi

TARGET_USER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      [[ $# -ge 2 ]] || die "--user требует значение"
      TARGET_USER="$2"
      shift 2
      ;;
    *)
      die "неизвестный параметр: $1"
      ;;
  esac
done

[[ -n ${TARGET_USER} ]] || die "обязателен --user <desktop-user>"
TARGET_UID=$(id -u "${TARGET_USER}") || die "пользователь не найден"
TARGET_GID=$(id -g "${TARGET_USER}") || die "primary group не найден"
[[ ${TARGET_UID} -ne 0 ]] || die "desktop helper нельзя привязать к root"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
GUI_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." && pwd -P)
SOURCE_PACKAGE="${GUI_ROOT}/xrayebator_gui"
UNIT_SOURCE="${SCRIPT_DIR}/xrayebator-gui-helper.service"
[[ -d ${SOURCE_PACKAGE} ]] || die "не найден пакет: ${SOURCE_PACKAGE}"
[[ -f ${UNIT_SOURCE} ]] || die "не найден systemd unit"

for command in curl unzip sha256sum nft systemctl python3; do
  command -v "${command}" >/dev/null 2>&1 ||
    die "не найдена зависимость '${command}'"
done

case "$(uname -m)" in
  x86_64|amd64)
    XRAY_ASSET="Xray-linux-64.zip"
    XRAY_SHA256="8195d909f1109b8f3d99eefe401a3c451d7bf4af71f24d3815420f77e5dd2a40"
    ;;
  aarch64|arm64)
    XRAY_ASSET="Xray-linux-arm64-v8a.zip"
    XRAY_SHA256="f5698bb218ada3b4022db26fafc39601c5f53b46b19eb76c9616325985807501"
    ;;
  *)
    die "неподдерживаемая архитектура: $(uname -m)"
    ;;
esac

STAGING=$(mktemp -d /tmp/xrayebator-helper.XXXXXXXXXX)
cleanup() {
  rm -rf -- "${STAGING}"
}
trap cleanup EXIT

XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${XRAY_ASSET}"
echo "Загрузка Xray ${XRAY_VERSION} (${XRAY_ASSET})…"
curl --fail --location --silent --show-error \
  --connect-timeout 15 --max-time 300 \
  "${XRAY_URL}" -o "${STAGING}/${XRAY_ASSET}"
printf '%s  %s\n' "${XRAY_SHA256}" "${STAGING}/${XRAY_ASSET}" |
  sha256sum --check --status ||
  die "SHA-256 Xray не совпал"
unzip -q "${STAGING}/${XRAY_ASSET}" xray geoip.dat geosite.dat -d "${STAGING}"
"${STAGING}/xray" version | grep -F "Xray ${XRAY_VERSION#v}" >/dev/null ||
  die "версия Xray не совпала с закреплённой"

python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 10))' ||
  die "требуется Python 3.10 или новее"

systemctl stop xrayebator-gui-helper.service >/dev/null 2>&1 || true
[[ ! -L ${INSTALL_ROOT} ]] || die "${INSTALL_ROOT} не должен быть symlink"
[[ ! -L ${INSTALL_ROOT}/app ]] ||
  die "${INSTALL_ROOT}/app не должен быть symlink"
install -d -m 0755 -o root -g root "${INSTALL_ROOT}/app"
install -d -m 0755 -o root -g root "${INSTALL_ROOT}/bin"
find "${INSTALL_ROOT}/app" -mindepth 1 -delete

while IFS= read -r -d '' source_file; do
  relative_path=${source_file#"${GUI_ROOT}/"}
  install -D -m 0644 -o root -g root \
    "${source_file}" "${INSTALL_ROOT}/app/${relative_path}"
done < <(find "${SOURCE_PACKAGE}" -type f -name '*.py' -print0)

install -m 0755 -o root -g root "${STAGING}/xray" "${INSTALL_ROOT}/xray"
install -m 0644 -o root -g root "${STAGING}/geoip.dat" \
  "${INSTALL_ROOT}/geoip.dat"
install -m 0644 -o root -g root "${STAGING}/geosite.dat" \
  "${INSTALL_ROOT}/geosite.dat"
cat >"${STAGING}/xrayebator-gui-helper" <<'WRAPPER'
#!/bin/sh
export PYTHONPATH=/opt/xrayebator-gui/app
exec /usr/bin/python3 -m xrayebator_gui.helper.service "$@"
WRAPPER
install -m 0755 -o root -g root "${STAGING}/xrayebator-gui-helper" \
  "${INSTALL_ROOT}/bin/xrayebator-gui-helper"

install -d -m 0700 -o root -g root "${CONFIG_ROOT}"
printf 'XRAYEBATOR_ALLOWED_UID=%s\nXRAYEBATOR_SOCKET_GID=%s\n' \
  "${TARGET_UID}" "${TARGET_GID}" >"${CONFIG_ROOT}/helper.env"
chown root:root "${CONFIG_ROOT}/helper.env"
chmod 0600 "${CONFIG_ROOT}/helper.env"
install -m 0644 -o root -g root "${UNIT_SOURCE}" "${SERVICE_PATH}"

systemctl daemon-reload
systemctl enable --now xrayebator-gui-helper.service
systemctl is-active --quiet xrayebator-gui-helper.service ||
  die "systemd helper не запустился; проверьте journalctl -u xrayebator-gui-helper"

echo "Xrayebator TUN helper установлен для ${TARGET_USER} (UID ${TARGET_UID})."
