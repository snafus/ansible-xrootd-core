# ansible-xrootd-core — Roadmap

Production-grade, simple-to-use Ansible configuration for XRootD servers.
Supports Rocky Linux 8/9 and Ubuntu 22.04/24.04. Designed for single-server
deployments today, with a clear extension path to HA redirector clusters.

Reference implementation: [snafus/ansible-xrootd](https://github.com/snafus/ansible-xrootd)
(fork of [uksrc/cloud-operations](https://github.com/uksrc/cloud-operations))

---

## Supported Platforms

| OS | Version | Notes |
|----|---------|-------|
| Rocky Linux | 8, 9 | EPEL + CERN XRootD yum repo |
| Ubuntu | 22.04 (jammy), 24.04 (noble) | CERN XRootD apt repo |

---

## Repository Layout

```
ansible-xrootd-core/
├── ansible.cfg
├── site.yml                                  # master entry point
├── ROADMAP.md
├── playbooks/
│   ├── xrootd_server.yml                     # full server deploy
│   └── certificates.yml                      # certificate management only
├── inventory/
│   ├── hosts.yml.example
│   └── group_vars/
│       ├── all/
│       │   └── main.yml                      # global defaults (minimal)
│       └── xrootd_servers/
│           ├── main.yml                      # role-level overrides
│           └── vault.yml.example             # secrets template (never commit vault.yml)
└── roles/
    ├── common/                               # OS prep, repos, firewall, chrony
    ├── certificates/                         # TLS cert management (4 modes)
    ├── xrootd/                               # install, configure, run XRootD
    └── xrootd_redirector/                    # HA redirector (phase 2 stub)
```

Each role follows full Ansible convention:
`defaults/  tasks/  handlers/  templates/  files/  meta/`

---

## Roles

### Role: `common`

Brings a bare OS to a known baseline before any application work.

**Task files:**

| File | Purpose |
|------|---------|
| `main.yml` | Dispatcher — branches by `ansible_os_family` |
| `rocky.yml` | EPEL repo, CERN XRootD yum repo, dnf makecache |
| `ubuntu.yml` | CERN XRootD apt repo + GPG key (dearmored to `/etc/apt/keyrings/`) |
| `packages.yml` | Common tools: openssl, net-tools, bind-utils/dnsutils, python3, ca-certificates |
| `firewall_rocky.yml` | Install + enable firewalld only (no port rules — handled by xrootd role) |
| `firewall_ubuntu.yml` | Install + enable ufw, allow ssh before enabling |
| `chrony.yml` | Install + enable chrony for time sync |

**Key defaults:**

```yaml
common_update_system: false     # opt-in: run dist-upgrade / dnf update
```

**Notes:**
- SELinux and AppArmor are explicitly out of scope for phase 1.
- System update (`dist-upgrade` / `dnf update`) is opt-in via tag `update` and
  `common_update_system: true` — never runs by default.
- Rocky 8 and Rocky 9 use different EPEL and CERN repo URLs; role detects via
  `ansible_distribution_major_version`.
- Ubuntu repo codename is derived from `ansible_distribution_release`
  (jammy / noble).

---

### Role: `certificates`

Provides TLS certificates at a consistent path regardless of how they were
obtained. All downstream roles (xrootd) consume the same output paths.

**Output contract** (always true after role runs):

```
/etc/xrootd/tls/server.crt   — certificate (PEM)
/etc/xrootd/tls/server.key   — private key  (PEM, mode 0600, owner xrootd)
/etc/xrootd/tls/ca.crt       — CA bundle    (PEM)
```

**Task files:**

| File | Purpose |
|------|---------|
| `main.yml` | Create cert dir, branch to mode sub-task, post-condition assertions |
| `self_signed.yml` | Generate key + self-signed cert with SANs; skip if cert still valid (7-day window) |
| `certbot.yml` | Install certbot, obtain cert, symlink to cert dir, install renewal timer |
| `external.yml` | Deploy cert from controller path or vault PEM content |

**Certificate modes** — set via `xrootd_cert_mode`:

| Mode | Value | Description |
|------|-------|-------------|
| Self-signed | `self_signed` | openssl with SAN (DNS + IP); renews when < 7 days remaining |
| Certbot staging | `certbot_staging` | Let's Encrypt staging ACME; for testing |
| Certbot production | `certbot_production` | Let's Encrypt production ACME |
| External | `external` | Controller-supplied cert (path or vault PEM content) |

**Key defaults:**

```yaml
xrootd_cert_mode:     self_signed
xrootd_cert_dir:      /etc/xrootd/tls
xrootd_cert_cn:       "{{ ansible_fqdn }}"
xrootd_cert_days:     365
xrootd_cert_keysize:  4096
xrootd_cert_org:      "My Organisation"
xrootd_cert_country:  "UK"

# Certbot
xrootd_certbot_email:  ""                     # required for certbot modes; use vault
xrootd_certbot_domain: "{{ ansible_fqdn }}"

# External — choose one sub-mode:
xrootd_ext_cert_src:  ""                      # path on Ansible controller
xrootd_ext_key_src:   ""                      # path on Ansible controller
xrootd_ext_ca_src:    ""                      # optional CA path
# OR use vault content vars (preferred — key never plaintext on disk):
# vault_xrootd_ext_cert, vault_xrootd_ext_key, vault_xrootd_ext_ca
```

**Notes:**
- `openssl.cnf.j2` template includes Subject Alternative Names:
  `DNS:{{ ansible_fqdn }}`, `DNS:{{ ansible_hostname }}`, `IP:{{ ansible_default_ipv4.address }}`
- Certbot renewal: systemd timer + post-renewal hook restarts
  `xrootd@{{ xrootd_config_name }}`.
- Certificate changes notify handler `restart xrootd`.

---

### Role: `xrootd`

Installs, configures, and runs the XRootD server daemon.

**Task files:**

| File | Purpose |
|------|---------|
| `main.yml` | Ordered include of all sub-tasks with tags |
| `install.yml` | Build package list (base + optional), install, verify version |
| `directories.yml` | Create data, admin, run, log, auth directories with correct ownership |
| `firewall.yml` | Open xrootd ports in firewalld/ufw (dispatches to OS sub-tasks) |
| `configure.yml` | Deploy xrootd config template, robots.txt, macaroon secret, scitokens.cfg |
| `auth.yml` | Deploy Authfile if auth enabled |
| `service.yml` | Enable + start systemd units; print service status |
| `validate.yml` | Wait for port, run xrdfs ls /, optional HTTP check |

**Key defaults:**

```yaml
# Config profile — drives template selection and systemd unit name
xrootd_config_name: standalone      # standalone | server | redirector

# Paths
xrootd_data_path:   /data/xrootd
xrootd_admin_path:  /var/spool/xrootd
xrootd_run_path:    /run/xrootd
xrootd_log_path:    /var/log/xrootd
xrootd_auth_dir:    /opt/xrd/etc

# Network
xrootd_port:         1094
xrootd_bind_address: ""             # empty = all interfaces

# TLS
xrootd_tls_enabled: true
xrootd_cert_file:   /etc/xrootd/tls/server.crt
xrootd_key_file:    /etc/xrootd/tls/server.key
xrootd_ca_dir:      /etc/grid-security/certificates

# Features — all opt-in
xrootd_http_enabled:       true
xrootd_http_tpc_enabled:   true
xrootd_auth_enabled:       false
xrootd_scitokens_enabled:  false
xrootd_macaroons_enabled:  false
xrootd_monitoring_enabled: false

# Macaroon secret (see Secrets section)
xrootd_macaroon_secret_file: /etc/xrootd/macaroon-secret

# SciTokens
xrootd_scitokens_audience: "https://wlcg.cern.ch/jwt/v1/any"
xrootd_scitokens_issuers: []
# - name:         my-iam
#   url:          https://iam.example.org/
#   base_path:    /
#   default_user: xrootd

# Authfile entries
xrootd_auth_entries: []
# - type: g        # u=user, g=group, h=host
#   name: /ska
#   path: /data/xrootd
#   permissions: rl

# Redirector (clustered mode only)
xrootd_redirector_host: ""
xrootd_redirector_port: 1094

# Site identity
xrootd_site_name: "{{ inventory_hostname }}"
```

**Templates:**

| Template | Deployed to |
|----------|------------|
| `xrootd-standalone.cfg.j2` | `/etc/xrootd/xrootd-standalone.cfg` |
| `xrootd-server.cfg.j2` | `/etc/xrootd/xrootd-server.cfg` (clustered data node) |
| `scitokens.cfg.j2` | `/etc/xrootd/scitokens.cfg` |
| `Authfile.j2` | `/opt/xrd/etc/Authfile` |

Config template uses conditional blocks for every optional feature (TLS, HTTP,
TPC, Macaroons, SciTokens, Authfile, Monitoring) so the rendered file contains
only what is enabled.

**Macaroon secret logic (`configure.yml`):**

```
if vault_macaroon_secret is defined and non-empty:
    → write vault value to secret file      (consistent across cluster nodes)
else if secret file does not already exist:
    → openssl rand -base64 64 > file        (standalone convenience)
else:
    → leave existing file untouched         (idempotent)
```

**Systemd units:**

| Unit | When |
|------|------|
| `xrootd@standalone` | `xrootd_config_name == standalone` |
| `xrootd@server` | `xrootd_config_name == server` |
| `cmsd@server` | `xrootd_config_name == server` (phase 2) |
| `xrootd@redirector` | `xrootd_config_name == redirector` (phase 2) |
| `cmsd@redirector` | `xrootd_config_name == redirector` (phase 2) |

---

### Role: `xrootd_redirector` *(phase 2 stub)*

Role exists with correct directory structure and vars file. Tasks print a clear
warning that the role is not yet implemented.

Pre-populated defaults for phase 2:

```yaml
xrootd_redirector_port:        1094
xrootd_redirector_data_servers: []   # list of data server FQDNs
xrootd_redirector_ha_pair:     ""    # secondary redirector FQDN
```

---

## Secrets

### Ansible Vault

Sensitive values are stored in an encrypted vault file per group:

```
inventory/group_vars/xrootd_servers/vault.yml    ← encrypted, never committed plaintext
inventory/group_vars/xrootd_servers/vault.yml.example  ← template, always committed
```

`.gitignore` rules:
```
inventory/group_vars/**/vault.yml
!inventory/group_vars/**/vault.yml.example
```

### Secrets reference

| Secret | Vault variable | Notes |
|--------|---------------|-------|
| Macaroon secret | `vault_macaroon_secret` | Leave empty to auto-generate (standalone only) |
| Certbot email | `vault_certbot_email` | Required for certbot modes |
| External cert (PEM) | `vault_xrootd_ext_cert` | Content mode — preferred over path mode |
| External key (PEM) | `vault_xrootd_ext_key` | Content mode — key never plaintext on disk |
| External CA (PEM) | `vault_xrootd_ext_ca` | Optional |

Role vars wire vault vars in with safe defaults:

```yaml
xrootd_certbot_email:   "{{ vault_certbot_email   | default('') }}"
xrootd_macaroon_secret: "{{ vault_macaroon_secret | default('') }}"
```

---

## Playbooks

### `site.yml`
Master entry point. Imports `playbooks/xrootd_server.yml`.

### `playbooks/xrootd_server.yml`
Full server deploy. Role order:
1. `common`
2. `certificates`
3. `xrootd`

### `playbooks/certificates.yml`
Certificate management only — for renewals without a full redeploy.
Includes a second play after the `certificates` role that restarts
`xrootd@{{ xrootd_config_name }}` if the service is running.

---

## Minimum Configuration to Deploy

Only two values are required to get a running server:

```yaml
# inventory/hosts.yml
all:
  children:
    xrootd_servers:
      hosts:
        myserver.example.org:
          ansible_user: rocky        # or ubuntu
```

```yaml
# inventory/group_vars/xrootd_servers/main.yml
xrootd_data_path: /data/xrootd
```

Everything else defaults to: self-signed cert, port 1094, HTTP+TPC enabled,
auth/scitokens/macaroons off.

---

## OS × Feature Matrix

| Feature | Rocky 8 | Rocky 9 | Ubuntu 22.04 | Ubuntu 24.04 |
|---------|---------|---------|--------------|--------------|
| XRootD repo | EPEL + CERN yum | EPEL + CERN yum | CERN apt (jammy) | CERN apt (noble) |
| Firewall | firewalld | firewalld | ufw | ufw |
| SELinux | out of scope | out of scope | N/A | N/A |
| AppArmor | N/A | N/A | out of scope | out of scope |
| Certbot source | EPEL | EPEL | apt | apt |
| Time sync | chrony | chrony | chrony | chrony |

---

## Known Gaps

### CA Certificate Bundle Management *(major)*

The current implementation has a significant gap in how CA certificate bundles
are handled for TLS peer verification.

**What is broken:**

The config templates emit `xrd.tlsca certdir {{ xrootd_ca_dir }}` which
defaults to `/etc/grid-security/certificates`. This directory is:

- Never created by any role
- Never populated with CA certificates
- Not guaranteed to exist on a freshly installed OS

XRootD will warn or fail to start if the directory is absent.

**The two distinct purposes conflated:**

| Purpose | Path | Status |
|---------|------|--------|
| CA that signed *our* server cert (for clients to trust us) | `/etc/xrootd/tls/ca.crt` | Produced correctly |
| CAs XRootD trusts for verifying *incoming* TLS peers | `xrootd_ca_dir` | Directory never populated ✗ |

**What is needed:**

| Deployment type | Correct CA source |
|-----------------|------------------|
| Basic TLS, no client auth | OS system CA bundle (default) |
| Macaroons / SciTokens only | OS system CA bundle (tokens carry their own trust) |
| WLCG/grid with X.509 client certs | IGTF CA bundles via `fetch-crl` + WLCG repo packages |

**Planned fix:**

1. Add `xrootd_ca_mode` variable: `system` (default) or `grid`
2. `system` mode: set `xrd.tlsca` to OS system CA path
   - Rocky: `/etc/pki/tls/certs/ca-bundle.crt`
   - Ubuntu: `/etc/ssl/certs/ca-certificates.crt`
3. `grid` mode: create `/etc/grid-security/certificates`, install
   `fetch-crl` and IGTF trust anchor packages from WLCG repo,
   run `fetch-crl` on deploy and via systemd timer
4. Update both config templates to use correct path per mode
5. `xrootd_ca_file` (`ca.crt`) remains as a client-facing artefact
   (what clients should add to their trust store to verify our server)

---

## Phased Delivery

### Phase 1 — Single Server (current)

| Step | Scope |
|------|-------|
| 1a | `common` role: repos, packages, firewall setup, chrony |
| 1b | `certificates` role: all 4 cert modes, vault integration |
| 1c | `xrootd` role: install, dirs, firewall ports, configure, service, validate |
| 1d | Playbooks, inventory examples, `ansible.cfg`, `.gitignore` |

### Phase 2 — HA Redirector

- `xrootd_redirector` role: cmsd, redirector config template, HA pair support
- Multiple data servers pointing at a redirector pair
- Shared macaroon secret via vault across all nodes

### Phase 3 — Testing & Integration

- Molecule test suite: Rocky 9 + Ubuntu 24.04 via Docker
- Verify all cert modes, all feature flags
- GitHub Actions CI

### Phase 4 — Advanced Features

- Token/macaroon auth end-to-end
- Rucio Storage Element integration
- Prometheus/node-exporter + xrootd monitoring exporter
- Logrotate configuration

---

## ansible.cfg

```ini
[defaults]
inventory         = inventory/hosts.yml
roles_path        = roles
host_key_checking = False
stdout_callback   = yaml
```

---

## Key Design Decisions

- **Firewall port rules live in `xrootd` role**, not `common` — avoids coupling
  port numbers into the base OS role.
- **`common` installs and enables firewalld/ufw** but opens no ports itself.
- **Certificate output contract** — consistent paths mean `xrootd` role never
  branches on cert mode.
- **Macaroon auto-generate is standalone-only** — vault value is required for
  any multi-node deployment where cross-node macaroon validation is needed.
- **System updates are opt-in** (`common_update_system: false`) — running
  dist-upgrade in production requires explicit intent.
- **All optional features default off** (`scitokens_enabled`, `macaroons_enabled`,
  `auth_enabled`) — minimum viable config is as simple as possible.
