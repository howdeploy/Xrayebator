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
# add_inbound собирает inbound из heredoc и подставляет ключи из переменных
# (в бою их выставляет install.sh/миграция), в тесте задаём их явно.
PRIVATE_KEY='test-private-key'
PUBLIC_KEY='test-public-key'
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

# Одно-маршрутная форма (сценарий 7) живёт на порту 20001, и её uuid обязан быть
# клиентом этого инбаунда: _generate_vless_url_pure не выдаёт ссылку на маршрут,
# клиента которого нет в config.json (проверка рассинхрона профиля и конфига).
safe_jq_write --argjson port 20001 --arg uuid "99999999-8888-7777-6666-555555555555" \
  '(.inbounds[] | select(.port == $port) | .settings.clients) += [{"id": $uuid, "flow": "xtls-rprx-vision"}]' \
  "$CONFIG_FILE" || fail "не удалось подготовить инбаунд 20001 под одно-маршрутную форму"

# build_transport_defaults только ПОДБИРАЕТ свободный порт — инбаунд создаёт сам
# _pq_add_route_for_profile через add_inbound. Поэтому подменяем его на СВОБОДНЫЙ
# порт: тест обязан пройти реальный путь создания инбаунда, иначе он снова закроет
# регрессию, на которой маршрут добавлялся, а порт не слушал (живой Ubuntu 22.04).
build_transport_defaults() { printf '%s\n' "${NEXT_PORT:-30001}||"; }
reserve_port() { return 0; }
_default_sni_for_transport() { printf '%s\n' "www.ozon.ru"; }
# В CI нет root/systemd: фиксируем вызовы, но систему не трогаем.
BACKUP_CALLED=""
RESTART_CALLED=""
FIREWALL_OPENED=""
backup_config() { BACKUP_CALLED="$1"; printf -v "$2" '%s' "$WORKDIR/backup-$1.json"; return 0; }
safe_restart_xray() { RESTART_CALLED="$1"; return 0; }
open_firewall_port() { FIREWALL_OPENED="$1"; return 0; }
close_firewall_port() { return 0; }

_pq_add_route_for_profile "$PROFILES_DIR/sample.json" "tcp" || fail "PQ-маршрут не создан"
# 0) Инбаунд под PQ-порт действительно создан. Регрессия живого теста: раньше маршрут
#    добавлялся на порт, которого нет в config.json — порт не слушал, UFW не
#    открывался, а profile-pq отдавал ok:true с пустым link.
jq -e '.inbounds | map(select(.port == 30001)) | length == 1' "$CONFIG_FILE" >/dev/null \
  || fail "PQ-инбаунд не создан в config.json"
jq -e '.inbounds[] | select(.port == 30001) | .protocol == "vless" and .streamSettings.security == "reality"' \
  "$CONFIG_FILE" >/dev/null || fail "PQ-инбаунд не vless/reality"
jq -e 'any(.inbounds[] | select(.port == 30001) | .settings.clients[]?; .id == "11111111-2222-3333-4444-555555555555")' \
  "$CONFIG_FILE" >/dev/null || fail "в PQ-инбаунд не добавлен клиент профиля"
[[ "$FIREWALL_OPENED" == "30001" ]] || fail "порт PQ не открыт в firewall"
[[ "$RESTART_CALLED" == "$WORKDIR/backup-pq_route_tcp.json" ]] \
  || fail "Xray не перезапущен с бэкапом операции (получено: '$RESTART_CALLED')"

# 1) инбаунд стал PQ (decryption != none), обычный инбаунд не тронут
jq -e '.inbounds[] | select(.port == 30001) | .settings.decryption == "mlkem768x25519plus.native.test-decryption"' \
  "$CONFIG_FILE" >/dev/null || fail "PQ-инбаунд не получил decryption"
jq -e '.inbounds[] | select(.port == 10001) | .settings.decryption == "none"' \
  "$CONFIG_FILE" >/dev/null || fail "обычный инбаунд не должен становиться PQ"

# 2) в профиле появился PQ-маршрут
jq -e '.routes | map(select(.pq_enabled == true and .transport == "tcp")) | length == 1' \
  "$PROFILES_DIR/sample.json" >/dev/null || fail "PQ-маршрут не добавлен в профиль"
