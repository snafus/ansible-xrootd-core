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
    ├── tune/                                 # kernel + NIC performance tuning (phase 1e, planned)
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
xrootd_log_path:    /var/log/xrootd
xrootd_auth_dir:    /opt/xrd/etc

# Network
xrootd_port:         1094
xrootd_bind_address: ""             # empty = all interfaces

# TLS
xrootd_tls_enabled: true
xrootd_cert_file:   /etc/xrootd/tls/server.crt
xrootd_key_file:    /etc/xrootd/tls/server.key
xrootd_ca_file:     /etc/xrootd/tls/ca.crt
xrootd_ca_mode:     file          # file | system | grid
xrootd_ca_dir:      /etc/grid-security/certificates   # grid mode only

# Features — all opt-in
xrootd_http_enabled:       false
xrootd_http_tpc_enabled:   false
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
TPC, Macaroons, SciTokens, Authfile, Monitoring, Reporting, Trace) so the
rendered file contains only what is enabled.  `xrd.tlsca` uses `certfile` or
`certdir` depending on `xrootd_ca_mode`.

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

*No known gaps at this time.*  See Phased Delivery below for planned work.

---

## Phased Delivery

### Phase 1 — Single Server (current)

| Step | Scope |
|------|-------|
| 1a | `common` role: repos, packages, firewall setup, chrony |
| 1b | `certificates` role: all 4 cert modes, vault integration |
| 1c | `xrootd` role: install, dirs, firewall ports, configure, service, validate |
| 1d | Playbooks, inventory examples, `ansible.cfg`, `.gitignore` |
| 1e | `tune` role: kernel + NIC performance tuning *(planned — see below)* |

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

## Role: `tune` *(Phase 1e — planned)*

### Purpose

