#!/usr/bin/env bash
# Регрессия «PPA amnezia/ppa ставится только вместе с ключом подписи».
#
# Живой дефект 2026-10-23 (2.26.125.228): фолбэк-ветка установки писала
# /etc/apt/sources.list.d/amneziawg.list без ключа. apt-get update после этого
# возвращал rc=100 («NO_PUBKEY … / repository is not signed»), и на сервере
# ломались ВСЕ apt-операции (в том числе установка плагина certbot для DNS-01),
# а amneziawg из PPA переставал находиться.
#
# Тест функциональный там, где это возможно: пути репозитория/брелка/маркера
# переопределяются на временный каталог, а apt-get update подменяется заглушкой.
set -u
cd "$(dirname "$0")/.."

fail() { echo "✗ $1"; exit 1; }
pass() { echo "✓ $1"; }

command -v jq >/dev/null 2>&1 || fail "jq required (CI installs it)"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export AWG_PPA_LIST_FILE="$TMP_ROOT/sources.list.d/amneziawg.list"
export AWG_PPA_KEYRING="$TMP_ROOT/keyrings/amnezia-ppa.gpg"
export AWG_PPA_KEY_ID="4166F2C257290828"
mkdir -p "$(dirname "$AWG_PPA_LIST_FILE")"

# shellcheck disable=SC1091
source ./xrayebator || fail "source ./xrayebator failed"
[[ "$XRAYEBATOR_SOURCED" == "1" ]] || fail "source-mode guard not detected"

# --- 1. Строка репозитория несёт signed-by -------------------------------------
line=$(_awg_ppa_sources_line_pure "$AWG_PPA_KEYRING")
expected="deb [signed-by=$AWG_PPA_KEYRING] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main"
[[ "$line" == "$expected" ]] \
  || fail "sources line has no signed-by: '$line' (expected '$expected')"
pass "repo line carries signed-by=<keyring>"

# --- 2. Установка не пишет репозиторий мимо подписанного пути ------------------
install_fn=$(sed -n '/^_awg_install_packages() {/,/^}/p' xrayebator)
[[ -n "$install_fn" ]] || fail "_awg_install_packages block not found"
if grep -q 'amneziawg\.list' <<< "$install_fn"; then
  fail "_awg_install_packages must not write sources.list.d directly"
fi
grep -q '_awg_ppa_configure' <<< "$install_fn" \
  || fail "_awg_install_packages must go through _awg_ppa_configure"

configure_fn=$(sed -n '/^_awg_ppa_configure() {/,/^}/p' xrayebator)
[[ -n "$configure_fn" ]] || fail "_awg_ppa_configure block not found"
# Ключ обязан появляться ДО записи строки репозитория.
fetch_line=$(grep -n '_awg_ppa_fetch_key' <<< "$configure_fn" | head -1 | cut -d: -f1)
write_line=$(grep -n '_awg_ppa_sources_line_pure' <<< "$configure_fn" | head -1 | cut -d: -f1)
[[ -n "$fetch_line" && -n "$write_line" ]] \
  || fail "_awg_ppa_configure must both fetch the key and write the repo"
[[ "$fetch_line" -lt "$write_line" ]] \
  || fail "repo is written before the signing key is fetched"
if grep -qE '^[^#]*echo "deb https://ppa\.launchpadcontent' <<< "$configure_fn"; then
  fail "unsigned deb line is still written verbatim in _awg_ppa_configure"
fi
pass "repo file is only written through the signed-by helper"

# --- 3. Без ключа и без add-apt-repository репозиторий не появляется -----------
_awg_ppa_apt_update() { :; }
add-apt-repository() { return 1; }
_awg_ppa_fetch_key() { return 1; }
rm -f "$AWG_PPA_LIST_FILE" "$AWG_PPA_KEYRING"
_awg_ppa_configure && fail "_awg_ppa_configure must fail without the signing key"
[[ -f "$AWG_PPA_LIST_FILE" ]] \
  && fail "repo file must not appear without the signing key (apt-get update would break)"
pass "no key → no repo (apt stays usable)"

# --- 4. Ремонт испорченного сервера: без ключа репозиторий убирается -----------
marker="$TMP_ROOT/.awg_ppa_signed_2026"
printf 'deb https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main\n' > "$AWG_PPA_LIST_FILE"
migrate_awg_ppa_signed_2026 "$marker" || fail "repair migration failed"
[[ -f "$AWG_PPA_LIST_FILE" ]] && fail "unsigned repo file must be removed by the repair"
[[ -f "$marker" ]] || fail "repair marker was not written"
pass "unsigned repo removed when the key is unavailable"

# --- 5. С доступным ключом репозиторий переписывается подписанным --------------
rm -f "$marker"
printf 'deb https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main\n' > "$AWG_PPA_LIST_FILE"
_awg_ppa_fetch_key() {
  mkdir -p "$(dirname "$AWG_PPA_KEYRING")"
  printf 'fake-keyring' > "$AWG_PPA_KEYRING"
  return 0
}
migrate_awg_ppa_signed_2026 "$marker" || fail "repair migration failed with key"
grep -q "signed-by=$AWG_PPA_KEYRING" "$AWG_PPA_LIST_FILE" \
  || fail "repo was not re-signed although the key is available"
pass "broken repo gets signed-by when the key is available"

# --- 6. Повторный запуск по маркеру ничего не делает --------------------------
apt_update_calls=0
_awg_ppa_apt_update() { apt_update_calls=$((apt_update_calls + 1)); return 0; }
migrate_awg_ppa_signed_2026 "$marker" || fail "second migration run failed"
[[ "$apt_update_calls" -eq 0 ]] || fail "migration ran again despite the marker"
pass "repair is idempotent (marker short-circuits)"

# --- 7. Ремонт подключён к main_menu, quickstart и happ-setup ------------------
for fn in main_menu quickstart_command happ_setup_command; do
  block=$(sed -n "/^${fn}() {/,/^}/p" xrayebator)
  [[ -n "$block" ]] || fail "${fn} block not found"
  grep -q 'migrate_awg_ppa_signed_2026' <<< "$block" \
    || fail "${fn} does not run migrate_awg_ppa_signed_2026"
done
pass "repair is wired into main_menu, quickstart and happ-setup"

echo "✓ PPA amnezia/ppa is always installed together with its signing key"
