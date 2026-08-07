# Configuration

[← Back to README](../README.md) · [Русский](ru/configuration.md) · [简体中文](zh-CN/configuration.md)

Sections: [Environment variables](#installer-environment-variables) ·
[Firewall and host networking](#firewall-and-host-networking) · [Main menu](#main-menu) ·
[Commands](#commands) · [Bypass routing](#bypass-routing) · [Cascade](#cascade-and-upstream-nodes) ·
[Self-steal](#custom-domain-and-self-steal-stub) · [Domain and DNS](#domain-and-dns)

---

## Installer environment variables

| Variable | Value | Effect |
|---|---|---|
| `XRAY_FORCE_IPV4` | `1` | Forces the Xray release download over IPv4 |
| `XRAY_DOWNLOAD_PROXY` | proxy URL | Downloads the core through an HTTP or SOCKS proxy |
| `XRAY_LOCAL_ZIP` | file path | Uses a local core ZIP instead of downloading |
| `XRAY_LOCAL_DGST` | file path | Uses a local `.dgst` SHA-256 manifest |

When GitHub Releases is unreachable:

```bash
XRAY_FORCE_IPV4=1 XRAY_DOWNLOAD_PROXY=socks5h://127.0.0.1:1080 \
  sudo -E bash ./xrayebator-install.sh
```

Alternatively download the official ZIP and `.dgst` through any other channel and pass local paths.
The SHA-256 check is mandatory and cannot be disabled:

```bash
XRAY_LOCAL_ZIP=/tmp/Xray-linux-64.zip \
XRAY_LOCAL_DGST=/tmp/Xray-linux-64.zip.dgst \
  sudo -E bash ./xrayebator-install.sh
```

## Firewall and host networking

Xrayebator does not change the host TCP congestion-control algorithm and does not write or apply
system-wide `sysctl` values. Host networking remains under the VPS operator's control.

When upgrading an installation created by an older release, v3.0 runs a one-time migration. It
removes only exact Xrayebator-owned legacy tuning files/blocks and immediately changes an active BBR
algorithm to `cubic` (or `reno` when `cubic` is unavailable). Foreign sysctl files are never edited:
the migration reports them and retries on the next launch until the operator removes the setting.
Removed project-owned files are backed up under `/usr/local/etc/xray/backups/` and are not restored
when the live switch fails, so a reboot cannot re-enable the removed setting.

The installer manages UFW itself: it installs the `ufw` package, enables it with `ufw --force enable`
when inactive, then opens ports `22, 80, 443, 8443, 2053, 2083, 2087, 8080, 2096, 8880, 9443/tcp`
and reloads the rules.

> The port list is fixed and may not contain your SSH port. If SSH is not on `22`, or you maintain
> your own firewall policy, compare the numbered rules before and after installation. Rules opened by
> the installer are not removed when Xrayebator is uninstalled.

## Main menu

| Item | Purpose |
|---|---|
| `1` | Create a profile manually: a single route or a set |
| `2` | Delete a profile and its inbounds |
| `3` | Show connection details for a profile |
| `4` | Manage a profile: SNI, fingerprint, port, advanced |
| `5` | Upgrade a single profile to PQ XHTTP |
| `6` | HAPP subscription: a profile of 7 routes, public TLS, URL, QR, revoke |
| `7` | Bypass routing: send domains directly, skipping the VPN |
| `8` | Cascade and upstream nodes |
| `9` | Custom domain and self-steal stub |
| `10` | Set up an outbound server so this VPS can act as a foreign cascade node |
| `0` | Exit |

Actions are numbered consecutively from `1` to `10`; `0` exits the program.

Changing SNI or a port restarts the corresponding server inbound. Fingerprint is a client-side
parameter: it changes only for the selected route and does not require an Xray restart. After any
change, force a subscription refresh in the client or fetch the raw route again through
`3) Подключиться по профилю`.

## Commands

| Command | Effect |
|---|---|
| `sudo xrayebator` | Open the interactive menu |
| `sudo xrayebator update` | Update **only the Xray-core binary**; Xrayebator itself is untouched |
| `sudo xrayebator probe-test` | Check SNI reachability from the VPS before switching |
| `sudo xrayebator quickstart --email <address>` | Non-interactive one-shot deploy used by the desktop GUI: sets up the subscription server, obtains an IP-TLS certificate and creates the multi-route HAPP profile. Prints a JSON result line |
| `sudo xrayebator happ-setup` | Idempotent re-entry point for the HAPP multi-route profile: installs/restarts the subscription service and prints the same JSON payload as `quickstart` |
| `sudo xrayebator-update` | Update **Xrayebator itself** from the branch stored in `.current_branch` |
| `sudo xrayebator-update main` | Update Xrayebator itself, forced from the `main` branch |
| `sudo xrayebator-uninstall` | Remove the service and configuration |

`xrayebator update` and `xrayebator-update main` only look similar:

| | `sudo xrayebator update` | `sudo xrayebator-update main` |
|---|---|---|
| What it updates | The Xray-core binary | The Xrayebator scripts |
| Source | GitHub Releases of the XTLS project | The `main` branch of this repository |
| Argument | Takes none | Takes a branch name: `main`, `dev`, `experimental` or any other |
| Affects | Core version, transports, protocols | Menu, migrations, subscription generation |
| Side effect | Xray restart after config validation | Migrations run on the next menu launch |

## Bypass routing

Bypass adds Xray routing rules so selected domains go straight out through `freedom` instead of the
VPN. The `domain -> direct` rules sit above the catch-all, so they keep working with the cascade
enabled.

Default bundle groups:

| Group | Contents |
|---|---|
| `steam` | Steam: CDN, chat, community |
| `banks` | Russian banks and payments |
| `marketplaces` | Russian marketplaces and retail |
| `streaming` | Russian streaming and media |
| `yandex` | The Yandex ecosystem |
| `vk` | VKontakte |
| `mailru` | VK Group and Mail.ru |

The menu is interactive: arrows move the selection, space toggles a group, Enter applies.

## Cascade and upstream nodes

The cascade is a server-side outbound and routing mode, not a new client profile. The client keeps
connecting to the current VPS:

```text
client → current VPS → foreign VLESS Reality upstream → internet
```

Menu item `8` stores the parameters in `/usr/local/etc/xray/upstreams/cascade.json`, adds the
`cascade-upstream` outbound and switches only the `network=tcp,udp` catch-all rule.

Two upstream types are supported: VLESS Reality over TCP, including Vision and XUDP, and XHTTP. The
menu accepts a ready `vless://` link and carries transport-specific parameters over automatically;
manual entry needs `address`, `port`, `uuid`, `publicKey`, `shortId`, SNI and fingerprint. When the
cascade is already active, switching the upstream rebuilds the outbound and routing and restarts
Xray — no separate disable and enable is needed.

Disabling the cascade removes the `cascade-upstream` outbound and returns the catch-all to `direct`.
All changes go through `backup_config`, `safe_jq_write` and `safe_restart_xray`.

Item `10` configures the other side: it turns the current VPS into the foreign node that a cascade
from another server connects to.

## Custom domain and self-steal stub

Self-steal puts nginx with a valid certificate on `127.0.0.1:9444`, and Reality inbounds receive
`serverNames=[domain]` and `dest=127.0.0.1:9444`. For XHTTP, `xhttpSettings.host` is updated as well.

You need a domain with an A or AAAA record pointing at the VPS and an email for Let's Encrypt. The
menu installs `nginx` and `certbot`, writes the config to
`/etc/nginx/sites-available/xrayebator-selfsteal`, enables and reloads nginx, opens and rate-limits
`80/tcp` when UFW is active, and issues the certificate through a webroot challenge.

Available templates: `Simple web template`, `SNI template`, `Nothing SNI template`.

If there is no inbound on `443`, Xrayebator creates a service fallback-only Reality inbound
`inbound-443` with no clients — otherwise an external TLS probe to `https://domain/` never reaches
the stub.

## Domain and DNS

For the domain mode create an `A` record pointing at the VPS IPv4. Add `AAAA` only if IPv6 is really
configured and reachable.

If the domain sits behind Cloudflare, `DNS only` is more reliable than `Proxied` for testing: certbot
must reach the VPS over the HTTP challenge on port 80.

If `443` is taken by Xray or another service, the subscription moves to `8443` and the URL carries
the port: `https://domain:8443/sub/<token>`.
