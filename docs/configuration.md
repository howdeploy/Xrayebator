# Configuration

[← Back to README](../README.md) · [Русский](ru/configuration.md) · [简体中文](zh-CN/configuration.md)

Sections: [Prerequisites](#prerequisites-and-tested-systems) · [Environment variables](#installer-environment-variables) ·
[Firewall and host networking](#firewall-and-host-networking) · [Main menu](#main-menu) ·
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
| `7` | Bypass routing: send selected domains (banks, marketplaces, Steam…) direct instead of through the tunnel |
| `8` | Cascade and upstream nodes |
| `9` | Custom domain and self-steal stub |
| `10` | Set up an outbound server so another VPS can use this server as a foreign cascade node |
| `11` | Hysteria 2 backend: install/status/client link/uninstall (fast UDP transport) |
| `12` | AmneziaWG 2.0 backend: install/status/client conf/uninstall (system VPN) |
| `13` | Status of all multi-protocol backends |
| `0` | Exit |

Actions are numbered consecutively from `1` to `13`; `0` exits the program. SNI and port are
shared inbound settings, so changing either can affect other profiles on that port. The fingerprint
is a client-side profile/route setting; changing it does not restart Xray or alter other routes.

## Commands

| Command | Effect |
|---|---|
| `sudo xrayebator` | Open the interactive menu |
| `sudo xrayebator update` | Update only the Xray-core binary |
| `sudo xrayebator update <branch>` | Self-update the manager from the canonical raw repository branch, continue with the new script, then update Xray-core; the branch is pinned in `.current_branch` for later GUI updates |
| `sudo xrayebator probe-test` | Check SNI reachability from the VPS before switching |
| `sudo xrayebator quickstart --email <address>` | One-shot deploy path used by the desktop GUI: runs the broad setup/migration path, provisions the current IP-TLS endpoint on `8443`, and creates a standard HAPP profile with `schema_version: 3` and 7 routes; emits JSON with `subscription_url` |
| `sudo xrayebator quickstart --without-email` | Same new-server path without an ACME contact email; Certbot uses `--register-unsafely-without-email`, so no renewal notices or email-based account recovery are available |
| `sudo xrayebator inspect --json` | Read-only GUI import probe: reports manager, Xray, profile and subscription markers without installing, migrating or changing services/configuration |
| `sudo xrayebator happ-setup` | Reduced existing-install HAPP path: ensures the subscription service and a usable multi-route profile, but does not replace the endpoint prerequisite; when `.subscription_domain` or `.subscription_port` is missing, it verifies a real public TLS endpoint before writing markers and otherwise fails |
| `quickstart` http_tls mode | If Let's Encrypt cannot validate the IP over http-01 (`Connection reset by peer` from validation hosts — usually the hoster filters port 80 for foreign sources), the deploy does not fail: the subscription is published over HTTP (port 8080 outbound, token gate and 404 without token preserved), a self-signed certificate is generated for future backends, and the result JSON carries `degraded:true`, `tls_mode:"http_tls"` and the Certbot reason. The GUI stores the server as *Partially configured* and loads keys over SSH from the loopback handler; the ACME challenge location on port 80 stays in place — rerunning quickstart after the port is unblocked issues the LE certificate and switches the subscription back to HTTPS |
| `sudo xrayebator profiles` | Print all server profiles as a JSON array for the desktop GUI Server Settings page; expiry includes both epoch seconds (`expire`) for enforcement and the server-local calendar date (`expire_date`) for display, so clients in another timezone still see the selected date |
| `sudo xrayebator profile-create --name NAME [--transport tcp\|tcp-utls\|tcp-xudp\|tcp-mux\|grpc\|xhttp] [--port P] [--count N] [--expire DATE]` | Create one or more profiles non-interactively; `--expire` accepts `YYYY-MM-DD[ HH:MM]`, epoch seconds or 13-digit milliseconds. A date without time is inclusive through `23:59:59` in the server's local timezone; an explicit time uses that server-local time. Past expiries are rejected; existing names are never overwritten — they are reported in `errors` (the GUI also pre-checks a name collision before creating, since deletion is per-profile and unique names keep it precise); prints `{"ok":true,"names":[...],"errors":[...]}` |
| `sudo xrayebator profile-delete --name NAME` | Delete a profile non-interactively; the deleted profile's backend grants are revoked immediately (the AWG peer is dropped from `awg0.conf`, the Hysteria password from `server.yaml` — no orphaned credentials) and the name is free for reuse; prints `{"ok":true,"name":"..."}` |
| `sudo xrayebator profile-revoke --name NAME [--full]` | Reissue the subscription link: new `sub_token`; with `--full` also a new uuid in every inbound of the profile (already-downloaded configs are cut off); prints JSON |
| `sudo xrayebator profile-expire --name NAME --expire DATE\|epoch\|none` | Set, extend or remove a profile expiry; a date without time is inclusive through `23:59:59` in the server's local timezone, while an explicit time is used as given in that timezone; applied immediately (a passed expiry removes the client, an extension restores it); prints JSON |
| `sudo xrayebator expire-check` | Apply every due expiry in one batch; idempotent and never restarts Xray without changes. Driven by the `xrayebator-expire.timer` unit every 10 minutes |
| `sudo xrayebator fp-change --name NAME [--route R] --fp FINGERPRINT` | Change the client fingerprint for one profile route; prints JSON |
| `sudo xrayebator sni-change --name NAME [--route R] --sni SNI` | Change the shared inbound SNI and synchronise profiles on that port; prints JSON |
| `sudo xrayebator sni-list` | Print SNI candidates grouped by category for the GUI SNI dialog; prints JSON. The first uncommented line of `sni_list.txt` is the default SNI for new profiles (`www.cloudflare.com`) |
| `sudo xrayebator port-change --name NAME [--route R] --port PORT\|random` | Change the inbound port, firewall and subscription metadata; reconnect the client; prints JSON |
| `sudo xrayebator bypass list` | Print current bypass domain rules as JSON |
| `sudo xrayebator bypass add --domain D` | Add a domain to bypass rules |
| `sudo xrayebator bypass remove --domain D` | Remove a domain from bypass rules |
| `sudo xrayebator bypass reset` | Clear all custom bypass rules |
| `sudo xrayebator bypass bundle [--group a,b,c]` | Apply the default bypass groups; without `--group`, apply all groups |
| `sudo xrayebator backend-status` | Print the multi-protocol backend registry status as JSON (`{"ok":true,"backends":{…}}`) |
| `sudo xrayebator hysteria2-install [--port P] [--grant-all]` | Install the Hysteria 2 UDP backend: binary from `HyNetworks/hysteria` releases (SHA-256 verified), dedicated `hysteria` service user, own systemd unit with `CAP_NET_BIND_SERVICE`, QUIC sysctl buffers, adaptive TLS (subscription Let's Encrypt cert with a renewal deploy-hook, otherwise self-signed); default UDP port 443; prints JSON (`already: true` when installed) |
| `sudo xrayebator hysteria2-uninstall` | Remove the Hysteria 2 backend (service, config, certs, firewall rule); prints JSON |
| `sudo xrayebator hysteria2-status` | Hysteria 2 backend status as JSON |
| `sudo xrayebator hysteria2-grant --name N` | Issue a per-profile Hysteria 2 credential (stored in the profile's `.backends.hysteria2`); the server config is regenerated from all profiles; prints JSON |
| `sudo xrayebator hysteria2-subbody --on\|--off` | Kill switch for the `hysteria2://` lines in both subscription bodies: the flag lives in the backend registry and the handler re-reads it on every request, no service restart; prints JSON |
| `sudo xrayebator hysteria2-link --name N` | Print the `hysteria2://` link of a profile with a grant as JSON `{ok, name, link}` (naming mirrors the VLESS routes, with the country flag) |
| `sudo xrayebator awg-install [--grant-all]` | Install the AmneziaWG 2.0 system-VPN backend: kernel module via DKMS (PPA `amnezia/ppa`, source-build fallback), `awg0` interface with a random high UDP port, junk parameters matching the Amnezia defaults, `ip_forward` + MASQUERADE; prints JSON |
| `sudo xrayebator awg-uninstall` | Remove the AmneziaWG backend (interface, config, symlink, firewall rule; packages/module stay in the system); prints JSON |
| `sudo xrayebator awg-status` | AmneziaWG backend status as JSON |
| `sudo xrayebator awg-grant --name N` | Issue a per-profile peer (keypair + preshared key + `10.8.1.x` address in the profile's `.backends.awg`); `awg0.conf` is regenerated; prints JSON |
| `sudo xrayebator awg-conf --name N` | Print the client `.conf` for a profile peer as JSON `{ok, name, conf}` — full-tunnel AllowedIPs, server junk parameters, endpoint; import into the AmneziaWG/AmneziaVPN client |
| `sudo xrayebator awg-31 --on\|--off` | Toggle the AWG 3.1 config format (`HeaderProtectionKey`, `RandomTrailers`, `S3`/`S4`); 3.1 is on by default for new installs, the toggle upgrades legacy server params in place, warns that every issued client `.conf` must be re-downloaded (AmneziaVPN ≥ 5.0.1.5) and regenerates the interface with rollback |
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

If Let's Encrypt cannot validate the IP over http-01 — the deployment log shows
`Connection reset by peer` for the challenge fetch, typically because the hoster
filters port 80 for foreign sources — quickstart does not fail: it degrades to
`http_tls` mode. The subscription handler stays loopback-only: there is **no
public subscription URL at all** — the GUI loads keys over SSH from
`http://127.0.0.1:8080/sub/<token>` on the server itself. A self-signed
certificate is generated for future backends, and the result JSON carries
`degraded:true`, `tls_mode:"http_tls"` and the Certbot reason. The server stays
in the panel as *Partially configured* with a degraded badge, and the ACME
challenge location on port 80 stays in place — rerunning quickstart
after the hoster unblocks port 80 issues the Let's Encrypt certificate and
switches the subscription back to HTTPS (the path is idempotent).

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
SNI, fingerprint, port, update and uninstall operations plus the multi-protocol backend panel:
backend install/uninstall and status, a per-profile keys dialog (Hysteria 2 link + QR, AmneziaWG
client conf + QR), the subscription kill switch for `hysteria2://` lines and the AWG 3.1 toggle.
`probe-test`, HAPP setup, cascade,
self-steal, the interactive menu and service diagnostics remain server-side operations.

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

Bypass routing sends selected domains around the tunnel: matched traffic goes `direct`, everything
else keeps using the VPN. The `domain -> direct` rules sit above the catch-all, so they keep working with the cascade
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

## Multi-protocol backends

Beyond Xray Reality, one VPS can run additional transports managed from the same CLI/menu. All
backend state lives in a neutral root that does not touch `/usr/local/etc/xray/`:

```text
/usr/local/etc/xrayebator/
├── backends.json                 # registry: per-backend installed/version/port/flags (644, no secrets)
└── backends/
    ├── hysteria2/                # server.yaml, certs, placeholder credential
    └── awg/                      # awg0.conf, server-params.json (0600)
```

Per-profile credentials are stored in the profile JSON itself (`.backends.hysteria2`,
`.backends.awg`) — the profile is the single source of truth, and backend server configs are always
regenerated from profiles. Profile lifecycle events (create/delete/revoke/expire/restore) propagate
to every installed backend automatically: revoking a profile rotates its Hysteria password and AWG
peer keys; expiring it removes the grant from both server configs; extending restores both.

### Hysteria 2 (fast UDP)

`hysteria2-install` downloads the binary from the official `HyNetworks/hysteria` releases (SHA-256
verified), creates the `hysteria` service user and a dedicated systemd unit, and listens on UDP 443
by default (QUIC next to the TCP 443 Reality inbound). TLS is adaptive: when the subscription
endpoint already has a Let's Encrypt certificate it is reused (clients connect with `insecure=0`),
otherwise a self-signed cert is generated (`insecure=1`). While no profile has a grant the auth map
carries a `_xrayebator_placeholder` user — Hysteria rejects an empty userpass map. Client links look
like `hysteria2://user:pass@host:port/?sni=…&insecure=0|1#name` and are appended to both
subscription bodies (HAPP and generic); the registry flag `sub_body` is the kill switch if a client
parser objects.

### AmneziaWG 2.0 (system VPN)

`awg-install` builds the kernel module via DKMS (primary path: the `amnezia/ppa` PPA; fallback: a
source build that needs the full `linux-source` tree on kernels ≥ 5.6) and brings up the `awg0`
interface through `awg-quick@awg0` with a random high UDP port, subnet `10.8.1.0/24`, `ip_forward`
and MASQUERADE on the default-route interface. Junk parameters mirror the Amnezia defaults — the
dialect every official AmneziaVPN client (phone and desktop) applies reliably: `Jc` 5, `Jmin` 10,
`Jmax` 50, `H1`–`H4` = 1..4 (the WireGuard magic headers), `S1`/`S2` random 12..150 and `S3`/`S4`
random 12..64 (all unique, `S1+56 ≠ S2`). Each profile peer gets a keypair, a preshared key and the
first free address; the
client `.conf` (menu item 12 or `awg-conf --name N`) carries full-tunnel `AllowedIPs` and the
server's junk parameters, and starts with a self-describing header noting that the profile runs
through AmneziaVPN/AmneziaWG, not V2Ray clients (HAPP). In the desktop GUI the same keys are
delivered per profile via the «Ключи» button in Server Settings: the Hysteria 2 link and the AWG
`.conf` as text with QR codes and one-click grant issuance. The «QR · AmneziaVPN» code carries the
config in the app-native `vpn://` shape (`amnezia-awg2` container, server-side junk fields,
`protocol_version`, compressed payload) — a raw `.conf` pasted into AmneziaVPN does not reach its
tunnel intact, so that code is the recommended delivery for this app; the plain QR stays for the
standalone AmneziaWG client. Peer changes restart the interface with
rollback — a brief tunnel blip for all peers, acceptable because grants and revokes are rare.

### AWG 2.0 vs 3.x — and why 3.1 matters against DPI/ТСПУ

Per the upstream protocol split, AmneziaWG parameters divide into two groups:

| Must match byte-for-byte on server and client | Local per side |
|---|---|
| `S1`–`S4`, `H1`–`H4` | `PersistentKeepalive` (recommended 22–30) |
| 3.0: `HeaderProtectionKey` | 3.0: `ContentPaddingAddition`, `Rekey*`, `Reject*`, `Keepalive*`, `MaxHandshakeAttempts` (integer or `"a-b"` range) |
| 3.1: `RandomTrailers` | 3.1: `DisableCookies` |

Xrayebator implements the AWG 3.1 feature set: junk parameters plus `S1`–`S4` (≥ 12), a randomly
generated `HeaderProtectionKey` shared between the server and every client `.conf`, and
`RandomTrailers = on`. `DisableCookies` is available but off by default (it trades away the
built-in anti-amplification defence). New installs get 3.1 immediately; for installs made before
the 3.1 stage, menu item 12 → «Режим AWG 3.1» or `awg-31 --on|--off` generates the missing keys,
switches the config format and regenerates the interface. The migration caveat is unchanged, and
it is exactly what matters against Russian DPI/ТСПУ analysis: plain WireGuard handshakes have
fixed packet lengths and plaintext header type bytes, so passive classification works without
inspecting payloads — AWG 3.0 encrypts the header, 3.1 removes the fixed-length signature. The
3.1 keys live in the must-match group, so after a switch **every previously issued client `.conf`
must be re-downloaded**, and clients need AmneziaVPN ≥ 5.0.1.5 — older apps refuse to import the
config at all. Verify by `awg show`: no `latest handshake` means the must-match group disagrees; a
handshake without traffic points to `awg-quick`/routing/firewall instead.

### HAPP client routing profile

The subscription endpoint returns a client-side routing profile to HAPP in the `routing:` response
header. The managed default, `xrayebator-default`, sets `GlobalProxy: "true"`, so every destination
except private IPv4 ranges is tunnelled.

That is a different knob from [Bypass routing](#bypass-routing). Bypass changes where **the server**
sends a request; the client still tunnels it, so the destination sees the VPS address. On a node
without a cascade the catch-all outbound is already `direct`, so bypass cannot change what a Russian
site sees. Keeping domestic traffic out of the tunnel is only possible in the client profile.

The profile travels to the client in a response header, so a large `DirectSites` list can outgrow
nginx's default 4k proxy buffer. The generated subscription vhost raises it (`proxy_buffer_size 32k`)
— in the domain-mode `location /sub/` and in the IP-mode (quickstart) vhost alike; if you run your own
reverse proxy in front of the subscription, set `proxy_buffer_size` there too,
otherwise nginx answers 502 and logs `upstream sent too big header`.

### Generating it from the menu

`HAPP subscription → 7) Маршрутизация клиента` writes a ready split profile built from the same
bundles the server-side bypass uses. It keeps `GlobalProxy: "true"`, so anything unknown still
tunnels, and moves the Russian bundles plus `geoip:ru` into `DirectSites` and `DirectIp`. The
previous override is backed up next to the file, and removing the override restores the managed
default. The profile uses placeholders (`{{GEOIP_URL}}`, `{{GEOSITE_URL}}`, `{{LAST_UPDATED}}`)
resolved per subscriber at request time — no token is embedded in the shared file.

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

### Placeholders

The override is read per request, so three values can be left for the server to fill in:

| Placeholder | Replaced with |
|---|---|
| `{{GEOIP_URL}}` | `<base url>/sub/<token>/geoip.dat` for the requesting subscriber |
| `{{GEOSITE_URL}}` | `<base url>/sub/<token>/geosite.dat` for the requesting subscriber |
| `{{LAST_UPDATED}}` | newest mtime among `xrayebator` and the two geo databases |

Substitution runs before schema validation, so an unresolved placeholder fails the `https://` check
and the managed default is served instead of a broken profile. `{{LAST_UPDATED}}` also removes the
need to bump the value by hand after editing the geo databases.

Three things are easy to get wrong:

- **Telegram travels to IP addresses, not domains.** Domain rules never match it. Take the ranges
  from <https://core.telegram.org/resources/cidr.txt> instead of writing them from memory; the list
  changes, and a missing range silently degrades media downloads while chat still works.
- **`LastUpdated` must grow.** HAPP re-imports a profile only when the value is higher than the one
  it already stored.
- **Geo databases must be reachable by the client.** The managed default points at
  `/sub/<token>/geoip.dat`, which is per-subscriber. The placeholders above resolve this; without
  them, host the databases somewhere every client can fetch them.
- **The country in the base URL can be wrong.** ASN geolocation differs between providers: ipinfo.io
  and ipwho.is/ip-api may place the same range in different countries (e.g. NODE HOST LIMITED:
  Finland vs Germany/Frankfurt). The managed HAPP profile sends the client to fetch geo databases
  through `{{GEOIP_URL}}`/`{{GEOSITE_URL}}` of the same subscription, so under the http_tls fallback
  (public subscription unavailable) a client without pre-cached databases cannot download them and
  HAPP shows "no data". Fix by hand-writing `/usr/local/etc/xray/.server_country`
  (`code|country|city`) and importing keys over SSH, or by restoring the public subscription.

While a client downloads new geo databases the previous profile keeps running, so a failed download
leaves routing unchanged rather than broken.

### One key — how many devices?

VLESS, Hysteria 2 and AmneziaWG have different multi-device semantics:

- **VLESS (subscription)** — the subscription hands out the profile's UUIDs, and UUIDs are not
  exclusive: any number of devices can pull the same subscription in HAPP and connect
  simultaneously, each opening its own Reality tunnels per route. The routes are transports, not
  device slots.
- **Hysteria 2** — auth is per connection (`userpass`), and the server does not lock a credential
  to one session: **one `hysteria2://` link works from unlimited devices simultaneously**, each
  with its own QUIC session. They share the server's bandwidth, nothing else.
- **AmneziaWG** — cryptokey routing binds a peer to its keypair, and the interface keeps a single
  endpoint per peer (last authenticated sender wins). **One key = one device reliably.** Two
  devices on the same `.conf` fight over the endpoint and reconnect in turns; behind one NAT it
  limps along, across networks it breaks. A second device needs its own profile/key — it gets its
  own peer and `10.8.1.x` address.
- **nginx** serves only the subscription endpoint on 8443 (key delivery). Hysteria (UDP 443) and
  AmneziaWG (their UDP port) bypass nginx entirely, and nothing load-balances between the
  backends — they are independent services on separate ports; every device simply adds its own
  session to whichever protocol it uses.

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
