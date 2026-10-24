#!/usr/bin/env bash
# Регрессия: временный конфиг для `xray run -test` обязан заканчиваться на .json.
#
# Живой случай 2026-10-24 (Ubuntu 22.04 + Xray 26.10.21, свежий VPS): ядро
# определяет формат конфига по РАСШИРЕНИЮ файла и `-format json` больше не
# спасает. install.sh валидировал mktemp-файл `config.json.tmp.XXXXXX`, ядро
# отвечало «main/confloader/external: unsupported config file extension», и
# установка обрывалась на «Сгенерированный config.json не прошёл валидацию»
# на ЛЮБОМ чистом сервере. Тот же приём в update.sh молча терял обновление DNS.
set -u
cd "$(dirname "$0")/.."

fail() { echo "✗ $1"; exit 1; }
pass() { echo "✓ $1"; }

# --- 1. install.sh создаёт временный конфиг через --suffix=.json ----------------
grep -q 'mktemp --suffix=\.json "${CONFIG_FILE}\.tmp\.XXXXXX"' install.sh \
  || fail "install.sh: temp config must be created with --suffix=.json"
# Фолбэк на старый mktemp допустим, но тогда файл обязан переименовываться в .json.
if grep -q 'config_tmp=$(mktemp "${CONFIG_FILE}\.tmp\.XXXXXX")' install.sh; then
  grep -q 'mv -f -- "$config_tmp" "${config_tmp}\.json"' install.sh \
    || fail "install.sh: bare-mktemp fallback must rename the temp file to *.json"
fi
pass "install.sh: temp config is created with a .json suffix"

# --- 2. update.sh: оба временных конфига тоже с .json --------------------------
count=$(grep -c 'mktemp --suffix=\.json /tmp/xray-cfg\.XXXXXX' update.sh || true)
[[ "$count" -ge 2 ]] \
  || fail "update.sh: expected both temp configs to use --suffix=.json (found $count)"
pass "update.sh: both temp configs use the .json suffix"

# --- 3. Провал валидации обязан печатать вывод ядра ----------------------------
grep -q 'Вывод xray run -test' install.sh \
  || fail "install.sh must print the xray output when config validation fails"
pass "install.sh prints the xray reason on validation failure"

# --- 4. Сам приём работает на этом хосте --------------------------------------
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
probe=$(mktemp --suffix=.json "$TMP_ROOT/config.json.tmp.XXXXXX" 2>/dev/null) \
  || fail "mktemp --suffix=.json is not supported on this host (needed by install.sh)"
case "$probe" in
  *.json) ;;
  *) fail "mktemp --suffix=.json produced '$probe' (no .json suffix)" ;;
esac
[[ -f "$probe" ]] || fail "mktemp did not create the file"
pass "mktemp --suffix=.json yields a *.json path ($(basename "$probe"))"

# --- 5. xray (если есть) действительно требует расширение ---------------------
# Полноценная проверка только там, где установлен Xray: в CI ядра нет.
if command -v xray >/dev/null 2>&1; then
  printf '{"log":{"loglevel":"warning"}}\n' > "$probe"
  printf '{"log":{"loglevel":"warning"}}\n' > "$TMP_ROOT/plain.tmp"
  no_ext=$(xray run -test -format json -config "$TMP_ROOT/plain.tmp" 2>&1 || true)
  if grep -q 'unsupported config file extension' <<< "$no_ext"; then
    if ! grep -q 'Configuration OK' <<< "$(xray run -test -format json -config "$probe" 2>&1 || true)"; then
      fail "xray rejects the .json-suffixed temp config as well"
    fi
    pass "xray really keys the format off the extension (plain.tmp refused, *.json accepted)"
  else
    pass "this xray build accepts extensionless configs — the suffix is still correct"
  fi
else
  pass "xray not installed here — extension requirement covered by the static checks"
fi

echo "✓ temp-config validation keeps the .json suffix required by Xray ≥ 26.10"
