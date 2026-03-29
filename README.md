# ansible-xrootd-core

Production-grade Ansible configuration for [XRootD](https://xrootd.slac.stanford.edu/)
servers. Designed to be simple to run against a freshly installed OS with minimal
variables required.

## Supported Platforms

| OS | Versions |
|----|---------|
| Rocky Linux | 8, 9 |
| Ubuntu | 22.04 (jammy), 24.04 (noble) |

## Features

- Full OS preparation: package repos, firewall, time sync
- TLS certificate management with four modes:
  - Self-signed (default, auto-renews)
  - Let's Encrypt staging (certbot)
  - Let's Encrypt production (certbot)
  - Externally provided (path or vault PEM content)
- Configurable XRootD server with optional features:
  - HTTP/WebDAV + Third Party Copy (TPC)
  - Macaroon token auth
  - SciTokens (WLCG JWT profile)
  - Authorisation file (Authfile)
  - Monitoring export
- Ansible Vault integration for secrets
- Idempotent — safe to re-run

## Quick Start

### 1. Clone, enter the repo, and install collection dependencies

```bash
git clone https://github.com/snafus/ansible-xrootd-core.git
cd ansible-xrootd-core
ansible-galaxy collection install -r requirements.yml
```

### 2. Create your inventory

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
# edit inventory/hosts.yml with your server hostname and ansible_user
```

### 3. Set required variables

```bash
# inventory/group_vars/xrootd_servers/main.yml already exists
# Minimum required: xrootd_data_path (default: /data/xrootd)
```

### 4. (Optional) Create a vault for secrets

```bash
cp inventory/group_vars/xrootd_servers/vault.yml.example \
   inventory/group_vars/xrootd_servers/vault.yml
# edit vault.yml, then encrypt it:
ansible-vault encrypt inventory/group_vars/xrootd_servers/vault.yml
```

### 5. Deploy

```bash
# Full deploy (common + certificates + xrootd)
ansible-playbook site.yml

# With vault password
ansible-playbook site.yml --ask-vault-pass

# Certificate renewal only
ansible-playbook playbooks/certificates.yml
```

## Minimum Configuration

Only two values are needed for a working server with a self-signed certificate:

```yaml
# inventory/hosts.yml
all:
  children:
    xrootd_servers:
      hosts:
        myserver.example.org:
          ansible_user: rocky    # or: ubuntu
```

```yaml
# inventory/group_vars/xrootd_servers/main.yml
xrootd_data_path: /data/xrootd
```

Everything else uses safe defaults: self-signed cert, port 1094, all optional
features (HTTP, TPC, auth, SciTokens, macaroons) disabled.

## Certificate Modes

Set `xrootd_cert_mode` in your group_vars:

| Mode | Value | Requirements |
|------|-------|-------------|
| Self-signed | `self_signed` | None |
| Let's Encrypt staging | `certbot_staging` | Public DNS, port 80 open, `vault_certbot_email` |
| Let's Encrypt production | `certbot_production` | Public DNS, port 80 open, `vault_certbot_email` |
| External | `external` | `vault_xrootd_ext_cert` + `vault_xrootd_ext_key` in vault |

## Optional Features

All features are opt-in. Enable in `group_vars/xrootd_servers/main.yml`:

```yaml
xrootd_http_enabled: true           # HTTP/WebDAV protocol plugin
xrootd_http_tpc_enabled: true       # Third Party Copy (requires http_enabled)
xrootd_macaroons_enabled: true      # Macaroon bearer token auth
xrootd_scitokens_enabled: true      # SciTokens / WLCG JWT token auth
xrootd_auth_enabled: true           # Authfile-based access control
xrootd_monitoring_enabled: true     # xrd.monitor UDP event stream
xrootd_reporting_enabled: true      # xrd.report periodic stats (Prometheus)
xrootd_reporting_host: "collector.example.org"  # required when reporting enabled
```

### Version pinning

```yaml
xrootd_version: "5.6.9"   # pin to a specific release; empty = latest
```

### CA trust mode

Controls `xrd.tlsca` — how XRootD verifies client/peer certificates:

| Value | Behaviour |
|-------|-----------|
| `file` (default) | Use `xrootd_ca_file` — correct for self-signed and external modes |
| `system` | Symlink the OS CA bundle to `xrootd_ca_file` — use with certbot/public CAs |
| `grid` | Install trust anchors + fetch-crl (initial + timer), use `xrd.tlsca certdir` |

When `xrootd_ca_mode: grid`, select the trust anchor bundle with `xrootd_ca_bundle_provider`:

| Provider | Bundle | Platforms |
|----------|--------|-----------|
| `egi` (default) | EGI IGTF trust anchors | Rocky + Ubuntu |
| `osg` | OSG / CILogon trust anchors | Rocky only |

On Rocky, `update-crypto-policies --set DEFAULT:SHA1` is applied automatically —
required because some grid CA CRL chains still include SHA-1 signed components
that Rocky 9's default crypto policy rejects.

```yaml
xrootd_ca_mode: grid
xrootd_ca_bundle_provider: osg   # or egi (default)
```

### System resource limits

A systemd drop-in sets `LimitNOFILE` and `LimitNPROC` for all `xrootd@*` units.
Defaults are sized for Tier-1 / SRCNet production nodes:

```yaml
xrootd_limit_nofile: 1048576   # open file descriptors (default: 1 M)
xrootd_limit_nproc:  65536     # threads / sub-processes (default: 64 k)
```

### jemalloc

Preloading jemalloc reduces allocator lock contention under high concurrency
(many simultaneous transfers). Disabled by default; recommended for
high-throughput nodes:

```yaml
xrootd_jemalloc_enabled: true
```

Installs `jemalloc` (Rocky) or `libjemalloc2` (Ubuntu) and adds
`LD_PRELOAD` to the systemd drop-in automatically.

### Trace / logging

```yaml
xrootd_trace_xrd:      "conn net"     # xrd.trace flags
xrootd_trace_xrootd:   "auth login"   # xrootd.trace flags
xrootd_trace_http:     "request"      # http.trace (http_enabled only)
xrootd_macaroon_trace: "debug"        # macaroons.trace (macaroons_enabled only)
```

## Secrets

Sensitive values (macaroon secret, certbot email, external cert key) are managed
with Ansible Vault. See `inventory/group_vars/xrootd_servers/vault.yml.example`
for the full template.

**Never commit a plaintext `vault.yml`.** The `.gitignore` prevents this by default.

## Roles

| Role | Purpose |
|------|---------|
| `common` | OS repos, packages, firewall setup, chrony |
| `certificates` | TLS certificate provisioning (4 modes) |
| `xrootd` | Install, configure, and run XRootD server |
| `xrootd_redirector` | HA redirector cluster *(phase 2, not yet implemented)* |

See [ROADMAP.md](ROADMAP.md) for the full implementation plan and phased delivery.

## Tags

Run specific parts of the playbook with `--tags`:

| Tag | Scope |
|-----|-------|
| `install` | Package installation only |
| `users` | User/group creation only |
| `configure` | All configuration files |
| `firewall` | Firewall rules only |
| `auth` | Authfile deployment only |
| `logrotate` | Logrotate config only |
| `service` | Service management only |
| `validate` | Post-deploy checks only |
| `update` | OS package update (opt-in, never runs by default) |

```bash
ansible-playbook site.yml --tags configure
```

## CI

Every push runs four jobs:

| Job | What it checks |
|-----|---------------|
| `lint` | yamllint + ansible-lint (production profile) |
| `syntax-check` | `ansible-playbook --syntax-check` on all playbooks |
| `molecule (rockylinux9)` | Full converge + idempotence + verify in Docker |
| `molecule (ubuntu2204)` | Full converge + idempotence + verify in Docker |

Rocky 8 and Ubuntu 24.04 are pre-configured in the matrix and can be enabled
by uncommenting entries in `.github/workflows/ci.yml`.

Run checks locally before pushing:
```bash
make install        # install Python deps + Ansible collections (once)
make lint           # yamllint + ansible-lint
make syntax-check   # --syntax-check on all playbooks
make molecule       # full converge + verify (requires Docker)
make ci             # all of the above in sequence
```

## Versioning

This project uses [Semantic Versioning](https://semver.org/).
See [CHANGELOG.md](CHANGELOG.md) for release history.

## Contributing

Commit messages must follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add scitokens issuer support
fix: correct cert expiry check window
docs: update README quick start
chore: bump xrootd package list for Rocky 9
```
