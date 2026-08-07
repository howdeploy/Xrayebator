#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "Проверка rollback project update"
bash -n update.sh || fail "update.sh syntax failed"

grep -Fq 'UPDATE_CONFIG_BACKUP="$BACKUP_DIR/config.json"' update.sh ||
  fail "update.sh does not retain its exact session config backup"
grep -Fq '_restore_update_config_backup()' update.sh ||
  fail "update.sh lacks a centralized exact rollback helper"
grep -Fq 'chmod 700 "$BACKUP_DIR"' update.sh ||
  fail "session backup directory is not private"
grep -Fq 'chmod 640 /usr/local/etc/xray/config.json' update.sh ||
  fail "restored live config must be group-readable (640, group=xray)"
grep -Fq 'chown root:xray /usr/local/etc/xray/config.json' update.sh ||
  fail "restored live config must be group-owned by xray so the service can read it"

if grep -Eq 'LATEST_BACKUP=|backups/config\\.json\\.\\*' update.sh; then
  fail "update.sh still searches an unrelated latest-backup glob"
fi

restore_calls=$(grep -Fc '_restore_update_config_backup' update.sh)
[[ "$restore_calls" -ge 4 ]] ||
  fail "exact rollback is not wired into all validation/restart failure branches"

grep -Fq 'if ! _adguard_force_uninstall_if_present; then' update.sh ||
  fail "AdGuard cleanup failure is ignored"
grep -A18 '✗ Ошибка перезапуска Xray' update.sh | grep -Fq 'exit 1' ||
  fail "failed Xray restart can still report a successful project update"

echo "PASS: project update restores its own session backup"
