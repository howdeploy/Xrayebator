# Configuration

[← Back to README](../README.md) · [Русский](ru/configuration.md) · [简体中文](zh-CN/configuration.md)

Sections: [Prerequisites](#prerequisites-and-tested-systems) · [Environment variables](#installer-environment-variables) ·
[Firewall and host networking](#firewall-and-host-networking) · [Main menu](#main-menu) ·
[Commands](#commands) · [Desktop GUI](#desktop-gui) · [Bypass routing](#bypass-routing) ·
[Cascade](#cascade-and-upstream-nodes) · [Self-steal](#custom-domain-and-self-steal-stub) · [Domain and DNS](#domain-and-dns)

---

## Prerequisites and tested systems

The installer has hard prerequisites:

- root privileges, either a root shell or a user whose `sudo` session can obtain root;
- Bash (run `install.sh` and the manager with Bash, not `sh`);
- an apt-based Debian/Ubuntu-like system with `apt`/`apt-get`;
- a running systemd environment (`systemctl` and `/run/systemd/system`).

The supported family is broader than one release, but the current verification matrix covers:

| Distribution | Tested releases |
|---|---|
| Debian | 12, 13 |
| Ubuntu | 22.04, 24.04 |

A KVM-style VPS with working DNS, outbound HTTPS and a reachable SSH service is the practical
baseline. Containers without systemd are rejected by the installer rather than being partially
configured.

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

The installer installs `ufw` when needed and handles the SSH lockout hazard before enabling it:

1. it detects the active SSH port from the listening sockets and, when available, `sshd -T` and the
   SSH configuration;
2. it checks whether that port is already allowed, or opens it before enabling UFW;
3. it records only rules created by Xrayebator in the root-owned
   `/usr/local/etc/xray/.ufw_owned` manifest;
4. if the SSH port cannot be determined or cannot be opened safely, an inactive UFW is left
   disabled instead of applying a deny policy that could lock out the VPS.

If UFW was already active or becomes enabled after the SSH safety check, the installer adds this
fixed project service TCP list: `22, 80, 443, 8443, 2053, 2083, 2087, 8080, 2096, 8880, 9443`.
It records only rules it creates in the root-owned `.ufw_owned` manifest. The list is not a promise
that SSH uses port 22; compare numbered rules before and after installation. Owned rules are removed
on uninstall, while rules that existed beforehand stay untouched.

## Main menu

The interactive menu uses these exact meanings:

| Item | Purpose |
|---|---|
| `1` | Create a new profile manually, with one route or a multi-route set |
| `2` | Delete an existing profile and clean up its unused inbounds/firewall ports |
| `3` | Display connection details and generated links for a selected profile |
| `4` | Manage a profile: SNI, client fingerprint, port and advanced settings |
| `5` | Upgrade a single profile to post-quantum XHTTP + Reality |
| `6` | HAPP subscription: provision public/local publishing, URL/QR, revoke and HAPP settings; the managed profile has 7 routes and the published list has 6 |
| `7` | Bypass routing: send selected domains directly instead of through the VPN |
| `8` | Cascade and upstream nodes |
| `9` | Custom domain and self-steal stub |
| `10` | Set up an outbound server so another VPS can use this server as a foreign cascade node |
| `0` | Exit |

Actions are numbered consecutively from `1` to `10`; `0` exits the program. SNI and port are
shared inbound settings, so changing either can affect other profiles on that port. The fingerprint
is a client-side profile/route setting; changing it does not restart Xray or alter other routes.

## Commands

| Command | Effect |
|---|---|
| `sudo xrayebator` | Open the interactive menu |
| `sudo xrayebator update` | Update only the Xray-core binary |
| `sudo xrayebator update <branch>` | Self-update the manager from the canonical raw repository branch, continue with the new script, then update Xray-core |
| `sudo xrayebator probe-test` | Check SNI reachability from the VPS before switching |
| `sudo xrayebator quickstart --email <address>` | One-shot deploy path used by the desktop GUI: runs the broad setup/migration path, provisions the current IP-TLS endpoint on `8443`, and creates a standard HAPP profile with `schema_version: 3` and 7 routes; emits JSON with `subscription_url` |
| `sudo xrayebator quickstart --without-email` | Same new-server path without an ACME contact email; Certbot uses `--register-unsafely-without-email`, so no renewal notices or email-based account recovery are available |
| `sudo xrayebator inspect --json` | Read-only GUI import probe: reports manager, Xray, profile and subscription markers without installing, migrating or changing services/configuration |
| `sudo xrayebator happ-setup` | Reduced existing-install HAPP path: ensures the subscription service and a usable multi-route profile, but does not replace the endpoint prerequisite; when `.subscription_domain` or `.subscription_port` is missing, it verifies a real public TLS endpoint before writing markers and otherwise fails |
| `sudo xrayebator profiles` | Print all server profiles as a JSON array for the desktop GUI Server Settings page |
| `sudo xrayebator profile-create --name NAME [--transport tcp\|tcp-utls\|tcp-xudp\|tcp-mux\|grpc\|xhttp] [--port P] [--count N]` | Create one or more profiles non-interactively; prints `{"ok":true,"names":[...],"errors":[...]}` |
| `sudo xrayebator profile-delete --name NAME` | Delete a profile non-interactively; prints `{"ok":true,"name":"..."}` |
| `sudo xrayebator fp-change --name NAME [--route R] --fp FINGERPRINT` | Change the client fingerprint for one profile route; prints JSON |
| `sudo xrayebator sni-change --name NAME [--route R] --sni SNI` | Change the shared inbound SNI and synchronise profiles on that port; prints JSON |
| `sudo xrayebator sni-list` | Print SNI candidates grouped by category for the GUI SNI dialog; prints JSON |
| `sudo xrayebator port-change --name NAME [--route R] --port PORT\|random` | Change the inbound port, firewall and subscription metadata; reconnect the client; prints JSON |
| `sudo xrayebator bypass list` | Print current bypass domain rules as JSON |
| `sudo xrayebator bypass add --domain D` | Add a domain to bypass rules |
| `sudo xrayebator bypass remove --domain D` | Remove a domain from bypass rules |
| `sudo xrayebator bypass reset` | Clear all custom bypass rules |
| `sudo xrayebator bypass bundle [--group a,b,c]` | Apply the default bypass groups; without `--group`, apply all groups |
| `sudo xrayebator-update [branch]` | Run the full `update.sh` project lifecycle update; without a branch, display `.current_branch` and open the interactive branch selector; with a branch, use that explicit branch |
| `sudo xrayebator-uninstall` | Remove the service and installation |

These update commands are intentionally different:

| | `sudo xrayebator update <branch>` | `sudo xrayebator-update [branch]` |
|---|---|---|
| What it starts with | The installed manager script | The full lifecycle updater script |
| Source | Canonical raw file for the requested branch | The selected branch's `update.sh` workflow |
| Main result | Manager self-update followed by Xray-core update | The manager's lifecycle sequence: scripts, data, subscription integration and service refresh as implemented |
| Branch selection | Explicit branch is required for self-update | No argument shows `.current_branch` and then prompts; an explicit argument selects that branch |

`xrayebator update <branch>` self-updates the manager from the canonical raw branch, then invokes
the fresh manager for the Xray-core update. The full `update.sh` path has separate validation,
restart and rollback behavior, so do not infer that every full run changes Xray-core. The desktop
GUI currently invokes `xrayebator update <branch>` from Server Settings; it does not invoke the full
`xrayebator-update` workflow.

## HAPP provisioning paths

`quickstart --email <address>` is the broad migration path: it performs the setup needed by a new
deployment, provisions the IP-TLS subscription endpoint on `8443` and its certificate, and then creates
or reuses the managed HAPP profile. A newly created standard profile uses `schema_version: 3` with seven
routes, including `xhttp-legacy` and `xhttp-pq`. Migration calls in this non-interactive path are
best-effort; verify markers, the profile JSON and service status after deployment.

`quickstart --without-email` performs the same broad setup and endpoint provisioning as the email form, but registers the ACME account with `--register-unsafely-without-email`; Certbot renewal notices and email-based account recovery are unavailable.

`inspect --json` is the GUI's read-only import probe. It reports whether this is an Xrayebator installation, Xray/profile/service markers and saved subscription metadata; it does not run migrations, create profiles, change configuration, restart services or edit firewall rules.

`happ-setup` is the reduced path for an existing installation. It runs only the critical migrations,
restores the subscription service and ensures a multi-route profile; it is not a replacement for
initial endpoint provisioning. If `.subscription_domain` or `.subscription_port` is missing,
it verifies the public TLS endpoint before writing markers and refuses to fabricate them. Existing
markers are reused without necessarily being reverified, so stale saved markers still require
operator verification or a rerun of the appropriate setup path.

The helper may reuse an existing profile meeting the seven-live-route minimum, not necessarily one
with all standard labels or the current schema. Inspect the actual JSON; migrations do not retrofit missing
routes into an existing profile. Use the menu or `quickstart` to re-provision/create a managed
profile when `xhttp-legacy`, `xhttp-pq` or the expected seven-route shape is missing.

## Desktop GUI

The active Electron app is a CLI front-end over SSH, not a complete replacement for the terminal
menu. It deploys with `quickstart`, refreshes the saved `subscription_url`, and exposes profile
list/create/delete plus selected SNI, fingerprint, port, update and uninstall operations. Bypass,
probe, revoke, HAPP setup, cascade, self-steal, the interactive menu and service diagnostics remain
server-side operations.

See [Electron Desktop GUI](desktop-gui.md) for the complete command mapping, security boundary,
packaging and test details.

The GUI's local development checks are:

```bash
npm install
npm run dev
npm run build
npm test
npm run typecheck
```

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

## HAPP client routing profile

The subscription endpoint returns a client-side routing profile to HAPP in the `routing:` response
header. The managed default, `xrayebator-default`, sets `GlobalProxy: "true"`, so every destination
except private IPv4 ranges is tunnelled.

That is a different knob from [Bypass routing](#bypass-routing). Bypass changes where **the server**
sends a request; the client still tunnels it, so the destination sees the VPS address. On a node
without a cascade the catch-all outbound is already `direct`, so bypass cannot change what a Russian
site sees. Keeping domestic traffic out of the tunnel is only possible in the client profile.

The profile travels to the client in a response header, so a large `DirectSites` list can outgrow
nginx's default 4k proxy buffer. The generated `location /sub/` raises it; if you run your own
reverse proxy in front of the subscription, set `proxy_buffer_size` there too, otherwise nginx
answers 502 and logs `upstream sent too big header`.

### Generating it from the menu

`HAPP subscription -> 7) Маршрутизация клиента` writes a ready split profile built from the same
bundles the server-side bypass uses. It keeps `GlobalProxy: "true"`, so anything unknown still
tunnels, and moves the Russian bundles plus `geoip:ru` into `DirectSites` and `DirectIp`. The
previous override is backed up next to the file, and removing the override restores the managed
default.

### Override file

| Variable | Default | Meaning |
|---|---|---|
| `HAPP_ROUTING_ENABLED` | `true` | Set to `false` to stop sending the `routing:` header |
| `HAPP_ROUTING_JSON_FILE` | `/usr/local/etc/xray/.happ_routing.json` | Operator override |

If the override file exists and passes HAPP schema validation, it replaces the managed default for
every subscriber. Malformed JSON is ignored in favour of the default rather than broadcast. Restart
`xrayebator-sub.service` is not required: the file is read per request.

Verdicts are evaluated per destination. `GlobalProxy: "false"` makes `direct` the default and sends
only `ProxySites` and `ProxyIp` through the tunnel; `GlobalProxy: "true"` inverts that and treats
`DirectSites` and `DirectIp` as the exceptions.

### Split-tunnel example

Domestic traffic stays on the mobile carrier, blocked services go through the VPS:

```json
{
  "Name": "xrayebator-split",
  "GlobalProxy": "false",
  "RemoteDNSType": "DoH",
  "RemoteDNSDomain": "https://cloudflare-dns.com/dns-query",
  "RemoteDNSIP": "1.1.1.1",
  "DomesticDNSType": "DoU",
  "DomesticDNSDomain": "",
  "DomesticDNSIP": "77.88.8.8",
  "Geoipurl": "https://example.com/geo/geoip.dat",
  "Geositeurl": "https://example.com/geo/geosite.dat",
  "LastUpdated": "1788700000",
  "DnsHosts": { "cloudflare-dns.com": "1.1.1.1" },
  "DirectSites": ["domain:ru", "domain:xn--p1ai"],
  "DirectIp": ["geoip:private", "geoip:ru"],
  "ProxySites": ["domain:google.com", "domain:youtube.com", "domain:instagram.com"],
  "ProxyIp": ["149.154.160.0/20", "91.108.4.0/22", "91.105.192.0/23"],
  "BlockSites": [],
  "BlockIp": [],
  "DomainStrategy": "IPIfNonMatch",
  "FakeDNS": "false"
}
```

Three things are easy to get wrong:

- **Telegram travels to IP addresses, not domains.** Domain rules never match it. Take the ranges
  from <https://core.telegram.org/resources/cidr.txt> instead of writing them from memory; the list
  changes, and a missing range silently degrades media downloads while chat still works.
- **`LastUpdated` must grow.** HAPP re-imports a profile only when the value is higher than the one
  it already stored.
- **Geo databases must be reachable by the client.** The managed default points at
  `/sub/<token>/geoip.dat`, which is per-subscriber. An operator-wide override cannot embed one
  subscriber's token, so either host the databases somewhere every client can fetch them, or use
  the placeholders below.

### Placeholders

The override is read per request, so three values can be left for the server to fill in:

| Placeholder | Replaced with |
|---|---|
| `{{GEOIP_URL}}` | `<base url>/sub/<token>/geoip.dat` for the requesting subscriber |
| `{{GEOSITE_URL}}` | `<base url>/sub/<token>/geosite.dat` for the requesting subscriber |
| `{{LAST_UPDATED}}` | newest mtime among `xrayebator` and the two geo databases |

```json
  "Geoipurl": "{{GEOIP_URL}}",
  "Geositeurl": "{{GEOSITE_URL}}",
  "LastUpdated": "{{LAST_UPDATED}}",
```

Substitution runs before schema validation, so an unresolved placeholder fails the `https://` check
and the managed default is served instead of a broken profile. `{{LAST_UPDATED}}` also removes the
need to bump the value by hand after editing the geo databases.

While a client downloads new geo databases the previous profile keeps running, so a failed download
leaves routing unchanged rather than broken.

## Cascade and upstream nodes

The cascade is a server-side outbound and routing mode, not a new client profile. The client keeps
connecting to the current VPS:

```text
client → current VPS → foreign VLESS Reality upstream → internet
```

Menu item `8` stores the parameters in `/usr/local/etc/xray/upstreams/cascade.json`, adds the
`cascade-upstream` outbound and switches only the `network=tcp,udp` catch-all rule.

Two upstream types are supported: VLESS Reality over TCP, including Vision and XUDP, and XHTTP. The
menu accepts a ready `vless://` link and carries transport-specific parameters automatically;
manual entry needs `address`, `port`, `uuid`, `publicKey`, `shortId`, SNI and fingerprint. When the
cascade is already active, switching the upstream rebuilds the outbound and routing and restarts
Xray — no separate disable and enable is needed.

Disabling the cascade removes the `cascade-upstream` outbound and returns the catch-all to `direct`.
Item `10` configures the other side: it turns the current VPS into the foreign node that a cascade
from another server connects to.

## Custom domain and self-steal stub

Self-steal puts nginx with a valid certificate on `127.0.0.1:9444`, and Reality inbounds receive
`serverNames=[domain]` and `dest=127.0.0.1:9444`. For XHTTP, `xhttpSettings.host` is updated as
well.

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
configured and reachable. The automated IP-TLS flow currently supports a public IPv4 address; use
domain mode for an IPv6-only VPS.

If the domain sits behind Cloudflare, `DNS only` is more reliable than `Proxied` for testing: certbot
must reach the VPS over the HTTP challenge on port 80.

The generated `subscription_url` follows the selected public listener: port `443` is omitted from
the HTTPS URL, while `8443` or another public port is included, for example
`https://domain:8443/sub/<token>`. A DNS record alone does not change the saved subscription domain;
re-run the domain setup when changing the endpoint.
