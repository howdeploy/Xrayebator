#!/usr/bin/env bash
# test-port-change-cli.sh
# Тестирует CLI `port-change --name N [--route R] --port P|random` из xrayebator.
# Три сценария:
#   1. unit inbound → порт переименовывается в конфиге, профили синхронизируются;
#   2. shared inbound → UUID переносится в новый inbound, чужие клиенты остаются;
#   3. move в существующий inbound → UUID добавляется, пустой источник удаляется;
#   + invalid port / missing profile / multi-route без --route / конфликт транспорта.
#
# Usage:  bash validation/test-port-change-cli.sh
# Requires: jq, bash 4+.

set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORKDIR=$(mktemp -d /tmp/xrayebator-port-cli.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

source "$REPO_ROOT/xrayebator"

CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"
XRAY_BACKUPS_DIR="$WORKDIR/backups"
XRAY_BIN="$WORKDIR/xray"
mkdir -p "$PROFILES_DIR" "$XRAY_BACKUPS_DIR"

printf '#!/bin/sh\nprintf "Configuration OK."\nexit 0\n' > "$XRAY_BIN"
chmod +x "$XRAY_BIN"
PRIVATE_KEY="test_private_key_private_key_private_key_private_key_123"
ensure_xray_service_unit() { return 0; }
systemctl() { return 0; }
fix_xray_permissions() { return 0; }
open_firewall_port() { return 0; }
close_firewall_port() { return 0; }
sleep() { :; }

# --- Сценарий 1: unit inbound, смена 9001 → 9002 ---
jq -n '{
  inbounds: [
    {
      port: 9001,
      protocol: "vless",
      tag: "inbound-9001",
      settings: {clients: [{id: "11111111-2222-3333-4444-555555555555", flow: "xtls-rprx-vision"}], decryption: "none"},
      streamSettings: {network: "tcp", security: "reality", realitySettings: {privateKey: "key", shortIds: ["abcd"], serverNames: ["www.ozon.ru"], dest: "www.ozon.ru:443"}}
    }
  ]
}' > "$CONFIG_FILE"
jq -n '{
  name: "solo",
  uuid: "11111111-2222-3333-4444-555555555555",
  transport: "tcp",
  port: 9001,
  sni: "www.ozon.ru",
  fingerprint: "firefox"
}' > "$PROFILES_DIR/solo.json"

out=$(port_change_command --name solo --port 9002) || fail "solo port change failed"
jq -e '.ok == true and .port == 9002 and .old_port == 9001' <<< "$out" >/dev/null ||
  fail "solo change bad JSON: $out"
jq -e 'any(.inbounds[]; .port == 9002 and .tag == "inbound-9002")' "$CONFIG_FILE" >/dev/null ||
  fail "inbound port/tag not updated"
jq -e 'all(.inbounds[]; .port != 9001)' "$CONFIG_FILE" >/dev/null ||
  fail "old inbound still present"
[[ "$(jq -r '.port' "$PROFILES_DIR/solo.json")" == "9002" ]] ||
  fail "solo profile port not synced"

