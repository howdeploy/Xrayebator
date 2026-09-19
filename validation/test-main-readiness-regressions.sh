#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

WORKDIR=$(mktemp -d /tmp/xrayebator-main-ready.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/xrayebator"

echo "Проверка UFW ownership: pre-existing rule не присваивается и не удаляется"
CONFIG_FILE="$WORKDIR/config.json"
UFW_OWNED_MANIFEST="$WORKDIR/.ufw_owned"
UFW_CALLS="$WORKDIR/ufw-calls"
printf '{"inbounds":[]}\n' > "$CONFIG_FILE"
ufw() {
  case "$*" in
    status)
      printf 'Status: active\n443/tcp ALLOW Anywhere\n'
      ;;
    "show added")
      printf 'ufw allow 443/tcp\n'
      ;;
    "allow 8443/tcp")
      printf 'allow 8443/tcp\n' >> "$UFW_CALLS"
      ;;
    "limit 2053/tcp")
      printf 'limit 2053/tcp\n' >> "$UFW_CALLS"
      ;;
    "delete allow 8443/tcp")
      printf 'delete allow 8443/tcp\n' >> "$UFW_CALLS"
      ;;
    "delete limit 2053/tcp")
      printf 'delete limit 2053/tcp\n' >> "$UFW_CALLS"
      ;;
    reload)
      ;;
    *)
      printf 'unexpected:%s\n' "$*" >> "$UFW_CALLS"
      return 1
      ;;
  esac
}

open_firewall_port 443 tcp >/dev/null || fail "pre-existing 443/tcp was rejected"
[[ ! -e "$UFW_OWNED_MANIFEST" ]] || fail "pre-existing 443/tcp was claimed"
_ufw_remove_owned_port 443 tcp || fail "unowned removal should be a no-op"
[[ ! -e "$UFW_CALLS" ]] || fail "pre-existing 443/tcp was mutated"

open_firewall_port 8443 tcp >/dev/null || fail "new 8443/tcp rule was not opened"
grep -qxF '8443/tcp/allow' "$UFW_OWNED_MANIFEST" ||
  fail "new rule was not recorded with its exact action"
_ufw_remove_owned_port 8443 tcp || fail "owned 8443/tcp was not removed"
grep -qxF 'delete allow 8443/tcp' "$UFW_CALLS" ||
  fail "owned rule delete was not issued"
if grep -q '^8443/tcp/' "$UFW_OWNED_MANIFEST"; then
  fail "removed rule remained in ownership manifest"
fi

limit_firewall_port 2053 tcp || fail "new limited rule was not opened"
grep -qxF '2053/tcp/limit' "$UFW_OWNED_MANIFEST" ||
  fail "limited rule action was not recorded"
_ufw_remove_owned_port 2053 tcp || fail "owned limited rule was not removed"
grep -qxF 'delete limit 2053/tcp' "$UFW_CALLS" ||
  fail "limited rule was deleted with the wrong action"
unset -f ufw

echo "Проверка uninstall: только manifest, без ownership inference из config"
if grep -q 'ALL_XRAY_PORTS' uninstall.sh; then
  fail "uninstall still infers UFW ownership from Xray config/profiles"
fi
grep -Fq 'done < "$UFW_SNAPSHOT"' uninstall.sh ||
  fail "uninstall does not consume the UFW ownership snapshot directly"

quickstart_body=$(sed -n '/^quickstart_command()/,/^happ_setup_command()/p' xrayebator)
grep -Fq 'open_firewall_port "$firewall_port" tcp' <<< "$quickstart_body" ||
  fail "quickstart bypasses the ownership-safe firewall helper"
if grep -Eq '^[[:space:]]*ufw (allow|limit)' <<< "$quickstart_body"; then
  fail "quickstart contains a direct UFW add"
fi

echo "Проверка fail-closed backup install config при отказе cp"
install_backup_definition=$(awk '
  /^_install_backup_existing_config\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' install.sh)
[[ -n "$install_backup_definition" ]] || fail "install backup helper not found"
eval "$install_backup_definition"
INSTALL_CONFIG="$WORKDIR/install-config.json"
INSTALL_BACKUPS="$WORKDIR/install-backups"
printf '{"value":"live"}\n' > "$INSTALL_CONFIG"
before_hash=$(sha256sum "$INSTALL_CONFIG" | awk '{print $1}')
cp() { return 1; }
if _install_backup_existing_config "$INSTALL_CONFIG" "$INSTALL_BACKUPS" >/dev/null; then
  fail "install backup succeeded after forced cp failure"
fi
unset -f cp
after_hash=$(sha256sum "$INSTALL_CONFIG" | awk '{print $1}')
[[ "$before_hash" == "$after_hash" ]] || fail "failed backup mutated live config"
if find "$INSTALL_BACKUPS" -type f -print -quit 2>/dev/null | grep -q .; then
  fail "failed config backup left a partial file"
fi
grep -Fq 'config_tmp=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")' install.sh ||
  fail "base config is not written through a same-directory temp file"
grep -Fq 'mv -f -- "$config_tmp" "$CONFIG_FILE"' install.sh ||
  fail "base config is not atomically committed"

echo "Проверка fail-closed nginx backup при отказе cp"
NGINX_SOURCE="$WORKDIR/nginx-existing-vhost"
NGINX_BACKUP="$WORKDIR/nginx-existing-vhost.bak"
printf 'original-vhost\n' > "$NGINX_SOURCE"
cp() { return 1; }
if _qs_backup_path "$NGINX_SOURCE" "$NGINX_BACKUP"; then
  fail "nginx backup succeeded after forced cp failure"
fi
unset -f cp
[[ "$(<"$NGINX_SOURCE")" == "original-vhost" ]] ||
  fail "failed nginx backup mutated source vhost"
[[ ! -e "$NGINX_BACKUP" ]] || fail "failed nginx backup left a partial file"
grep -Fq 'if ! _qs_backup_path "$NGINX_SITES_AVAILABLE/xrayebator-sub" "$QS_VHOST_BACKUP"' \
  xrayebator || fail "quickstart does not fail closed on vhost backup"

echo "Проверка IPv6 SSH listener [::]:port"
sshd_parser_definition=$(awk '
  /^_extract_sshd_port_from_ss\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' install.sh)
[[ -n "$sshd_parser_definition" ]] || fail "SSH listener parser not found"
eval "$sshd_parser_definition"
for fixture in \
  'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=1,fd=3))' \
  'LISTEN 0 128 [::]:2222 [::]:* users:(("sshd",pid=1,fd=3))' \
  'LISTEN 0 128 *:2222 *:* users:(("sshd",pid=1,fd=3))'; do
  parsed=$(printf '%s\n' "$fixture" | _extract_sshd_port_from_ss) ||
    fail "SSH listener was not parsed: $fixture"
  [[ "$parsed" == "2222" ]] || fail "unexpected SSH port '$parsed' for: $fixture"
done

echo "Проверка полного SIL OFL 1.1 artifact"
OFL_FILE="gui-legacy/xrayebator_gui/assets/fonts/OFL.txt"
grep -Fq 'SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007' "$OFL_FILE" ||
  fail "full OFL header missing"
grep -Fq '5) The Font Software, modified or unmodified' "$OFL_FILE" ||
  fail "OFL conditions are incomplete"
grep -Fq 'THE FONT SOFTWARE IS PROVIDED "AS IS"' "$OFL_FILE" ||
  fail "OFL disclaimer missing"

echo "PASS: main readiness regressions"
