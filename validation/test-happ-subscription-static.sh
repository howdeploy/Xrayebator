#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "✗ $*" >&2
  exit 1
}

echo "Проверка HAPP subscription/install/update invariants"

bash -n xrayebator update.sh install.sh uninstall.sh || fail "bash -n failed"
echo "  ✓ shell syntax ok"

SUBHTTP_TMP=$(mktemp /tmp/xrayebator-subhttp-static.XXXXXX)
trap 'rm -f "$SUBHTTP_TMP"' EXIT
awk '/cat > \/usr\/local\/bin\/subhttp\.sh << '\''SUBHTTP_EOF'\''/{flag=1; next} /^SUBHTTP_EOF$/{flag=0} flag' \
  xrayebator > "$SUBHTTP_TMP"
[[ -s "$SUBHTTP_TMP" ]] || fail "subhttp heredoc not found"
bash -n "$SUBHTTP_TMP" || fail "generated subhttp heredoc is not valid bash"
echo "  ✓ generated subhttp syntax ok"

grep -q '^emit_500()' "$SUBHTTP_TMP" || fail "subhttp must emit HTTP 500 instead of closing connection"
! grep -q '^set -u$' "$SUBHTTP_TMP" || fail "subhttp must not use set -u; it can turn config/env issues into nginx 502"
grep -q 'source /usr/local/bin/xrayebator' "$SUBHTTP_TMP" || fail "subhttp must source installed xrayebator"
grep -q 'mktemp /tmp/xrayebator-subhttp-body.XXXXXX' "$SUBHTTP_TMP" || fail "subhttp response buffer must use mktemp"
! grep -q 'subhttp_body\\.\\$\\$' "$SUBHTTP_TMP" || fail "subhttp must not use a predictable PID-only temp path"
echo "  ✓ subhttp failure mode guards ok"

grep -q 'HAPP_ROUTING_ENABLED="${HAPP_ROUTING_ENABLED:-true}"' "$SUBHTTP_TMP" \
  || fail "managed HAPP routing must be enabled by default"
grep -q 'serve_geo_asset()' "$SUBHTTP_TMP" \
  || fail "subhttp must serve authenticated HAPP geo assets"
grep -Fq 'elif [[ "$path" =~ ^/sub/([a-f0-9]{32})/(geoip|geosite)\.dat$ ]]' "$SUBHTTP_TMP" \
  || fail "strict token-protected geo asset route is missing"
grep -Fq '[[ -n "$asset" ]] && serve_geo_asset "$asset"' "$SUBHTTP_TMP" \
  || fail "authenticated geo asset route does not reach the file handler"
# PR #22: подстановка плейсхолдеров до валидации, валидация — runtime
# `_happ_validate_routing_json` (после подстановки), а не _file-вариант.
grep -q '_happ_validate_routing_json' "$SUBHTTP_TMP" \
  || fail "custom HAPP routing JSON must be schema-validated"
grep -q '{{GEOIP_URL}}' "$SUBHTTP_TMP" \
  || fail "custom HAPP routing placeholders are not substituted per request"
grep -q '_happ_default_routing_json' "$SUBHTTP_TMP" \
  || fail "managed HAPP routing profile is not generated"
grep -Fq "routing_b64=\$(printf '%s' \"\$routing_json\" | base64 -w0)" "$SUBHTTP_TMP" \
  || fail "routing deeplink must use documented padded Base64"
! grep -Fq "tr '+/' '-_'" "$SUBHTTP_TMP" \
  || fail "routing deeplink must not silently rewrite documented Base64 as base64url"
grep -Fq "printf '\\n%s\\n' \"\$routing_uri\"" "$SUBHTTP_TMP" \
  || fail "routing deeplink must start on a new subscription-body line"
grep -Fq 'ReadOnlyPaths=/usr/local/etc/xray /usr/local/share/xray' xrayebator \
  || fail "subscription unit must explicitly expose geo assets read-only"
grep -q 'subhttp_managed_happ_routing_2026' xrayebator \
  || fail "existing installations need a managed-routing migration"
grep -q 'chmod 644 .*geoip.dat.*geosite.dat' install.sh \
  || fail "installer must make geo assets readable by the xray service user"
grep -q 'chmod 644 .*geoip.dat.*geosite.dat' update.sh \
  || fail "updater must repair geo asset permissions"
echo "  ✓ managed routing delivery guards ok"

# Pure schema/generator regression checks. Sourcing is safe by contract and does
# not enter the interactive menu.
# shellcheck disable=SC1091
source "$REPO_ROOT/xrayebator"
ROUTING_TOKEN=0123456789abcdef0123456789abcdef
ROUTING_JSON=$(_happ_default_routing_json \
  "https://vpn.example:8443" "$ROUTING_TOKEN" "1770000000") \
  || fail "managed routing profile generation failed"
