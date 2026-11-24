#!/usr/bin/env bash
# Тест backend Hysteria 2 — срезы 2+3 (2026-10-04).
# Функционально проверяются чистые функции (render server.yaml / systemd-unit,
# arch-маппинг, TLS-детект без LE-маркеров), гранты per-profile, события
# жизненного цикла, pure-ссылка и интеграция с реестром/статусом — в
# source-режиме с переопределёнными BACKENDS_ROOT/PROFILES_DIR/LOCK_FILE
# и фейковым systemctl (CI без systemd). Полный install/uninstall с сетью,
# openssl и настоящим systemd покрывается живым спайком на VPS (срез 7).
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
# Системные пути бэкенда — в tmp: на живом сервере реальный юнит/хук существуют, и
# проверки «бэкенд не установлен → rc=2» краснели от состояния машины, а не от кода.
export HYSTERIA2_UNIT_FILE="$TMP_ROOT/systemd/hysteria-server.service"
export HYSTERIA2_SYSCTL_FILE="$TMP_ROOT/sysctl/99-xrayebator-hysteria.conf"
export HYSTERIA2_CERTBOT_HOOK="$TMP_ROOT/renewal-hooks/deploy/xrayebator-hysteria.sh"
# Бинарник тоже в tmp: `_hysteria2_uninstall` делает `rm -f "$HYSTERIA2_BIN"`, и без
# этого override прогон теста на живом сервере УДАЛЯЛ настоящий /usr/local/bin/hysteria
# (живой инцидент 2026-11-07: реестр говорил installed, бинарника не было,
# hysteria2-install отвечал already). Тест не имеет права трогать реальный файл.
export HYSTERIA2_BIN="$TMP_ROOT/bin/hysteria"
mkdir -p "$(dirname "$HYSTERIA2_UNIT_FILE")" "$(dirname "$HYSTERIA2_SYSCTL_FILE")" \
  "$(dirname "$HYSTERIA2_CERTBOT_HOOK")"
mkdir -p "$PROFILES_DIR"

# Фейковый systemctl: CI/WSL без systemd — is-active должен говорить active,
# чтобы apply_config/regen проходили детерминированно.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
# Fake systemctl for tests: everything succeeds.
exit 0
EOF
chmod 755 "$FAKEBIN/systemctl"
export PATH="$FAKEBIN:$PATH"
export XRAYEBATOR_SERVER_ADDR_OVERRIDE="203.0.113.10"

# shellcheck disable=SC1091
source ./xrayebator || fail "source ./xrayebator failed"

# ── Срез 2: рендеры и детекты ──

yaml="$TMP_ROOT/server.yaml"
_hysteria2_render_server_yaml "$yaml" 443 "/opt/c.pem" "/opt/k.pem" '{}' "" || fail "render yaml"
grep -q '^listen: :443$' "$yaml" || fail "yaml listen"
grep -q '^  cert: /opt/c.pem$' "$yaml" || fail "yaml cert"
grep -q '^  key: /opt/k.pem$' "$yaml" || fail "yaml key"
grep -q '^  type: userpass$' "$yaml" || fail "yaml auth type"
grep -q '^  userpass: {}$' "$yaml" || fail "yaml userpass empty map"
grep -q '^  type: 404$' "$yaml" || fail "yaml masquerade 404"
pass "server.yaml rendered with expected structure"

_hysteria2_render_server_yaml "$yaml" 8443 "/c" "/k" '{"alice":"pw1"}' "" || fail "render yaml users"
grep -q '^  userpass: {"alice":"pw1"}$' "$yaml" || fail "yaml userpass map inline"
pass "server.yaml accepts users map parameter"

unit="$TMP_ROOT/hysteria-server.service"
_hysteria2_render_unit "$unit" || fail "render unit"
grep -q '^User=hysteria$' "$unit" || fail "unit User"
grep -qF 'ExecStart=/usr/local/bin/hysteria server -c /usr/local/etc/xrayebator/backends/hysteria/server.yaml' "$unit" || fail "unit ExecStart"
grep -q '^AmbientCapabilities=CAP_NET_BIND_SERVICE$' "$unit" || fail "unit AmbientCapabilities"
grep -q '^NoNewPrivileges=true$' "$unit" || fail "unit NoNewPrivileges"
grep -q '^Restart=on-failure$' "$unit" || fail "unit Restart"
pass "systemd unit rendered (dedicated user + CAP_NET_BIND_SERVICE + auto-restart)"

