#!/bin/bash
# Regression test: quickstart --without-email и read-only inspect.
#  1) quickstart_command принимает --without-email и НЕ требует email в этом режиме;
#  2) без email Certbot получает --register-unsafely-without-email и НЕ получает -m;
#  3) с email поведение не меняется (-m "$email" остаётся);
#  4) фиктивный email не подставляется.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "✗ FAIL: $*" >&2
  exit 1
}

# Полностью читаем источник в переменную: awk/sed с ранним exit в管道 роняют tr
# на SIGPIPE (pipefail в CI), а here-string безотказен.
source_text=$(tr -d '\r' < xrayebator)

quickstart_block=$(sed -n '/^quickstart_command() {$/,/^happ_setup_command() {$/p' <<< "$source_text")
[[ -n "$quickstart_block" ]] || fail "quickstart_command block not found"

grep -Fq -- '--without-email' <<< "$quickstart_block" \
  || fail "quickstart_command не принимает --without-email"
grep -Fq -- '--register-unsafely-without-email' <<< "$quickstart_block" \
  || fail "quickstart без email должен использовать --register-unsafely-without-email"
grep -Fq -- '-m "$email"' <<< "$quickstart_block" \
  || fail "quickstart с email должен по-прежнему передавать -m \"$email\""
grep -Fq -- '"${certbot_email_args[@]}"' <<< "$quickstart_block" \
  || fail "certbot email аргументы должны собираться в массив и передаваться единой точкой"
if grep -Eq 'email="(noreply|no-reply|admin)@' <<< "$quickstart_block"; then
  fail "найден фиктивный email-fallback"
fi

# Валидация email обязана применяться только в provided-режиме.
if grep -Eq '^\s*if \[\[ -z "\$email" \]\]' <<< "$quickstart_block"; then
  fail "жёсткая проверка '-z \"\$email\"' вне email_mode — сломает --without-email"
fi

echo "✓ quickstart поддерживает --without-email без фиктивного адреса"

# ── inspect: read-only диагностика для GUI-импорта ──
inspect_block=$(awk '/^inspect_command\(\) \{$/{f=1} f&&/^quickstart_command\(\) \{$/{exit} f' <<< "$source_text")
[[ -n "$inspect_block" ]] || fail "inspect_command block not found"

# Диспетч должен открывать subcommand.
grep -Eq '^[[:space:]]*inspect\)' <<< "$source_text" \
  || fail "dispatch не регистрирует inspect"

# JSON печатается через jq -n (одним блоком), диагностику — в stderr.
grep -Fq 'jq -n' <<< "$inspect_block" \
  || fail "inspect_command должен печатать JSON через jq -n"
if grep -Eq 'echo "\{[\"a-z]' <<< "$inspect_block"; then
  fail "inspect_command печатает JSON вручную вместо jq -n"
fi

# Read-only инвариант: никаких mutation-хелперов/пакетных/сетевых изменений.
if grep -Eq 'apt-get|safe_jq_write|systemctl (restart|enable|stop|start)|open_firewall_port|close_firewall_port|install_subscription_server|backup_config|quickstart_command|happ_setup|run_migration|touch |rm -|mv |> "/usr|>> "/usr' <<< "$inspect_block"; then
  echo "Найден mutation-вызов в inspect_command:"
  grep -En 'apt-get|safe_jq_write|systemctl (restart|enable|stop|start)|open_firewall_port|install_subscription_server|backup_config|quickstart_command|happ_setup|run_migration|touch |rm -|mv ' <<< "$inspect_block" || true
  fail "inspect_command обязан быть read-only"
fi

echo "✓ inspect зарегистрирован, печатает JSON и остаётся read-only"
