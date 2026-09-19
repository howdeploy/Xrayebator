#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "✗ $*" >&2
  exit 1
}

echo "Проверка генерации VLESS URLs"

WORKDIR=$(mktemp -d /tmp/xrayebator-urlgen.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/xrayebator"

CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"
PUBLIC_KEY_FILE="$WORKDIR/.public_key"
PRIVATE_KEY_FILE="$WORKDIR/.private_key"
VLESS_ENCRYPTION_FILE="$WORKDIR/.vless_encryption"
# Изоляция: geo-маркер не должен влиять на имена маршрутов в этом тесте.
SERVER_COUNTRY_FILE="$WORKDIR/.server_country"
printf '' > "$SERVER_COUNTRY_FILE"
SERVER_IP="203.0.113.10"

mkdir -p "$PROFILES_DIR"
printf '%s' 'test-public-key' > "$PUBLIC_KEY_FILE"
printf '%s' 'test-private-key' > "$PRIVATE_KEY_FILE"
printf '%s' 'mlkem768x25519plus.native.test-encryption' > "$VLESS_ENCRYPTION_FILE"

cat > "$CONFIG_FILE" <<'JSON'
{
  "inbounds": [
    {
      "port": 12345,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "11111111-2222-3333-4444-555555555555", "flow": ""}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "path": "/xhttp-test",
          "host": "www.ozon.ru"
        },
        "realitySettings": {
          "privateKey": "test-private-key",
          "shortIds": ["abcd1234"],
          "serverNames": ["www.ozon.ru"]
        }
      }
    },
    {
      "port": 12346,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "11111111-2222-3333-4444-555555555555", "flow": ""}],
        "decryption": "mlkem768x25519plus.native.test-decryption"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "path": "/xhttp-pq",
          "host": "www.ozon.ru"
        },
        "realitySettings": {
          "privateKey": "test-private-key",
          "shortIds": ["beef5678"],
          "serverNames": ["www.ozon.ru"]
        }
      }
    },
    {
      "port": 23456,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "11111111-2222-3333-4444-555555555555", "flow": ""}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "security": "reality",
        "grpcSettings": {"serviceName": "svc-test"},
        "realitySettings": {
          "privateKey": "test-private-key",
          "shortIds": ["feed9876"],
          "serverNames": ["www.cloudflare.com"]
        }
      }
    }
  ]
}
JSON

cat > "$PROFILES_DIR/sample.json" <<'JSON'
{
  "name": "sample",
  "uuid": "11111111-2222-3333-4444-555555555555",
  "routes": [
    {
      "label": "xhttp-legacy",
      "transport": "xhttp",
      "port": 12345,
      "sni": "www.ozon.ru",
      "fingerprint": "chrome",
      "xhttp_path": "/xhttp-test"
    },
    {
      "label": "xhttp-pq",
      "transport": "xhttp",
      "port": 12346,
      "sni": "www.ozon.ru",
      "fingerprint": "chrome",
      "pq_enabled": true,
      "xhttp_path": "/xhttp-pq"
    },
    {
      "label": "grpc",
      "transport": "grpc",
      "port": 23456,
      "sni": "www.cloudflare.com",
      "fingerprint": "chrome",
      "grpc_service_name": "svc-test"
    }
  ]
}
JSON

urls=$(_generate_vless_urls_for_profile "$PROFILES_DIR/sample.json") || fail "URL generation failed"

grep -q 'sample-xhttp-legacy' <<< "$urls" || fail "legacy XHTTP route missing"
grep -q 'encryption=none' <<< "$urls" || fail "legacy XHTTP must use encryption=none"
grep -q 'type=xhttp&path=%2Fxhttp-test&host=www.ozon.ru&mode=auto#sample-xhttp-legacy' <<< "$urls" || fail "legacy XHTTP URL must include mode=auto and encoded path"
grep -q 'encryption=mlkem768x25519plus.native.test-encryption' <<< "$urls" || fail "PQ XHTTP encryption missing"
grep -q 'type=xhttp&path=%2Fxhttp-pq&host=www.ozon.ru&mode=auto#sample-xhttp-pq' <<< "$urls" || fail "PQ XHTTP URL must include mode=auto"
grep -q 'type=grpc&serviceName=svc-test&mode=gun#sample-grpc' <<< "$urls" || fail "gRPC URL must include mode=gun"

jq '(.inbounds[] | select(.port == 12346) | .streamSettings.xhttpSettings.path) = "/wrong-path"' \
  "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

if _generate_vless_url_pure "$PROFILES_DIR/sample.json" 1 >/dev/null; then
  fail "route with mismatched XHTTP path must not be emitted"
fi
[[ "$(_profile_live_route_count "$PROFILES_DIR/sample.json")" == "2" ]] \
  || fail "live route count must exclude mismatched XHTTP route"

jq '(.inbounds[] | select(.port == 23456) | .settings.clients) = []' \
  "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

if _generate_vless_url_pure "$PROFILES_DIR/sample.json" 2 >/dev/null; then
  fail "route whose UUID is absent from inbound must not be emitted"
fi
[[ "$(_profile_live_route_count "$PROFILES_DIR/sample.json")" == "1" ]] \
  || fail "live route count must exclude orphaned UUID route"

echo "✓ VLESS URL generation checks passed"
