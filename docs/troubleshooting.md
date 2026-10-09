# Troubleshooting

[← Back to README](../README.md) · [Русский](ru/troubleshooting.md) · [简体中文](zh-CN/troubleshooting.md)

---

## HAPP does not refresh the subscription

The JSON emitted by `quickstart` contains `subscription_url`. It is built from the saved subscription
base, so the host and port in the URL are intentional. For a public TLS deployment, check the nginx
endpoint; local-only mode does not require nginx to be present or running:

```text
https://your-domain/sub/<token>        # public TLS on 443
https://your-domain:8443/sub/<token>   # public TLS on 8443
http://127.0.0.1:8080/sub/<token>      # local-only debug mode
```

Check the actual URL from the VPS, preserving its port:

```bash
curl -vkI https://your-domain[:port]/sub/
curl -vk https://your-domain[:port]/sub/<token>
```

`/sub/` without a token must return `404`. The full token URL must return `200` and a body with
`vless://` links. Then check the subscription service:

```bash
systemctl status xrayebator-sub --no-pager -l
```

For public TLS only, also check nginx and the public listener:

```bash
systemctl status nginx --no-pager -l
```

If the URL has the wrong host or port, inspect the subscription mode and rerun the corresponding
IP-TLS or domain setup; adding a DNS record alone does not rewrite the saved endpoint markers.

## The URL shows 127.0.0.1

Local-only mode is enabled; it is for debugging or an SSH tunnel only. For a phone, switch to public
TLS by IPv4 or by domain in the HAPP subscription menu. A local URL must not be copied to an external
client.

## IP-TLS does not work on an IPv6-only VPS

The automated IP certificate flow currently requires a public IPv4 address. It refuses to emit an
IPv6 IP-TLS endpoint because that path is not automated. Configure a domain with a reachable A/AAAA
record and use the domain TLS mode instead.

## The URL shows an IP even though a domain was added

A DNS record is not the stored subscription configuration. Enable the domain mode again:
`HAPP subscription → public TLS by domain`. Confirm that the resulting `subscription_url` uses the
domain and that it includes `:8443` when the public listener is not on 443.

## `happ-setup` refuses to return a public URL

This is a safety check, not a missing URL formatting option. Verification runs when
`.subscription_domain` or `.subscription_port` is missing: `happ-setup` will not fabricate markers
or a public endpoint and instead requires the subscription vhost, certificate and active HTTPS
listener to be verified. If both markers already exist, they are reused and are not necessarily
reverified; stale saved markers still require operator verification or a rerun of the appropriate
setup path.

For a new server, use the broad path `quickstart --email <address>` or complete the HAPP IP/domain
setup from the terminal menu first. `happ-setup` is the reduced existing-install recovery path and
still needs that endpoint prerequisite. For an existing setup with missing markers, the verifier is
specifically oriented to the product's IP-TLS listener/certificate on `8443`; a domain/443 setup should
be checked through its own saved endpoint and rerun through the appropriate setup path. Inspect:

```bash
sudo systemctl status xrayebator-sub --no-pager -l
sudo journalctl -u xrayebator-sub -n 80 --no-pager
```

For public TLS only, also inspect nginx:

```bash
sudo systemctl status nginx --no-pager -l
```

Fix the certificate or listener, then run `sudo xrayebator happ-setup` again. Do not work around the
error by hand-writing a plausible public URL.

## HAPP shows six routes although the profile has seven

That is expected for a newly provisioned standard managed HAPP profile. Its JSON uses
`schema_version: 3` and should contain seven live `routes[]`, including `xhttp-legacy` and
`xhttp-pq`; the published VLESS list contains six entries because the PQ-XHTTP route is retained
for the raw/profile path rather than the normal HAPP list.

The setup helper can reuse an existing profile meeting the seven-live-route minimum, even if it lacks
those standard labels or schema. Migrations do not retrofit missing routes into that existing
profile. Inspect the actual JSON and re-provision/create a managed profile through the menu or
`quickstart` when the required routes are absent.

Verify the profile and live ports:

```bash
jq -r '.routes[] | [.label,.transport,.port,(.pq_enabled // false)] | @tsv' \
  /usr/local/etc/xray/profiles/<profile>.json
```

