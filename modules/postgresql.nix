{ config, pkgs, lib, ... }:

let
  # Central app database registry.
  # Add one entry per app. Each gets a dedicated database + user.
  appDatabases = [
    { name = "family-archive"; user = "family_archive"; dbName = "family_archive"; }
  ];

  # Docker bridge subnet — containers connect from this range.
  # Verify with: docker network inspect postgres-net | jq '.[0].IPAM.Config[0].Subnet'
  dockerSubnet = "172.18.0.0/16"; # TODO: verify after network creation
in
{
  # --- PostgreSQL ---

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_16;

    settings = {
      # Connection limits — PgBouncer sits in front, so this handles pooled connections
      max_connections = 100;

      # Memory — tune based on available RAM
      # TODO: adjust for your hardware (general rule: shared_buffers = 25% of RAM)
      shared_buffers = "256MB";
      effective_cache_size = "768MB";
      work_mem = "4MB";
      maintenance_work_mem = "128MB";

      # WAL
      wal_buffers = "8MB";

      # Logging
      log_min_duration_statement = 1000; # log queries > 1s
    };

    ensureDatabases = map (app: app.dbName) appDatabases;

    ensureUsers = map (app: {
      name = app.user;
      ensureDBOwnership = true;
    }) appDatabases;

    # Per-app authentication: each user can only connect to its own database
    authentication = lib.mkForce (
      ''
        # Local connections (backups, admin)
        local all      postgres                peer

        local all      all                     peer

        # PgBouncer connects via localhost
        host  all      all      127.0.0.1/32   scram-sha-256

        # Per-app rules — Docker containers connect from the bridge subnet
      ''
      + lib.concatMapStringsSep "\n" (app:
        "host  ${app.dbName}  ${app.user}  ${dockerSubnet}  scram-sha-256"
      ) appDatabases
      + ''

        # Postgres exporter (monitoring)
        host  postgres  postgres_exporter  127.0.0.1/32  scram-sha-256
      ''
    );
  };

  # Generate PgBouncer auth file from PostgreSQL password hashes
  systemd.services.pgbouncer-auth = {
    description = "Generate PgBouncer userlist.txt from pg_shadow";
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    before = [ "pgbouncer.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RuntimeDirectory = "pgbouncer";
      RuntimeDirectoryMode = "0755";
      ExecStart = let
        sql = "SELECT concat('\"', usename, '\" \"', passwd, '\"') FROM pg_shadow WHERE passwd IS NOT NULL";
        psql = "${config.services.postgresql.package}/bin/psql";
      in pkgs.writeShellScript "pgbouncer-auth" ''
        ${pkgs.sudo}/bin/sudo -u postgres ${psql} -Atc "${sql}" > /run/pgbouncer/userlist.txt
        chmod 640 /run/pgbouncer/userlist.txt
        chgrp pgbouncer /run/pgbouncer/userlist.txt
      '';
    };
  };

  # --- PgBouncer ---

  services.pgbouncer = {
    enable = true;

    settings = {
      pgbouncer = {
        pool_mode = "transaction";
        max_client_conn = 400;
        default_pool_size = 20;
        min_pool_size = 5;

        listen_addr = "127.0.0.1,172.17.0.1";
        listen_port = 6432;

        auth_type = "scram-sha-256";
        auth_file = "/run/pgbouncer/userlist.txt";
      };

      databases = lib.listToAttrs (map (app: {
        name = app.dbName;
        value = "host=127.0.0.1 port=5432 dbname=${app.dbName}";
      }) appDatabases);
    };
  };

}
