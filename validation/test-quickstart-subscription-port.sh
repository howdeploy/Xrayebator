#!/bin/bash
# Regression test для bug B2: quickstart хардкодил порт :8443 в subscription_url,
# игнорируя _subscription_base_url / .subscription_port. После фикса
# quickstart должен использовать canonical helper.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "✗ FAIL: $*" >&2
  exit 1
}

# Извлекаем тело quickstart_command (tr -d '\r' для CRLF-safe)
quickstart_block=$(tr -d '\r' < xrayebator | sed -n '/^quickstart_command() {$/,/^happ_setup_command() {$/p')
[[ -n "$quickstart_block" ]] || fail "quickstart_command block not found"

# Проверяем, что quickstart использует _subscription_base_url
if ! grep -q '_subscription_base_url' <<< "$quickstart_block"; then
  fail "quickstart_command НЕ использует _subscription_base_url — вероятно вернулся hardcode :8443"
fi

# Анти-регрессионная проверка: старый паттерн не должен вернуться в активном коде.
# Хардкод "https://${server_ip}:8443/sub/${result_sub_token}" — построение URL
# напрямую с портом 8443. Долго быть заменено на _subscription_base_url.
# Допустимые упоминания 8443: fallback-строка с комментарием.
bad_lines=$(grep -E 'subscription_url="https://\$\{server_ip\}:8443/sub' <<< "$quickstart_block" || true)
if [[ -n "$bad_lines" ]]; then
  echo "Найден hardcoded 8443 без helper:"
  echo "$bad_lines"
  fail "quickstart содержит прямой хардкод 8443 — должен использовать _subscription_base_url"
fi

# Убеждаемся, что fallback тоже содержит правильный путь (не потерян)
if ! grep -q 'fallback на.*server_ip.*8443\|8443' <<< "$quickstart_block"; then
  echo "Внимание: в quickstart нет упоминания 8443 (возможно fallback изменился — ок)."
fi

echo "✓ quickstart использует _subscription_base_url, нет прямого hardcode :8443"
