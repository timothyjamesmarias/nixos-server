# Setup Lessons Learned

Hard-won knowledge from actually setting up this server. Read this before you start.

## NixOS is declarative — it will remove things you don't declare

If your config defines a `deploy` user but not the `user` account you've been using, `nixos-rebuild switch` **will delete that user**. You will be locked out if `deploy` doesn't have a working SSH key and the firewall allows port 22.

**Before every `nixos-rebuild switch`, verify:**
1. Your SSH user exists in the config (`modules/base.nix`)
2. Your SSH public key is on that user
3. Port 22 is in `allowedTCPPorts` in `modules/firewall.nix`
4. `services.openssh.enable = true` in `modules/ssh.nix`

If you get any of these wrong, you need physical access (keyboard + monitor) to recover.

## The firewall does NOT auto-open SSH

Despite comments you may see in NixOS configs, the firewall does not automatically open port 22 just because `services.openssh.enable = true`. You must explicitly add `22` to `networking.firewall.allowedTCPPorts`. If you don't, you will lose SSH access on the next rebuild.

## Always dry-run before switching

```bash
nixos-rebuild build --flake ~/nixos-server#server
```

This catches evaluation errors without changing the running system. It won't catch runtime issues (like a service failing to start), but it prevents the worst mistakes.

## Recovery options when locked out

In order of least to most painful:

1. **Boot previous generation** — Reboot, select the previous entry in the systemd-boot menu. This restores the old config including users and firewall rules. Requires keyboard + monitor.

2. **USB tethering** — If the server has no ethernet (e.g., you moved it to your desk), plug your phone in via USB-C and enable USB tethering. The server will pick up the interface. Bring it up with:
   ```bash
   ip link set <interface> up
   dhcpcd <interface>
   ```
   Find the interface name with `ip link`. It'll be something like `enp0s20f0u1`.

3. **NixOS installer USB** — Boot from the installer, mount the drive, chroot in, fix the config.

## sops-nix setup order

1. Generate age key on the server (`age-keygen -o /var/lib/sops-nix/key.txt`)
2. Generate age key on your local machine (`age-keygen -o ~/Library/Application Support/sops/age/keys.txt` on macOS)
3. Put **both** public keys in `.sops.yaml` (repo root, not `secrets/`)
4. Create `secrets/secrets.yaml` with `sops secrets/secrets.yaml`
5. If you already created secrets with only the server key, run `sops updatekeys secrets/secrets.yaml` **on the server** (as root, with `SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt`) to re-encrypt for both keys

**Common mistakes:**
- `.sops.yaml` in `secrets/` instead of repo root — sops won't find it
- Only the server's age key in `.sops.yaml` — you can't edit secrets from your local machine
- `path_regex` doesn't match the file path relative to `.sops.yaml` location

## Git on the server

The server needs to pull the config repo. Set up SSH for GitHub on the server:

```bash
ssh-keygen -t ed25519
cat ~/.ssh/id_ed25519.pub
# Add to GitHub → Settings → SSH keys
```

Use SSH URLs (`git@github.com:...`), not HTTPS. HTTPS will prompt for credentials that won't work without a token embedded in the URL.

If you get "not owned by current user" errors when rebuilding, it's because you pulled as a different user (e.g., root). Fix with:
```bash
sudo chown -R deploy:users ~/nixos-server
```

## DNS can break during rebuild

NixOS may switch network managers during a rebuild (e.g., from NetworkManager to dhcpcd). If DNS stops working:

```bash
echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf
```

## Static IP setup

Without a static IP, DHCP may assign a different address after a reboot. Set it in `configuration.nix`:

```nix
networking.interfaces.<your-interface>.ipv4.addresses = [{
  address = "192.168.1.7";  # pick an IP outside your router's DHCP range
  prefixLength = 24;
}];
networking.defaultGateway = "192.168.1.1";
networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];
```

Find your interface name: `ip route show default` — it's the name after `dev`.

## Docker vs Podman

NixOS defaults `virtualisation.oci-containers` to **podman**, not Docker. If you want Docker, you must set:

```nix
virtualisation.oci-containers.backend = "docker";
```

Without this, containers start as `podman-*` services and may not work with Docker-specific features (like Docker networks).

## systemd ExecStart is not a shell

This does NOT work in `serviceConfig.ExecStart`:

```nix
ExecStart = "docker network create my-net || true";
```

systemd passes `||` and `true` as literal arguments to docker. Wrap in a script:

```nix
ExecStart = pkgs.writeShellScript "create-network" ''
  docker network create my-net || true
'';
```

## Secrets must exist before rebuild

If `modules/secrets.nix` declares a secret that doesn't exist in `secrets/secrets.yaml`, the rebuild will fail. When adding placeholder values, make sure the YAML structure matches what sops-nix expects. Nested keys use `/` in sops-nix:

```yaml
# In secrets.yaml — this creates the secret "auth-service/jwt-secret"
auth-service:
    jwt-secret: placeholder
```

Not:
```yaml
# WRONG — sops treats this as a flat string, not a nested key
auth-service/jwt-secret: placeholder
```

## Port forwarding comes last

Don't expose the server to the internet until:
1. All placeholder credentials are replaced with real values
2. The firewall is properly configured (Docker→LAN isolation)
3. SSH is locked down (key-only, fail2ban)
4. You've verified services are running (`sudo docker ps`, `sudo systemctl --failed`)

## Useful commands

```bash
# See what generation you're running
nixos-rebuild list-generations

# Roll back to previous generation (if something breaks)
sudo nixos-rebuild switch --rollback

# Check all failed services
sudo systemctl --failed

# See running containers
sudo docker ps

# View container logs
sudo docker logs <container-name>

# Test the nix config without applying
nixos-rebuild build --flake ~/nixos-server#server

# Rebuild and switch
cd ~/nixos-server && git pull && sudo nixos-rebuild switch --flake ~/nixos-server#server
```
