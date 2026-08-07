<div align="center">

# Xrayebator

<h3>Xray VLESS Reality on your own VPS</h3>

<p>
<strong>inbounds</strong> · <strong>profiles</strong> · <strong>subscription</strong> ·
<strong>bypass</strong> · <strong>cascade</strong>
</p>

<p>
<strong>Read this in other languages</strong><br>
<a href="README.md">🇺🇸 English</a> ·
<a href="README.ru.md">🇷🇺 Русский</a> ·
<a href="README.zh-CN.md">🇨🇳 简体中文</a>
</p>

<p>
<img alt="Bash 5.0+" src="https://img.shields.io/badge/bash-5.0%2B-4EAA25?style=flat-square&logo=gnubash&logoColor=white">
<img alt="Xray-core Reality" src="https://img.shields.io/badge/Xray--core-Reality-22D3EE?style=flat-square">
<img alt="HAPP subscription" src="https://img.shields.io/badge/subscription-HAPP-A78BFA?style=flat-square">
<a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-3FB950?style=flat-square"></a>
</p>

<p>
<strong>One bash script turns a clean VPS into a personal VLESS Reality server.</strong><br>
Xrayebator installs Xray-core, brings up Reality inbounds on random ports, builds a profile of seven
routes and hands them to the client as a single HTTPS subscription link. Current line — 3.0.
</p>

</div>

```bash
curl -fsSLo ./xrayebator-install.sh \
  https://raw.githubusercontent.com/howdeploy/Xrayebator/main/install.sh
less ./xrayebator-install.sh          # review the script before running it
sudo bash ./xrayebator-install.sh

# Step-control flags (interrupt-safe install):
#   --check   Show which of the 10 steps are already done
#   --resume  Continue from the first unfinished step
#   --fresh   Reset all markers and start from zero
```

<div align="center">

<p>
Debian 12/13 · Ubuntu 22.04/24.04 · 512 MB RAM or more · <code>root</code> or <code>sudo</code><br>
Then run <code>sudo xrayebator</code>, pick item <code>6</code>, and the subscription is ready.
Details: <a href="#quick-start">Quick start</a>
</p>

<p>
<a href="#why-it-exists">Purpose</a> ·
<a href="#capability-map">Capabilities</a> ·
<a href="#how-it-works">How it works</a> ·
<a href="#quick-start">Quick start</a> ·
<a href="#documentation">Documentation</a> ·
<a href="#known-limitations">Limitations</a> ·
<a href="#updating-and-removal">Updating</a>
</p>

</div>

---

## Why it exists

A personal VLESS Reality setup is a dozen manual steps: assemble the inbound, generate keys, pick an
SNI, avoid breaking the config, deliver the link to a phone. One typo in `config.json` and Xray does
not start.

A single route is also not enough. DPI blocks transports unevenly: TCP Vision survives in one
network, only gRPC in another, and nothing but XHTTP in a third. Maintaining separate configs for
each case by hand is impractical.

Xrayebator solves both problems:

- a profile is not one route but a set of `routes` sharing a single `sub_token`;
- the client receives the whole set as one short subscription link instead of seven `vless://` links;
- every config change goes through a backup, an `xray run -test` validation and an automatic
  rollback, so a failed edit never leaves the server without VPN;
- changing SNI, port or fingerprint does not require recreating the profile.