The last column is `pq_enabled`, not a health status. `false` is expected for every non-PQ route;
`true` should appear only for `xhttp-pq`. If `xhttp-legacy` is missing, re-provision/create the managed multi-route profile through the menu or
`quickstart`; pending migrations do not add routes to an existing profile. Then refresh the subscription.

## XHTTP does not work in HAPP

The HAPP-compatible XHTTP candidate is `xhttp-legacy`, not the PQ route. After an update, inspect the
profile first. The legacy-route migration does not retrofit routes into an existing profile; if the route
is missing, re-provision/create the managed multi-route profile through the menu or `quickstart`, then
force a subscription refresh in HAPP. Confirm that the route exists in the profile and that its port
exists in the live configuration.

## v2rayNG connects intermittently

`v2rayNG` is not the primary HAPP client. It receives a v2ray-compatible body, but the routes still
depend on transport support and the Xray-core version bundled in the client. Test routes one by one:
there is no universal best-to-worst order.

## The connection died after changing SNI, port or fingerprint

Refresh the subscription in the client or fetch the raw route again. SNI and port are shared inbound
settings, so changing either can affect every profile using that port and normally requires a client
reconnect. Fingerprint is different: it is client-side per selected profile/route, does not restart
Xray and does not alter other routes. The server-side subscription changes immediately, but HAPP
still needs a forced refresh or its next automatic one.

## The subscription returns 410 even though the profile looks alive

The profile is switched off by its expiry: the profile JSON carries `.expire_disabled: true`, or
`.expire` (epoch seconds) is already in the past. Enforcement is done by the `xrayebator-expire.timer`
systemd unit (every 10 minutes, `xrayebator expire-check`): it removes the client from the inbounds,
so even an already-downloaded link cannot connect, and the subscription answers `410 Gone` with the
body `Profile expired or disabled`. A date-only expiry (for example, September 30) includes the
whole selected day and ends at `23:59:59` in the server's local timezone; explicit CLI times use
that same timezone. Extend or clear the date:

```bash
sudo xrayebator profile-expire --name NAME --expire 2026-12-31   # extend
sudo xrayebator profile-expire --name NAME --expire none         # make unlimited
```

Renewal restores the very same client (same uuid), so devices do not need to re-import the
subscription. In the GUI the same action lives behind the “Expiry” button on the profile card.

## Old profiles exist on the server but do not work

If the profile JSON points at ports that no longer exist in `config.json`, the profile is stale.
A profile with no live routes returns `410 Gone`; a partially stale multi-route profile can still
return its remaining live routes with `200`. Recreate the profile or repair the live inbound through
the terminal menu; do not publish a link that points to a dead port.

## The client cannot connect

Causes in order:

1. HAPP is outdated — update to version `3.3.6` or newer, fully quit all old HAPP processes, start
   exactly one current instance and refresh the subscription.
2. A green route ping does not prove the main TUN works: HAPP checks routes with a separate temporary
   Xray-core. On Linux run `ss -lntp | grep ':10808'`; empty output means the main core is not
   listening, so fully restart HAPP.
3. The client does not support the transport — start with the subscription URL or TCP routes.
4. The SNI is unsuitable — check it with `sudo xrayebator probe-test` and replace it.
5. The provider blocks the port — change the profile port.
6. The fingerprint is detected — try `firefox` instead of `chrome`.
7. The subscription is stale — confirm the route exists in the live `config.json`.

Xrayebator 3.0 also removes the legacy project-installed UDP/443 block once. That rule could break
Telegram while TCP route probes remained green. Operator routing rules with extra selectors are
preserved.

Keep 2–4 profiles ready so you can switch in an emergency.

## The GUI update did not perform the full project update

Server Settings in the Electron GUI invokes `xrayebator update <branch>`: it self-updates the manager
from the canonical raw branch and then updates Xray-core. It is not the same as
`xrayebator-update [branch]`, which is the full project lifecycle updater. With no branch,
`xrayebator-update` displays `.current_branch` and opens the interactive selector; it does not
silently use that marker. Run the latter from an SSH terminal when you need the broader lifecycle
sequence, and verify Xray, DNS and the subscription endpoint/service afterwards.

