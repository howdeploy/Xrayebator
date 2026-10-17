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
_hysteria2_render_server_yaml "$yaml" 443 "/opt/c.pem" "/opt/k.pem" || fail "render yaml"
grep -q '^listen: :443$' "$yaml" || fail "yaml listen"
grep -q '^  cert: /opt/c.pem$' "$yaml" || fail "yaml cert"
grep -q '^  key: /opt/k.pem$' "$yaml" || fail "yaml key"
grep -q '^  type: userpass$' "$yaml" || fail "yaml auth type"
grep -q '^  userpass: {}$' "$yaml" || fail "yaml userpass empty map"
grep -q '^  type: 404$' "$yaml" || fail "yaml masquerade 404"
pass "server.yaml rendered with expected structure"

_hysteria2_render_server_yaml "$yaml" 8443 "/c" "/k" '{"alice":"pw1"}' || fail "render yaml users"
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

[[ "$(_hysteria2_tls_mode_detect)" == "selfsigned" ]] || fail "tls detect expected selfsigned"
pass "tls mode defaults to selfsigned without subscription markers"

# ── Реестр + статус ──

_backend_set hysteria2 '(.hysteria2.installed) = true' || fail "set installed"
_backend_set hysteria2 '(.hysteria2.version) = $v' --arg v "v2.12.3" || fail "set version"
_backend_set hysteria2 '(.hysteria2.port) = $p' --argjson p 443 || fail "set port"
_backend_set hysteria2 '(.hysteria2.unit) = $u' --arg u "hysteria-server.service" || fail "set unit"
_backend_set hysteria2 '(.hysteria2.tls_mode) = $m' --arg m "selfsigned" || fail "set tls"
_backend_set hysteria2 '(.hysteria2.sni) = $s' --arg s "" || fail "set sni"
_backend_set hysteria2 '(.hysteria2.sub_body) = true' || fail "set sub_body"
status="$(hysteria2_status_command)" || fail "hysteria2_status_command"
jq -e '.ok == true and
       .backend.installed == true and
       .backend.version == "v2.12.3" and
       .backend.tls_mode == "selfsigned" and
       .backend.port == 443 and
       (.binary == "absent" or .binary == "present")' <<<"$status" >/dev/null \
  || fail "status JSON shape: $status"
pass "hysteria2-status JSON shape correct (registry fields preserved)"

# ── Срез 3: гранты, события, ссылка ──
# В реальном жизненном цикле каталог бэкенда создаёт _hysteria2_install;
# тест собирает состояние вручную — воспроизводим это.
mkdir -p "$HYSTERIA2_DIR"

jq -n '{name:"alice", uuid:"u-alice", transport:"tcp", port:443, fingerprint:"firefox",
        sni:"www.example.com", sub_token:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", created:"2026-10-04"}' \
  > "$PROFILES_DIR/alice.json" || fail "fixture alice"
[[ "$(_hysteria2_grants_count)" == "0" ]] || fail "grants count 0 expected"

_hysteria2_grant_profile alice || fail "grant alice"
pw1=$(jq -r '.backends.hysteria2.password' "$PROFILES_DIR/alice.json")
[[ "$pw1" =~ ^[0-9a-f]{32}$ ]] || fail "grant password format: $pw1"
jq -r '.backends.hysteria2.username' "$PROFILES_DIR/alice.json" | grep -qx "alice" || fail "grant username"
grep -q "alice: $pw1" "$HYSTERIA2_DIR/server.yaml" 2>/dev/null \
  || grep -q "\"alice\":\"$pw1\"" "$HYSTERIA2_DIR/server.yaml" || fail "regen: alice missing in users map"
[[ "$(_hysteria2_grants_count)" == "1" ]] || fail "grants count 1 expected"
pass "grant_profile writes password to profile and regenerates users map"

link=$(_hysteria2_profile_link_pure "$PROFILES_DIR/alice.json") || fail "link pure"
[[ "$link" == "hysteria2://alice:${pw1}@203.0.113.10:443/?insecure=1#alice" ]] \
  || fail "link shape: $link"
pass "pure link: selfsigned -> insecure=1, no sni param, name fragment"

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
[[ "$users_line" != *"alice"* ]] || fail "expired: alice still in users map: $users_line"
grep -q '_xrayebator_placeholder' <<<"$users_line" \
  || fail "expired: empty map must fall back to placeholder: $users_line"
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

# ── Отсутствие установки: безопасные no-op ──

safe_jq_write --arg t hysteria2 'del(.[$t])' "$BACKENDS_REGISTRY_FILE" || fail "registry del"
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

echo ""
pass "hysteria2 backend (slices 2+3): all checks green"