printf '%s' "$ROUTING_JSON" | _happ_validate_routing_json \
  || fail "generated managed routing profile fails its own schema"
printf '%s' "$ROUTING_JSON" | jq -e --arg token "$ROUTING_TOKEN" '
  .Name == "xrayebator-default" and
  .GlobalProxy == "true" and
  .FakeDNS == "false" and
  .RemoteDNSType == "DoH" and
  .DomesticDNSType == "DoH" and
  .RemoteDNSDomain == "https://cloudflare-dns.com/dns-query" and
  .DomesticDNSDomain == "https://cloudflare-dns.com/dns-query" and
  .Geoipurl == ("https://vpn.example:8443/sub/" + $token + "/geoip.dat") and
  .Geositeurl == ("https://vpn.example:8443/sub/" + $token + "/geosite.dat") and
  .LastUpdated == "1770000000" and
  .DirectSites == [] and
  .ProxySites == [] and
  .ProxyIp == [] and
  .BlockSites == [] and
  .BlockIp == [] and
  (.DirectIp | index("10.0.0.0/8") != null) and
  (.DirectIp | all(. != "geoip:ru"))
' >/dev/null || fail "managed routing profile has unsafe routing or DNS values"

if printf '%s' '{"name":"xrayebator-default","rules":[]}' | _happ_validate_routing_json; then
  fail "legacy lowercase/rules-only routing payload must be rejected"
fi
if printf '%s' "$ROUTING_JSON" | jq '.Geoipurl = "http://blocked.example/geoip.dat"' | _happ_validate_routing_json; then
  fail "insecure custom geo URL must be rejected"
fi
if _happ_default_routing_json "http://127.0.0.1:8080" "$ROUTING_TOKEN" "1770000000" >/dev/null; then
  fail "local-only HTTP URL must not be embedded into a client routing profile"
fi
echo "  ✓ managed HAPP routing schema ok"

grep -q '^ensure_xray_runtime_user()' xrayebator || fail "xrayebator missing runtime user repair"
grep -q '^ensure_xray_runtime_user()' update.sh || fail "update.sh missing runtime user repair"
grep -q 'getent passwd xray' install.sh || fail "install.sh must verify xray user creation"
echo "  ✓ xray runtime user repair ok"

grep -q '^_subscription_restart_service()' xrayebator || fail "missing centralized subscription restart helper"
! grep -q 'enable --now xrayebator-sub.service' xrayebator || fail "xrayebator must restart/reset subscription service, not just enable --now"
grep -q '_subscription_restart_service' update.sh || fail "update.sh must use subscription restart helper after regenerating handler"
echo "  ✓ systemd restart path ok"

grep -q 'openssl' install.sh || fail "install.sh dependencies must include openssl"
grep -q 'socat' install.sh || fail "install.sh dependencies must include socat"
grep -q 'bash -n "$XRAYEBATOR_TMP"' install.sh || fail "install.sh must validate downloaded xrayebator"
grep -q 'chmod 755 "$XRAYEBATOR_TMP"' install.sh || fail "install.sh must install xrayebator as world-readable 755"
grep -q 'chmod 755 "$XRAY_TMP"' update.sh || fail "update.sh must install xrayebator as world-readable 755"
grep -q 'chmod 755 /usr/local/bin/xrayebator' update.sh || fail "update.sh must repair existing xrayebator permissions"
grep -q 'chmod 755 /usr/local/bin/xrayebator' xrayebator || fail "install_subscription_server must repair xrayebator permissions for xray user"
echo "  ✓ install dependencies/download validation ok"

grep -q 'type=xhttp&path=.*&host=.*&mode=auto' xrayebator || fail "raw XHTTP VLESS URLs must include mode=auto"
grep -q 'type=grpc&serviceName=.*&mode=gun' xrayebator || fail "raw gRPC VLESS URLs must include mode=gun"
grep -q 'tcp_vision=()' "$SUBHTTP_TMP" || fail "HAPP subscription must bucket routes for stable ordering"
grep -q 'xhttp_legacy=()' "$SUBHTTP_TMP" || fail "HAPP subscription must keep XHTTP legacy as fallback route"
grep -q 'xhttp_xmux_throughput_2026' xrayebator || fail "missing XHTTP throughput migration for existing inbounds"
grep -q '"maxConcurrency": "16-32"' xrayebator || fail "new XHTTP inbounds must use throughput-friendly XMUX concurrency"
! grep -q '"maxConcurrency": "1-1"' xrayebator || fail "XHTTP XMUX maxConcurrency=1-1 must not be the shipped default"
echo "  ✓ transport URL compatibility ok"

echo "✓ HAPP subscription static checks passed"
