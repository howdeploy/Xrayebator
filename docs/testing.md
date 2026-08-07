# Testing

[← Back to README](../README.md) · [Русский](ru/testing.md) · [简体中文](zh-CN/testing.md)

---

## Local checkout validation

```bash
bash -n xrayebator install.sh update.sh uninstall.sh
for test_file in validation/*.sh; do bash "$test_file" || exit; done
shellcheck -S error xrayebator install.sh update.sh uninstall.sh
```

All three must pass before a commit.

## What the tests cover

`validation/` holds static and local regression tests:

| Test | What it checks |
|---|---|
| `test-transaction-safety.sh` | Transactional safety of config operations |
| `test-project-update-rollback.sh` | Rollback of a failed project update |
| `test-xhttp-route-path-repair.sh` | Repair of XHTTP route paths during migration |
| `test-multiroute-argument-preservation.sh` | Preservation of multiroute transport arguments |
| `test-happ-subscription-static.sh` | The HAPP subscription handler |
| `test-subscription-server-name.sh` | The subscription server name shown in the client |
| `test-fingerprint-subscription-sync.sh` | Route and subscription sync on fingerprint change |
| `test-dead-stealth-route-pruning.sh` | Pruning of dead stealth routes |
| `test-cascade-routing.sh` | Cascade routing |
| `test-cascade-upstream-import.sh` | Cascade upstream import from a link |
| `test-update-xray-core-sync.sh` | Xray-core update synchronisation |
| `test-vless-url-generation.sh` | `vless://` link generation |
| `test-installer-network-fallbacks.sh` | Installer network fallbacks |
| `test-bbr-removal-migration.sh` | Safe removal of the removed BBR/TCP tuning on every path |
| `test-legacy-udp443-migration.sh` | One-time removal of the legacy UDP/443 block rule |
| `test-main-menu-numbering.sh` | Interactive menu items number consecutively and match handlers |

> Static tests do not replace a disposable VPS run: profile creation and deletion, config validation,
> service restarts, rollback and a real client connection.

## Manual checks on a live server

```bash
sudo xrayebator probe-test                                        # SNI reachability from the VPS
sudo /usr/local/bin/xray test -config /usr/local/etc/xray/config.json
sudo systemctl status xray --no-pager -l
sudo systemctl status xrayebator-sub --no-pager -l
curl -sS -i http://127.0.0.1:8080/sub/                            # expected: 404
jq -r '.routes[] | [.label,.transport,.port,(.pq_enabled // false)] | @tsv' \
  /usr/local/etc/xray/profiles/<profile>.json
```

If UFW is already active, compare the numbered rules before and after the operation: an install must
not re-enable the firewall or change its default policy.
