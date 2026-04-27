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
  - Self-signed (default, renews automatically when < 7 days remain)
  - Let's Encrypt staging (certbot — no rate limits, untrusted CA)
  - Let's Encrypt production (certbot)
  - Externally provided (vault PEM content, controller path, or host path)
- Configurable XRootD server with optional features:
  - Multiple export paths, each independently configured
  - HTTP/WebDAV + Third Party Copy (TPC)
  - Macaroon token auth
  - SciTokens (WLCG JWT profile)
  - Authorisation file (Authfile)
  - UDP monitoring export + Prometheus reporting
  - Kernel and NIC performance tuning (ESNet DTN recommendations)
- Ansible Vault integration for secrets
- Idempotent — safe to re-run

## Quick Start

### 1. Clone and install dependencies

```bash
git clone https://github.com/snafus/ansible-xrootd-core.git
cd ansible-xrootd-core
ansible-galaxy collection install -r requirements.yml
```

### 2. Create your inventory

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
# edit inventory/hosts.yml — set your server hostname and ansible_user
```

### 3. Set required variables

```yaml
# inventory/group_vars/xrootd_servers/main.yml
xrootd_exports:
  - path: /data/xrootd
```

### 4. (Optional) Create a vault for secrets

```bash
cp inventory/group_vars/xrootd_servers/vault.yml.example \
   inventory/group_vars/xrootd_servers/vault.yml
# edit vault.yml, then encrypt:
ansible-vault encrypt inventory/group_vars/xrootd_servers/vault.yml
```

### 5. Deploy

```bash
ansible-playbook site.yml
ansible-playbook site.yml --ask-vault-pass   # with vault
ansible-playbook playbooks/certificates.yml  # certificate renewal only
```

## Minimum Configuration

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
xrootd_exports:
  - path: /data/xrootd
```

Everything else uses safe defaults: self-signed cert, port 1094,
HTTP/WebDAV + HTTP TPC + adler32 checksum enabled, auth/SciTokens/macaroons disabled.

## Export Paths

XRootD exports one or more filesystem paths into the namespace. All paths are
equal — there is no primary/secondary distinction. Configure them with
`xrootd_exports`:

```yaml
xrootd_exports:
  - path: /data/xrootd          # created automatically, owned by xrootd user
  - path: /archive/xrootd
    mode: "0755"                 # optional directory permissions (default: 0755)
  - path: /mnt/ceph/xrootd
    create: false                # do not mkdir — directory is managed externally
    mount: true                  # assert this path is a real mount point at deploy time
```

### Export path keys

| Key | Default | Description |
|-----|---------|-------------|
| `path` | — | Required. Filesystem path to export. |
| `mode` | `"0755"` | Directory permissions. |
| `create` | `true` | Create the directory if absent. Set `false` for paths owned by an external agent (Puppet, ACME client, site PKI). |
| `mount` | `false` | Assert the path is a real mount point. Fails the play if the filesystem (CephFS, NFS, Lustre, etc.) is not mounted, preventing xrootd from silently serving from an empty underlying directory. |

### Health check path

Post-deploy validation (`xrdfs ls`) targets `xrootd_exports[0].path` by default.
Override if the first export is a pre-existing mount unavailable in CI:

```yaml
xrootd_health_check_path: /data/xrootd
```

## Certificate Modes

Set `xrootd_cert_mode` in your group_vars:

| Mode | Value | Requirements |
|------|-------|-------------|
| Self-signed | `self_signed` | None (default) |
| Let's Encrypt staging | `certbot_staging` | Public DNS, port 80 open, `vault_certbot_email` |
| Let's Encrypt production | `certbot_production` | Public DNS, port 80 open, `vault_certbot_email` |
| External | `external` | See sub-modes below |

### External certificate sub-modes

Three sub-modes are evaluated in priority order:

**A — Vault content (recommended):** key never exists as plaintext on disk.

```yaml
# vault.yml (encrypted)
vault_xrootd_ext_cert: |
  -----BEGIN CERTIFICATE-----
  ...
vault_xrootd_ext_key: |
  -----BEGIN PRIVATE KEY-----
  ...
vault_xrootd_ext_ca: |          # optional
  -----BEGIN CERTIFICATE-----
  ...
```

