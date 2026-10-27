# Recommendations: VPS, domain and DNS

[← Back to README](../README.md) · [Русский](ru/recommendations.md) · [简体中文](zh-CN/recommendations.md)

Sections: [Choosing a VPS](#choosing-a-vps) · [Domain and DNS](#domain-and-dns) · [Cloudflare step by step](#cloudflare-step-by-step) ·
[Route 53 step by step](#route-53-step-by-step) · [Checking the domain](#checking-the-domain) · [Clients](#clients) ·
[What is not here](#what-is-not-here)

---

This document is about the infrastructure around Xrayebator, not about its commands: which server fits,
how to get a domain and how to configure DNS so that the certificate is issued without surprises. Commands
and flags are described in [configuration](configuration.md).

## Choosing a VPS

We deliberately do not recommend hosters: prices, subnets and terms change faster than our releases come
out, and a recommendation with an affiliate link is no longer a recommendation. Below are the criteria that
decide whether a server fits.

### Hard requirements

| Requirement | Why |
|---|---|
| Debian 12/13 or Ubuntu 22.04/24.04 | the only verified matrix; on any other OS `install.sh` refuses to run |
| `systemd` | `xray` unit, `xrayebator-sub.service`, the `expire`/`traffic`/`monitor` timers |
| root or `sudo` | package installation, units, `ufw` rules |
| `x86_64`/`amd64` or `aarch64`/`arm64` | any other architecture is rejected at the first install step |
| a public IPv4 address | the IP-based subscription mode; an IPv6-only server can only use a domain |
| KVM, not OpenVZ/LXC | AmneziaWG is a kernel module built through DKMS; inside a container without kernel access the backend cannot be installed |

A container without `systemd` is rejected right away: a partially configured server is worse than an
unconfigured one.

### Kernel and AmneziaWG

The `amneziawg` module is built through DKMS, so the headers of the running kernel
(`linux-headers-$(uname -r)`) are required. Debian 12 does not install them by default — the backend
installer brings them in, but an exact match is not always available: if the running kernel is older than
the one in the repository, the module is built for the newer kernel and the install returns
`reboot_required: true`. That is not an error but a reboot requirement: run `awg-install` again afterwards.

Practical conclusion: pick a server whose kernel you can update. Hosters that freeze the kernel on an old
LTS release and publish no headers for it turn AmneziaWG into a lottery.

### Resources

| Parameter | Minimal | Medium |
|---|---|---|
| CPU | 1 vCPU | 2 vCPU |
| RAM | 1 GB | 2–4 GB |
| Disk | 10 GB | 15–20 GB |
| Devices | 6–8 | 8–20 |
| Bandwidth | 100 Mbit/s | 300 Mbit/s |

The minimal one is verified live: on 1 vCPU and 1 GB, Xray, nginx, Hysteria 2 and AmneziaWG run at the same
time (production carries 4 profiles and 13 inbounds, using ~224 MB of RAM and 5 GB of disk). The medium one
is a recommendation we have not tested on.

The device counts are guidance from operating experience, not a measurement; the bandwidth row is the
recommended link, and on a narrower one the channel becomes the bottleneck before the CPU does. Xray itself
takes ~54 MB.

### What to check before paying

- IPv4 and SSH are reachable **from your own network**, not only from the hoster panel;
- ports `80` and `443` are not filtered: `nc -vz <ip> 80` and `nc -vz <ip> 443`;
- UDP is not sold as "best effort" — ask support if you need Hysteria 2;
- a snapshot or backup exists: the installation changes `ufw`, `sysctl`, `nginx` and installs packages;
- reinstalling the OS wipes keys, subscription markers and profiles — the server has to be configured
  again from scratch (`xrayebator inspect --json` helps to see what survived);
- SSH on a public VPS is brute-forced constantly. `xrayebator ssh-protect` enables `fail2ban` and `sshd`
  limits automatically on install and deploy; see [security](security.md) for details.

## Domain and DNS

A domain serves three purposes: a subscription over HTTPS with a valid certificate (no client warnings),
self-steal masquerading as your own site, and DNS-01 — the way to issue a certificate when the hoster
filters `80/tcp`.

| Path | What it needs | Cost | Port `80` | `dns01-setup` |
|---|---|---|---|---|
| A. Server by IP | nothing | 0 | needed for an IP certificate | not needed |
| B. Free subdomain | an account at a subdomain provider, an A record | 0 | needed | **not supported** |
| C. Own domain at Cloudflare | a domain, a free Cloudflare zone, an API token | domain is paid, DNS is free | not needed | `--provider cloudflare` |
| D. Own domain at Route 53 | an AWS account with a card, a hosted zone, IAM keys | paid: zone and queries | not needed | `--provider route53` |

`dns01-setup` supports exactly two providers. This is a deliberate limit: we do not install arbitrary
certbot plugins on a user's server. If your DNS provider is neither Cloudflare nor Route 53, paths A and B
work — through `80/tcp`.

### Path A: no domain at all

The subscription is published by IP: `https://<ip>/sub/<token>`, and the certificate is issued for the IP
address. This is the fastest start and it is fully supported — a domain is needed only if you want a
human-readable address, or if `80/tcp` is closed and you are not setting up DNS-01.

### Path B: a free subdomain

Free subdomains are offered by, for example, [DuckDNS](https://www.duckdns.org) and
[FreeDNS](https://freedns.afraid.org). The procedure is the same:

1. sign up and create a subdomain, for example `myvpn` → `myvpn.duckdns.org`;
2. point it at the server IPv4 with an A record (on DuckDNS this is done on the main page or through their
   API);
3. verify: `dig +short myvpn.duckdns.org` must return the server address;
4. use this domain when configuring the subscription — the certificate is issued over http-01, so
   `80/tcp` must be reachable from outside.

A limitation worth knowing in advance: `dns01-setup` will **not** work with such a subdomain — the zone
belongs to the provider, not to you, and no API token can be issued for it.

### Paths C and D: your own domain

An expensive domain is not needed: any accredited registrar and the cheapest domain in a zone you like will
do. A domain can also be registered directly at [Cloudflare Registrar](https://dash.cloudflare.com) — at
cost, without markup; the zone then lands in Cloudflare immediately and the nameserver step is skipped.

Common to both paths:

- the `sub` record (or the apex) points at the server IPv4. Add `AAAA` only if IPv6 on the server actually
  works — otherwise clients receive a dead path;
- DNS is not updated instantly: from a few minutes to an hour, sometimes longer. Do not start certificate
  issuance until `dig +short` returns the expected address;
- in Cloudflare, set **Proxy status: DNS only** for records that point at the server. Proxying breaks
  http-01 and adds a layer between the client and Reality that we do not want.

## Cloudflare step by step

Path C. Everything needed fits into the free Cloudflare plan: you pay only for the domain itself.

1. Create an account: <https://dash.cloudflare.com/sign-up>.
2. **Add a site** → your domain → the **Free** plan → Cloudflare shows you two of its nameservers.
3. Replace the nameservers at the registrar with the ones shown. If DNSSEC was enabled, turn it off at the
   registrar first, otherwise the nameserver change will not go through.
4. Wait for the **Active** status in the Cloudflare panel. Verification:
   `dig +short NS example.com` must show Cloudflare nameservers.
5. **DNS → Records → Add record**: type `A`, name `sub` (or `@` for the apex), the server IPv4,
   **Proxy status — DNS only**.
6. API token: <https://dash.cloudflare.com/profile/api-tokens> → **Create Token** → the **Edit zone DNS**
   template → **Zone Resources**: `Include` → `Specific zone` → your domain → **Continue to summary** →
   **Create Token**. The secret is shown once, store it in a password manager.
7. Verify the token without leaking it into shell history:

   ```bash
   read -rs CF_API_TOKEN && export CF_API_TOKEN
   curl -sS -H "Authorization: Bearer $CF_API_TOKEN" \
     https://api.cloudflare.com/client/v4/user/tokens/verify
   ```

8. Configure the subscription on the server:

   ```bash
   sudo xrayebator dns01-setup --domain sub.example.com --provider cloudflare \
     --token "$CF_API_TOKEN" --email admin@example.com
   ```

9. Check the result: `sudo xrayebator dns01-status` — provider, domain, port, certificate lifetime and
   whether the deploy hook is present.
10. Renewal is handled by the stock `certbot.timer` with the deploy hook; no extra timer is needed.

Useful neighbours:

- `dns01-test` verifies the "domain + token" pair in the staging contour, on its own certificate lineage,
  publishing nothing: `sudo xrayebator dns01-test --domain sub.example.com --provider cloudflare --token "$CF_API_TOKEN"`
- Let's Encrypt has limits: five certificates per exact set of names per 168 hours and five failed
  validations per name per hour. While debugging, add `--staging` to `dns01-setup`/`repair-dns01`,
  otherwise you can block your own issuance for hours.

## Route 53 step by step

Path D. Unlike Cloudflare there is no free tier here: AWS charges for every hosted zone and for queries.
Current numbers are at <https://aws.amazon.com/route53/pricing/>; budget at least the zone cost per month.

1. An AWS account: <https://aws.amazon.com>. A linked card is required.
2. **Route 53 → Hosted zones → Create hosted zone** → your domain → type **Public** → create. AWS shows
   four nameservers.
3. Put those nameservers at the registrar and wait for propagation: `dig +short NS example.com`.
4. **DNS → Records → Create record**: `A`, name `sub` (or empty for the apex), the server IPv4.
5. **IAM → Users → Create user** without console access → **Access key** → save the key pair.
6. Grant the user the minimum — only on the zone you need:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": ["route53:ChangeResourceRecordSets", "route53:ListHostedZones"],
         "Resource": "*"
       },
       {
         "Effect": "Allow",
         "Action": ["route53:GetChange"],
         "Resource": "*"
       }
     ]
   }
   ```

7. Configure the subscription:

   ```bash
   sudo xrayebator dns01-setup --domain sub.example.com --provider route53 \
     --aws-access-key-id AKIA... --aws-secret-access-key ... --email admin@example.com
   ```

8. Check: `sudo xrayebator dns01-status`.

Practice: do not use AWS root keys and do not grant `Route53FullAccess` when the policy above is enough.
Our keys live in the `0600 root` file `/etc/letsencrypt/xrayebator-dns01-aws.ini`, and `uninstall.sh`
removes them — but key rotation is still your responsibility.

## Checking the domain

A short set of checks is worth running before and after certificate issuance.

| Check | Command | Expected |
|---|---|---|
| A record | `dig +short sub.example.com` | the IPv4 of your server |
| NS delegated | `dig +short NS example.com` | Cloudflare or AWS nameservers |
| Port `80` open | `curl -sS -o /dev/null -w '%{http_code}\n' http://sub.example.com/` | any code, but not `000` |
| Subscription answers | `curl -sS -o /dev/null -w '%{http_code}\n' https://sub.example.com/sub/<token>` | `200` |
| DNS-01 state | `sudo xrayebator dns01-status` | provider, domain, certificate lifetime |
| Server state | `sudo xrayebator inspect --json` | subscription mode, profiles, backends |

A `000` from `curl` means there is no connection at all: the port is closed, DNS does not match, or a
proxying layer swallowed the request. This is the first thing to check when a certificate "is not being
issued".

## Clients

The server serves the same set of routes in four formats: the format is selected by the `?target=`
parameter in the subscription link, or by the client User-Agent.

| Subscription format | Who asks for it | What it contains and what it does not |
|---|---|---|
| HAPP (default) | HAPP | every route including PQ; a routing profile and geo data by token |
| base64 for v2ray | v2rayNG, v2rayN (`?target=v2ray`) | PQ routes are hidden: a client without ML-KEM cannot use them |
| Clash/mihomo YAML | mihomo, Stash, FlClash (`?target=clash`) | xhttp only with `?xhttp=1` and mihomo newer than 1.19; PQ is skipped |
| sing-box JSON | sing-box, Karing, Hiddify (`?target=singbox`) | xhttp is not supported; PQ is skipped |

The rule is simple: if a client is not listed in the table, start with the HAPP link — it is the most
compatible. We do not publish or distribute client builds of our own; official pages:
[HAPP](https://www.happ.su), [v2rayN](https://github.com/2dust/v2rayN), [sing-box](https://sing-box.sagernet.org),
[mihomo](https://github.com/MetaCubeX/mihomo).

## What is not here

- **Hoster recommendations and affiliate links.** Not for VPS, not for domains, not for anything else.
  "Verified" hoster lists go stale within weeks, and a paid recommendation stops being a recommendation.
- **Allow-lists of blocked subnets.** Check reachability yourself, from the network where you are going to
  use the server.
- **A promise that the server will be reachable from everywhere.** Some providers block at the level of the
  hoster subnet — that is not fixed by configuring Xray, it is fixed by choosing another hosting or by a
  two-server bridge (see [cascade](configuration.md)).
- **Legal advice.** Which hosting to buy and in which jurisdiction is your decision and your
  responsibility.

If something here diverges from reality, that matters more than the accuracy of the text: open an issue.
