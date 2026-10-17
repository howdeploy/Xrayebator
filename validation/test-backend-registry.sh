#!/usr/bin/env bash
# Тест backend-реестра мультипротокольного этапа 1 (2026-10-04).
# Функциональный: source xrayebator в source-режиме (SOURCE-SAFETY GUARD
# пропускает root-check/key-load/dispatch) с BACKENDS_ROOT во временном каталоге.
# Проверяет: ensure/idempotency, set/field, installed, lifecycle no-op,
# status JSON форму, сохранение ранее записанных полей.
set -u
cd "$(dirname "$0")/.."

fail() { echo "✗ $1"; exit 1; }
pass() { echo "✓ $1"; }

command -v jq >/dev/null 2>&1 || fail "jq required (CI installs it)"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export BACKENDS_ROOT="$TMP_ROOT/xrayebator-backends"
# safe_jq_write -> _lock_acquire открывает LOCK_FILE; в тестовой среде
# /usr/local/etc/xray не существует — уводим lock во временный каталог.
export LOCK_FILE="$TMP_ROOT/xrayebator.lock"

# shellcheck disable=SC1091
source ./xrayebator || fail "source ./xrayebator failed"

[[ "$XRAYEBATOR_SOURCED" == "1" ]] || fail "source-mode guard not detected"
[[ "$BACKENDS_ROOT" == "$TMP_ROOT/xrayebator-backends" ]] || fail "BACKENDS_ROOT override lost"

# 1) ensure: создаёт корень, каталог и пустой реестр
_backend_ensure_registry || fail "_backend_ensure_registry failed"
[[ -d "$BACKENDS_ROOT" ]] || fail "BACKENDS_ROOT dir not created"
[[ -d "$BACKENDS_DIR" ]] || fail "BACKENDS_DIR not created"
[[ -s "$BACKENDS_REGISTRY_FILE" ]] || fail "registry file missing/empty"
[[ "$(jq -r 'type' "$BACKENDS_REGISTRY_FILE")" == "object" ]] || fail "registry is not a JSON object"

# 2) по умолчанию бэкенды не установлены
_backend_installed hysteria2 && fail "hysteria2 reported installed on empty registry"
_backend_installed awg && fail "awg reported installed on empty registry"
pass "empty registry: no backends installed"

# 3) set создаёт объект бэкенда и пишет поле (jq-опции до фильтра)
_backend_set hysteria2 '(.hysteria2.port) = $port' --argjson port 443 \
  || fail "_backend_set hysteria2 port failed"
[[ "$(_backend_field hysteria2 port)" == "443" ]] || fail "field readback port != 443"

# 4) второй set НЕ затирает предыдущие поля и включает installed
_backend_set hysteria2 '(.hysteria2.installed) = true' \
  || fail "_backend_set hysteria2 installed failed"
_backend_installed hysteria2 || fail "_backend_installed hysteria2 after set"
[[ "$(_backend_field hysteria2 port)" == "443" ]] || fail "port lost after second set"
pass "set accumulates fields, installed flips on"

# 5) set для отсутствующего типа создаёт объект с нуля
_backend_set awg '(.awg.port) = $port' --argjson port 51820 \
  || fail "_backend_set awg failed"
[[ "$(_backend_field awg port)" == "51820" ]] || fail "awg field readback"
_backend_installed awg && fail "awg installed must stay false (only port set)"
pass "set auto-creates backend object"

# 6) lifecycle-хук: no-op безопасен для любых событий (обработчиков ещё нет)
_backend_apply_profile_lifecycle "some-profile" created || fail "lifecycle created failed"
_backend_apply_profile_lifecycle "some-profile" expired  || fail "lifecycle expired failed"
_backend_apply_profile_lifecycle "some-profile" bogus    || fail "lifecycle bogus event failed"
pass "lifecycle hook is a safe no-op without handlers"

# 6b) boolean false читается из реестра как "false", а не глотается как null
_backend_set hysteria2 '(.hysteria2.sub_body) = false' || fail "set sub_body=false"
[[ "$(_backend_field hysteria2 sub_body)" == "false" ]] \
  || fail "boolean false must read back as 'false' (jq // empty swallows it)"
pass "boolean false fields read back correctly"

# 7) status JSON: ok=true, форма backends.{type}.{installed,port,state}
status="$(_backend_status_json)" || fail "_backend_status_json failed"
jq -e '
  .ok == true and
  .backends.hysteria2.installed == true and
  .backends.hysteria2.port == 443 and
  .backends.hysteria2.state == "unknown" and
  .backends.awg.installed == false and
  .backends.awg.port == 51820 and
  .backends.awg.state == "unknown"
' <<<"$status" >/dev/null || fail "status JSON shape mismatch: $status"
pass "status JSON shape correct"

# 8) idempotent ensure повторно (после мутаций)
_backend_ensure_registry || fail "second ensure failed"
[[ "$(_backend_field hysteria2 port)" == "443" ]] || fail "registry mutated by second ensure"
pass "ensure is idempotent"

# 9) порт-проверка UDP не падает в среде без ss (возвращает 0/1, не креш)
_backend_port_busy_udp 44399 >/dev/null 2>&1
rc=$?
[[ "$rc" == "0" || "$rc" == "1" ]] || fail "_backend_port_busy_udp rc=$rc (expected 0/1)"
pass "udp busy check safe without listener"

echo ""
pass "backend registry: all checks green"
