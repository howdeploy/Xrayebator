#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

WORKDIR=$(mktemp -d /tmp/xrayebator-transaction.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/xrayebator"

CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"
XRAY_BACKUPS_DIR="$WORKDIR/backups"
XRAY_BIN="$WORKDIR/xray"
mkdir -p "$PROFILES_DIR" "$XRAY_BACKUPS_DIR"

printf '#!/bin/sh\nprintf "%s\\n" "invalid test config"\nexit 1\n' > "$XRAY_BIN"
chmod +x "$XRAY_BIN"

echo "Проверка точного rollback backup"
printf '{"value":"expected"}\n' > "$CONFIG_FILE"
rollback_config=""
backup_config "expected_operation" rollback_config >/dev/null ||
  fail "backup_config failed"
[[ -n "$rollback_config" && -f "$rollback_config" ]] ||
  fail "backup_config did not return the exact path"

printf '{"value":"broken"}\n' > "$CONFIG_FILE"
printf '{"value":"wrong-newer-operation"}\n' > "$XRAY_BACKUPS_DIR/config_99999999_wrong.json"
restart_rc=0
safe_restart_xray "$rollback_config" >/dev/null 2>&1 || restart_rc=$?
[[ "$restart_rc" -eq 1 ]] || fail "invalid config unexpectedly passed validation"
[[ "$(jq -r '.value' "$CONFIG_FILE")" == "expected" ]] ||
  fail "safe_restart_xray restored an unrelated backup"

echo "Проверка rollback после неудачного systemd restart"
printf '#!/bin/sh\nprintf "%s\\n" "Configuration OK."\nexit 0\n' > "$XRAY_BIN"
chmod +x "$XRAY_BIN"
ensure_xray_service_unit() { return 0; }
sleep() { :; }
systemctl() {
  if [[ "${1:-}" == "is-active" ]]; then
    return 1
  fi
  return 0
}

printf '{"value":"service-expected"}\n' > "$CONFIG_FILE"
service_rollback=""
backup_config "service_expected" service_rollback >/dev/null ||
  fail "service rollback backup failed"
printf '{"value":"service-new"}\n' > "$CONFIG_FILE"
service_rc=0
safe_restart_xray "$service_rollback" >/dev/null 2>&1 || service_rc=$?
[[ "$service_rc" -eq 1 ]] || fail "failed service restart unexpectedly succeeded"
[[ "$(jq -r '.value' "$CONFIG_FILE")" == "service-expected" ]] ||
  fail "service restart failure did not restore its exact backup"

echo "Проверка UUID-scoped удаления профиля"
jq -n '{
  inbounds: [
    {port:41001,settings:{clients:[{id:"foreign"}]},tag:"foreign-only"},
    {port:41002,settings:{clients:[{id:"target"},{id:"foreign"}]},tag:"shared"},
    {port:41003,settings:{clients:[{id:"target"}]},tag:"target-only"},
    {port:41004,settings:{clients:[{id:"target"}]},tag:"outside-scope"}
  ]
}' > "$CONFIG_FILE"

_remove_profile_uuid_from_config "target" '[41001,41002,41003]' ||
  fail "UUID-scoped removal failed"
jq -e '
  any(.inbounds[]; .port == 41001 and .settings.clients == [{id:"foreign"}]) and
  any(.inbounds[]; .port == 41002 and .settings.clients == [{id:"foreign"}]) and
  ([.inbounds[] | select(.port == 41003)] | length) == 0 and
  any(.inbounds[]; .port == 41004 and .settings.clients == [{id:"target"}])
' "$CONFIG_FILE" >/dev/null ||
  fail "profile deletion removed a foreign/out-of-scope client or kept an empty inbound"

echo "Проверка атомарного переноса клиента"
jq -n '{
  inbounds: [
    {
      port:42001,
      settings:{clients:[{id:"move-me",flow:"xtls-rprx-vision",testpre:7,testseed:[11,12]}]},
      tag:"old"
    },
    {port:42002,settings:{clients:[{id:"stay"}]},tag:"new"}
  ]
}' > "$CONFIG_FILE"

