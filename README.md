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

**Note:** You only need the Cloudflare account and API token during initial setup. You don't need to add domains or create DNS records until you're ready to deploy an app.

### On Your Local Machine

| Requirement | What it's for | Install |
|---|---|---|
| **`sops`** | Encrypting/decrypting secrets | `brew install sops` |
| **`age`** | Key pair for sops encryption | `brew install age` |
| **SSH key pair** | Accessing the server | `ssh-keygen -t ed25519 -f ~/.ssh/your-server-key` |
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
| **stateVersion** | `configuration.nix` | Run `grep stateVersion /etc/nixos/configuration.nix` on the server |
| **SSH public key(s)** | `modules/base.nix` | `ssh-ed25519 AAAA...` |
| **Cloudflare email** | `modules/traefik.nix` | Your Cloudflare account email |
| **ACME email** | `modules/traefik.nix` | Email for Let's Encrypt certificate notifications |
| **GitHub username** | `modules/docker.nix` | Your GitHub username |
| **PostgreSQL tuning** | `modules/postgresql.nix` | `shared_buffers` = 25% of server RAM |

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

On your local machine, generate a local age key so you can edit secrets from your machine:

```bash
age-keygen -o ~/Library/Application\ Support/sops/age/keys.txt
# Note the public key (age1...)
```

Update `.sops.yaml` in the repo root with both the server's and your local age public keys:

```yaml
keys:
  - &server age1-server-public-key-here
  - &local age1-your-local-public-key-here
creation_rules:
  - path_regex: secrets/secrets\.yaml$
    key_groups:
      - age:
          - *server
          - *local
```

**Important:** `.sops.yaml` must be in the repo root, not inside `secrets/`.

Then create the encrypted secrets file:

```bash
sops secrets/secrets.yaml
# Fill in values per secrets.example.yaml, save and exit
```

You can use `placeholder` for secrets you don't have yet (like GHCR token). The Cloudflare API token should be real if you want TLS to work.

### 4. Fill in config values

Search for `TODO` across all `.nix` files and fill in your values:

```bash
grep -rn "TODO" --include="*.nix"
```

**Critical values to set before first rebuild:**

- `configuration.nix` — `stateVersion` (must match your NixOS install)
- `modules/base.nix` — Your SSH public key on the `deploy` user
- `modules/traefik.nix` — Cloudflare email and ACME email
- `modules/docker.nix` — GitHub username for GHCR login

### 5. Build without applying (dry run)

Before applying anything, test that the config evaluates:

```bash
nixos-rebuild build --flake .#server
```

**Review the config carefully before switching.** In particular, verify:
- Port 22 is in `firewall.nix` `allowedTCPPorts` (or you will lose SSH access)
- Your SSH key is configured on the `deploy` user
- The `deploy` user exists and has sudo access

### 6. Clone on the server and apply

On the server, set up an SSH key for GitHub:

```bash
ssh-keygen -t ed25519
cat ~/.ssh/id_ed25519.pub
# Add this to GitHub → Settings → SSH keys
```

Clone and apply:

```bash
git clone git@github.com:YOU/nixos-server.git ~/nixos-server
sudo ln -sfn ~/nixos-server /etc/nixos/nixos-server
sudo nixos-rebuild switch --flake ~/nixos-server#server
```

### 7. Verify

```bash
# Core services
systemctl status docker
systemctl status postgresql
systemctl status pgbouncer
sudo docker ps  # should show traefik + monitoring containers

# SSH still works (test from local machine!)
ssh -i ~/.ssh/your-server-key deploy@<server-ip>

# Check for failures
sudo systemctl --failed
```

### 8. Set a static IP

Add to `configuration.nix` (replace values for your network):

```nix
networking.interfaces.enp86s0.ipv4.addresses = [{
  address = "192.168.1.7";
  prefixLength = 24;
}];
networking.defaultGateway = "192.168.1.1";
networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];
```

Find your interface name with `ip route show default` on the server.

### 9. Port forwarding and Cloudflare (when ready for public access)

1. Forward TCP 80 and 443 on your router to the server's static IP
2. Add your domain to Cloudflare, update nameservers at your registrar
3. Create A records pointing your app domains to your public IP
4. Traefik handles TLS automatically via DNS challenge

## Architecture

```
Internet → Cloudflare (DNS / DDoS / WAF — one or more domains)
  |
  └─ Router (port forward 80/443)
      |
      └─ NixOS Host (firewall: 22/80/443, Docker→LAN blocked)
          |
          ├─ Traefik (reverse proxy, auto TLS via DNS challenge per domain)
          |    ├─ api.foo.com          → app-one:8080
          |    ├─ dashboard.bar.org    → app-two:8080
          |    └─ grafana.foo.com      → grafana:3000
          |
          ├─ App containers (isolated Docker networks)
          |    └─ GraalVM native images pulled from GHCR
          |
          ├─ PostgreSQL (NixOS-managed, single instance)
          |    ├─ PgBouncer (connection pooling, bound to localhost + Docker bridge)
          |    └─ One database + user per app, scoped pg_hba.conf
          |
          └─ Monitoring (internal network, no internet access)
               ├─ Prometheus (metrics)
               ├─ Grafana (dashboards)
               ├─ Loki (logs)
               └─ OTel Collector (receives OTLP from apps)
```