# --- Сценарий 2: shared inbound, перенос UUID на новый порт ---
cat > "$CONFIG_FILE" <<'JSON'
{
  "inbounds": [
    {
      "port": 9101,
      "protocol": "vless",
      "tag": "inbound-9101",
      "settings": {
        "clients": [
          {"id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "flow": "xtls-rprx-vision"},
          {"id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "flow": "xtls-rprx-vision"}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {"privateKey": "key", "shortIds": ["ab01"], "serverNames": ["www.ozon.ru"], "dest": "www.ozon.ru:443"}
      }
    }
  ]
}
JSON
jq -n '{
  name: "shared-a",
  uuid: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  transport: "tcp",
  port: 9101,
  sni: "www.ozon.ru",
  fingerprint: "firefox"
}' > "$PROFILES_DIR/shared-a.json"
jq -n '{
  name: "shared-b",
  uuid: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
  transport: "tcp",
  port: 9101,
  sni: "www.ozon.ru",
  fingerprint: "firefox"
}' > "$PROFILES_DIR/shared-b.json"

out=$(port_change_command --name shared-a --port 9102) || fail "shared-a port change failed"
jq -e '.ok == true and .port == 9102' <<< "$out" >/dev/null ||
  fail "shared split bad JSON: $out"
jq -e '
  any(.inbounds[]; .port == 9102 and any(.settings.clients[]?; .id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")) and
  any(.inbounds[]; .port == 9101 and any(.settings.clients[]?; .id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" and .flow == "xtls-rprx-vision")) and
  all(.inbounds[]; (any(.settings.clients[]?; .id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa") | not) or .port == 9102)
' "$CONFIG_FILE" >/dev/null ||
  fail "shared split wrong: foreign client lost or source duplicated"
[[ "$(jq -r '.port' "$PROFILES_DIR/shared-a.json")" == "9102" ]] ||
  fail "shared-a profile port not updated"
[[ "$(jq -r '.port' "$PROFILES_DIR/shared-b.json")" == "9101" ]] ||
  fail "shared-b profile port unexpectedly changed"

# --- Сценарий 3: move в существующий пустой inbound с другой SNI ---
cat > "$CONFIG_FILE" <<'JSON'
{
  "inbounds": [
    {
      "port": 9201,
      "protocol": "vless",
      "tag": "inbound-9201",
      "settings": {"clients": [{"id": "cccccccc-cccc-cccc-cccc-cccccccccccc", "flow": "xtls-rprx-vision"}], "decryption": "none"},
      "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"privateKey": "key", "shortIds": ["ab02"], "serverNames": ["www.ozon.ru"], "dest": "www.ozon.ru:443"}}
    },
    {
      "port": 9202,
      "protocol": "vless",
      "tag": "inbound-9202",
      "settings": {"clients": [], "decryption": "none"},
      "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"privateKey": "key", "shortIds": ["ab03"], "serverNames": ["www.wildberries.ru"], "dest": "www.wildberries.ru:443"}}
    }
  ]
}
JSON
jq -n '{
  name: "mover",
  uuid: "cccccccc-cccc-cccc-cccc-cccccccccccc",
  transport: "tcp",
  port: 9201,
  sni: "www.ozon.ru",
  fingerprint: "firefox"
}' > "$PROFILES_DIR/mover.json"

out=$(port_change_command --name mover --port 9202) || fail "mover port change failed"
jq -e '.ok == true and .port == 9202' <<< "$out" >/dev/null ||
  fail "mover move bad JSON: $out"
jq -e 'any(.inbounds[]; .port == 9202 and any(.settings.clients[]?; .id == "cccccccc-cccc-cccc-cccc-cccccccccccc"))' \
  "$CONFIG_FILE" >/dev/null ||
  fail "mover client not added to target inbound"
jq -e 'all(.inbounds[]; (.settings.clients // []) | length > 0)' "$CONFIG_FILE" >/dev/null ||
  fail "empty inbound was not removed after move"
[[ "$(jq -r '.port' "$PROFILES_DIR/mover.json")" == "9202" ]] ||
  fail "mover profile port not updated"
[[ "$(jq -r '.sni' "$PROFILES_DIR/mover.json")" == "www.wildberries.ru" ]] ||
  fail "mover SNI not switched to target inbound SNI"

# --- Валидации ---
if out=$(port_change_command --name mover --port 70000); then
  fail "invalid port range unexpectedly succeeded"
fi
jq -e '.ok == false' <<< "$out" >/dev/null ||
  fail "invalid port range did not return ok:false"

if out=$(port_change_command --name ghost --port random 2>/dev/null); then
  fail "missing profile unexpectedly succeeded"
fi
jq -e '.ok == false' <<< "$out" >/dev/null ||
  fail "missing profile did not return ok:false"

# Конфликт транспорта: tcp-профиль не может переехать на существующий xhttp inbound.
cat > "$CONFIG_FILE" <<'JSON'
{
  "inbounds": [
    {
      "port": 9301,
      "protocol": "vless",
      "tag": "inbound-9301",
      "settings": {"clients": [{"id": "dddddddd-dddd-dddd-dddd-dddddddddddd", "flow": "xtls-rprx-vision"}], "decryption": "none"},
      "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"privateKey": "key", "shortIds": ["ab04"], "serverNames": ["www.ozon.ru"], "dest": "www.ozon.ru:443"}}
    },
    {
      "port": 9302,
      "protocol": "vless",
      "tag": "inbound-9302",
      "settings": {"clients": [{"id": "11111111-aaaa-bbbb-cccc-999999999999", "flow": ""}], "decryption": "none"},
      "streamSettings": {"network": "xhttp", "security": "reality", "realitySettings": {"privateKey": "key", "shortIds": ["ab05"], "serverNames": ["www.ozon.ru"], "dest": "www.ozon.ru:443"}, "xhttpSettings": {"host": "www.ozon.ru", "path": "/s"}}
    }
  ]
}
JSON
jq -n '{
  name: "tcp-only",
  uuid: "dddddddd-dddd-dddd-dddd-dddddddddddd",
  transport: "tcp",
  port: 9301,
  sni: "www.ozon.ru",
  fingerprint: "firefox"
}' > "$PROFILES_DIR/tcp-only.json"

if out=$(port_change_command --name tcp-only --port 9302); then
  fail "tcp→xhttp transport conflict unexpectedly succeeded"
fi
jq -e '.ok == false' <<< "$out" >/dev/null ||
  fail "transport conflict did not return ok:false"

# Порт 9303 свободен → создаётся новый inbound (shared не задействован).
if ! out=$(port_change_command --name tcp-only --port 9303); then
  fail "free-port tcp move failed: $out"
fi
jq -e '.ok == true and .port == 9303' <<< "$out" >/dev/null ||
  fail "free-port tcp move bad JSON: $out"
jq -e 'any(.inbounds[]; .port == 9303 and any(.settings.clients[]?; .id == "dddddddd-dddd-dddd-dddd-dddddddddddd"))' \
  "$CONFIG_FILE" >/dev/null ||
  fail "free-port tcp move: client not on new inbound"
jq -e 'all(.inbounds[]; (.settings.clients // []) | length > 0)' "$CONFIG_FILE" >/dev/null ||
  fail "free-port tcp move: empty inbound left behind"
[[ "$(jq -r '.port' "$PROFILES_DIR/tcp-only.json")" == "9303" ]] ||
  fail "free-port tcp move: profile port not synced"

# --- Сценарий 4: firewall fail → полный rollback до рестарта Xray ---
cat > "$CONFIG_FILE" <<'JSON'
{
  "inbounds": [
    {
      "port": 9401,
      "protocol": "vless",
      "tag": "inbound-9401",
      "settings": {"clients": [{"id": "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee", "flow": "xtls-rprx-vision"}], "decryption": "none"},
      "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"privateKey": "key", "shortIds": ["ab06"], "serverNames": ["www.ozon.ru"], "dest": "www.ozon.ru:443"}}
    }
  ]
}
JSON
jq -n '{
  name: "firewall-rollback",
  uuid: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
  transport: "tcp",
  port: 9401,
  sni: "www.ozon.ru",
  fingerprint: "firefox"
}' > "$PROFILES_DIR/firewall-rollback.json"

open_firewall_port() { return 1; }
safe_restart_xray() { touch "$WORKDIR/restart-called"; return 0; }

if out=$(port_change_command --name firewall-rollback --port 9402 2>/dev/null); then
  fail "firewall failure unexpectedly succeeded"
fi
jq -e '.ok == false and (.error | contains("файрвол"))' <<< "$out" >/dev/null ||
  fail "firewall failure did not return actionable ok:false: $out"
[[ ! -e "$WORKDIR/restart-called" ]] ||
  fail "Xray restarted before the new firewall port was available"
jq -e 'any(.inbounds[]; .port == 9401) and all(.inbounds[]; .port != 9402)' "$CONFIG_FILE" >/dev/null ||
  fail "config was not rolled back after firewall failure"
[[ "$(jq -r '.port' "$PROFILES_DIR/firewall-rollback.json")" == "9401" ]] ||
  fail "profile was not rolled back after firewall failure"

echo "PASS: port-change CLI renames/moves inbounds and syncs profiles atomically"