arch=$(_hysteria2_asset_arch) || fail "asset arch"
case "$arch" in amd64|arm64|arm|386) ;; *) fail "unexpected arch: $arch" ;; esac
pass "asset arch resolves: $arch"

# Проверяем выбор TLS и deploy-hook на изолированных LE-линиях.
HYSTERIA2_SUBSCRIPTION_DOMAIN_FILE="$TMP_ROOT/.subscription_domain"
HYSTERIA2_LETSENCRYPT_LIVE_DIR="$TMP_ROOT/letsencrypt"
SELFSTEAL_DOMAIN_FILE="$TMP_ROOT/.selfsteal_domain"
[[ "$(_hysteria2_tls_mode_detect)" == "selfsigned" ]] || fail "tls detect without domain"
printf 'sub.example.com' > "$HYSTERIA2_SUBSCRIPTION_DOMAIN_FILE"
[[ "$(_hysteria2_tls_mode_detect)" == "selfsigned" ]] || fail "tls detect without cert"
live="$HYSTERIA2_LETSENCRYPT_LIVE_DIR/sub.example.com"
ip_live="$HYSTERIA2_LETSENCRYPT_LIVE_DIR/203.0.113.10"
mkdir -p "$live" "$ip_live" "$HYSTERIA2_DIR"
printf 'domain cert\n' > "$live/fullchain.pem"
printf 'domain key\n' > "$live/privkey.pem"
printf 'IP cert\n' > "$ip_live/fullchain.pem"
printf 'IP key\n' > "$ip_live/privkey.pem"
[[ "$(_hysteria2_tls_mode_detect)" == "le sub.example.com" ]] || fail "subscription domain cert"
printf '203.0.113.10' > "$HYSTERIA2_SUBSCRIPTION_DOMAIN_FILE"
[[ "$(_hysteria2_tls_mode_detect)" == "selfsigned" ]] || fail "IP-only TLS fallback"
printf 'sub.example.com' > "$SELFSTEAL_DOMAIN_FILE"
tls_mode=$(_hysteria2_tls_mode_detect)
[[ "$tls_mode" == "le sub.example.com" ]] || fail "domain cert must win over IP cert"
domain=${tls_mode#le }

_hysteria2_render_server_yaml "$yaml" 443 /c /k '{}' "$domain" || fail "render proxy"
grep -qx '  type: proxy' "$yaml" || fail "known domain must use proxy"
grep -Fxq "    url: https://$domain/" "$yaml" || fail "proxy must target operator domain"
grep -qx '    rewriteHost: true' "$yaml" || fail "proxy must rewrite Host"
! grep -qx '  type: 404' "$yaml" || fail "known domain must not use 404"

_hysteria2_write_certbot_hook "$domain" || fail "write deploy-hook"
export HYSTERIA2_RESTART_LOG="$TMP_ROOT/restarts"
cat > "$FAKEBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == restart ]]; then
  printf '%s\n' "$2" >> "$HYSTERIA2_RESTART_LOG"
fi
exit 0
EOF
printf 'old cert\n' > "$HYSTERIA2_DIR/cert.pem"
printf 'old key\n' > "$HYSTERIA2_DIR/key.pem"
for renewed in "203.0.113.10" "203.0.113.10 $domain" "$domain 2001:db8::1" "other.example.com" ""; do
  RENEWED_DOMAINS="$renewed" bash "$HYSTERIA2_CERTBOT_HOOK" || fail "deploy-hook: $renewed"
  [[ $(<"$HYSTERIA2_DIR/cert.pem") == "old cert" &&
     $(<"$HYSTERIA2_DIR/key.pem") == "old key" &&
     ! -e "$HYSTERIA2_RESTART_LOG" ]] || fail "unexpected TLS update or restart: $renewed"
done
RENEWED_DOMAINS="$domain" RENEWED_LINEAGE="$HYSTERIA2_LETSENCRYPT_LIVE_DIR/other.example.com" \
  bash "$HYSTERIA2_CERTBOT_HOOK" || fail "foreign lineage deploy-hook"
[[ ! -e "$HYSTERIA2_RESTART_LOG" ]] || fail "foreign lineage triggered restart"
RENEWED_DOMAINS="$domain" RENEWED_LINEAGE="$live" bash "$HYSTERIA2_CERTBOT_HOOK" || fail "domain deploy-hook"
cmp -s "$live/fullchain.pem" "$HYSTERIA2_DIR/cert.pem" &&
  cmp -s "$live/privkey.pem" "$HYSTERIA2_DIR/key.pem" &&
  grep -qx 'hysteria-server' "$HYSTERIA2_RESTART_LOG" || fail "domain renewal must update TLS and restart"
rm -f "$HYSTERIA2_CERTBOT_HOOK"
pass "domain TLS wins over IP, uses proxy masquerade and ignores IP renewal"

# ── Реестр + статус ──

(
  _hysteria2_fetch_release_info() { printf 'app/v2.12.3 \n'; }
  _hysteria2_ensure_user() { return 0; }
  _hysteria2_apply_sysctl() { return 0; }
  _backend_port_busy_udp() { return 1; }
  open_firewall_port() { return 0; }
  sleep() { return 0; }
  curl() {
    local output
    while [[ "$1" != "-o" ]]; do shift; done
    output=$2
    printf '#!/bin/bash\nexit 0\n' > "$output"
  }

  mkdir -p "$(dirname "$HYSTERIA2_BIN")"
  _hysteria2_install 443 no_prompt > "$TMP_ROOT/install.log" 2>&1 || { cat "$TMP_ROOT/install.log"; fail "install with domain TLS"; }
) || fail "staged installation"
cmp -s "$live/fullchain.pem" "$HYSTERIA2_DIR/cert.pem" &&
  cmp -s "$live/privkey.pem" "$HYSTERIA2_DIR/key.pem" || fail "install did not copy domain TLS"
grep -Fxq "    url: https://$domain/" "$HYSTERIA2_DIR/server.yaml" || fail "install lost proxy"
status="$(hysteria2_status_command)" || fail "hysteria2_status_command"
jq -e --arg domain "$domain" '.ok == true and
       .backend.installed == true and
       .backend.version == "v2.12.3" and
       .backend.tls_mode == ("le " + $domain) and
       .backend.sni == $domain and
       .backend.masquerade == "proxy" and
       .backend.masquerade_domain == $domain and
       .backend.port == 443 and
       .binary == "present"' <<<"$status" >/dev/null || fail "status JSON: $status"
pass "install writes domain TLS and proxy to server config and registry"

# ── Срез 3: гранты, события, ссылка ──
jq -n '{name:"alice", uuid:"u-alice", transport:"tcp", port:443, fingerprint:"firefox",
        sni:"www.example.com", sub_token:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", created:"2026-10-04"}' \
  > "$PROFILES_DIR/alice.json" || fail "fixture alice"
[[ "$(_hysteria2_grants_count)" == "0" ]] || fail "grants count 0 expected"

_hysteria2_grant_profile alice || fail "grant alice"
pw1=$(jq -r '.backends.hysteria2.password' "$PROFILES_DIR/alice.json")
[[ "$pw1" =~ ^[0-9a-f]{32}$ ]] || fail "grant password format"
jq -r '.backends.hysteria2.username' "$PROFILES_DIR/alice.json" | grep -qx "alice" || fail "grant username"
grep -q "alice: $pw1" "$HYSTERIA2_DIR/server.yaml" 2>/dev/null \
  || grep -q "\"alice\":\"$pw1\"" "$HYSTERIA2_DIR/server.yaml" || fail "regen: alice missing in users map"
grep -Fxq "    url: https://$domain/" "$HYSTERIA2_DIR/server.yaml" || fail "regen lost proxy"
[[ "$(_hysteria2_grants_count)" == "1" ]] || fail "grants count 1 expected"
pass "grant_profile writes password to profile and regenerates users map"

link=$(_hysteria2_profile_link_pure "$PROFILES_DIR/alice.json") || fail "link pure"
[[ "$link" == *"@203.0.113.10:443/?sni=$domain&insecure=0#"* ]] || fail "domain TLS link disagrees with registry"
_backend_set hysteria2 '.hysteria2 |= (.port = 8443 | .tls_mode = "selfsigned" | .sni = "")' \
  || fail "set selfsigned endpoint"
# Метка ссылки включает страну, если на хосте есть geo-маркер (.server_country):
# на живом сервере тест падал, потому что ожидал голое имя. Изолируем маркер и
# проверяем ОБА варианта — без него и с ним (иначе один из путей не покрыт).
export SERVER_COUNTRY_FILE="$TMP_ROOT/.server_country"
rm -f "$SERVER_COUNTRY_FILE"
link=$(_hysteria2_profile_link_pure "$PROFILES_DIR/alice.json") || fail "link pure (no country)"
[[ "$link" == "hysteria2://alice:${pw1}@203.0.113.10:8443/?insecure=1#alice" ]] \
  || fail "link shape without country"
printf 'NL|Netherlands|Kerkrade' > "$SERVER_COUNTRY_FILE"
link_geo=$(_hysteria2_profile_link_pure "$PROFILES_DIR/alice.json") || fail "link pure (country)"
case "$link_geo" in
  "hysteria2://alice:${pw1}@203.0.113.10:8443/?insecure=1#"*"Netherlands"*"alice") ;;
  *) fail "link shape with country" ;;
