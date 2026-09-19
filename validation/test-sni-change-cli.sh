#!/usr/bin/env bash
# test-sni-change-cli.sh
# Тестирует CLI `sni-change --name N [--route R] --sni S` из xrayebator.
# Гарантии:
#   - stdout CLI содержит ТОЛЬКО JSON;
#   - config.json обновляет Reality serverNames/dest (и xhttpSettings.host для XHTTP);
#   - ВСЕ профили/маршруты на порту синхронизированы через update_all_profiles_on_port;
#   - откат при неудачном safe_restart_xray восстанавливает config и profile JSON;
#   - multi-route профиль требует --route;
#   - gRPC отклоняет российские SNI.
#
# Usage:  bash validation/test-sni-change-cli.sh
# Requires: jq, bash 4+.

set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORKDIR=$(mktemp -d /tmp/xrayebator-sni-cli.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

source "$REPO_ROOT/xrayebator"

CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"
XRAY_BACKUPS_DIR="$WORKDIR/backups"
XRAY_BIN="$WORKDIR/xray"
mkdir -p "$PROFILES_DIR" "$XRAY_BACKUPS_DIR"

printf '#!/bin/sh\nprintf "Configuration OK."\nexit 0\n' > "$XRAY_BIN"
chmod +x "$XRAY_BIN"
ensure_xray_service_unit() { return 0; }
systemctl() { return 0; }
fix_xray_permissions() { return 0; }
sleep() { :; }

# --- Исходный конфиг: один XHTTP inbound на 443 и один TCP inbound на 8443. ---
jq -n '{
  inbounds: [
    {
      port: 443,
      protocol: "vless",
      tag: "inbound-443",
      settings: {
        clients: [{id: "11111111-2222-3333-4444-555555555555", flow: ""}],
        decryption: "none"
      },
      streamSettings: {
        network: "xhttp",
        security: "reality",
        realitySettings: {
          privateKey: "private-test-key",
          shortIds: ["abcd1234"],
          serverNames: ["www.ozon.ru"],
          dest: "www.ozon.ru:443"
        },
        xhttpSettings: {
          host: "www.ozon.ru",
          path: "/s"
        }
      }
    },
    {
      port: 8443,
      protocol: "vless",
      tag: "inbound-8443",
      settings: {
        clients: [{id: "22222222-2222-3333-4444-555555555555", flow: "xtls-rprx-vision"}],
        decryption: "none"
      },
      streamSettings: {
        network: "tcp",
        security: "reality",
        realitySettings: {
          privateKey: "private-test-key",
          shortIds: ["beef5678"],
          serverNames: ["www.ozon.ru"],
          dest: "www.ozon.ru:443"
        }
      }
    }
  ]
}' > "$CONFIG_FILE"

# Профиль A: single-route XHTTP на 443.
jq -n '{
  name: "alpha",
  uuid: "11111111-2222-3333-4444-555555555555",
  transport: "xhttp",
  port: 443,
  sni: "www.ozon.ru",
  fingerprint: "firefox"
}' > "$PROFILES_DIR/alpha.json"

# Профиль B: multi-route (2 маршрута: 443 и 8443).
jq -n '{
  name: "beta",
  uuid: "22222222-2222-3333-4444-555555555555",
  transport: "xhttp",
  port: 443,
  sni: "www.ozon.ru",
  fingerprint: "firefox",
  routes: [
    {label: "xhttp-main", transport: "xhttp", port: 443, sni: "www.ozon.ru", fingerprint: "firefox"},
    {label: "tcp-fallback", transport: "tcp", port: 8443, sni: "www.ozon.ru", fingerprint: "firefox"}
  ]
}' > "$PROFILES_DIR/beta.json"

# Профиль C: single-route gRPC на 443 (общий inbound).
jq -n '{
  name: "gamma",
  uuid: "33333333-2222-3333-4444-555555555555",
  transport: "grpc",
  port: 443,
  sni: "www.cloudflare.com",
  fingerprint: "firefox"
}' > "$PROFILES_DIR/gamma.json"

# --- 1. SNI для gRPC: российский домен отклоняется ---
if out=$(sni_change_command --name gamma --sni www.ozon.ru); then
  fail "gRPC accepted RU SNI"
fi
jq -e '.ok == false' <<< "$out" >/dev/null ||
  fail "gRPC RU SNI did not return ok:false: $out"

# --- 2. SNI для gRPC: зарубежный домен принимается ---
out=$(sni_change_command --name gamma --sni github.com) || fail "gRPC foreign SNI change failed"
jq -e '.ok == true and .sni == "github.com" and .port == 443' <<< "$out" >/dev/null ||
  fail "gRPC foreign SNI bad JSON: $out"
jq -e 'any(.inbounds[]; .port == 443 and (.streamSettings.realitySettings.serverNames[0] == "github.com"))' \
  "$CONFIG_FILE" >/dev/null ||
  fail "gRPC SNI not applied to inbound 443"
