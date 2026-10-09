#!/usr/bin/env bash
# Тест backend AmneziaWG 2.0 — срез 4 (2026-10-04).
# Функционально: junk-параметры (диапазоны спеки AWG 2.0), рендер серверного
# конфига, keygen через фейковый awg, реестр/статус. Полная установка (PPA/
# DKMS/сборка) и поднятие интерфейса — живой спайк на VPS (срез 7).
set -u
cd "$(dirname "$0")/.."

fail() { echo "✗ $1"; exit 1; }
pass() { echo "✓ $1"; }

command -v jq >/dev/null 2>&1 || fail "jq required (CI installs it)"
command -v openssl >/dev/null 2>&1 || fail "openssl required"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export BACKENDS_ROOT="$TMP_ROOT/xrayebator-backends"
export LOCK_FILE="$TMP_ROOT/xrayebator.lock"
export PROFILES_DIR="$TMP_ROOT/profiles"
mkdir -p "$PROFILES_DIR"

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$FAKEBIN/awg" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  genkey) openssl rand -base64 32 ;;
  genpsk) openssl rand -base64 32 ;;
  pubkey) cat >/dev/null; openssl rand -base64 32 ;;
  show)   exit 0 ;;
  *)      exit 0 ;;
esac
EOF
cat > "$FAKEBIN/awg-quick" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$FAKEBIN"/systemctl "$FAKEBIN"/awg "$FAKEBIN"/awg-quick
export PATH="$FAKEBIN:$PATH"
export XRAYEBATOR_SERVER_ADDR_OVERRIDE="203.0.113.10"

# shellcheck disable=SC1091
source ./xrayebator || fail "source ./xrayebator failed"

# 1) junk-параметры: дефолтный диалект Amnezia (совместимость с их мобильными
#    клиентами) + уникальность S1..S4 (5 прогонов), включая 3.1-поля
for _ in 1 2 3 4 5; do
  junk=$(_awg_gen_junk)
  jq -e '
    .Jc == 5 and .Jmin == 10 and .Jmax == 50 and
    .S1 >= 12 and .S1 <= 150 and .S2 >= 12 and .S2 <= 150 and
    .S3 >= 12 and .S3 <= 64 and .S4 >= 12 and .S4 <= 64 and
    ([.S1, .S2, .S3, .S4] | (length == ([unique[]] | length))) and
    (.S1 + 56) != .S2 and
    .H1 == 1 and .H2 == 2 and .H3 == 3 and .H4 == 4 and
    (.HeaderProtectionKey | length == 44 and endswith("="))
  ' <<<"$junk" >/dev/null || fail "junk/3.1 params out of spec: $junk"
done
pass "junk = Amnezia defaults (Jc=5/Jmin=10/Jmax=50/H=1..4) + S1-S4 unique + HPK (5/5 runs)"

# 1b) _awg_ensure_31_params дополняет старый params (до-3.1 установка)
old_junk=$(jq -c 'del(.S3, .S4, .HeaderProtectionKey)' <<<"$junk")
upgraded=$(_awg_ensure_31_params "$old_junk") || fail "ensure_31_params"
jq -e 'has("S3") and has("S4") and (.S3 >= 12) and (.S4 >= 12) and
       (.HeaderProtectionKey | length == 44)' <<<"$upgraded" >/dev/null \
  || fail "ensure_31_params did not add 3.1 fields: $upgraded"
pass "_awg_ensure_31_params upgrades legacy params with S3/S4/HPK"

# 2) keygen через awg (фейковый): три непустых base64
keys=$(_awg_gen_keys) || fail "awg gen keys"
read -r priv pub psk <<<"$keys"
[[ -n "$priv" && -n "$pub" && -n "$psk" ]] || fail "keys empty"
pass "awg genkey/pubkey/genpsk produce key triple"