esac
# Фрагмент обязан быть URL-encoded: юникод-флаг не должен попасть сырым.
case "$link_geo" in
  *"%"*) ;;
  *) fail "link fragment not URL-encoded" ;;
esac
rm -f "$SERVER_COUNTRY_FILE"
pass "pure link: selfsigned -> insecure=1, no sni param, name fragment (with and without country)"

# revoked: ротация пароля
_hysteria2_on_profile_event alice revoked || fail "event revoked"
pw2=$(jq -r '.backends.hysteria2.password' "$PROFILES_DIR/alice.json")
[[ "$pw2" =~ ^[0-9a-f]{32}$ && "$pw2" != "$pw1" ]] || fail "revoked did not rotate password"
grep -q "\"alice\":\"$pw2\"" "$HYSTERIA2_DIR/server.yaml" || fail "revoked: users map not updated"
pass "event revoked rotates password and regenerates config"

# expired: expire_disabled=true выкидывает грант из users-карты
safe_jq_write '.expire_disabled = true' "$PROFILES_DIR/alice.json" || fail "fixture expire"
_hysteria2_on_profile_event alice expired || fail "event expired"
users_line=$(grep '^  userpass: ' "$HYSTERIA2_DIR/server.yaml")
[[ "$users_line" != *"alice"* ]] || fail "expired: alice still in users map"
grep -q '_xrayebator_placeholder' <<<"$users_line" \
  || fail "expired: empty map must fall back to placeholder"
