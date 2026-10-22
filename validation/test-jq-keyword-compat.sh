#!/bin/bash
# test-jq-keyword-compat.sh
# Стережёт класс jq-конструкций, которые молча ломаются на jq 1.6 — а это
# поддерживаемые системы Ubuntu 22.04 и Debian 12 (там jq 1.6), тогда как CI и
# WSL-валидация живут на jq 1.7 и ошибку не видят.
#
# Что именно запрещено:
#   1) пара объекта, где ключ — ключевое слово jq, а значение — переменная с тем же
#      именем: `label: $label`. В jq 1.6 `label` — ключевое слово, парсер уходит в
#      label-выражение и падает: «syntax error, unexpected label, expecting IDENT».
#   2) shorthand `{$label}` — то же самое.
#
# Живой пример (2026-10, VPS Ubuntu 22.04): из-за `label: $label` в
# _pq_add_route_for_profile команда `profile-pq`, флаг `quickstart --pq` и кнопка «PQ»
# в GUI возвращали ok:true с пустым link, а маршрут не создавался. Ошибка была
# заглушена `2>/dev/null`, поэтому выглядела как «нет ключей ML-KEM».
#
# Usage: bash validation/test-jq-keyword-compat.sh
set -euo pipefail

fail() {
  echo "✗ $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

[[ -f xrayebator ]] || fail "не найден xrayebator"

# Ключевые слова jq 1.6 (грамматика), которые встречаются как ключи объектов.
JQ_KEYWORDS="label as def if then else elif end reduce foreach try catch and or not import include module namespace __loc__"

hits=""
for kw in $JQ_KEYWORDS; do
  # Комментарии (строка начинается с #) не код: в них эталонная конструкция описана
  # словами, и детектор обязан их игнорировать.
  if out=$(grep -nE "(^|[^A-Za-z0-9_])${kw}:[[:space:]]*\\\$${kw}([^A-Za-z0-9_]|$)" xrayebator \
      | grep -vE '^[0-9]+:[[:space:]]*#'); then
    hits+="${out}"$'\n'
  fi
  # 2) {$<kw>}
  if out=$(grep -nF "{\$${kw}}" xrayebator | grep -vE '^[0-9]+:[[:space:]]*#'); then
    hits+="${out}"$'\n'
  fi
done

if [[ -n "$hits" ]]; then
  echo "✗ jq 1.6 не распарсит эти конструкции (переименуйте переменную, ключ оставьте):" >&2
  printf '%s' "$hits" >&2
  fail "jq-конструкции, несовместимые с jq 1.6"
fi

# Контрольная проверка самого детектора: он обязан находить эталонную конструкцию.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "jq -n --arg label x '{label: \$label}'" > "$tmp"
if ! grep -qE "(^|[^A-Za-z0-9_])label:[[:space:]]*\\\$label([^A-Za-z0-9_]|$)" "$tmp"; then
  fail "детектор не находит эталонную конструкцию 'label: \$label' — проверьте сам тест"
fi

echo "✓ jq 1.6-совместимость: нет пар '<keyword>: \$<keyword>' и shorthand '{\$<keyword>}' — OK"
