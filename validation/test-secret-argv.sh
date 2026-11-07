#!/usr/bin/env bash
# Тест «секреты не ходят через argv».
#
# Почему это отдельный тест: /proc/<pid>/cmdline читается ЛЮБЫМ пользователем хоста
# (0444), а /proc/<pid>/environ — только владельцем процесса и root (0400). Значит
# любой секрет, попавший в аргументы (URL с токеном бота, sub_token подписки,
# --token в командной строке xrayebator, значения --arg у jq), доступен соседнему
# непривилегированному процессу — например пользователю `xray`, под которым
# работает сам Xray.
#
# Что проверяем:
#  - статически: в скрипте нет curl-вызова с токеном в argv; есть помощник
#    `_curl_secret_url` и им пользуются все четыре «секретных» URL;
#  - функционально: подставной curl видит URL в stdin-конфиге и НЕ видит токена
#    в своих аргументах;
#  - `--secret-file`/`--secret-stdin`: разбор пейлоада, приоритет явного флага,
#    отказ файлу с правами шире 0600, удаление файла после чтения;
#  - `--token`/`--aws-secret-access-key` продолжают работать, но печатают
#    предупреждение в stderr (stdout остаётся чистым JSON);
#  - jq-секреты идут окружением ($ENV.XRAYEBATOR_JQ_SECRET), а не --arg.
#
# Тест не трогает систему: всё на временном каталоге и подставных бинарниках.
set -u
cd "$(dirname "$0")/.."

fail() { echo "✗ $1"; exit 1; }
pass() { echo "✓ $1"; }

command -v jq >/dev/null 2>&1 || fail "jq required (CI installs it)"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export LOCK_FILE="$TMP_ROOT/xrayebator.lock"
# shellcheck disable=SC1091
source ./xrayebator || fail "source ./xrayebator failed"

# ── 1. Статика: помощник есть и используется ─────────────────────────────────
grep -q '^_curl_secret_url() {' xrayebator || fail "нет помощника _curl_secret_url"
grep -q '^_secret_payload_apply() {' xrayebator || fail "нет _secret_payload_apply"
grep -q '^_secret_source_apply() {' xrayebator || fail "нет _secret_source_apply"

# Токен бота и sub_token не должны встречаться в аргументах curl. Правило: каждая
# строка со секретом обязана либо идти через помощник (тогда URL уходит в stdin),
# либо быть комментарием; если в строке есть настоящий вызов curl — это утечка.
bad=""
while IFS= read -r line; do
  body="${line#*:}"
  [[ "$body" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" == *"_curl_secret_url"* ]] && continue
  if printf '%s' "$body" | grep -qE '(^|[^_[:alnum:]])curl([[:space:]]|$)'; then
    bad+="  $line"$'\n'
  fi
done < <(grep -nE 'bot\$token|/sub/\$\{?token' xrayebator)
[[ -z "$bad" ]] || fail "curl с секретом в argv:
$bad"
# Все четыре секретных URL идут через помощник.
[[ "$(grep -c '_curl_secret_url' xrayebator)" -ge 5 ]] \
  || fail "мало вызовов _curl_secret_url (ожидаются определение + 4 места)"
pass "статика curl: секретных URL в argv нет"

# Значения-секреты не передаются jq через --arg.
for pat in '--arg p "\$password"' '--arg t "\$token"' '--arg t "\$new_token"' \
           '--arg cp "\$cpriv"' '--arg ps "\$psk"' '--arg priv "\$priv"' \
           '--arg d "\$decryption"'; do
  if grep -nE -- "$pat" xrayebator >/dev/null; then
    fail "секрет через jq --arg: $pat"
  fi
done
grep -q 'XRAYEBATOR_JQ_SECRET' xrayebator || fail "jq-секреты не передаются окружением"
pass "статика jq: секреты идут окружением"

# Флаги объявлены у всех команд, которым нужен секрет.
for cmd in dns01_setup_command dns01_test_command repair_dns01_command \
           alerts_setup_command quickstart_command; do
  body=$(sed -n "/^${cmd}() {/,/^}/p" xrayebator)
  [[ -n "$body" ]] || fail "не найдена $cmd"
  case "$body" in
    *--secret-file*|*--dns01-secret-file*) ;;
    *) fail "$cmd не разбирает --secret-file" ;;
  esac
  case "$body" in
    *--secret-stdin*|*--dns01-secret-stdin*) ;;
    *) fail "$cmd не разбирает --secret-stdin" ;;
  esac