The GUI intentionally exposes only a subset of the Bash menu. Use the terminal for `probe-test`,
HAPP setup, cascade, self-steal and service logs/status; profile expiry dates and subscription
revocation are handled in Server settings, while bypass stays a terminal/CLI operation.

## The Electron unit test fails on Windows

`tests/unit/shell-command.test.ts` deliberately invokes POSIX `/bin/sh`. Native Windows does not
provide that path, so this one shell-specific test can fail locally even when the TypeScript code is
valid. Run the full Electron unit suite on Linux or in the Ubuntu CI job; Linux is the source of truth
for this POSIX behavior. The active Electron release workflow also runs its unit tests on Ubuntu
before packaging the Windows, macOS and Linux builds.

## I got kicked off the server while configuring it

Connecting to your own VPN and then changing things on the server can drop the SSH session. The
simplest fix is to reach the server through a path other than your own route. A keep-alive helps too:

```bash
sudo nano /etc/ssh/sshd_config
```

```text
ClientAliveInterval 60
ClientAliveCountMax 120
TCPKeepAlive yes
```

```bash
sudo systemctl restart sshd
```

## The whole internet became unreachable

Check DNS on the client. DNS breaks first when providers block VPNs. Keep a list of alternative
subscription links on the client. On desktop clients, check whether TUN mode is required for system
proxying.

## How many users can connect

The interface imposes no hard profile limit. Real capacity is bound by CPU, RAM, VPS bandwidth, route
count and provider limits. Grow the user count gradually and watch the load.

Multiple profiles can be used at once: different subscriptions, SNIs, ports and routes give more
options for bypassing blocks, but they share the same VPS resources.

## Hysteria 2 service does not start

Read the reason first — the install rolls its artifacts back, so reproduce the state:

```bash
journalctl -u hysteria-server.service --no-pager | tail -20
```

Known failure modes, all fixed in the generator but relevant when hand-editing configs:

- `invalid config: auth.userpass: empty auth userpass` — the auth map key is `userpass`, **not**
  `users`, and an empty map is rejected. The generator always renders at least the
  `_xrayebator_placeholder` user while no profile has a grant; if you hand-edit `server.yaml`, keep
  a non-empty map under `userpass:`.
- `Changing to the requested working directory failed: Permission denied` — the backend directory
  must be `root:hysteria 0750`; a `chmod` without the matching `chown` keeps it `root:root` and the
  unit cannot enter it.
- Certificate unreadable — in `le` mode the certificates are copies owned `root:hysteria 0640`; the
  renewal deploy-hook refreshes them.

After fixing, the clean path is `hysteria2-uninstall` followed by a fresh `hysteria2-install`.

## AWG: interface is up but there is no `latest handshake`

AmneziaWG reports parameter mismatches by silence: the peer simply never appears with a handshake.
Check the must-match group — these must be identical on the server and in every client `.conf`:

- `S1`–`S4` (≥ 12 for 3.x engines), `H1`–`H4`;
- any 3.x keys present on the other side: `HeaderProtectionKey` (3.0) and `RandomTrailers` (3.1)
  must match byte-for-byte. Xrayebator emits them only in 3.1 mode (`awg-31 --on`, on by default
  for new installs); a mismatch usually means the client `.conf` predates a 3.1 switch —
  re-download it — or was mixed with a hand-made or third-party one;
- the client application version: `RandomTrailers`-era configs need AmneziaVPN ≥ 5.0.1.5; older
  clients may refuse to import the config entirely.

Then split the debug zones: `awg show awg0` on the server — if the peer is listed with a handshake
but no traffic passes, the problem is in the `awg-quick`/routing/firewall zone (`ip_forward`,
MASQUERADE interface), not in the protocol parameters.

Before blaming the parameters, verify the network path itself. The AWG socket lives in kernel
space, so the UDP port is invisible to `ss`/`netstat` — the only way to see anything is a capture
on the server while the client tries to connect:

```bash
tcpdump -l -ni <iface> 'udp port <port>'
```

Nothing captured → the packets never arrive: carrier/DPI filtering (a typical RU pattern is
Hysteria 2 on UDP 443 passing while a high random UDP port is silently dropped). The capture shows
packets but `awg show` still reports no handshake → the client is sending garbage: re-issue the
`.conf`, check the app version (3.1 params need AmneziaVPN ≥ 5.0.1.5), or temporarily run
`awg-31 --off` and re-import to test 2.0 compatibility. Note that `tcpdump` without `-l`
block-buffers its output when redirected to a file — early packets may not appear until the buffer
flushes.