_move_profile_client_between_inbounds "move-me" 42001 42002 "" ||
  fail "atomic client move failed"
jq -e '
  ([.inbounds[] | select(.port == 42001)] | length) == 0 and
  any(.inbounds[] | select(.port == 42002) | .settings.clients[];
      .id == "move-me" and .flow == "" and .testpre == 7 and .testseed == [11,12]) and
  any(.inbounds[] | select(.port == 42002) | .settings.clients[]; .id == "stay")
' "$CONFIG_FILE" >/dev/null ||
  fail "client move lost advanced fields or left the empty source inbound"

before_duplicate=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
duplicate_rc=0
_move_profile_client_between_inbounds "move-me" 42002 42002 "" >/dev/null 2>&1 ||
  duplicate_rc=$?
after_duplicate=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
[[ "$duplicate_rc" -ne 0 && "$before_duplicate" == "$after_duplicate" ]] ||
  fail "duplicate target move was not rejected atomically"

echo "Проверка firewall guard при повреждённом config.json"
UFW_CALLS_FILE="$WORKDIR/ufw-calls"
ufw() {
  printf 'called\n' >> "$UFW_CALLS_FILE"
  return 0
}
printf '{broken-json\n' > "$CONFIG_FILE"
close_firewall_port 42003 || fail "close_firewall_port failed on invalid config"
[[ ! -e "$UFW_CALLS_FILE" ]] ||
  fail "close_firewall_port touched UFW after jq/config failure"
unset -f ufw

echo "Проверка XHTTP legacy/PQ совместимости"
VLESS_DECRYPTION_FILE="$WORKDIR/vless_decryption"
printf 'mlkem768x25519plus.test-key-material\n' > "$VLESS_DECRYPTION_FILE"
find "$PROFILES_DIR" -maxdepth 1 -type f -delete
jq -n '{
  inbounds: [
    {
      port:44001,
      protocol:"vless",
      settings:{clients:[{id:"legacy-stay",flow:""}],decryption:"none"},
      streamSettings:{
        network:"xhttp",
        security:"reality",
        xhttpSettings:{path:"/legacy-live",host:"legacy.example"},
        realitySettings:{serverNames:["legacy.example"]}
      },
      tag:"legacy"
    },
    {
      port:44002,
      protocol:"vless",
      settings:{clients:[{id:"pq-stay",flow:""}],decryption:"mlkem768x25519plus.live"},
      streamSettings:{
        network:"xhttp",
        security:"reality",
        xhttpSettings:{path:"/pq-live",host:"pq.example"},
        realitySettings:{serverNames:["pq.example"]}
      },
      tag:"pq"
    },
    {
      port:44003,
      protocol:"vless",
      settings:{clients:[{id:"tls-stay",flow:""}],decryption:"none"},
      streamSettings:{
        network:"xhttp",
        security:"tls",
        xhttpSettings:{path:"/tls-live",host:"tls.example"}
      },
      tag:"not-reality"
    }
  ]
}' > "$CONFIG_FILE"

before_modes=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
pq_into_legacy_rc=0
add_inbound "pq-new" "xhttp" 44001 "legacy.example" "firefox" "" "/requested" "true" >/dev/null 2>&1 ||
  pq_into_legacy_rc=$?
legacy_into_pq_rc=0
add_inbound "legacy-new" "xhttp" 44002 "pq.example" "firefox" "" "/requested" "false" >/dev/null 2>&1 ||
  legacy_into_pq_rc=$?
not_reality_rc=0
add_inbound "tls-new" "xhttp" 44003 "tls.example" "firefox" "" "/requested" "false" >/dev/null 2>&1 ||
  not_reality_rc=$?
after_modes=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
[[ "$pq_into_legacy_rc" -ne 0 && "$legacy_into_pq_rc" -ne 0 && "$not_reality_rc" -ne 0 ]] ||
  fail "add_inbound accepted an incompatible XHTTP/PQ/REALITY mode"
