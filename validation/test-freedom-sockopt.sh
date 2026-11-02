#!/usr/bin/env bash
# Тест «freedom.domainStrategy → streamSettings.sockopt.domainStrategy».
#
# Причина: с 26.10.31 Xray при каждом старте печатает
#   The "freedom.domainStrategy" setting is deprecated and will be removed.
#   For compatibility, its value has been automatically migrated to
#   "sockopt.domainStrategy".
# Ядро обновляется командой `xrayebator update` без участия оператора, поэтому
# ждать удаления поля нельзя: когда его уберут, домены начнут резолвиться не так,
# как задумано (IPv6-only сервер без UseIP просто перестанет работать).
#
# Проверяем: перенос значения, удаление legacy-ключа, сохранение уже заданного
# sockopt-значения, идемпотентность (второй запуск — no-op без перезапуска Xray),
# новую форму в шаблоне install.sh и отказ возвращать старую форму в остальном коде.
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
[[ "$XRAYEBATOR_SOURCED" == "1" ]] || fail "source-mode guard not detected"

# CONFIG_FILE задаётся в скрипте жёстко, поэтому переопределяем ПОСЛЕ source:
# до него любое значение перетёрлось бы, и миграция пошла бы в живой конфиг.
CONFIG_FILE="$TMP_ROOT/config.json"

write_config() {
  cat > "$CONFIG_FILE" <<'EOF'
{
  "outbounds": [
    {"protocol": "freedom", "settings": {"domainStrategy": "UseIP"}, "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
EOF
}

# --- 1. Перенос значения ---------------------------------------------------------
write_config
_migrate_freedom_sockopt_2026 || fail "первый запуск должен переносить значение (rc=0)"
[[ "$(jq -r '.outbounds[0].streamSettings.sockopt.domainStrategy' "$CONFIG_FILE")" == "UseIP" ]] \
  || fail "значение должно оказаться в streamSettings.sockopt"
if jq -e '.outbounds[0].settings.domainStrategy' "$CONFIG_FILE" >/dev/null 2>&1; then
  fail "legacy-ключ settings.domainStrategy должен быть удалён"
fi
[[ "$(jq -r '.outbounds[1].tag' "$CONFIG_FILE")" == "block" ]] \
  || fail "другие outbound-ы не должны пострадать"
pass "domainStrategy переносится в sockopt, legacy-ключ удаляется"

# --- 2. Идемпотентность: второй запуск — no-op -----------------------------------
if _migrate_freedom_sockopt_2026; then
  fail "второй запуск должен возвращать no-op (1), иначе Xray перезапускается зря"
fi
[[ "$(jq -r '.outbounds[0].streamSettings.sockopt.domainStrategy' "$CONFIG_FILE")" == "UseIP" ]] \
  || fail "идемпотентный прогон не должен терять значение"
pass "повторный запуск не меняет конфиг (без лишнего restart)"

# --- 3. Уже заданный sockopt побеждает -------------------------------------------
cat > "$CONFIG_FILE" <<'EOF'
{
  "outbounds": [
    {"protocol": "freedom",
     "settings": {"domainStrategy": "AsIs"},
     "streamSettings": {"sockopt": {"domainStrategy": "UseIPv4"}},
     "tag": "direct"}
  ]
}
EOF
_migrate_freedom_sockopt_2026 >/dev/null || fail "перенос при готовом sockopt должен проходить"
[[ "$(jq -r '.outbounds[0].streamSettings.sockopt.domainStrategy' "$CONFIG_FILE")" == "UseIPv4" ]] \
  || fail "явный sockopt не должен перетираться legacy-значением"
pass "явное значение sockopt сохраняется"

# --- 4. Пустой конфиг не считается изменённым ------------------------------------
echo '{"outbounds": [{"protocol": "freedom", "settings": {}, "tag": "direct"}]}' > "$CONFIG_FILE"
if _migrate_freedom_sockopt_2026; then
  fail "конфиг без domainStrategy не должен требовать перезапуска"
fi
pass "конфиг без legacy-поля остаётся нетронутым"

# --- 5. Шаблон install.sh пишет новую форму --------------------------------------
grep -q '"sockopt": {' install.sh || fail "install.sh должен писать sockopt"
if grep -q '"domainStrategy": "\${FREEDOM_STRATEGY}"' install.sh; then
  # Единственное допустимое место — внутри блоков sockopt; legacy-форма выглядела
  # как гипhen "settings": { "domainStrategy": "${FREEDOM_STRATEGY}" }.
  if grep -B2 '"domainStrategy": "\${FREEDOM_STRATEGY}"' install.sh | grep -q '"settings": {'; then
    fail "install.sh всё ещё пишет legacy settings.domainStrategy"
  fi
fi
pass "install.sh пишет только новую форму"

# --- 6. Код больше не пишет legacy-ключ -------------------------------------------
if grep -n 'settings\.domainStrategy = ' xrayebator | grep -v 'migrate_freedom_sockopt\|\.settings\.domainStrategy? != null\|del(\.settings\.domainStrategy)' ; then
  fail "в xrayebator осталась запись legacy-ключа settings.domainStrategy"
fi
pass "запись legacy-ключа осталась только в миграции"

echo "✅ test-freedom-sockopt: все проверки пройдены"