## AmneziaVPN (the full app) fails with error 1000, the standalone client works

`error 1000` is the app's generic `AndroidError`; the phone-side log then shows
`VPN config format error: No value for client_ip`. The app's native pipeline only accepts its own
export shape — the `amnezia-awg2` container, server-side junk fields next to `last_config`,
`protocol_version` and a compressed (`qCompress`) payload. A raw `.conf` (or a bare `vpn://`
without those fields) is stored, but the client part never reaches the tunnel. The desktop GUI's
«QR · AmneziaVPN» code builds exactly that shape — use it instead of pasting a `.conf`. The junk
group Xrayebator installs mirrors the Amnezia defaults (`Jc` 5, `Jmin` 10, `Jmax` 50,
`H1`–`H4` = 1..4) precisely because the app's go-tunnel applies custom junk incompletely.

## AWG install fails

- The primary path is the `amnezia/ppa` PPA; on distribution series without PPA builds Xrayebator
  falls back to a source build. For kernels ≥ 5.6 that build needs the **full** `linux-source`
  package — kernel headers alone are not enough (the module build links the whole source tree).
- Verify after install: `lsmod | grep amneziawg` shows the module, `awg --version` answers.
- The `awg-quick@awg0` unit reads `/etc/amnezia/amneziawg/awg0.conf` — Xrayebator maintains it as a
  symlink to `/usr/local/etc/xrayebator/backends/awg/awg0.conf`. Deleting the symlink breaks the
  unit while the backend config remains valid.
- On uninstall the packages and the kernel module deliberately stay in the system; only the
  interface, config, symlink and firewall rule are removed.

## The subscription has no `hysteria2://` line

`hysteria2://` links are appended to both subscription bodies only when all of these hold:

1. the Hysteria 2 backend is installed (`xrayebator hysteria2-status`);
2. the profile has a grant (`profiles` JSON → `.backends.hysteria2.password`);
3. the registry flag `sub_body` is `true` (the kill switch — flip it in `backends.json`, the
   handler re-reads the registry on every request, no service restart needed).

An expired or disabled profile never gets the line; a revoked profile gets a new credential on the
next subscription fetch. A `404` on a previously working token URL after a revoke is expected — the
token itself was rotated.

## Quickstart fails with `apt-get install nginx failed`

On a freshly provisioned Ubuntu VPS, `unattended-upgrades` may hold the apt/dpkg lock for ~10 minutes and invoke `dpkg` separately for every package, so a plain flock check slips into the gap between packages. The quickstart path now also waits for an active `unattended-upgrade` worker (12-minute budget) and passes `-o DPkg::Lock::Timeout=180` to `apt-get install`. Rerun the deployment when it reports the lock is still busy, or wait for the queue to finish. `validation/test-apt-lock-race.sh` locks these behaviors.

## Quickstart reports `certbot failed: ... Connection reset by peer` but still succeeds

Let's Encrypt could not fetch the http-01 challenge — most often the hoster's
network filters port 80 for foreign sources (verified with tcpdump and
multi-node probes: our firewall and nginx are fine, the reset happens upstream).
Since this degradation the deploy finishes in `http_tls` fallback mode: the
result JSON carries `degraded:true` and `tls_mode:"http_tls"`, the GUI shows the
server as *Partially configured*, and keys are loaded over SSH. There is **no
public subscription URL at all** in this mode — no leakable HTTP link exists.
To restore
HTTPS, ask the hoster to unblock port 80 for Let's Encrypt validation ranges
(or point a domain at the server and use the domain TLS mode), then re-run the
deploy; the run is idempotent and issues the LE certificate when the challenge
becomes reachable. `validation/test-quickstart-tls-fallback.sh` locks the
fallback structure.

## An error appeared during installation or use

Copy the full error text from the terminal. For installation failures, include the relevant
`/tmp/xrayebator-*.log` file and the output of `systemctl status xray --no-pager -l`. If the problem is
in Xrayebator code, open an issue.
