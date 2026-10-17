#!/bin/bash
# test-pq-routes.sh
# Проверяет PQ-маршрут на произвольном транспорте (VLESS Encryption):
#   - _pq_add_route_for_profile создаёт ОТДЕЛЬНЫЙ инбаунд, переключает его
#     .settings.decryption на ключ из .vless_decryption и добавляет маршрут
#     <transport>-pq с pq_enabled (VLESS decryption — свойство инбаунда, делить
#     порт с обычными маршрутами нельзя);
#   - ссылка PQ-маршрута несёт encryption=mlkem768…, а не none;
#   - обычный маршрут того же профиля остаётся encryption=none;
#   - profile-pq отдаёт JSON, отказывает при отсутствии ключей и при дубле;
#   - v2ray/base64-тело выкидывает PQ-маршруты любого транспорта (не только xhttp).
#
# Живой выпуск PQ-маршрута на VPS проверяется в спайке: здесь только pure-часть.
# Usage: bash validation/test-pq-routes.sh   (нужны jq, bash 4+)

set -euo pipefail

fail() {
  echo "✗ $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORKDIR=$(mktemp -d /tmp/xrayebator-pq.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/xrayebator"

CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"
PUBLIC_KEY_FILE="$WORKDIR/.public_key"
PRIVATE_KEY_FILE="$WORKDIR/.private_key"
VLESS_ENCRYPTION_FILE="$WORKDIR/.vless_encryption"
VLESS_DECRYPTION_FILE="$WORKDIR/.vless_decryption"
SERVER_COUNTRY_FILE="$WORKDIR/.server_country"
printf '' > "$SERVER_COUNTRY_FILE"
XRAYEBATOR_SERVER_ADDR_OVERRIDE="203.0.113.10"
mkdir -p "$PROFILES_DIR"
printf '%s' 'test-public-key' > "$PUBLIC_KEY_FILE"
printf '%s' 'test-private-key' > "$PRIVATE_KEY_FILE"
printf '%s' 'mlkem768x25519plus.native.test-encryption' > "$VLESS_ENCRYPTION_FILE"
printf '%s' 'mlkem768x25519plus.native.test-decryption' > "$VLESS_DECRYPTION_FILE"

cat > "$CONFIG_FILE" <<'JSON'
{"inbounds": [
  {"port": 10001, "protocol": "vless",
   "settings": {"clients": [{"id": "11111111-2222-3333-4444-555555555555", "flow": "xtls-rprx-vision"}], "decryption": "none"},
   "streamSettings": {"network": "tcp", "security": "reality",
     "realitySettings": {"privateKey": "test-private-key", "shortIds": ["aa11"], "serverNames": ["www.ozon.ru"]}}},
  {"port": 20001, "protocol": "vless",
   "settings": {"clients": [{"id": "11111111-2222-3333-4444-555555555555", "flow": "xtls-rprx-vision"}], "decryption": "none"},
   "streamSettings": {"network": "tcp", "security": "reality",
     "realitySettings": {"privateKey": "test-private-key", "shortIds": ["aa22"], "serverNames": ["www.ozon.ru"]}}}
]}
JSON

cat > "$PROFILES_DIR/sample.json" <<'JSON'
{"name": "sample", "uuid": "11111111-2222-3333-4444-555555555555", "fingerprint": "chrome",
 "routes": [{"label": "tcp-vision", "transport": "tcp", "port": 10001, "sni": "www.ozon.ru", "fingerprint": "chrome"}]}
JSON

# build_transport_defaults создаёт инбаунд на сервере — в тесте подменяем на
# существующий PQ-инбаунд 20001, чтобы проверять остальную логику герметично.
build_transport_defaults() { printf '%s\n' "20001||"; }
reserve_port() { return 0; }
_default_sni_for_transport() { printf '%s\n' "www.ozon.ru"; }

_pq_add_route_for_profile "$PROFILES_DIR/sample.json" "tcp" || fail "PQ-маршрут не создан"

# 1) инбаунд стал PQ (decryption != none), обычный инбаунд не тронут
jq -e '.inbounds[] | select(.port == 20001) | .settings.decryption == "mlkem768x25519plus.native.test-decryption"' \
  "$CONFIG_FILE" >/dev/null || fail "PQ-инбаунд не получил decryption"
jq -e '.inbounds[] | select(.port == 10001) | .settings.decryption == "none"' \
  "$CONFIG_FILE" >/dev/null || fail "обычный инбаунд не должен становиться PQ"

# 2) в профиле появился PQ-маршрут
jq -e '.routes | map(select(.pq_enabled == true and .transport == "tcp")) | length == 1' \
  "$PROFILES_DIR/sample.json" >/dev/null || fail "PQ-маршрут не добавлен в профиль"
jq -e '.routes[-1].port == 20001 and .routes[-1].label == "tcp-pq"' "$PROFILES_DIR/sample.json" >/dev/null \
  || fail "PQ-маршрут указывает не на тот порт/label"

# 3) ссылки: PQ-маршрут с encryption=mlkem…, обычный — encryption=none
urls=$(_generate_vless_urls_for_profile "$PROFILES_DIR/sample.json") || fail "генерация ссылок"
pq_url=$(grep -F 'tcp-pq' <<<"$urls" || true)
[[ -n "$pq_url" ]] || fail "PQ-маршрут не попал в ссылки"
grep -q 'encryption=mlkem768x25519plus' <<<"$pq_url" || fail "PQ-ссылка без ML-KEM encryption"
plain_url=$(grep -F 'tcp-vision' <<<"$urls" || true)
grep -q 'encryption=none' <<<"$plain_url" || fail "обычная ссылка должна остаться encryption=none"

# 4) дубль отклоняется
out=$(profile_pq_command --name sample --transport tcp) || true
jq -e '.ok == false and (.error | test("уже есть"))' <<<"$out" >/dev/null || fail "дубль PQ-маршрута: $out"

# 5) без ключей — понятная ошибка
VLESS_DECRYPTION_FILE="$WORKDIR/missing-decryption"
out=$(profile_pq_command --name sample --transport grpc) || true
jq -e '.ok == false and (.error | test("PQ-ключи"))' <<<"$out" >/dev/null || fail "нет проверки PQ-ключей: $out"

# 6) v2ray/base64-тело выкидывает PQ ЛЮБОГО транспорта (фильтр в heredoc'е handler'а)
handler=$(awk '/cat > \/usr\/local\/bin\/subhttp\.sh << '\''SUBHTTP_EOF'\''/{f=1;next} /^SUBHTTP_EOF$/{f=0} f' xrayebator)
grep -q 'encryption=none' <<<"$handler" || fail "в handler'е нет фильтра PQ"
grep -q '\[?&\]encryption=' <<<"$handler" || fail "фильтр PQ должен быть транспортно-независимым (не только xhttp)"

echo "✓ PQ-маршруты: отдельный инбаунд с decryption, ссылка с ML-KEM, обычный маршрут без изменений, CLI-контракт — OK"
