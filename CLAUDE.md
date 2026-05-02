# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Declarative NixOS configuration for a self-hosted server running Kotlin/Ktor backends as Docker containers (GraalVM native images from GHCR) behind Traefik, with PostgreSQL + PgBouncer, and a full observability stack.

## Key Commands

```bash
# Build and apply configuration (run on the server)
sudo nixos-rebuild switch --flake .#server

# Dry-run to preview changes without applying
nixos-rebuild dry-activate --flake .#server

# Build only (check for evaluation errors)
nixos-rebuild build --flake .#server

# Evaluate a specific config value
nix eval .#nixosConfigurations.server.config.networking.hostName

# Rollback to previous generation
sudo nixos-rebuild switch --rollback

# Deploy an app image update
./scripts/deploy.sh <app-name> <sha256:digest>

# Create a new app database
./scripts/db-create.sh <app-name> <db-user> <db-name>

# Manage backups
./scripts/backup-restore.sh list|restore-db|restore-volume

# Edit encrypted secrets
sops secrets/secrets.yaml
```

## Architecture

- **flake.nix** — Entry point. Pins nixpkgs + sops-nix inputs, defines single `nixosConfigurations.server` output.
- **configuration.nix** — Top-level imports only. Add new app imports here.
- **modules/** — Each file owns one concern (base, ssh, firewall, hardening, secrets, docker, postgresql, traefik, monitoring, backups).
- **apps/** — One file per app container. `_template.nix` is the canonical starting point.
- **secrets/** — sops-nix encrypted secrets (age keys). `.sops.yaml` has key config.
- **scripts/** — Operational helpers (deploy, db-create, backup-restore).

## Adding a New App

1. Copy `apps/_template.nix` to `apps/<name>.nix`
2. Fill in `appName`, `domain`, `imageSha`, `ghOrg`
3. Add database entry to the `appDatabases` list in `modules/postgresql.nix`
4. Import the new file in `configuration.nix`
5. Add any secrets to `secrets/secrets.yaml` and declare in `modules/secrets.nix`

## Conventions

- App names use kebab-case (`my-app`); database users/names use snake_case (`my_app`)
- Images are pinned by digest (`sha256:...`), never by tag
- Each app gets its own Docker network isolation — connects to `proxy-net` for Traefik routing, reaches PostgreSQL via `host.docker.internal:6432` (PgBouncer)
- Apps cannot communicate with each other
- Secrets use sops-nix with age encryption; never store plaintext secrets
- PostgreSQL has per-app users with scoped `pg_hba.conf` rules
- Traefik labels on containers handle routing, TLS, and middleware (ForwardAuth, rate-limit, secure-headers)
- TODOs in the codebase mark placeholders that need real values for deployment
