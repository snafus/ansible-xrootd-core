# Changelog

All notable changes to this project will be documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Commit messages follow the [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) specification.

---

## [0.1.0] - 2026-03-28

Initial release. Production-grade Ansible role suite for deploying XRootD servers
on Rocky Linux 8/9 and Ubuntu 22.04/24.04.

### Added

**Roles**
- `common` — OS baseline: EPEL + CERN XRootD repos (yum/apt), common packages,
  firewalld/ufw setup, chrony time sync
- `certificates` — TLS certificate provisioning in four modes:
  `self_signed`, `certbot_staging`, `certbot_production`, `external`
- `xrootd` — full server lifecycle: user/group pre-creation, package install,
  directories, firewall ports, configuration, auth, service management, validation
- `xrootd_redirector` — HA redirector stub (Phase 2)

**Certificate features**
- Self-signed with SANs (DNS + IP); regenerates when < 7 days from expiry
- Let's Encrypt via certbot standalone; systemd renewal timer + post-renewal hook
- External cert from controller path or vault PEM content (key never on disk)
- `xrootd_ca_mode`: `file` (default) / `system` (OS CA bundle) / `grid` (certdir)
- `xrootd_ca_bundle_provider`: `egi` (EGI IGTF, Rocky + Ubuntu) / `osg` (OSG/CILogon, Rocky only)
- `fetch-crl` run at deploy time and via systemd timer (`fetch-crl-cron.timer` on
  Rocky, `fetch-crl.timer` on Ubuntu)
- `update-crypto-policies --set DEFAULT:SHA1` applied on Rocky in grid mode —
  required for SHA-1 components present in some grid CA CRL chains
- Guards: `self_signed + system` rejected; post-condition asserts `ca_file` exists
  for non-grid modes; `osg` provider asserts Rocky-only

**XRootD features**
- Config profiles: `standalone` (default), `server`, `redirector` (Phase 2)
- All features opt-in: HTTP/WebDAV, TPC, macaroons, SciTokens, Authfile,
  `xrd.monitor` event stream, `xrd.report` Prometheus summary stats
- Trace directives: `xrd.trace`, `xrootd.trace`, `http.trace`, `macaroons.trace`
- Macaroon secret: vault value (multi-node) or auto-generated (standalone)
- SciTokens: configurable audience + issuer list
- Version pinning via `xrootd_version` (empty = latest)
- xrootd user/group pre-created before package install; optional fixed UID/GID
- Logrotate via `copytruncate` (SIGUSR1 unsafe for xrootd)

**Infrastructure**
- Ansible Vault integration; `vault.yml.example` template; `.gitignore` rules
- `site.yml` master entry point; `playbooks/certificates.yml` for cert-only runs
- Inventory examples with `group_vars` and `xrootd_servers` group structure
- `Makefile` for local dev: `make lint / syntax-check / molecule / ci`
- CI: yamllint + ansible-lint (production profile) + syntax check + Molecule
  converge/idempotence/verify on Rocky Linux 9 and Ubuntu 22.04
- `ROADMAP.md` with phased delivery plan and full variable reference

<!-- New release entry format:
## [X.Y.Z] - YYYY-MM-DD
### Added | Changed | Deprecated | Removed | Fixed | Security
- description
-->
