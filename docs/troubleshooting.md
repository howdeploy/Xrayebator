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

The GUI intentionally exposes only a subset of the Bash menu. Use the terminal for bypass, probing,
subscription revocation, HAPP setup, cascade, self-steal and service logs/status.

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

## Quickstart fails with `apt-get install nginx failed`

On a freshly provisioned Ubuntu VPS, `unattended-upgrades` may hold the apt/dpkg lock for ~10 minutes and invoke `dpkg` separately for every package, so a plain flock check slips into the gap between packages. The quickstart path now also waits for an active `unattended-upgrade` worker (12-minute budget) and passes `-o DPkg::Lock::Timeout=180` to `apt-get install`. Rerun the deployment when it reports the lock is still busy, or wait for the queue to finish. `validation/test-apt-lock-race.sh` locks these behaviors.

## An error appeared during installation or use

Copy the full error text from the terminal. For installation failures, include the relevant
`/tmp/xrayebator-*.log` file and the output of `systemctl status xray --no-pager -l`. If the problem is
in Xrayebator code, open an issue.