### Network Isolation

Each app container connects to `proxy-net` (so Traefik can route to it) and reaches PostgreSQL via `host.docker.internal:6432` (PgBouncer). Apps cannot communicate with each other. Docker containers are blocked from reaching the home LAN via iptables rules.

```
proxy-net        ← Traefik + all app containers (has internet access)
postgres-net     ← Reserved for exporters (internal, no internet)
monitoring-net   ← Prometheus, Grafana, Loki, OTel Collector (internal, no internet)
```

## Adding a New App

1. Copy `apps/_template.nix` to `apps/<name>.nix`
2. Fill in `appName`, `domain`, `imageSha`, `ghOrg` — the domain can be any domain/subdomain you control, it doesn't have to match other apps
3. Add database entry to the `appDatabases` list in `modules/postgresql.nix`
4. Import the new file in `configuration.nix`
5. Add any secrets to `secrets/secrets.yaml` and declare in `modules/secrets.nix`
6. If using a new domain (not just a new subdomain of an existing one), add the domain to Cloudflare and ensure the API token has DNS edit access for it
7. Add an A record in Cloudflare pointing the domain to your server's public IP
8. Deploy:

```bash
cd ~/nixos-server && sudo nixos-rebuild switch --flake ~/nixos-server#server
```

## Operations

### Deploying updates

```bash
# Via script (updates image SHA and rebuilds)
./scripts/deploy.sh <app-name> <sha256:digest>

# Manual: edit the imageSha in apps/<name>.nix, then rebuild
sudo nixos-rebuild switch --flake ~/nixos-server#server

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
- **Prometheus** — scrapes node-exporter, postgres-exporter, Traefik (metrics on internal port 8082)
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
nixos-rebuild build --flake ~/nixos-server#server   # build without applying

# Check all failed services
sudo systemctl --failed
```

## File Structure

```
├── flake.nix                   Flake entry point (inputs + outputs)
├── flake.lock                  Pinned dependency versions
├── .sops.yaml                  Age key config for sops (must be in repo root)
├── configuration.nix           Top-level imports + bootloader + static IP
├── hardware-configuration.nix  Hardware-specific config (generated on server)
├── modules/
│   ├── base.nix                Users, locale, base packages, sudo rules
│   ├── ssh.nix                 SSH hardening + fail2ban
│   ├── firewall.nix            iptables rules + Docker→LAN isolation
│   ├── hardening.nix           Kernel sysctl + module blacklist
│   ├── docker.nix              Docker daemon + shared networks (internal/external)
│   ├── postgresql.nix          PostgreSQL + PgBouncer + app DB registry
│   ├── traefik.nix             Reverse proxy + TLS + ForwardAuth
│   ├── monitoring.nix          Prometheus, Grafana, Loki, OTel, exporters
│   ├── backups.nix             Scheduled pg_dump + volume backups
│   └── secrets.nix             sops-nix secret declarations
├── apps/
│   └── _template.nix           Copy this for new apps
├── scripts/
│   ├── deploy.sh               Update image SHA + rebuild
│   ├── db-create.sh            Create app database + user
│   └── backup-restore.sh       List and restore backups
└── secrets/
    └── secrets.example.yaml    Template for secrets.yaml
```

## Security

```
Layer 0  Cloudflare        DDoS protection, WAF, bot filtering
Layer 1  Router            Port forward only 80/443 to the server
Layer 2  NixOS firewall    TCP 22/80/443 open, Docker→LAN traffic blocked
Layer 3  SSH               Key-only auth, no root login, fail2ban (3 retries, 1h ban)
Layer 4  Kernel            sysctl hardening (syncookies, no redirects, rp_filter)
Layer 5  Traefik           TLS termination, HSTS, rate limiting, ForwardAuth
Layer 6  Docker networks   Apps isolated from each other, monitoring on internal network
Layer 7  Auth service      JWT validation via Traefik ForwardAuth middleware
Layer 8  App-level         Authorization logic in your Kotlin code
Layer 9  PostgreSQL        Per-app user, scoped pg_hba.conf, no cross-db access
Layer 10 PgBouncer         Bound to localhost + Docker bridge only
Layer 11 Secrets           Encrypted at rest via sops-nix (age), decrypted at boot
Layer 12 Metrics           Prometheus endpoint on internal port only, not publicly accessible
```