**B — Controller path:** files on the Ansible controller are copied to the host.

```yaml
xrootd_ext_cert_src: /path/on/controller/server.crt
xrootd_ext_key_src:  /path/on/controller/server.key
xrootd_ext_ca_src:   /path/on/controller/ca.crt      # optional
```

**C — Host path:** files already present on the target (written by Puppet, an
ACME client, or site PKI) are copied into the standard TLS directory with correct
ownership and permissions.

```yaml
xrootd_ext_cert_host_src: /etc/pki/tls/certs/server.crt
xrootd_ext_key_host_src:  /etc/pki/tls/private/server.key
xrootd_ext_ca_host_src:   /etc/pki/tls/certs/ca.crt   # optional
```

## CA Trust Mode

Controls `xrd.tlsca` — how XRootD verifies client and peer certificates:

| Value | Behaviour |
|-------|-----------|
| `file` (default) | Use `xrootd_ca_file` — correct for self-signed and external modes |
| `system` | Symlink the OS CA bundle — use with certbot / public CAs |
| `grid` | Install IGTF/OSG trust anchors + fetch-crl, use `xrd.tlsca certdir` |

```yaml
xrootd_ca_mode: grid
xrootd_ca_bundle_provider: egi   # egi (default, Rocky + Ubuntu) | osg (Rocky only)
```

On Rocky, `update-crypto-policies --set DEFAULT:SHA1` is applied automatically
when `ca_mode: grid` — required because some grid CA CRL chains include SHA-1
signed components that Rocky 9's default crypto policy rejects.

## Features

### Enabled by default

```yaml
xrootd_http_enabled: true       # HTTP/WebDAV protocol plugin
xrootd_http_tpc_enabled: true   # HTTP Third Party Copy (requires http_enabled)
xrootd_chksum_enabled: true     # adler32 checksum (WLCG standard for FTS3/Rucio)
```

### Disabled by default — enable in `group_vars/xrootd_servers/main.yml`

```yaml
xrootd_tpc_enabled: true             # Native XRootD TPC (FTS3 server-to-server)
xrootd_macaroons_enabled: true       # Macaroon bearer token auth
xrootd_scitokens_enabled: true       # SciTokens / WLCG JWT token auth
xrootd_auth_enabled: true            # Authfile-based access control
xrootd_monitoring_enabled: true      # xrd.monitor UDP event stream
xrootd_monitoring_host: "collector.example.org"   # required when monitoring enabled
xrootd_reporting_enabled: true       # xrd.report periodic stats (Prometheus)
xrootd_reporting_host: "collector.example.org"    # required when reporting enabled
```

### Authfile

```yaml
xrootd_auth_enabled: true
xrootd_auth_entries:
  - type: g            # u=unix user, g=group, h=hostname
    name: /ska
    path: /data/xrootd
    permissions: rl    # r=read, l=list, w=write, d=delete, a=all
```

### SciTokens

```yaml
xrootd_scitokens_enabled: true
xrootd_scitokens_audience: "https://xrootd.example.org/"
xrootd_scitokens_onmissing: passthrough   # passthrough | deny
xrootd_scitokens_issuers:
  - name: my-iam
    url: https://iam.example.org/
    base_path: /data/xrootd
    default_user: xrootd
    map_subject: false
```

### Version pinning

```yaml
xrootd_version: "5.6.9"   # empty string installs latest
```

### System resource limits

A systemd drop-in sets `LimitNOFILE` and `LimitNPROC`. Defaults are sized for
Tier-1 / SRCNet production nodes:

```yaml
xrootd_limit_nofile: 1048576   # open file descriptors (default: 1 M)
xrootd_limit_nproc:  65536     # threads / sub-processes (default: 64 k)
```

### jemalloc

Preloads jemalloc to reduce allocator lock contention under high concurrency.
Disabled by default; recommended for high-throughput nodes:

```yaml
xrootd_jemalloc_enabled: true
```

Installs `jemalloc` (Rocky) or `libjemalloc2` (Ubuntu) and sets `LD_PRELOAD`
in the systemd drop-in automatically.

### Trace / debug logging