The project is developed and tested by one person. The consequences are listed plainly in
[Known limitations](#known-limitations) — read that section before installing on a VPS you care
about.

## Capability map

| Capability | What it does | Where it lives |
|---|---|---|
| Xray-core installation | Downloads the release from GitHub, always verifies SHA-256 against `.dgst`, installs the binary via `install -m 755`, runs a self-test | `install.sh` |
| Reality inbounds | Brings up inbounds on free ports in `30000-60000`, checking both `config.json` and actually listening sockets | `xrayebator` |
| Multi-route profile | One profile = a set of routes with a shared `sub_token`; several profiles may share one port | `profiles/<name>.json` |
| HAPP subscription | A local HTTP server serves the `vless://` list and HAPP metadata; nginx publishes it over HTTPS | `subhttp.sh`, `xrayebator-sub.service` |
| Post-quantum XHTTP | The `xhttp-pq` route runs VLESS encryption `mlkem768x25519plus` | `.vless_encryption`, `.vless_decryption` |
| v2ray compatibility | `v2rayNG` and `v2rayN` receive a classic base64 body without HAPP metadata | `subhttp.sh` |
| Subscription revoke | Generates a new 32-character hex token; the old URL stops working | `openssl rand -hex 16` |
| Bypass routing | Seven domain groups can be sent straight through `freedom`, skipping the VPN | menu `7` |
| Cascade | Switches the `tcp,udp` catch-all to a foreign VLESS Reality upstream of type `tcp` or `xhttp` | `upstreams/cascade.json` |
| Self-steal stub | Puts nginx with a valid certificate on `127.0.0.1:9444` and points a Reality fallback at it | menu `9` |
| Safe JSON writes | Writes a temporary file inside the destination directory, validates it, renames atomically | `safe_jq_write` |
| Safe restart | Runs `xray run -test -config` before restarting; rolls the config back from a backup on failure | `safe_restart_xray` |
| Migrations | One-shot migrations driven by marker files: backup → edit → restart → marker | `run_migration` |
| geo databases | Places extended `geoip.dat` and `geosite.dat` from Loyalsoldier releases into `/usr/local/share/xray` | `install.sh` |

Not supported and not claimed: H2, WebSocket, SplitHTTP, Clash/mihomo subscriptions.

## How it works

Control flow. Every config change follows the same path:

```text
sudo xrayebator
      │
      ▼
xrayebator  (bash)
create profile · change SNI/port/fingerprint · migrations · routing
      │
      ├─ backup_config ───────► /usr/local/etc/xray/backups/<timestamp>
      │
      ├─ safe_jq_write ───────► config.json  +  profiles/<name>.json
      │
      └─ safe_restart_xray
               │
               ├─ xray run -test -config  → ok ──► systemctl restart xray
               │
               └─ invalid config ─────────────────► rollback from backup,
                                                    Xray keeps running
                                                    on the previous config
```

Client flow. From the subscription link to the open internet:

```text
client (HAPP)
    │  https://<domain-or-ip>/sub/<32-hex-token>
    ▼
nginx  :443  (or :8443 when 443 is taken)
    │  proxy_pass
    ▼
xrayebator-sub.service   127.0.0.1:8080
    │  reads profiles/*.json and checks routes against the live config.json
    ▼
vless:// list — HAPP receives 6 of the profile's 7 routes
    │
    ▼
Reality inbound on a port in 30000-60000   (User=xray, CAP_NET_BIND_SERVICE)
    │
    ├─ domain in an enabled bypass group ──► freedom  (direct, no VPN)
    │
    └─ all other tcp/udp ─────────────────► direct
                                            OR cascade-upstream ──► foreign VPS
```

### Profile routes

The HAPP flow creates or reuses a profile of seven routes:

| Route | Transport | Purpose |
|---|---|---|
| `xhttp-legacy` | xhttp | HAPP-compatible XHTTP fallback, `decryption=none`, no PQ |
| `xhttp-pq` | xhttp | XHTTP with post-quantum encryption `mlkem768x25519plus` |
| `tcp-mux` | tcp | TCP Reality without Vision flow, a separate compatible fallback |
| `grpc` | grpc | gRPC Reality; sensitive to HTTP/2 and SNI |
| `tcp-vision` | tcp | TCP Reality with `xtls-rprx-vision` |
| `tcp-utls-firefox` | tcp | TCP Vision with a Firefox fingerprint |
| `tcp-xudp` | tcp | TCP Vision + XUDP, a narrow fallback for harsh mobile networks |

Six of the seven routes reach the HAPP subscription: when `xhttp-legacy` is present, PQ-XHTTP is not
offered as the XHTTP candidate. All seven remain in the profile JSON itself.

The default client fingerprint for new and updated profiles is `firefox`. Explicitly chosen
fingerprints other than the deprecated `chrome` are preserved across updates.

Route order in the subscription is stable but it is not a best-to-worst ranking. Whether a transport
works depends on the client, its bundled Xray-core version and the specific network.

### Subscription publishing modes

| Mode | Result | When to use |
|---|---|---|
| Public TLS by VPS IP | `https://<ip>/sub/<token>` | Quick start without a domain. Let's Encrypt IP certificates are short-lived, renewal is mandatory |
| Public TLS by domain | `https://sub.example.com/sub/<token>` | Recommended for permanent use |
| Local-only debug | `http://127.0.0.1:8080/sub/<token>` | Only for checks from the VPS itself or through an SSH tunnel. Does not work from a phone directly |

---

## Quick start

### Requirements

- A VPS with Debian 12/13 or Ubuntu 22.04/24.04 LTS and `root` or `sudo` access
- 512 MB RAM minimum, 1 GB or more recommended
- 1 CPU core, 2 or more recommended
- 1 GB of free disk space

The installer pulls `ca-certificates curl wget jq qrencode uuid-runtime ufw unzip openssl socat`.

> The installer does not check the OS version — the matrix above is declared, not enforced. Field
> testing happens mostly on Debian. Take a snapshot before installing on a VPS that matters.

### Installation

Download the script, review it, and only then run the local file as root:

```bash
curl -fsSLo ./xrayebator-install.sh \
  https://raw.githubusercontent.com/howdeploy/Xrayebator/main/install.sh
less ./xrayebator-install.sh
sudo bash ./xrayebator-install.sh
```

> The installer does not change host TCP or sysctl settings, but manages UFW on its own. Read
> [Environment variables](docs/configuration.md#installer-environment-variables) and
> [Firewall and host networking](docs/configuration.md#firewall-and-host-networking) BEFORE running it,
> especially if SSH listens on a non-standard port.

### HAPP subscription in five steps

1. Open the menu:

   ```bash
   sudo xrayebator
   ```

2. Choose `6) Подписка HAPP` — the HAPP subscription entry.
3. Choose the publishing mode: by VPS IP for a quick start without a domain, by domain for permanent
   use.
4. Xrayebator creates the `happ` profile, brings up the inbounds, issues the certificate and prints
   the URL and a QR code.
5. Import the subscription URL or QR into HAPP — not an individual `vless://` link.

### FAQ: routes are green, but Telegram or other apps do not work

> **HAPP 3.3.6 or newer is required.** If Xrayebator routes have a green ping but connections do not
> work, fully quit every old HAPP process, start exactly one current instance and refresh the
> subscription. A green route ping uses a separate temporary Xray-core and does not prove that the
> main TUN is healthy. On Linux, `ss -lntp | grep ':10808'` must show the main HAPP core listening.

Also check the active **Routing** profile in HAPP. Routing profiles left over from another paid VPN
can override Xrayebator and send Telegram directly instead of through the VPS, even while route
pings stay green. Disable third-party routing and use Global Proxy, or select
`xrayebator-default` if that profile is present. In particular, avoid profiles with
`globalProxy: false` and no explicit Telegram proxy rule.

Use `1) Создать новый профиль` for manual control over SNI, transport or a single route.

> The terminal interface is in Russian. This README and the documentation describe every menu item,
> so the interface language is not a blocker.

---

## Documentation

| Document | Contents |
|---|---|
| [Configuration](docs/configuration.md) | Environment variables, firewall and host networking, main menu, commands, bypass, cascade, self-steal, domain and DNS |
| [Architecture](docs/architecture.md) | Repository and on-server state trees, inbound versus profile, subscription internals |
| [Security](docs/security.md) | Service account and permissions, subscription protection, SSH access to the VPS |
| [Troubleshooting](docs/troubleshooting.md) | Subscription not refreshing, XHTTP not working, client not connecting and other cases |
| [Testing](docs/testing.md) | Local checks, what `validation/` covers, manual checks on a live server |

Russian and Chinese versions live in [`docs/ru/`](docs/ru/) and [`docs/zh-CN/`](docs/zh-CN/).

---

## Known limitations

- The installer enables UFW via `ufw --force enable` and opens a fixed list of eleven ports. SSH on a
  non-standard port is not in that list.
- `xrayebator-update` automatically removes a detected `/opt/AdGuardHome` as deprecated: it first
  moves Xray DNS back to DoH, then stops the service and deletes the files. Do not update without a
  snapshot if AdGuard Home is in use on that VPS.
- `/usr/local/etc/xray/` is owned by `xray:xray` in full and `config.json` has mode `0644`: the
  service account can write to its own config and profiles.
- The installer does not check the OS version. The support matrix is declared, not enforced.
- The Xray core is verified by SHA-256 unconditionally, while Loyalsoldier geo databases are
  downloaded without a checksum check.
- `xrayebator-uninstall` does not remove everything. It stops and disables `xray`, deletes
  `/usr/local/etc/xray`, `/usr/local/bin/xrayebator` and the `xray.service` and `xray@.service`
  units. It does NOT remove the `/usr/local/bin/xray` binary, `subhttp`, `xrayebator-update`,
  `xrayebator-uninstall`, the `xrayebator-sub.service` unit, nginx configs, geo databases, UFW rules
  or the `xray` system user. Clean up the remains manually.
- The `tcp-mux` route is kept for compatibility; it is not a mux preset.
- H2, WebSocket, SplitHTTP and Clash/mihomo subscriptions are not supported.
- The interface imposes no hard limit on users, but real capacity is bound by CPU, RAM, VPS
  bandwidth, route count and provider limits.

---

## Updating and removal

```bash
sudo xrayebator update            # Xray-core only
sudo xrayebator-update            # Xrayebator itself, branch from .current_branch
sudo xrayebator-update main       # Xrayebator itself, forced from main
sudo xrayebator-uninstall         # remove the service and configuration
```

The names look alike, the meaning does not:

| | `sudo xrayebator update` | `sudo xrayebator-update main` |
|---|---|---|
| What it updates | The Xray-core binary | The Xrayebator scripts |
| Source | GitHub Releases of the XTLS project | The `main` branch of this repository |
| Argument | Takes none | Takes a branch name: `main`, `dev`, `experimental` or any other |
| Affects | Core version, transports, protocols | Menu, migrations, subscription generation |
| Side effect | Xray restart after config validation | Migrations run on the next menu launch |

The chosen branch is stored in `/usr/local/etc/xray/.current_branch` and shown in the menu header.
After updating Xrayebator itself, the first `sudo xrayebator` run executes migrations: wait for them
to finish before refreshing the subscription in the client.

What stays on the system after `xrayebator-uninstall` is listed in
[Known limitations](#known-limitations).

---

## Clients

Import the subscription URL into the client, not an individual `vless://` link. Raw routes from
`3) Подключиться по профилю` are for diagnostics.

| Client | Status | Comment |
|---|---|---|
| HAPP | Recommended | The target client. Supports subscriptions by URL and QR plus VLESS links |
| v2rayNG | Partial | Receives the base64 subscription, ignores HAPP metadata |
| v2rayN | Partial | VLESS subscriptions work, HAPP specifics are unused |
| Shadowrocket | Manual | Fine for raw VLESS, not the primary subscription client |
| sing-box · Hiddify · NekoBox · mihomo | Not targeted | Do not expect PQ-XHTTP or HAPP routing |

- Android: [HAPP](https://www.happ.su/) · [v2rayNG](https://github.com/2dust/v2rayNG) · [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid)
- iOS: [HAPP](https://www.happ.su/) · [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118) · [V2Box](https://apps.apple.com/app/v2box-v2ray-client/id6446814690)
- Windows: [Throne](https://github.com/throneproj/Throne) · [v2rayN](https://github.com/2dust/v2rayN) · [NekoRay](https://github.com/MatsuriDayo/nekoray)
- macOS: [Throne](https://github.com/throneproj/Throne) · [V2RayXS](https://github.com/tzmax/V2RayXS) · [Qv2ray](https://github.com/Qv2ray/Qv2ray)
- Linux: [Throne](https://github.com/throneproj/Throne) · [v2rayA](https://github.com/v2rayA/v2rayA) · [Qv2ray](https://github.com/Qv2ray/Qv2ray)

Client documentation: [HAPP subscription](https://www.happ.su/main/faq/adding-configuration-subscription) ·
[v2rayN subscription format](https://github.com/2dust/v2rayN/wiki/Description-of-subscription)

---

## License

MIT. See the [LICENSE](LICENSE) file.

## Credits

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core) — for the protocol.
- [HAPP](https://www.happ.su/) — for the target client and the subscription format.
- [2dust/v2rayNG](https://github.com/2dust/v2rayNG) and [2dust/v2rayN](https://github.com/2dust/v2rayN) — for the clients and subscription formats.
- [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat) — for the extended geo databases.
- [Umalanif/xray-server-setup](https://github.com/Umalanif/xray-server-setup) — for the uTLS reference and automation.
- [ServerTechnologies/simple-xray-core](https://github.com/ServerTechnologies/simple-xray-core) — for fast deployment.
- The community — for support and testing.

## Supporting the project

A star on GitHub is the simplest way to support the project.

Donations:

```text
EVM     0x7acE4442b92f2769c24484c78A13024B139E1A5b
Solana  FS9RBrG5yXJty3WNWgkBkfai6BfNoYxGMFeH1LQEpRZr
TON     UQA56zsOv3zvU5x-p7iNNDL8jHh9dt7Q7WlY_gfbaj4ZhcyT
BTC     34EznmkBGpBu4dUnzoHL5GBnpg2Rq86v4H
```

---

<div align="center">
<strong>Made for a free internet</strong>
</div>
