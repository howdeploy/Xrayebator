#!/usr/bin/env bash
# Local CLI contract: opt-in legacy XHTTP, unchanged PQ default and backend grants.
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR=$(mktemp -d /tmp/xrayebator-create-without-pq.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT
source "$REPO_ROOT/xrayebator"

CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"
PUBLIC_KEY_FILE="$WORKDIR/public-key"
PRIVATE_KEY_FILE="$WORKDIR/private-key"
VLESS_ENCRYPTION_FILE="$WORKDIR/pq-encryption"
VLESS_DECRYPTION_FILE="$WORKDIR/pq-decryption"
SERVER_COUNTRY_FILE="$WORKDIR/country"
XRAYEBATOR_SERVER_ADDR_OVERRIDE="203.0.113.10"
PRIVATE_KEY="test-private-key"
printf '%s' "$PRIVATE_KEY" > "$PRIVATE_KEY_FILE"
printf '%s' 'test-public-key' > "$PUBLIC_KEY_FILE"
mkdir -p "$PROFILES_DIR"
printf '%s\n' '{"inbounds":[]}' > "$CONFIG_FILE"
: > "$WORKDIR/events"

# Keep real profile/inbound creation, metadata validation, URI and backend dispatch.
# Only host-dependent operations are replaced; no network, firewall or service calls.
_default_sni_for_transport() { echo "example.com"; }
_reality_dest_for_sni() { echo "$1:443"; }
backup_config() { cp "$CONFIG_FILE" "$WORKDIR/backup.json"; printf -v "$2" '%s' "$WORKDIR/backup.json"; }
safe_restart_xray() { echo restart >> "$WORKDIR/events"; }
fix_xray_permissions() { return 0; }
open_firewall_port() { echo "open:$1" >> "$WORKDIR/events"; }
close_firewall_port() { echo "close:$1" >> "$WORKDIR/events"; }
_profile_cli_subscription_url() { return 1; }
_backend_installed() { return 0; }
_hysteria2_on_profile_event() { echo "hy2:$1:$2" >> "$WORKDIR/events"; }
_awg_on_profile_event() { echo "awg:$1:$2" >> "$WORKDIR/events"; }

out=$(profile_create_command --name legacy --transport xhttp --port 34001 --without-pq)
jq -e '.ok and .names == ["legacy"] and .errors == []' <<< "$out" >/dev/null || fail "legacy creation: $out"
jq -e '.pq_enabled == false and .schema_version == 2 and .xhttp_path == "/xhttp"' \
  "$PROFILES_DIR/legacy.json" >/dev/null || fail "legacy metadata"
jq -e '.inbounds[0].settings.decryption == "none" and .inbounds[0].streamSettings.network == "xhttp"' \
  "$CONFIG_FILE" >/dev/null || fail "legacy inbound"
uri=$(_generate_vless_url_pure "$PROFILES_DIR/legacy.json") || fail "legacy URI export without PQ keys"
[[ "$uri" == vless://*'encryption=none&'*'type=xhttp&'* ]] || fail "legacy URI: $uri"

# A compatible shared legacy inbound works for every member of a batch.
out=$(profile_create_command --name shared --port 34001 --count 2 --without-pq)
jq -e '.names == ["shared", "shared-2"] and .errors == []' <<< "$out" >/dev/null || fail "legacy batch: $out"
jq -e '.inbounds | length == 1 and (.[0].settings.clients | length == 3)' \
  "$CONFIG_FILE" >/dev/null || fail "legacy shared inbound"

# Normal XHTTP still requires PQ keys; the failed profile leaves config untouched.
before=$(cat "$CONFIG_FILE")
out=$(profile_create_command --name missing-keys --transport xhttp --port 34002)
jq -e '.names == [] and (.errors | length == 1)' <<< "$out" >/dev/null || fail "default PQ must require keys"
[[ ! -e "$PROFILES_DIR/missing-keys.json" && "$(cat "$CONFIG_FILE")" == "$before" ]] || fail "missing keys changed state"
printf '%s' 'mlkem768x25519plus.native.test-encryption' > "$VLESS_ENCRYPTION_FILE"
printf '%s' 'mlkem768x25519plus.native.test-decryption' > "$VLESS_DECRYPTION_FILE"
out=$(profile_create_command --name pq --port 34002)
jq -e '.names == ["pq"] and .errors == []' <<< "$out" >/dev/null || fail "PQ default: $out"
jq -e '.pq_enabled == true' "$PROFILES_DIR/pq.json" >/dev/null || fail "PQ default metadata"
jq -e '.inbounds[] | select(.port == 34002) | .settings.decryption == "mlkem768x25519plus.native.test-decryption"' \
  "$CONFIG_FILE" >/dev/null || fail "PQ default inbound"
uri=$(_generate_vless_url_pure "$PROFILES_DIR/pq.json") || fail "PQ URI export"
[[ "$uri" == *'encryption=mlkem768x25519plus.native.test-encryption&'* ]] || fail "PQ URI encryption"

# Reject a PQ/legacy port collision without changing the existing inbound.
before=$(cat "$CONFIG_FILE")
out=$(profile_create_command --name collision --port 34002 --without-pq)
jq -e '.names == [] and (.errors | length == 1)' <<< "$out" >/dev/null || fail "PQ/legacy collision accepted"
[[ ! -e "$PROFILES_DIR/collision.json" && "$(cat "$CONFIG_FILE")" == "$before" ]] || fail "collision changed state"

for transport in tcp tcp-utls tcp-xudp tcp-mux grpc; do
  events_before=$(cat "$WORKDIR/events")
  if out=$(profile_create_command --name invalid --transport "$transport" --port 34003 --without-pq); then
    fail "--without-pq accepted for $transport"
  fi
  jq -e '.ok == false and (.error | contains("--without-pq"))' <<< "$out" >/dev/null || fail "invalid-transport JSON"
  [[ ! -e "$PROFILES_DIR/invalid.json" && "$(cat "$CONFIG_FILE")" == "$before" && "$(cat "$WORKDIR/events")" == "$events_before" ]] \
    || fail "invalid transport had side effects"
done
out=$(profile_create_command --name tcp --transport tcp --port 34003)
jq -e '.names == ["tcp"] and .errors == []' <<< "$out" >/dev/null || fail "normal TCP creation"
uri=$(_generate_vless_url_pure "$PROFILES_DIR/tcp.json") || fail "normal TCP URI"
[[ "$uri" == *'encryption=none&flow=xtls-rprx-vision&'*'type=tcp&'* ]] || fail "normal TCP changed"
[[ "$(grep -c '^hy2:.*:created$' "$WORKDIR/events")" == 5 && "$(grep -c '^awg:.*:created$' "$WORKDIR/events")" == 5 ]] \
  || fail "successful creations must preserve optional backend grants"

echo "PASS: profile-create legacy XHTTP opt-in, PQ default, compatibility guards and backend grants"