# 3) рендер серверного конфига: 2.0-режим (без фич) и 3.1-режим
junk=$(_awg_gen_junk)
conf="$TMP_ROOT/awg0.conf"
_awg_render_server_conf "$conf" 51820 "$priv" "$junk" "eth0" '{}' || fail "render server conf"
grep -q '^Address = 10.8.1.1/24$' "$conf" || fail "conf Address"
grep -q '^ListenPort = 51820$' "$conf" || fail "conf ListenPort"
grep -qF "PrivateKey = $priv" "$conf" || fail "conf PrivateKey"
grep -q '^MTU = 1280$' "$conf" || fail "conf MTU"
grep -qF "Jc = $(jq -r .Jc <<<"$junk")" "$conf" || fail "conf Jc"
grep -qF "S3 = $(jq -r .S3 <<<"$junk")" "$conf" || fail "conf S3"
grep -qF "S4 = $(jq -r .S4 <<<"$junk")" "$conf" || fail "conf S4"
grep -qF "H4 = $(jq -r .H4 <<<"$junk")" "$conf" || fail "conf H4"
grep -qF "PostUp = iptables -A FORWARD -i awg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE" "$conf" || fail "conf PostUp"
grep -qF "PostDown = iptables -D FORWARD -i awg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE" "$conf" || fail "conf PostDown"
! grep -q '^\[Peer\]' "$conf" || fail "conf must have no peers at install"
! grep -q 'HeaderProtectionKey' "$conf" || fail "2.0 render must not emit HPK"
! grep -q 'RandomTrailers' "$conf" || fail "2.0 render must not emit RandomTrailers"
pass "server conf rendered (2.0 mode: S3/S4 present, no 3.x keys)"

_awg_render_server_conf "$conf" 51820 "$priv" "$junk" "eth0" '{"hpk":true,"rt":true,"dc":true}' \
  || fail "render server conf 3.1"
grep -qF "HeaderProtectionKey = $(jq -r .HeaderProtectionKey <<<"$junk")" "$conf" || fail "conf HPK"
grep -q '^RandomTrailers = on$' "$conf" || fail "conf RandomTrailers"
grep -q '^DisableCookies = on$' "$conf" || fail "conf DisableCookies"
pass "server conf 3.1 mode emits HeaderProtectionKey/RandomTrailers/DisableCookies"

# 4) реестр + awg-status
_backend_set awg '(.awg.installed) = true' || fail "set installed"
_backend_set awg '(.awg.port) = $p' --argjson p 51820 || fail "set port"
_backend_set awg '(.awg.unit) = $u' --arg u "awg-quick@awg0.service" || fail "set unit"
_backend_set awg '(.awg.subnet) = $s' --arg s "10.8.1.0/24" || fail "set subnet"
status="$(awg_status_command)" || fail "awg_status_command"
jq -e '.ok == true and .backend.installed == true and .backend.port == 51820 and
       .backend.subnet == "10.8.1.0/24"' <<<"$status" >/dev/null \
  || fail "awg status shape: $status"
pass "awg-status JSON shape correct"

# ── Срез 5: peers, адреса, клиентский .conf, события жизненного цикла ──
# Каталог и server-params в реальном цикле пишет _awg_install — собираем вручную.
mkdir -p "$AWG_DIR"
jq -n --arg priv "$priv" --arg pub "$pub" --argjson port 51820 --arg iface "eth0" \
  --argjson junk "$junk" --arg subnet "10.8.1.0/24" --argjson mtu 1280 \
  '{private_key:$priv, public_key:$pub, port:$port, iface:$iface, junk:$junk, subnet:$subnet, mtu:$mtu}' \
  > "$AWG_PARAMS_FILE" || fail "fixture server-params"

jq -n '{name:"carol", uuid:"u-carol", transport:"tcp", port:443}' > "$PROFILES_DIR/carol.json" || fail "fixture carol"
_awg_grant_profile carol || fail "awg grant carol"
addr1=$(jq -r '.backends.awg.address' "$PROFILES_DIR/carol.json")
[[ "$addr1" == "10.8.1.2" ]] || fail "first address expected 10.8.1.2, got $addr1"
cpub1=$(jq -r '.backends.awg.client_public_key' "$PROFILES_DIR/carol.json")
grep -qF "AllowedIPs = 10.8.1.2/32" "$AWG_CONF_FILE" || fail "peer AllowedIPs missing in awg0.conf"
grep -qF "PublicKey = $cpub1" "$AWG_CONF_FILE" || fail "peer pubkey missing in awg0.conf"
pass "awg grant allocates first free address (.2) and regenerates [Peer] section"

