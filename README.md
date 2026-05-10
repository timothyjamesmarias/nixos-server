# NixOS Server Configuration

Declarative NixOS configuration for a self-hosted server running Kotlin/Ktor backends as Docker containers (GraalVM native images from GHCR) behind Traefik, with PostgreSQL + PgBouncer, and a full observability stack.

## What You Need Before Starting

### Accounts and Services

| Requirement | What it's for | Where to get it |
|---|---|---|
| **Cloudflare account** | DNS management, TLS certificates, DDoS protection | [cloudflare.com](https://cloudflare.com) |
| **Cloudflare API token** | Traefik uses this to issue TLS certs via DNS challenge | Cloudflare dashboard → My Profile → API Tokens → Create Token → Zone:DNS:Edit (scope to **All Zones** if using multiple domains) |
| **Domain name(s)** | Routed through Cloudflare to your server. Each app can use a different domain — they don't need to share one. | Any registrar, then add each domain to Cloudflare |
| **GitHub account** | Container registry for app images | [github.com](https://github.com) |
| **GHCR personal access token** | Pulling private container images from GitHub | GitHub → Settings → Developer settings → Personal access tokens → `read:packages` scope |

### On Your Local Machine

| Requirement | What it's for | Install |
|---|---|---|
| **`sops`** | Encrypting/decrypting secrets | `brew install sops` |
| **`age`** | Key pair for sops encryption | `brew install age` |
| **SSH key pair** | Accessing the server | `ssh-keygen -t ed25519` (if you don't have one) |
| **Git** | Cloning/pushing this repo | `brew install git` (or Xcode CLI tools) |

### On the Server

| Requirement | What it's for | How |
|---|---|---|
| **NixOS installed** | The operating system | [nixos.org/download](https://nixos.org/download) — minimal ISO is fine |
| **SSH access** | Remote management | Enable `services.openssh.enable = true` in the installer config, or at the console after install |
| **Internet/DNS working** | Downloading packages | Verify with `ping cache.nixos.org` — if DNS fails, add `nameserver 1.1.1.1` to `/etc/resolv.conf` |
| **`age` key pair** | Decrypting secrets at build time | `nix-shell -p age --run "age-keygen -o /var/lib/sops-nix/key.txt"` — note the public key |

### Information You'll Need to Fill In

These are the values marked `TODO` throughout the config files:

| Value | Where it goes | Example |
|---|---|---|
| **Hostname** | `configuration.nix` | `homelab` |
| **stateVersion** | `configuration.nix` | Check `grep stateVersion /etc/nixos/configuration.nix` on the server |
| **Timezone** | `modules/base.nix` | `America/New_York`, `America/Los_Angeles`, etc. |
| **SSH public key(s)** | `modules/base.nix` | `ssh-ed25519 AAAA...` |
| **Domain(s)** | `apps/example-api.nix`, `modules/traefik.nix`, `modules/monitoring.nix` | Each app sets its own domain — e.g. `api.foo.com`, `app.bar.org`, `grafana.foo.com` |
| **Cloudflare email** | `modules/traefik.nix` | Your Cloudflare account email |
| **ACME email** | `modules/traefik.nix` | Email for Let's Encrypt certificate notifications |
| **GitHub username/org** | `modules/docker.nix`, `apps/example-api.nix` | Your GitHub username |
| **Container image digest** | `apps/example-api.nix` | `sha256:abc123...` from your CI build |
| **PostgreSQL tuning** | `modules/postgresql.nix` | `shared_buffers` = 25% of server RAM |
| **Docker subnet** | `modules/postgresql.nix` | Verify `172.18.0.0/16` matches after Docker network creation |

### Secrets (encrypted via sops-nix)

These go in `secrets/secrets.yaml` (encrypted). See `secrets/secrets.example.yaml` for the structure.

| Secret | What it's for | How to get it |
|---|---|---|
| **`ghcr-token`** | Pulling private images from GitHub Container Registry | GitHub → Settings → Developer settings → Personal access tokens → `read:packages` |
| **`cloudflare-api-token`** | Traefik DNS challenge for TLS certs | Cloudflare → My Profile → API Tokens → Zone:DNS:Edit (use **All Zones** for multi-domain setups) |
| **`grafana-admin-password`** | Grafana web UI login | Choose a password |
| **`postgres-exporter-dsn`** | Prometheus monitoring of PostgreSQL | `postgresql://postgres_exporter:<password>@localhost:5432/postgres?sslmode=disable` |
| **`auth-service/jwt-secret`** | JWT signing for the auth ForwardAuth service | Generate with `openssl rand -hex 32` |

## Setup Steps

### 1. Generate hardware configuration

On the server:

```bash
nixos-generate-config --show-hardware-config
```

Copy the output into `hardware-configuration.nix`, replacing the placeholder.

### 2. Generate age key for secrets

On the server:

```bash
sudo mkdir -p /var/lib/sops-nix
nix-shell -p age --run "sudo age-keygen -o /var/lib/sops-nix/key.txt"
sudo chmod 600 /var/lib/sops-nix/key.txt
sudo cat /var/lib/sops-nix/key.txt   # note the public key (age1...)
```

### 3. Configure sops

On your local machine, update `secrets/.sops.yaml` with the server's age public key from step 2:

```yaml
keys:
  - &server age1your-public-key-here
creation_rules:
  - path_regex: secrets\.yaml$
    key_groups:
      - age:
          - *server
```

Then create the encrypted secrets file:

```bash
sops secrets/secrets.yaml
# Fill in values per secrets.example.yaml, save and exit
```

### 4. Fill in TODOs

Search for `TODO` across all `.nix` files and fill in your values. The full list is in the table above under "Information You'll Need to Fill In."

```bash
grep -rn "TODO" --include="*.nix"
```

### 5. Copy config to the server

```bash
# If repo is on GitHub
ssh user@server "git clone https://github.com/YOU/nixos-server.git /etc/nixos"

# Or rsync from your local machine
rsync -avz --exclude .git ./ user@server:/etc/nixos/
```

### 6. Build and apply

On the server:

```bash
cd /etc/nixos
sudo nixos-rebuild switch --flake .#server
```

### 7. Verify

```bash
systemctl status docker
systemctl status postgresql
systemctl status traefik
ssh deploy@<server-ip>   # test key-based login as the deploy user
```

## Architecture

```
Internet → Cloudflare (DNS / DDoS / WAF — one or more domains)
  │
  └─ NixOS Host (firewall: 80/443 only)
      │
      ├─ Traefik (reverse proxy, auto TLS via DNS challenge per domain)
      │    ├─ api.foo.com          → app-one:8080
      │    ├─ dashboard.bar.org    → app-two:8080
      │    └─ grafana.foo.com      → grafana:3000
      │
      ├─ App containers (isolated Docker networks)
      │    └─ GraalVM native images pulled from GHCR
      │
      ├─ PostgreSQL (NixOS-managed, single instance)
      │    ├─ PgBouncer (transaction-mode connection pooling)
      │    └─ One database + user per app, scoped pg_hba.conf
      │
      └─ Monitoring
           ├─ Prometheus (metrics)
           ├─ Grafana (dashboards)
           ├─ Loki (logs)
           └─ OTel Collector (receives OTLP from apps)
```

### Network Isolation

Each app container connects to `proxy-net` (so Traefik can route to it) and reaches PostgreSQL via `host.docker.internal`. Apps cannot communicate with each other.

```
proxy-net        ← Traefik + all app containers
postgres-net     ← (reserved, exporters)
monitoring-net   ← Prometheus, Grafana, Loki, OTel Collector, exporters
```

## Adding a New App

1. Copy `apps/_template.nix` to `apps/<name>.nix`
2. Fill in `appName`, `domain`, `imageSha`, `ghOrg` — the domain can be any domain/subdomain you control, it doesn't have to match other apps
3. Add database entry to the `appDatabases` list in `modules/postgresql.nix`
4. Import the new file in `configuration.nix`
5. Add any secrets to `secrets/secrets.yaml` and declare in `modules/secrets.nix`
6. If using a new domain (not just a new subdomain of an existing one), add the domain to Cloudflare and ensure the API token has DNS edit access for it
7. Add an A record in Cloudflare pointing the domain to your server's IP
8. Deploy:

```bash
sudo nixos-rebuild switch --flake .#server
```

## Operations

### Deploying updates

```bash
# Via script (updates image SHA and rebuilds)
./scripts/deploy.sh <app-name> <sha256:digest>

# Manual: edit the imageSha in apps/<name>.nix, then rebuild
sudo nixos-rebuild switch --flake .#server

# Rollback
sudo nixos-rebuild switch --rollback
```

### Managing secrets

```bash
# Edit secrets (decrypts in-place, re-encrypts on save)
sops secrets/secrets.yaml

# Add a new secret: add key to secrets.yaml, declare in modules/secrets.nix
sops.secrets."my-app/api-key" = { owner = "root"; };
```

### Backups

| What | When | Retention |
|---|---|---|
| PostgreSQL databases | Daily 3:00 AM | 30 days |
| Docker volumes | Weekly Sunday 4:00 AM | 30 days |

Stored in `/var/backups/`.

```bash
./scripts/backup-restore.sh list
./scripts/backup-restore.sh restore-db <db_name> <backup_file>
./scripts/backup-restore.sh restore-volume <volume_name> <backup_file>
```

### Monitoring

- **Grafana** at `grafana.yourdomain.com` — dashboards for system and app metrics
- **Prometheus** — scrapes node-exporter, postgres-exporter, Traefik
- **Loki** — aggregated container and system logs
- **OTel Collector** — receives OTLP telemetry from app containers

### Troubleshooting

```bash
# Container won't start
systemctl status docker-<app-name>.service
journalctl -u docker-<app-name>.service -n 50

# TLS certificate issues
docker logs traefik 2>&1 | grep -i acme

# Database connection refused
systemctl status postgresql
systemctl status pgbouncer

# Rebuild errors
nixos-rebuild build --flake .#server   # build without applying
```

## File Structure

```
├── flake.nix                   Flake entry point (inputs + outputs)
├── configuration.nix           Top-level imports
├── hardware-configuration.nix  Hardware-specific config (generated)
├── modules/
│   ├── base.nix                Users, locale, base packages
│   ├── ssh.nix                 SSH hardening + fail2ban
│   ├── firewall.nix            iptables rules
│   ├── hardening.nix           Kernel sysctl + module blacklist
│   ├── docker.nix              Docker daemon + shared networks
│   ├── postgresql.nix          PostgreSQL + PgBouncer + app DB registry
│   ├── traefik.nix             Reverse proxy + TLS + ForwardAuth
│   ├── monitoring.nix          Prometheus, Grafana, Loki, OTel, exporters
│   ├── backups.nix             Scheduled pg_dump + volume backups
│   └── secrets.nix             sops-nix secret declarations
├── apps/
│   ├── _template.nix           Copy this for new apps
│   └── example-api.nix         Working example
├── scripts/
│   ├── deploy.sh               Update image SHA + rebuild
│   ├── db-create.sh            Create app database + user
│   └── backup-restore.sh       List and restore backups
└── secrets/
    ├── .sops.yaml              Age key config for sops
    └── secrets.example.yaml    Template for secrets.yaml
```

## Security

```
Layer 0  Cloudflare        DDoS protection, WAF, bot filtering
Layer 1  NixOS firewall    Only TCP 80/443 open to the world
Layer 2  SSH               Key-only auth, fail2ban (3 retries, 1h ban)
Layer 3  Kernel            sysctl hardening (syncookies, no redirects, rp_filter)
Layer 4  Traefik           TLS termination, HSTS, rate limiting, ForwardAuth
Layer 5  Auth service      JWT validation via Traefik ForwardAuth middleware
Layer 6  App-level         Authorization logic in your Kotlin code
Layer 7  PostgreSQL        Per-app user, scoped pg_hba.conf, no cross-db access
Layer 8  Docker networks   Apps isolated from each other
Layer 9  Secrets           Encrypted at rest via sops-nix (age), decrypted at boot
```
