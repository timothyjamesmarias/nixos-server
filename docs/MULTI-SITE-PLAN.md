# Multi-Site Deployment Plan

Plan for running the same stack across two geographically separate servers with database replication and automatic failover.

## Architecture

```
                         Cloudflare
                    (DNS failover or load balancer)
                   /                                \
          Location A                          Location B
          NixOS Server                        NixOS Server
          (primary)                           (replica)
              |                                   |
         PostgreSQL ── streaming replication ──> PostgreSQL
              |            (via WireGuard)         |
         PgBouncer                            PgBouncer
              |                                   |
         Traefik                              Traefik
              |                                   |
         App containers                      App containers
```

## Why NixOS Makes This Easier

Both servers share the same flake. `flake.nix` defines two outputs:

```nix
nixosConfigurations = {
  server-a = mkSystem ./hosts/server-a.nix;
  server-b = mkSystem ./hosts/server-b.nix;
};
```

Each host file imports the same shared modules but provides host-specific values (hardware config, IP, replication role). Most modules don't change at all — Docker, Traefik, monitoring, firewall, hardening, SSH are identical.

## Components

### 1. Cloudflare Failover

Two approaches, cheapest first:

**DNS-based failover (free):** Add two A records for the same subdomain, both proxied. Cloudflare round-robins by default. Enable Health Checks (free tier has limited checks) to detect when a server is down and stop routing to it.

**Cloudflare Load Balancer (paid, ~$5/month):** Active health checks, weighted routing, geo-steering, session affinity. More reliable failover with configurable thresholds.

Either way, the DDNS module (`cloudflare-ddns.nix`) on each server keeps its own A record updated.

### 2. WireGuard Tunnel

Secure private link between the two servers for database replication traffic. No replication data goes over the public internet unencrypted.

```nix
# modules/wireguard.nix
networking.wireguard.interfaces.wg0 = {
  ips = [ "10.0.0.1/24" ];  # .1 for server-a, .2 for server-b
  listenPort = 51820;
  privateKeyFile = config.sops.secrets."wireguard-private-key".path;
  peers = [{
    publicKey = "peer-public-key";
    endpoint = "peer-public-ip:51820";
    allowedIPs = [ "10.0.0.0/24" ];
    persistentKeepalive = 25;
  }];
};
```

Firewall: open UDP 51820 on both servers.

PostgreSQL replication connects over `10.0.0.x` addresses (WireGuard), not public IPs.

### 3. PostgreSQL Streaming Replication

**Primary (server-a):**

```nix
# modules/postgresql-primary.nix
services.postgresql.settings = {
  wal_level = "replica";
  max_wal_senders = 3;
  wal_keep_size = "1GB";
};

# pg_hba.conf entry for replication
# host replication replicator 10.0.0.2/32 scram-sha-256
```

Create a replication user:
```sql
CREATE USER replicator WITH REPLICATION PASSWORD 'secret';
```

**Replica (server-b):**

```nix
# modules/postgresql-replica.nix
services.postgresql.settings = {
  hot_standby = true;
};

# Set up with pg_basebackup initially:
# pg_basebackup -h 10.0.0.1 -U replicator -D /var/lib/postgresql/16 -Fp -Xs -R
```

The `-R` flag creates `standby.signal` and sets `primary_conninfo` automatically.

### 4. Application Write Routing

The replica is read-only. Options for handling writes:

**Option A: All writes go to primary.** Apps on server-b proxy write requests to server-a. Simplest but adds latency for writes from location B.

**Option B: Smart client routing.** Each app connects to PgBouncer. PgBouncer on the primary points to the local PostgreSQL. PgBouncer on the replica points to the primary's PostgreSQL over WireGuard for writes, local PostgreSQL for reads. Requires read/write splitting in the app or middleware.

**Option C: Primary-only writes with Cloudflare.** Cloudflare routes all traffic to the primary. Replica is standby-only, activated on failover. Simplest operationally — no write routing logic needed.

Recommendation: **Start with Option C.** It's the least complex and covers the main use case (disaster recovery). Move to A or B only if you need active-active for latency reasons.

### 5. Failover Procedure

When the primary goes down:

1. Cloudflare health check detects failure, stops routing to server-a
2. On server-b, promote the replica:
   ```bash
   sudo -u postgres pg_ctl promote -D /var/lib/postgresql/16
   ```
3. Server-b is now the primary — accepts writes
4. Update Cloudflare to route all traffic to server-b (automatic if using health checks)
5. When server-a recovers, set it up as the new replica

Automate step 2 with a promotion script that runs when the health check fails:

```bash
#!/bin/bash
# Check if primary is reachable over WireGuard
if ! pg_isready -h 10.0.0.1 -p 5432 -t 5; then
  echo "Primary unreachable, promoting replica"
  sudo -u postgres pg_ctl promote -D /var/lib/postgresql/16
fi
```

This could be a systemd timer, but be careful with split-brain — both servers thinking they're primary. Use a fencing mechanism or manual confirmation for safety.

### 6. Backup Strategy

With two sites:
- Primary backs up to local storage (already configured)
- Replicate backups to server-b (or vice versa) via rsync over WireGuard
- Optionally push to a third location (B2, S3) for true offsite backup

## File Structure Changes

```
├── flake.nix                        Add server-b to nixosConfigurations
├── hosts/
│   ├── server-a.nix                 Host-specific: hardware, IP, role = "primary"
│   └── server-b.nix                 Host-specific: hardware, IP, role = "replica"
├── modules/
│   ├── wireguard.nix                WireGuard tunnel between sites
│   ├── postgresql-primary.nix       WAL sender config, replication user
│   ├── postgresql-replica.nix       Hot standby config, recovery settings
│   └── ... (existing modules)       Shared unchanged
├── scripts/
│   ├── promote-replica.sh           Promote replica to primary
│   ├── setup-replica.sh             Initial pg_basebackup from primary
│   └── ... (existing scripts)
```

## New Secrets

| Secret | What it's for |
|---|---|
| `wireguard-private-key` | WireGuard tunnel (each server has its own) |
| `replication-password` | PostgreSQL replication user |

## Order of Implementation

1. **WireGuard tunnel** — Get the two servers talking privately
2. **PostgreSQL streaming replication** — Get data flowing
3. **Replica app containers** — Same apps running on server-b (read-only mode or proxying writes)
4. **Cloudflare failover** — Health checks + automatic DNS failover
5. **Promotion automation** — Scripts and monitoring for failover
6. **Backup replication** — Cross-site backup sync

## Open Questions

- **Consistency requirements:** Can your apps tolerate a few seconds of replication lag? Streaming replication is async by default (some data loss on failover). Synchronous replication eliminates data loss but adds write latency.
- **Docker volumes:** Stateful containers (Grafana, Prometheus data) need their own replication strategy or should be treated as ephemeral on the replica.
- **Split-brain prevention:** How to ensure only one server is primary at a time. Options: manual promotion only, quorum-based (needs a third node), or external arbitrator.
- **Cost:** Second server hardware, second residential ISP, Cloudflare Load Balancer ($5/month) if using paid failover.