conf="$(awg_conf_command --name carol)" || fail "awg-conf command"
jq -e '.ok == true and .name == "carol" and
       (.conf | contains("[Interface]")) and (.conf | contains("[Peer]")) and
       (.conf | contains("AllowedIPs = 0.0.0.0/0, ::/0")) and
       (.conf | contains("Endpoint = 203.0.113.10:51820")) and
       (.conf | contains("PersistentKeepalive = 25")) and
       (.conf | contains("PresharedKey = ")) and
       (.conf | contains("HeaderProtectionKey = ")) and
       (.conf | contains("RandomTrailers = on")) and
       (.conf | startswith("# Xrayebator:")) and
       (.conf | contains("НЕ через"))' <<<"$conf" >/dev/null \
  || fail "client conf shape: $conf"
jq -r '.conf' <<<"$conf" > "$TMP_ROOT/carol-client.conf"
grep -qF "H1 = $(jq -r '.junk.H1' "$AWG_PARAMS_FILE")" "$TMP_ROOT/carol-client.conf" \
  || fail "client conf junk params mismatch with server"
grep -qF "S3 = $(jq -r '.junk.S3' "$AWG_PARAMS_FILE")" "$TMP_ROOT/carol-client.conf" \
  || fail "client conf S3 mismatch with server"
grep -qF "HeaderProtectionKey = $(jq -r '.junk.HeaderProtectionKey' "$AWG_PARAMS_FILE")" "$TMP_ROOT/carol-client.conf" \
  || fail "client conf HPK mismatch with server"
grep -qF "PublicKey = $(jq -r '.public_key' "$AWG_PARAMS_FILE")" "$TMP_ROOT/carol-client.conf" \
  || fail "client conf server pubkey mismatch"
! grep -q '^DisableCookies' "$TMP_ROOT/carol-client.conf" \
  || fail "client conf must not emit DisableCookies when dc=false"
pass "client .conf carries keys, S1-S4+HPK/RandomTrailers, server peer and endpoint"

# 3.1 toggle: off -> 2.0-формат, on -> 3.1 возвращается
_awg_31_toggle off "" >/dev/null 2>&1 || fail "awg-31 toggle off"
grep -q '^RandomTrailers = on$' "$AWG_CONF_FILE" && fail "toggle off: RandomTrailers still present"
! grep -q 'HeaderProtectionKey' "$AWG_CONF_FILE" || fail "toggle off: HPK still present"
_awg_31_toggle on "" >/dev/null 2>&1 || fail "awg-31 toggle on"
grep -qF "HeaderProtectionKey = $(jq -r '.junk.HeaderProtectionKey' "$AWG_PARAMS_FILE")" "$AWG_CONF_FILE" \
  || fail "toggle on: HPK missing"
grep -q '^RandomTrailers = on$' "$AWG_CONF_FILE" || fail "toggle on: RandomTrailers missing"
pass "3.1 toggle switches conf format and preserves the shared HPK"

# второй профиль → следующий адрес .3
jq -n '{name:"dave", uuid:"u-dave", transport:"tcp", port:443}' > "$PROFILES_DIR/dave.json" || fail "fixture dave"
_awg_grant_profile dave || fail "awg grant dave"
addr2=$(jq -r '.backends.awg.address' "$PROFILES_DIR/dave.json")
[[ "$addr2" == "10.8.1.3" ]] || fail "second address expected 10.8.1.3, got $addr2"
pass "address allocation advances (.2 -> .3)"

# revoked: ротация ключей peer-а
k1=$(jq -r '.backends.awg.client_private_key' "$PROFILES_DIR/carol.json")
_awg_on_profile_event carol revoked || fail "awg event revoked"
k2=$(jq -r '.backends.awg.client_private_key' "$PROFILES_DIR/carol.json")
[[ "$k2" != "$k1" ]] || fail "awg revoke did not rotate keys"
grep -qF "PublicKey = $(jq -r '.backends.awg.client_public_key' "$PROFILES_DIR/carol.json")" "$AWG_CONF_FILE" \
  || fail "awg revoke: conf not updated"
[[ "$(jq -r '.backends.awg.address' "$PROFILES_DIR/carol.json")" == "10.8.1.2" ]] \
  || fail "awg revoke must keep the address"
pass "event revoked rotates peer keys, keeps address, regenerates conf"

