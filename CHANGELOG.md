# Changelog

User-facing Xrayebator changes. The server manager and Electron application are published from the canonical `howdeploy/Xrayebator` repository.

## [Unreleased]

### Added

- Optional email during deployment: `quickstart --without-email` registers Certbot with `--register-unsafely-without-email` instead of substituting a fake address; the GUI offers both modes and explains that renewal notices and ACME account recovery are unavailable without an email.
- Separate "deploy a new server" and "connect an existing server" flows. Import is strictly read-only (`xrayebator inspect --json`), recognizes Xrayebator installations only, and imports a partially configured server with honest component statuses.
- SSH login password is stored in the operating-system keychain after the first successful authentication and reused across restarts; the server card keeps only its non-secret credential id.
- Server card shows a summary of the saved access (`user@host:port`, where the secret lives) with a three-dot menu to change it, plus the reported OS, active route count and SSH user as icon tiles.
- The import wizard shows a live console of the work performed, alongside the step index.

### Changed

- Server Settings auto-connects with saved credentials and shows the profile panel directly; the access form appears only when there is no saved secret or a connection failed. The installation-status table was removed as a duplicate of the deployment and import consoles.
- The subscription token is masked in the deployment log and import console, because it is a bearer credential.

### Fixed

- `quickstart` no longer fails with `apt-get install nginx failed` when `unattended-upgrades` holds the apt/dpkg lock: every install waits for an active `unattended-upgrade` worker within a 12-minute budget and passes `-o DPkg::Lock::Timeout=180`.
- Bash validation scripts no longer die with `tr: write error: Broken pipe` on Ubuntu (`pipefail` plus an early-exiting reader).

## [0.5.0] - 2026-09-22

The first combined release of the updated server manager and **Xrayebator Desktop GUI**.

### Added

- Electron + React + TypeScript GUI for managing VPS instances over SSH.
- Dashboard, server add wizard, keys page, and QR codes.
- Profile creation/deletion and fingerprint, SNI, and port changes.
- RU / EN / 中文 interface switching.
- Standard HAPP schema-v3 profile with seven routes and one subscription URL.
- Improved installer IPv6 scenarios, DNS fallback, and IPv6 URL formatting; automated public IP-TLS for IPv6-only VPS is still not claimed and requires domain TLS.
- Installer step control with `--check` / `--resume` / `--fresh`.
- A 24-script Bash validation suite and Electron unit tests.

### Changed

- Runtime configuration changes go through backup, Xray validation, and rollback on failure.
- Installer, update, firewall ownership, and lifecycle paths have additional checks.
- The archival PySide6 GUI is separated into `gui-legacy/`; the active application is the Electron GUI in `src/`.
- Release packages use clear platform suffixes: `-win`, `-mac-arm64`, and `-linux`.
- Documentation is synchronized in Russian, English, and Chinese.

### Fixed

- Migration, HAPP subscription, IPv6 DNS/URL fallback, certificate, and profile synchronization scenarios.
- GUI deployment, SSH validation, JSON CLI responses, SNI/port-change, and CI issues.

### Limitations

- The full interactive menu, bypass, probe-test, revoke, happ-setup, cascade, self-steal, and service logs remain CLI-only.
- Hardening tasks found in a later audit around `safe_jq_write`, lifecycle rollback, JSON escaping, and existing-inbound validation are not included in this release.

Detailed English release notes: [docs/releases/v0.5.0.en.md](docs/releases/v0.5.0.en.md).
Russian release notes: [docs/releases/v0.5.0.md](docs/releases/v0.5.0.md).