pass "event expired removes disabled profile grant (placeholder keeps config valid)"

# restored: возврат гранта
safe_jq_write '.expire_disabled = false' "$PROFILES_DIR/alice.json" || fail "fixture restore"
_hysteria2_on_profile_event alice restored || fail "event restored"
grep -q "\"alice\":\"$pw2\"" "$HYSTERIA2_DIR/server.yaml" || fail "restored: alice missing"
pass "event restored returns grant to users map"

# deleted: файл профиля удалён ДО события (как в profile_delete_command) —
# реген users-карты обязан пройти без удалённого гранта, иначе осиротевший
# пароль остаётся в server.yaml и удалённый пользователь сохраняет доступ.
jq -n '{name:"cleo", uuid:"u-cleo", transport:"tcp", port:443}' \
  > "$PROFILES_DIR/cleo.json" || fail "fixture cleo"
_hysteria2_grant_profile cleo || fail "grant cleo"
grep -q '"cleo"' "$HYSTERIA2_DIR/server.yaml" || fail "cleo missing after grant"
rm -f "$PROFILES_DIR/cleo.json" || fail "fixture delete cleo"
_hysteria2_on_profile_event cleo deleted || fail "event deleted (file pre-removed)"
grep -q '"cleo"' "$HYSTERIA2_DIR/server.yaml" && fail "deleted: cleo still in users map"
grep -q '"alice"' "$HYSTERIA2_DIR/server.yaml" || fail "deleted: alice collateral damage"
pass "event deleted (file pre-removed) removes grant from users map"

# created: авто-выдача при создании отключена — только явный grant.
jq -n '{name:"eve", uuid:"u-eve", transport:"tcp", port:443}' \
  > "$PROFILES_DIR/eve.json" || fail "fixture eve"
_hysteria2_on_profile_event eve created || fail "hysteria2 event created"
jq -e '.backends.hysteria2 == null' "$PROFILES_DIR/eve.json" >/dev/null \
  || fail "created must not auto-grant hysteria2 keys"
pass "event created is a no-op — keys only via explicit grant"
rm -f "$PROFILES_DIR/eve.json"

# grant_all: массовая выдача с одним регеном
jq -n '{name:"bob", uuid:"u-bob", transport:"xhttp", port:8443, fingerprint:"firefox",
        sni:"www.example.com", sub_token:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", created:"2026-10-04"}' \
  > "$PROFILES_DIR/bob.json" || fail "fixture bob"
_hysteria2_grant_all_profiles >/dev/null 2>&1 || fail "grant_all"
[[ "$(_hysteria2_grants_count)" == "2" ]] || fail "grants count 2 expected"
grep -q '"bob":' "$HYSTERIA2_DIR/server.yaml" || fail "grant_all: bob missing"
pass "grant_all provisions every profile with a single regen"