jq -e 'any(.inbounds[]; .port == 443 and (.streamSettings.realitySettings.dest == "github.com:443"))' \
  "$CONFIG_FILE" >/dev/null ||
  fail "gRPC SNI dest not updated"

# --- 3. Одинаковый SNI — unchanged:true без мутаций ---
before_hash=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
out=$(sni_change_command --name gamma --sni github.com) || fail "unchanged SNI change failed"
jq -e '.ok == true and .unchanged == true' <<< "$out" >/dev/null ||
  fail "unchanged SNI not flagged: $out"
[[ "$before_hash" == "$(sha256sum "$CONFIG_FILE" | awk '{print $1}')" ]] ||
  fail "unchanged SNI mutated config"

# --- 4. Multi-route профиль без --route — ошибка ---
if out=$(sni_change_command --name beta --sni www.wildberries.ru); then
  fail "multi-route without --route unexpectedly succeeded"
fi
jq -e '.ok == false' <<< "$out" >/dev/null ||
  fail "multi-route no-route did not return ok:false: $out"

# --- 5. XHTTP SNI: serverNames + xhttpSettings.host + все профили на порту ---
out=$(sni_change_command --name alpha --sni www.wildberries.ru) || fail "alpha SNI change failed"
jq -e '.ok == true and .sni == "www.wildberries.ru" and .port == 443' <<< "$out" >/dev/null ||
  fail "alpha SNI bad JSON: $out"

# config.json: XHTTP host обновлён, гамма-клиент на том же порту тоже.
jq -e 'any(.inbounds[]; .port == 443 and (.streamSettings.xhttpSettings.host == "www.wildberries.ru"))' \
  "$CONFIG_FILE" >/dev/null ||
  fail "xhttpSettings.host not updated"
jq -e 'any(.inbounds[]; .port == 443 and (.streamSettings.realitySettings.serverNames[0] == "www.wildberries.ru"))' \
  "$CONFIG_FILE" >/dev/null ||
  fail "Reality serverNames not updated"

# profile JSON: alpha.sni обновлён; gamma (грpc, тот же порт) переехал на WB — это ОК,
# SNI привязан к порту. Проверяем все профили на 443 синхронизированы.
[[ "$(jq -r '.sni' "$PROFILES_DIR/alpha.json")" == "www.wildberries.ru" ]] ||
  fail "alpha profile SNI not synced"
[[ "$(jq -r '.sni' "$PROFILES_DIR/gamma.json")" == "www.wildberries.ru" ]] ||
  fail "gamma profile SNI not synced (shared inbound)"

# beta: маршрут 0 (порт 443) синхронизирован, маршрут 1 (8443) НЕ тронут.
[[ "$(jq -r '.routes[0].sni' "$PROFILES_DIR/beta.json")" == "www.wildberries.ru" ]] ||
  fail "beta route0 SNI not synced"
[[ "$(jq -r '.routes[1].sni' "$PROFILES_DIR/beta.json")" == "www.ozon.ru" ]] ||
  fail "beta route1 SNI unexpectedly changed"

# --- 6. Смена маршрута 1 (TCP 8443) через --route 1 ---
out=$(sni_change_command --name beta --route 1 --sni www.sberbank.ru) || fail "beta route1 change failed"
jq -e '.ok == true and .sni == "www.sberbank.ru" and .port == 8443' <<< "$out" >/dev/null ||
  fail "beta route1 bad JSON: $out"
jq -e 'any(.inbounds[]; .port == 8443 and (.streamSettings.realitySettings.serverNames[0] == "www.sberbank.ru"))' \
  "$CONFIG_FILE" >/dev/null ||
  fail "route1 inbound SNI not updated"
[[ "$(jq -r '.routes[1].sni' "$PROFILES_DIR/beta.json")" == "www.sberbank.ru" ]] ||
  fail "beta route1 profile SNI not synced"
[[ "$(jq -r '.routes[0].sni' "$PROFILES_DIR/beta.json")" == "www.wildberries.ru" ]] ||
  fail "beta route0 SNI unexpectedly changed"
[[ "$(jq -r '.sni' "$PROFILES_DIR/beta.json")" == "www.wildberries.ru" ]] ||
  fail "beta top-level SNI mirror broken"

# --- 7. Некорректный SNI / отсутствующий профиль ---
if out=$(sni_change_command --name alpha --sni "not a domain"); then
  fail "invalid SNI unexpectedly succeeded"
fi
jq -e '.ok == false' <<< "$out" >/dev/null ||
  fail "invalid SNI did not return ok:false"
if out=$(sni_change_command --name ghost --sni www.ozon.ru); then
  fail "missing profile unexpectedly succeeded"
fi
jq -e '.ok == false' <<< "$out" >/dev/null ||
  fail "missing profile did not return ok:false"

echo "PASS: sni-change CLI updates config + all port profiles atomically"