# expired: expire_disabled=true убирает peer из конфига
safe_jq_write '.expire_disabled = true' "$PROFILES_DIR/carol.json" || fail "fixture expire"
_awg_on_profile_event carol expired || fail "awg event expired"
grep -qF "10.8.1.2/32" "$AWG_CONF_FILE" && fail "expired peer still in conf"
grep -qF "10.8.1.3/32" "$AWG_CONF_FILE" || fail "active peer lost on expired event"
pass "event expired removes disabled peer, keeps active ones"

# restored: возврат peer-а
safe_jq_write '.expire_disabled = false' "$PROFILES_DIR/carol.json" || fail "fixture restore"
_awg_on_profile_event carol restored || fail "awg event restored"
grep -qF "10.8.1.2/32" "$AWG_CONF_FILE" || fail "restored peer missing in conf"
pass "event restored returns peer to conf"

# deleted: файл профиля удалён ДО события (как в profile_delete_command) —
# реген обязан сняться с интерфейса без удалённого peer-а, иначе осиротевший
# peer живёт вечно и удалённый пользователь сохраняет доступ.
rm -f "$PROFILES_DIR/carol.json" || fail "fixture delete carol"
_awg_on_profile_event carol deleted || fail "awg event deleted (file pre-removed)"
grep -qF "10.8.1.2/32" "$AWG_CONF_FILE" && fail "deleted peer still in conf (regen skipped)"
grep -qF "10.8.1.3/32" "$AWG_CONF_FILE" || fail "active peer lost on deleted event"
pass "event deleted (file pre-removed) removes peer — no orphans"

# created: авто-выдача ключей при создании отключена — ключ бэкенда
# выдаётся только явным grant (выбор протокола в GUI / меню 11-13).
jq -n '{name:"eve", uuid:"u-eve", transport:"tcp", port:443}' > "$PROFILES_DIR/eve.json" \
  || fail "fixture eve"
_awg_on_profile_event eve created || fail "awg event created"
jq -e '.backends.awg == null' "$PROFILES_DIR/eve.json" >/dev/null \
  || fail "created must not auto-grant awg keys"
pass "event created is a no-op — keys only via explicit grant"
rm -f "$PROFILES_DIR/eve.json"

# grant без backend — безопасный no-op проверяется ниже вместе с uninstall

# ── Отсутствие установки: безопасные no-op ──
safe_jq_write --arg t awg 'del(.[$t])' "$BACKENDS_REGISTRY_FILE" || fail "registry del"
rm -f "$AWG_CONF_FILE"
rc=0; _awg_uninstall >/dev/null 2>&1 || rc=$?
[[ "$rc" == "2" ]] || fail "uninstall rc=$rc on not-installed (expected 2)"
pass "awg uninstall is a safe no-op (rc 2) when not installed"

# 6) статика: диспетчер и меню
grep -Fq '    awg-install)' xrayebator || fail "dispatch awg-install missing"
grep -Fq '    awg-uninstall)' xrayebator || fail "dispatch awg-uninstall missing"
grep -Fq '    awg-status)' xrayebator || fail "dispatch awg-status missing"
grep -Fq '    awg-grant)' xrayebator || fail "dispatch awg-grant missing"
grep -Fq '    awg-conf)' xrayebator || fail "dispatch awg-conf missing"
grep -Fq '      12) awg_menu ;;' xrayebator || fail "menu dispatch 12 missing"
grep -Fq '      13) backend_status_menu ;;' xrayebator || fail "menu dispatch 13 missing"
grep -Fq 'awg_menu() {' xrayebator || fail "awg_menu definition missing"
grep -Fq 'awg_conf_menu() {' xrayebator || fail "awg_conf_menu definition missing"
grep -Fq 'backend_status_menu() {' xrayebator || fail "backend_status_menu definition missing"
grep -Fq '_backend_apply_profile_lifecycle "$name" revoked' xrayebator || fail "revoke lifecycle wiring missing"
grep -Fq '"$(basename "$profile_file" .json)" expired' xrayebator || fail "expire lifecycle wiring missing"
pass "CLI dispatch, menu, lifecycle wiring present (12/13)"

echo ""
pass "amneziawg backend (slice 4): all checks green"