```yaml
xrootd_trace_xrd:      "conn net"     # xrd.trace flags
xrootd_trace_xrootd:   "auth login"   # xrootd.trace flags
xrootd_trace_http:     "request"      # http.trace (http_enabled only)
xrootd_macaroon_trace: "debug"        # macaroons.trace (macaroons_enabled only)
```

## Firewall

The firewall is managed by the `common` role (installs and enables firewalld /
ufw) and the `xrootd` role (opens port 1094). To disable firewall management
entirely — for example when firewall rules are owned by an external tool or
cloud security group:

```yaml
common_firewall_enabled: false
```

This skips both the firewall service setup and all port-open tasks.

## Secrets

Sensitive values are managed with Ansible Vault. See
`inventory/group_vars/xrootd_servers/vault.yml.example` for the full template.

| Secret | Vault variable | Notes |
|--------|---------------|-------|
| Macaroon secret | `vault_macaroon_secret` | Leave empty to auto-generate (standalone only) |
| Certbot email | `vault_certbot_email` | Required for certbot modes |
| External cert (PEM) | `vault_xrootd_ext_cert` | Content mode — preferred over path modes |
| External key (PEM) | `vault_xrootd_ext_key` | Key never plaintext on disk |
| External CA (PEM) | `vault_xrootd_ext_ca` | Optional |

**Never commit a plaintext `vault.yml`.** The `.gitignore` prevents this by default.

## Roles

| Role | Purpose |
|------|---------|
| `common` | OS repos, packages, firewall, chrony |
| `certificates` | TLS certificate provisioning (4 modes, 3 external sub-modes) |
| `xrootd` | Install, configure, and run XRootD server |
| `tune` | Kernel + NIC performance tuning (ESNet DTN recommendations) |
| `xrootd_redirector` | HA redirector cluster *(phase 2, not yet implemented)* |

## Performance Tuning

The `tune` role applies ESNet ([fasterdata.es.net](https://fasterdata.es.net))
recommended tuning for Data Transfer Nodes. All settings are opt-in:

```yaml
# NIC identification — required for NIC-specific tasks; no default
tune_nic_device: bond0        # set at host level when nodes differ

tune_nic_speed: auto          # auto | 10g | 40g | 100g
tune_sysctl_enabled: true     # TCP buffer sysctl drop-in (safe, no NIC required)
tune_qdisc_enabled: false     # tc fq qdisc (persistent via systemd unit)
tune_ethtool_enabled: false   # ring buffers, coalescing, flow control
tune_jumbo_frames_enabled: false   # MTU 9000
tune_cpu_governor_enabled: false   # performance governor
tune_irq_affinity_enabled: false   # NUMA IRQ binding (Mellanox/NVIDIA only)
tune_grub_iommu_enabled: false     # IOMMU=pt kernel param (requires reboot)
```

Run tuning independently:

```bash
ansible-playbook playbooks/tune.yml
```

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
ansible-playbook site.yml --tags configure,service
```

## CI

Every push runs Molecule against multiple scenarios:

| Scenario | What it tests |
|----------|--------------|
| `default` | Self-signed cert, plain XRootD protocol |
| `cert_external` | External cert, host-path sub-mode (Sub-mode C) |
| `grid_egi` | EGI IGTF trust anchors + fetch-crl, `ca_mode: grid` |
| `grid_osg` | OSG trust anchors + fetch-crl, Rocky only |

Each scenario runs converge → idempotence (second converge must produce zero
changed tasks) → verify.

Run checks locally:

```bash
make install        # install Python deps + Ansible collections (once)
make lint           # yamllint + ansible-lint
make syntax-check   # --syntax-check on all playbooks
make molecule       # full converge + verify (requires Docker)
make ci             # all of the above in sequence
```

Select a different distro for local molecule runs:

```bash
MOLECULE_DISTRO=ubuntu2204 make molecule
```

## Versioning

This project uses [Semantic Versioning](https://semver.org/).
See [CHANGELOG.md](CHANGELOG.md) for release history.

## Contributing

Commit messages must follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add scitokens issuer support
fix: correct cert expiry check window
docs: update README
refactor: extract shared molecule prepare tasks
```
