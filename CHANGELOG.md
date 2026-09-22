# Changelog

User-facing Xrayebator changes. The server manager and Electron application are published from the canonical `howdeploy/Xrayebator` repository.

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