# grant_profile idempotent: повторный вызов не меняет пароль
_hysteria2_grant_profile alice || fail "grant alice twice"
pw3=$(jq -r '.backends.hysteria2.password' "$PROFILES_DIR/alice.json")
[[ "$pw3" == "$pw2" ]] || fail "grant re-issue rotated password unexpectedly"
pass "grant_profile is idempotent"

_backend_set hysteria2 '.hysteria2 |= (del(.masquerade_domain) | .masquerade = "404")' \
  || fail "fixture legacy masquerade"
_hysteria2_grant_profile alice || fail "grant retry on legacy registry"
grep -Fxq "    url: https://$domain/" "$HYSTERIA2_DIR/server.yaml" || fail "legacy regen lost proxy"
jq -e --arg domain "$domain" '.hysteria2 | .masquerade == "proxy" and .masquerade_domain == $domain' \
  "$BACKENDS_REGISTRY_FILE" >/dev/null || fail "legacy regen did not update registry"
pass "grant retry preserves proxy and updates legacy registry"

# ── Отсутствие установки: безопасные no-op ──

(
  close_firewall_port() { return 0; }
  _hysteria2_uninstall >/dev/null 2>&1
) || fail "uninstall staged backend"
rc=0; _hysteria2_uninstall >/dev/null 2>&1 || rc=$?
[[ "$rc" == "2" ]] || fail "uninstall rc=$rc on not-installed (expected 2)"
rc=0; _hysteria2_grant_profile nobody >/dev/null 2>&1 || rc=$?
[[ "$rc" == "0" ]] || fail "grant without backend rc=$rc (expected no-op 0)"
pass "uninstall/grant are safe no-ops without backend"

# ── Статика: диспетчер, меню, миграция, подписка ──

grep -Fq '    hysteria2-install)' xrayebator || fail "dispatch hysteria2-install missing"
grep -Fq '    hysteria2-uninstall)' xrayebator || fail "dispatch hysteria2-uninstall missing"
grep -Fq '    hysteria2-status)' xrayebator || fail "dispatch hysteria2-status missing"
grep -Fq '    hysteria2-grant)' xrayebator || fail "dispatch hysteria2-grant missing"
grep -Fq '      11) hysteria2_menu ;;' xrayebator || fail "menu dispatch 11 missing"
grep -Fq 'hysteria2_menu() {' xrayebator || fail "hysteria2_menu definition missing"
[[ "$(grep -Fc 'run_migration "subhttp_hysteria2_2026"' xrayebator)" == "2" ]] \
  || fail "migration subhttp_hysteria2_2026 must be registered in main_menu AND quickstart"
grep -Fq '_migrate_subhttp_hysteria2_2026() {' xrayebator || fail "migration fn missing"
grep -Fq 'hysteria2_uri=""' xrayebator || fail "subhttp handler hysteria2_uri wiring missing"
grep -Fq '_backend_apply_profile_lifecycle "$name" created' xrayebator || fail "create lifecycle wiring missing"
grep -Fq '_backend_apply_profile_lifecycle "$name" deleted' xrayebator || fail "delete lifecycle wiring missing"
grep -Fq '_backend_apply_profile_lifecycle "$name" revoked' xrayebator || fail "revoke lifecycle wiring missing"
grep -Fq '"$(basename "$profile_file" .json)" expired' xrayebator || fail "expire wiring missing"
grep -Fq '"$(basename "$profile_file" .json)" restored' xrayebator || fail "restore wiring missing"
pass "CLI dispatch, menu, migration parity, subscription and lifecycle wiring present"

# uninstall.sh сносит нейтральный корень; до этого он обязан погасить юнит и
# снять deploy-hook, иначе после удаления остаётся включённый сервис с
# конфигом, которого уже нет.
grep -Fq 'systemctl disable --now hysteria-server.service' uninstall.sh \
  || fail "uninstall.sh must stop hysteria-server before removing state"
grep -Fq '/etc/letsencrypt/renewal-hooks/deploy/xrayebator-hysteria.sh' uninstall.sh \
  || fail "uninstall.sh must drop the hysteria certbot deploy-hook"
grep -Fq '/usr/local/bin/hysteria' uninstall.sh \
  || fail "uninstall.sh must remove the hysteria binary"
pass "uninstall.sh tears the backend down before deleting the neutral root"

echo ""
pass "hysteria2 backend (slices 2+3): all checks green"