[[ "$before_modes" == "$after_modes" ]] ||
  fail "incompatible XHTTP add mutated config.json"

OPENED_PORT_FILE="$WORKDIR/opened-port"
open_firewall_port() {
  printf '%s\n' "$1" > "$OPENED_PORT_FILE"
  return 0
}
add_inbound "legacy-new" "xhttp" 44001 "legacy.example" "firefox" "" "/requested" "false" >/dev/null ||
  fail "compatible legacy XHTTP client was rejected"
jq -e 'any(.inbounds[] | select(.port == 44001) | .settings.clients[]; .id == "legacy-new")' \
  "$CONFIG_FILE" >/dev/null ||
  fail "compatible XHTTP client was not added"
[[ "$(<"$OPENED_PORT_FILE")" == "44001" ]] ||
  fail "existing inbound path did not verify/open its firewall port"

echo "Проверка переноса одного UUID из shared inbound на свободный порт"
find "$PROFILES_DIR" -maxdepth 1 -type f -delete
jq -n '{
  name:"selected",
  uuid:"move-me",
  transport:"tcp",
  port:45001,
  sni:"shared.example",
  fingerprint:"firefox",
  pq_enabled:false
}' > "$PROFILES_DIR/selected.json"
jq -n '{
  inbounds: [{
    port:45001,
    protocol:"vless",
    settings:{
      clients:[
        {id:"move-me",flow:"xtls-rprx-vision"},
        {id:"stay",flow:"xtls-rprx-vision"}
      ],
      decryption:"none"
    },
    streamSettings:{
      network:"tcp",
      security:"reality",
      realitySettings:{serverNames:["shared.example"]}
    },
    tag:"inbound-45001"
  }]
}' > "$CONFIG_FILE"
PRIVATE_KEY="test-private-key"
show_ascii() { :; }
fix_xray_permissions() { :; }
safe_restart_xray() { return 0; }
open_firewall_port() { return 0; }
close_firewall_port() { return 0; }
printf '1\n10\n45002\ny\n\n' | change_port_menu >/dev/null ||
  fail "change_port_menu failed to split a shared inbound"
jq -e '
  any(.inbounds[] | select(.port == 45001) | .settings.clients[]; .id == "stay") and
  ([.inbounds[] | select(.port == 45001) | .settings.clients[] | select(.id == "move-me")] | length) == 0 and
  any(.inbounds[] | select(.port == 45002) | .settings.clients[]; .id == "move-me") and
  ([.inbounds[] | select(.port == 45002) | .settings.clients[] | select(.id == "stay")] | length) == 0
' "$CONFIG_FILE" >/dev/null ||
  fail "shared inbound move relocated a foreign client or lost the selected UUID"
[[ "$(jq -r '.port' "$PROFILES_DIR/selected.json")" == "45002" ]] ||
  fail "selected profile JSON did not move to the new port"

echo "Проверка rollback profile JSON"
printf '{"name":"sample","port":43001}\n' > "$PROFILES_DIR/sample.json"
profiles_snapshot=""
_snapshot_profiles profiles_snapshot || fail "profile snapshot failed"
printf '{"name":"sample","port":43002}\n' > "$PROFILES_DIR/sample.json"
_restore_profiles_snapshot "$profiles_snapshot" >/dev/null ||
  fail "profile snapshot restore failed"
_discard_profiles_snapshot "$profiles_snapshot"
[[ "$(jq -r '.port' "$PROFILES_DIR/sample.json")" == "43001" ]] ||
  fail "profile snapshot did not restore original JSON"

echo "Проверка обязательного exact-backup аргумента"
if rg -n \
  '^[[:space:]]*(if[[:space:]]+!?[[:space:]]*)?safe_restart_xray[[:space:]]*(;|$)' \
  "$REPO_ROOT/xrayebator" >/dev/null; then
  fail "found safe_restart_xray call without an exact backup path"
fi

echo "PASS: config/profile mutations are rollback-safe and UUID-scoped"
