#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

WORKDIR=$(mktemp -d /tmp/xrayebator-bbr-migration.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/xrayebator"

TEST_ETC="$WORKDIR/etc"
TEST_PROC="$WORKDIR/proc"
XRAY_BACKUPS_DIR="$WORKDIR/backups"
LEGACY_FILE="$TEST_ETC/sysctl.d/99-xrayebator-tcp.conf"
SYSCTL_CONF="$TEST_ETC/sysctl.conf"
ACTIVE_FILE="$TEST_PROC/tcp_congestion_control"
AVAILABLE_FILE="$TEST_PROC/tcp_available_congestion_control"
MARKER="$WORKDIR/state/.host_tcp_tuning_removed_v3"
SCAN_PATHS="$SYSCTL_CONF:$TEST_ETC/sysctl.d"
EXPECTED_UID=$(id -u)
SYSCTL_CALLS=0

mkdir -p "$TEST_ETC/sysctl.d" "$TEST_PROC" "$XRAY_BACKUPS_DIR"

sysctl() {
  [[ "$*" == "-q -w net.ipv4.tcp_congestion_control=cubic" ]] \
    || fail "unexpected sysctl call: $*"
  SYSCTL_CALLS=$((SYSCTL_CALLS + 1))
  printf 'cubic\n' > "$ACTIVE_FILE"
}

cat > "$LEGACY_FILE" <<'EOF'
# Xrayebator minimal TCP tuning
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

cat > "$SYSCTL_CONF" <<'EOF'
vm.swappiness=10

# BBR TCP Congestion Control Optimization
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_max_tw_buckets=2000000
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_syncookies=1
net.core.netdev_max_backlog=16384
net.ipv4.tcp_max_syn_backlog=8192

fs.file-max=100000
EOF

printf 'bbr\n' > "$ACTIVE_FILE"
printf 'reno cubic bbr\n' > "$AVAILABLE_FILE"

echo "Checking owned legacy cleanup and live fallback"
migrate_remove_legacy_tcp_tuning_v3 \
  "$MARKER" "$LEGACY_FILE" "$SYSCTL_CONF" "$ACTIVE_FILE" "$AVAILABLE_FILE" \
  "$SCAN_PATHS" "$EXPECTED_UID" >/dev/null \
  || fail "owned legacy migration failed"

[[ ! -e "$LEGACY_FILE" ]] || fail "legacy sysctl.d file was not removed"
[[ -f "$MARKER" ]] || fail "migration marker was not created"
[[ "$(<"$ACTIVE_FILE")" == "cubic" ]] || fail "active congestion control was not changed"
[[ "$SYSCTL_CALLS" -eq 1 ]] || fail "migration did not make exactly one live sysctl change"
grep -q '^vm.swappiness=10$' "$SYSCTL_CONF" || fail "unrelated sysctl prefix was lost"
grep -q '^fs.file-max=100000$' "$SYSCTL_CONF" || fail "unrelated sysctl suffix was lost"
! grep -q 'BBR TCP Congestion Control Optimization' "$SYSCTL_CONF" \
  || fail "legacy marker remained in sysctl.conf"
! grep -q '^net.ipv4.tcp_congestion_control=bbr$' "$SYSCTL_CONF" \
  || fail "legacy BBR assignment remained in sysctl.conf"

echo "Checking idempotent marker"
migrate_remove_legacy_tcp_tuning_v3 \
  "$MARKER" "$LEGACY_FILE" "$SYSCTL_CONF" "$ACTIVE_FILE" "$AVAILABLE_FILE" \
  "$SCAN_PATHS" "$EXPECTED_UID" >/dev/null \
  || fail "marked migration was not idempotent"
[[ "$SYSCTL_CALLS" -eq 1 ]] || fail "marked migration changed live state twice"

echo "Checking modified project file is preserved"
rm -f "$MARKER"
cat > "$LEGACY_FILE" <<'EOF'
# operator-owned replacement
net.ipv4.tcp_congestion_control=bbr
EOF
printf 'bbr\n' > "$ACTIVE_FILE"
if migrate_remove_legacy_tcp_tuning_v3 \
  "$MARKER" "$LEGACY_FILE" "$SYSCTL_CONF" "$ACTIVE_FILE" "$AVAILABLE_FILE" \
  "$SCAN_PATHS" "$EXPECTED_UID" >/dev/null 2>&1; then
  fail "migration accepted a modified legacy file"
fi
[[ -f "$LEGACY_FILE" ]] || fail "modified legacy file was deleted"
[[ ! -e "$MARKER" ]] || fail "failed migration created a marker"
[[ "$(<"$ACTIVE_FILE")" == "cubic" ]] || fail "modified file case did not disable live BBR"

echo "Checking foreign persistent BBR is reported but not deleted"
rm -f "$LEGACY_FILE"
cat > "$TEST_ETC/sysctl.d/operator.conf" <<'EOF'
net.ipv4.tcp_congestion_control=bbr
EOF
printf 'bbr\n' > "$ACTIVE_FILE"
if migrate_remove_legacy_tcp_tuning_v3 \
  "$MARKER" "$LEGACY_FILE" "$SYSCTL_CONF" "$ACTIVE_FILE" "$AVAILABLE_FILE" \
  "$SCAN_PATHS" "$EXPECTED_UID" >/dev/null 2>&1; then
  fail "migration marked foreign persistent BBR as resolved"
fi
[[ "$(<"$ACTIVE_FILE")" == "cubic" ]] || fail "foreign config case did not disable live BBR"
[[ -f "$TEST_ETC/sysctl.d/operator.conf" ]] || fail "foreign sysctl config was deleted"
[[ ! -e "$MARKER" ]] || fail "foreign config case created a marker"

echo "Checking live-switch failure keeps owned persistent settings removed"
rm -f "$TEST_ETC/sysctl.d/operator.conf"
cat > "$LEGACY_FILE" <<'EOF'
# Xrayebator minimal TCP tuning
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
printf 'bbr\n' > "$ACTIVE_FILE"
sysctl() {
  return 1
}
if migrate_remove_legacy_tcp_tuning_v3 \
  "$MARKER" "$LEGACY_FILE" "$SYSCTL_CONF" "$ACTIVE_FILE" "$AVAILABLE_FILE" \
  "$SCAN_PATHS" "$EXPECTED_UID" >/dev/null 2>&1; then
  fail "migration ignored a failed live congestion-control switch"
fi
[[ ! -e "$LEGACY_FILE" ]] || fail "failed live switch restored persistent BBR"
compgen -G "$XRAY_BACKUPS_DIR/host-tuning-v3.*/99-xrayebator-tcp.conf" >/dev/null \
  || fail "failed live switch did not preserve a backup"
[[ ! -e "$MARKER" ]] || fail "failed live switch created a marker"

# Запрет — на host-wide TCP-тюнинг. Собственные drop-in'ы бэкендов
# (/etc/sysctl.d/99-xrayebator-*.conf: UDP-буферы Hysteria/AWG, их снимает
# uninstall) к нему не относятся и отфильтровываются отдельно.
if grep -Ei \
  'XRAY_TCP_TUNING|tcp_congestion_control|default_qdisc|/etc/sysctl|(^|[;&|[:space:]])sysctl([[:space:]]|$)' \
  "$REPO_ROOT/install.sh" "$REPO_ROOT/update.sh" "$REPO_ROOT/uninstall.sh" \
  | grep -Fv '/etc/sysctl.d/99-xrayebator-' >/dev/null; then
  fail "install/update/uninstall contain host TCP tuning outside the one-time runtime migration"
fi
if grep -Eq \
  'target_cc="bbr"|sysctl.*tcp_congestion_control[[:space:]]*=[[:space:]]*bbr' \
  "$REPO_ROOT/xrayebator"; then
  fail "runtime contains a path that enables BBR"
fi

echo "PASS: legacy BBR removal is scoped, live, and idempotent"
