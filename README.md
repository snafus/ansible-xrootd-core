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

Everything else uses safe defaults: self-signed cert, port 1094, HTTP+TPC
enabled, auth/scitokens/macaroons disabled.

## Certificate Modes

Set `xrootd_cert_mode` in your group_vars:

| Mode | Value | Requirements |
|------|-------|-------------|
| Self-signed | `self_signed` | None |
| Let's Encrypt staging | `certbot_staging` | Public DNS, port 80 open, `vault_certbot_email` |
| Let's Encrypt production | `certbot_production` | Public DNS, port 80 open, `vault_certbot_email` |
| External | `external` | `vault_xrootd_ext_cert` + `vault_xrootd_ext_key` in vault |

## Optional Features

Enable in `group_vars/xrootd_servers/main.yml`:

```yaml
xrootd_http_enabled: true           # HTTP/WebDAV (default: true)
xrootd_http_tpc_enabled: true       # Third Party Copy (default: true)
xrootd_macaroons_enabled: true      # Macaroon token auth
xrootd_scitokens_enabled: true      # SciTokens / WLCG JWT
xrootd_auth_enabled: true           # Authfile authorisation
xrootd_monitoring_enabled: true     # UDP monitoring export
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
| `configure` | Configuration files only |
| `service` | Service management only |
| `validate` | Post-deploy checks only |
| `update` | OS package update (opt-in, not run by default) |

```bash
ansible-playbook site.yml --tags configure
```

## CI

Every push runs three jobs:

| Job | What it checks |
|-----|---------------|
| `lint` | yamllint + ansible-lint |
| `syntax-check` | `ansible-playbook --syntax-check` on all playbooks |
| `molecule` | Full converge + verify inside a Docker container |

Molecule runs a matrix of target OS images. Rocky Linux 9 is active; Rocky 8,
Ubuntu 22.04, and Ubuntu 24.04 are pre-configured and can be enabled by
uncommenting entries in `.github/workflows/ci.yml`.

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