done
pass "флаги --secret-file/--secret-stdin объявлены у всех команд"

# ── 2. Функционально: подставной curl не видит секрета в argv ────────────────
CURL_LOG="$TMP_ROOT/curl-argv.log"
CURL_URL_LOG="$TMP_ROOT/curl-url.log"
: > "$CURL_LOG"
curl() {
  printf '%s\n' "$*" >> "$CURL_LOG"
  local a cfg="" out="" fmt=""
  local -a argv=("$@")
  local i url=""
  for ((i = 0; i < ${#argv[@]}; i++)); do
    case "${argv[i]}" in
      -K) cfg="${argv[i + 1]:-}" ;;
      -o) out="${argv[i + 1]:-}" ;;
      -w) fmt="${argv[i + 1]:-}" ;;
    esac
  done
  if [[ "$cfg" == "-" ]]; then
    cat > "$TMP_ROOT/curl-stdin.txt"
    url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$TMP_ROOT/curl-stdin.txt" | head -n1)
    printf '%s\n' "$url" >> "$CURL_URL_LOG"
  fi
  local body='{"ok":true,"result":{"username":"stub_bot","message_id":1}}'
  case "$url" in
    */getMe) body='{"ok":true,"result":{"username":"stub_bot"}}' ;;
    */sub/*) body='vless://11111111-2222-3333-4444-555555555555@203.0.113.10:443#p' ;;
  esac
  [[ -n "$out" ]] && printf '%s\n' "$body" > "$out" || printf '%s\n' "$body"
  [[ -n "$fmt" ]] && printf '%s' '200'
  return 0
}

TOKEN="999999999:AAFakeBotTokenForArgvProof_123456"
TELEGRAM_API_BASE="http://telegram.stub"
_telegram_get_me "$TOKEN" >/dev/null 2>&1 || true
_telegram_send_raw "$TOKEN" "123456" "hello" >/dev/null 2>&1 || true
SUBHTTP_LOCAL_BASE="http://127.0.0.1:8080"
_monitor_sub_probe "0123456789abcdef0123456789abcdef" >/dev/null 2>&1 || true

[[ -s "$CURL_LOG" ]] || fail "подставной curl не вызывался"
if grep -qF "$TOKEN" "$CURL_LOG"; then
  fail "токен бота попал в argv curl: $(grep -F "$TOKEN" "$CURL_LOG" | head -n1)"
fi
if grep -q '0123456789abcdef0123456789abcdef' "$CURL_LOG"; then
  fail "sub_token попал в argv curl"
fi
grep -q 'bot.*getMe' "$CURL_URL_LOG" || fail "getMe не получил URL через stdin-конфиг"
grep -q '/sub/0123456789abcdef0123456789abcdef' "$CURL_URL_LOG" \
  || fail "проба подписки не получила URL через stdin-конфиг"
pass "curl: URL с секретом приходит stdin-конфигом, argv чист"

unset -f curl

# ── 3. --secret-file / --secret-stdin ───────────────────────────────────────
token="" aws_key="" aws_secret=""
_secret_payload_apply "bareTokenValue12345" token aws_key aws_secret \
  || fail "одиночная строка не распознана как токен"
[[ "$token" == "bareTokenValue12345" ]] || fail "токен не разложен"

token="" aws_key="" aws_secret=""
_secret_payload_apply $'aws_access_key_id=AKIAEXAMPLE\naws_secret_access_key=s3cr3t/+=x' \
  token aws_key aws_secret || fail "AWS-пейлоад не разобран"
[[ "$aws_key" == "AKIAEXAMPLE" && "$aws_secret" == "s3cr3t/+=x" ]] || fail "AWS-ключи не разложены"

token="from-argv"
_secret_payload_apply "token=from-file" token "" "" || fail "rc при известном ключе"
[[ "$token" == "from-argv" ]] || fail "явный флаг обязан быть сильнее файла"

token=""
_secret_payload_apply "unknown=value" token "" "" && fail "неизвестный ключ должен давать rc 1"
pass "разбор пейлоада: токен, AWS, приоритет флага, мусор"

secret_file="$TMP_ROOT/secret.txt"
printf 'token=FILE_TOKEN_VALUE_123456\n' > "$secret_file"
if [[ "${OSTYPE:-}" != msys* && "${OSTYPE:-}" != cygwin* ]]; then
  chmod 644 "$secret_file"
  token=""
  out=$(_secret_source_apply "$secret_file" token "" "") && fail "файл 0644 должен отвергаться"
  [[ "$out" == *"chmod 600"* ]] || fail "сообщение про 0644: $out"
  [[ -e "$secret_file" ]] || fail "отвергнутый файл не должен удаляться"
fi
chmod 600 "$secret_file"
token=""
_secret_source_apply "$secret_file" token "" "" || fail "файл 0600 не прочитан"
[[ "$token" == "FILE_TOKEN_VALUE_123456" ]] || fail "значение из файла: $token"
[[ ! -e "$secret_file" ]] || fail "файл секрета не удалён после чтения"

token=""
_secret_source_apply - token "" "" <<< 'token=STDIN_TOKEN_VALUE' || fail "stdin не прочитан"
[[ "$token" == "STDIN_TOKEN_VALUE" ]] || fail "значение из stdin: $token"

token="keep"
_secret_source_apply "" token "" "" || fail "пустой источник обязан быть no-op"
[[ "$token" == "keep" ]] || fail "пустой источник тронул переменную"

token=""
out=$(_secret_source_apply "$TMP_ROOT/nonexistent" token "" "") && fail "нет файла — должен быть rc 1"
[[ "$out" == *"не найден"* ]] || fail "сообщение о ненайденном файле: $out"
pass "источник секрета: 0600, отказ 0644, stdin, отсутствующий файл"

# ── 4. CLI: секрет из stdin работает, --token предупреждает ──────────────────
out=$(printf 'token=short\n' | dns01_setup_command --domain sub.example.com \
  --provider cloudflare --secret-stdin --without-email 2>/dev/null)
jq -e '.ok == false and (.error | test("--token"))' <<< "$out" >/dev/null \
  || fail "dns01-setup --secret-stdin не довёл токен до валидации: $out"

out=$(printf 'token=1:short\n' | alerts_setup_command --secret-stdin --chat-id 123456 2>/dev/null)
jq -e '.ok == false and (.error | test("формат токена"))' <<< "$out" >/dev/null \
  || fail "alerts-setup --secret-stdin: $out"

err=$(dns01_setup_command --domain sub.example.com --provider cloudflare \
  --token short --without-email 2>&1 >/dev/null)
[[ "$err" == *"cmdline"* ]] || fail "--token обязан предупреждать о видимости в /proc: $err"
out=$(dns01_setup_command --domain sub.example.com --provider cloudflare \
  --token short --without-email 2>/dev/null)
jq -e '.ok == false' <<< "$out" >/dev/null || fail "stdout с --token не JSON: $out"
pass "CLI: секрет из stdin доходит, --token предупреждает в stderr"

# ── 5. jq-секрет через окружение ────────────────────────────────────────────
val=$(XRAYEBATOR_JQ_SECRET="env-secret-value" jq -n -r '$ENV.XRAYEBATOR_JQ_SECRET')
[[ "$val" == "env-secret-value" ]] || fail "jq \$ENV не читается: $val"
json=$(XRAYEBATOR_JQ_SECRET="env-secret-value" jq -cn '{v: $ENV.XRAYEBATOR_JQ_SECRET}')
jq -e '.v == "env-secret-value"' <<< "$json" >/dev/null || fail "jq -n с \$ENV: $json"
pass "jq: значение читается из окружения"

echo "✓ Секреты в argv: помощник curl, --secret-file/--secret-stdin, jq через \$ENV — OK"