jq -e '.routes[-1].port == 30001 and .routes[-1].label == "tcp-pq"' "$PROFILES_DIR/sample.json" >/dev/null \
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
# Возвращаем ключи: сценарии ниже снова идут через рабочий путь создания PQ.
VLESS_DECRYPTION_FILE="$WORKDIR/.vless_decryption"

# 6) v2ray/base64-тело выкидывает PQ ЛЮБОГО транспорта (фильтр в heredoc'е handler'а)
handler=$(awk '/cat > \/usr\/local\/bin\/subhttp\.sh << '\''SUBHTTP_EOF'\''/{f=1;next} /^SUBHTTP_EOF$/{f=0} f' xrayebator)
grep -q 'encryption=none' <<<"$handler" || fail "в handler'е нет фильтра PQ"
grep -q '\[?&\]encryption=' <<<"$handler" || fail "фильтр PQ должен быть транспортно-независимым (не только xhttp)"

# 7) Одно-маршрутный профиль (так его пишет profile-create: транспорт/порт/SNI только
#    в top-level, .routes нет) не должен терять базовый маршрут при добавлении PQ.
#    Живой дефект 2026-10-20: profile-pq дописывал .routes из одного PQ-маршрута, и
#    базовый инбаунд выпадал из подписки, из channel-test (1 маршрут вместо 2) и из
#    profile-delete — порт оставался в config.json с живым клиентом удалённого профиля.
cat > "$PROFILES_DIR/single.json" <<'JSON'
{"name": "single", "uuid": "99999999-8888-7777-6666-555555555555", "fingerprint": "chrome",
 "transport": "tcp", "port": 20001, "sni": "www.ozon.ru"}
JSON
jq -e '(.routes // []) | length == 0' "$PROFILES_DIR/single.json" >/dev/null \
  || fail "фикстура single должна быть одно-маршрутной"
# Свободный порт под PQ-инбаунд этого сценария: 30001 уже занят PQ-инбаундом выше.
NEXT_PORT=30003
_pq_add_route_for_profile "$PROFILES_DIR/single.json" "tcp" || fail "PQ для одно-маршрутного профиля"
jq -e '(.routes | length) == 2' "$PROFILES_DIR/single.json" >/dev/null \
  || fail "одно-маршрутная форма не развёрнута в .routes (базовый маршрут потерян)"
jq -e '.routes[0].port == 20001 and .routes[0].transport == "tcp"
       and (.routes[0].pq_enabled // false) == false' "$PROFILES_DIR/single.json" >/dev/null \
  || fail "базовый маршрут развёрнут неверно (порт/транспорт/pq)"
jq -e '.routes[1].pq_enabled == true and .routes[1].port == 30003' "$PROFILES_DIR/single.json" >/dev/null \
  || fail "PQ-маршрут одно-маршрутного профиля не добавлен"
single_urls=$(_generate_vless_urls_for_profile "$PROFILES_DIR/single.json") || fail "ссылки single"
single_count=$(grep -c 'vless://' <<<"$single_urls" || true)
[[ "$single_count" -eq 2 ]] \
  || fail "одно-маршрутный профиль после PQ должен отдавать 2 ссылки (получено: $single_count)"

# 8) Порт'ы профиля — union форм: иначе delete/expire не видят базовый инбаунд.
ports=$(_profile_ports_json "$PROFILES_DIR/single.json")
jq -e 'sort == [20001, 30003]' <<<"$ports" >/dev/null \
  || fail "union портов профиля неверен: $ports"

# 9) Дубль PQ на транспорте, который уже PQ в одно-маршрутной форме (xhttp от
#    profile-create несёт pq_enabled в top-level и decryption в инбаунде) — отказ.
cat > "$PROFILES_DIR/single-xhttp.json" <<'JSON'
{"name": "single-xhttp", "uuid": "77777777-6666-5555-4444-333333333333", "fingerprint": "chrome",
 "transport": "xhttp", "port": 10001, "sni": "www.ozon.ru", "xhttp_path": "/xhttp-aa",
 "pq_enabled": true, "schema_version": 2}
JSON
out=$(profile_pq_command --name single-xhttp --transport xhttp) || true
jq -e '.ok == false and (.error | test("уже есть"))' <<<"$out" >/dev/null \
  || fail "одно-маршрутный PQ xhttp должен отклоняться как дубль: $out"

echo "✓ PQ-маршруты: отдельный инбаунд с decryption, ссылка с ML-KEM, обычный маршрут без изменений, CLI-контракт — OK"
