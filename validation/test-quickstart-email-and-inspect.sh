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

quickstart_block=$(tr -d '\r' < xrayebator | sed -n '/^quickstart_command() {$/,/^happ_setup_command() {$/p')
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