Apply ESNet ([fasterdata.es.net](https://fasterdata.es.net)) recommended kernel
and NIC performance tuning for high-speed data transfer.  Designed for
Data Transfer Nodes (DTNs) running XRootD at Tier-1 / SRCNet scale
(10G, 40G, 100G). All tuning is opt-in and off by default except the
core sysctl settings.

Reference: ESNet fasterdata.es.net (last reviewed 2026-03-29).

### Design decisions

- **`tune_nic_speed` drives sysctl buffer presets** — operators choose `10g`, `40g`,
  or `100g`; ESNet-recommended `rmem_max`, `wmem_max`, `tcp_rmem`, `tcp_wmem`
  are set automatically.  Every individual parameter is also overridable.
- **sysctl drop-in at `90-xrootd-net.conf`** — the `90-` prefix sits above distro
  defaults (60-) and below operator overrides (99-).
- **ESNet "do not touch" params are explicitly excluded** — `tcp_timestamps`,
  `tcp_sack`, `tcp_congestion_control`, `tcp_mem` are commented out in the
  template with the reason documented.  ESNet explicitly warns against disabling
  timestamps and SACK.
- **`qdisc` runs as a systemd unit** — `tc` commands do not survive reboot.
  A `tune-qdisc.service` (`Type=oneshot RemainAfterExit=yes`) re-applies on boot.
- **grub tasks (IOMMU, SMT) are double-gated** — variable default is `false`,
  and the task emits an explicit `debug` warning that a reboot is pending.
  An optional `tune_grub_reboot: false` variable triggers `ansible.builtin.reboot`
  if set to `true`.
- **`tune_nic_device` guard** — tasks that target a specific NIC (`qdisc`,
  `ethtool`, `jumbo_frames`, `irq_affinity`) skip with a clear `fail_msg`
  if `tune_nic_device` is empty.  No silent no-ops.
- **IRQ affinity requires OFED** — the `set_irq_affinity_bynode.sh` script is
  shipped with Mellanox OFED; the task checks for its presence and skips gracefully
  on non-Mellanox / vanilla kernel nodes.

### Task files

| File | Purpose | Reboot? |
|------|---------|---------|
| `sysctl.yml` | Deploy `90-xrootd-net.conf`, reload sysctl | No |
| `qdisc.yml` | Deploy and enable `tune-qdisc.service` (`tc fq`) | No |
| `ethtool.yml` | Ring buffers, adaptive coalescing, flow control pause frames | No |
| `jumbo_frames.yml` | Set MTU 9000 via nmcli (persistent) | No |
| `cpu_governor.yml` | Install cpupower, set `performance` governor | No |
| `irq_affinity.yml` | Disable irqbalance, deploy IRQ affinity systemd unit | No |
| `grub.yml` | IOMMU passthrough + optional SMT disable in grub | **Yes** |

### NIC identification — why it cannot be automatic

On a multi-interface, multi-bond node a typical interface list looks like:

```
lo  eno1  ens1f0  ens1f1  bond0  bond1  vlan100  docker0
```

There is no programmatic way to identify the *data transfer* NIC. A node
commonly has distinct interfaces for management (SSH/Ansible), data
(XRootD transfers), storage backend (Ceph/NFS), and out-of-band.
Which is which is **site topology knowledge** — it cannot be inferred from
the host.

`tune_nic_device` therefore has no default and **must be set explicitly**
in the inventory, at host level when nodes differ. NIC-specific tasks
(`qdisc`, `ethtool`, `jumbo_frames`, `irq_affinity`) assert it is non-empty
and fail with a descriptive message if it is not set.

`tune_nic_speed: auto` is still valid — it reads
`ansible_facts[tune_nic_device]['speed']` (in Mbps) **after** the operator
has identified the correct NIC. Auto-detection maps:

| Detected speed | Buffer tier |
|---|---|
| ≤ 10 000 Mbps | `10g` |
| 10 001 – 40 000 Mbps | `40g` (covers 25G and 40G) |
| > 40 000 Mbps | `100g` (covers 50G, 100G, 200G) |

When detection fails (virtual NIC reports `-1`, or `tune_nic_device` is
unset) the role warns and falls back to `10g`.

### Key variables

```yaml
# tune_nic_device has no default — must be set at host level in inventory.
# See hosts.yml.example for the recommended multi-host pattern.
tune_nic_device: ""            # data-transfer NIC name: bond0, ens1f0, eth1 …
tune_nic_speed: auto           # auto | 10g | 40g | 100g
                               # auto: detect from ansible_facts[tune_nic_device].speed

tune_sysctl_enabled: true      # TCP buffer sysctl drop-in (always safe, no NIC needed)
tune_qdisc_enabled: false      # tc fq qdisc via systemd unit
tune_ethtool_enabled: false    # ring buffers, adaptive coalescing, flow control
tune_jumbo_frames_enabled: false    # MTU 9000 — only if full path supports it
tune_cpu_governor_enabled: false    # performance governor (recommended for 100G)
tune_irq_affinity_enabled: false    # NUMA IRQ binding (Mellanox/NVIDIA nodes only)
tune_grub_iommu_enabled: false      # IOMMU=pt kernel param (REQUIRES REBOOT)
tune_grub_smt_disable: false        # disable SMT/HT (REQUIRES REBOOT)
tune_grub_reboot: false             # if true, reboot immediately after grub changes
```

### ESNet buffer presets

| Speed | `rmem_max` / `wmem_max` | `tcp_rmem` max | `tcp_wmem` max | Notes |
|-------|------------------------|----------------|----------------|-------|
| `10g` | 64 MB | 32 MB | 32 MB | Multi-stream, ≤ 100ms RTT |
| `40g` | 128 MB | 64 MB | 64 MB | Also: 10G ≤ 200ms RTT |
| `100g` | 2 GB | 1 GB | 1 GB | Adds `optmem_max = 1048576` |

Always set regardless of speed: `tcp_mtu_probing = 1`, `default_qdisc = fq`.

### Integration

- New playbook `playbooks/tune.yml` — standalone, can be run independently
  or before a full server deploy.
- `xrootd_server.yml` gains an optional first role gated by
  `tune_enabled: false` so existing deployments are unaffected.

### Molecule / CI

Sysctl tasks work in the existing privileged Docker scenario (container
inherits host kernel; `sysctl -w` succeeds in privileged mode).
The grub/reboot tasks require a VM-based scenario — deferred to Phase 3.

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
