# Architecture

[← Back to README](../README.md) · [Русский](ru/architecture.md) · [简体中文](zh-CN/architecture.md)

Sections: [Repository](#repository) · [On-server state](#on-server-state) ·
[Inbound versus profile](#inbound-versus-profile) · [How the subscription works](#how-the-subscription-works)

---

## Repository

```text
Xrayebator/
├── xrayebator            # main application: menu, profiles, inbounds, routing, migrations
├── install.sh            # installs the core, service, permissions, geo databases, lifecycle commands
├── update.sh             # updates Xrayebator itself from the selected branch
├── uninstall.sh          # removes the service and configuration
├── validation/           # static and local regression tests
├── docs/                 # documentation: en, ru, zh-CN
├── sni_list.txt          # SNI candidates
├── ascii_art.txt         # terminal interface header
├── CLAUDE.md             # working rules and project policies
└── LICENSE
```

The management logic lives in the single `xrayebator` file. `install.sh`, `update.sh` and
`uninstall.sh` cover the lifecycle. The generated `subhttp.sh`, the nginx config and the systemd unit
form the HAPP subscription path.

## On-server state

```text
/usr/local/bin/
├── xray                          # the core
├── xrayebator                    # the manager
├── subhttp.sh                       # subscription backend
├── xrayebator-update
└── xrayebator-uninstall

/usr/local/etc/xray/
├── config.json                   # inbounds, outbounds, routing, DNS
├── profiles/<name>.json          # profile metadata: routes, sub_token, SNI, fingerprint
├── upstreams/cascade.json        # cascade upstream parameters
├── backups/config_<timestamp>_<op>.json          # config backups taken before every change
├── .private_key / .public_key    # Reality keys, generated once at install time
├── .vless_decryption             # PQ keys for xhttp-pq
├── .vless_encryption
├── .subscription_mode            # subscription publishing mode
├── .subscription_domain          # subscription domain; a DNS record alone does not change it
├── .subscription_port            # 443 or 8443
├── .happ_defaults.env            # HAPP settings, including the server name shown in the client
├── .current_branch               # branch Xrayebator updates from
└── .xhttp_migrated, ...          # marker files of completed migrations

/usr/local/share/xray/            # geoip.dat and geosite.dat
/etc/systemd/system/xray.service.d/security.conf
/etc/systemd/system/xrayebator-sub.service
/etc/nginx/sites-available/xrayebator-sub
/etc/nginx/sites-available/xrayebator-selfsteal
```

## Inbound versus profile

An inbound is a block in `config.json` bound to a port. A profile is a JSON file with user-facing
metadata. Several profiles can live on one inbound, that is, on one port.

The consequence matters: the SNI and fingerprint of an inbound are shared by every profile on that
port. Changing the SNI on a port affects all profiles attached to it.

## How the subscription works

`xrayebator-sub.service` listens on `127.0.0.1:8080` and nginx publishes it over HTTPS. The endpoint:

```text
https://<domain-or-ip>/sub/<32-hex-token>
```

The token lives in the profile JSON as `sub_token`. If it leaks, use `Revoke` in the subscription
menu — the token changes and the old URL dies.

The subscription name shown in the client is set separately from the profile name:
`Подписка HAPP` → `Настройки HAPP` → `HAPP_SERVER_NAME`. Several VPS instances can therefore be
labelled differently in the client list even when the internal profile on each is called `happ`. An
empty value falls back to the profile name.

Per-client behaviour:

- HAPP receives a plain-text `vless://` list, HAPP headers and an optional `happ://routing/onadd/...`;
- `v2rayNG` and `v2rayN` receive the classic base64 body without HAPP metadata;
- profiles without a live inbound are hidden from the subscription menu and their old URLs return
  `410 Gone`.

## Config edits

Every change follows the same path:

```text
backup_config ────► /usr/local/etc/xray/backups/config_<timestamp>_<op>.json
safe_jq_write ────► temp file in the destination directory → validation → atomic rename
safe_restart_xray ► xray run -test -config → systemctl restart
                    on failure — rollback from the backup, Xray keeps the old config
```

Migrations run once and are recorded by marker files in `/usr/local/etc/xray/`. The scheme is always
the same: marker missing → backup → edit → restart → create the marker.
