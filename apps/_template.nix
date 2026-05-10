# ============================================================================
# App Template — copy this file and fill in the TODOs.
#
# Checklist for adding a new app:
#   1. Copy this file to apps/<your-app>.nix
#   2. Fill in appName, domain, imageSha, and GitHub org below
#   3. Add a database entry to modules/postgresql.nix (appDatabases list)
#   4. Add any app-specific secrets to secrets/secrets.yaml
#   5. Import the new file in configuration.nix
#   6. Deploy: nixos-rebuild switch --flake /path/to/nixos#server
#
# Domain notes:
#   - Each app can use any domain or subdomain you control (they don't need
#     to share a single domain). For example, one app could be on
#     api.foo.com and another on dashboard.bar.org.
#   - Every domain used must have its DNS managed through Cloudflare, and
#     the Cloudflare API token must have DNS edit permissions for all zones.
#   - Add an A record in Cloudflare pointing the domain to your server IP.
# ============================================================================
{ config, pkgs, lib, ... }:

let
  appName  = "my-app";       # TODO: container and router name (kebab-case)
  domain   = "my-app.example.com"; # TODO: any domain/subdomain you control (doesn't have to match other apps)
  imageSha = "sha256:0000000000000000000000000000000000000000000000000000000000000000"; # TODO: real image digest
  ghOrg    = "USERNAME";     # TODO: your GitHub org or username
  appPort  = "8080";         # Port the app listens on inside the container
in
{
  virtualisation.oci-containers.containers.${appName} = {
    image = "ghcr.io/${ghOrg}/${appName}@${imageSha}";

    environment = {
      # Database — connects through PgBouncer on the host
      # host.docker.internal resolves to the Docker host
      DATABASE_URL  = "jdbc:postgresql://host.docker.internal:6432/${appName}";
      DATABASE_USER = lib.replaceStrings ["-"] ["_"] appName; # kebab → snake

      # OpenTelemetry — send traces/metrics to the OTel Collector
      OTEL_EXPORTER_OTLP_ENDPOINT = "http://otel-collector:4317";
      OTEL_SERVICE_NAME = appName;

      # App-specific environment variables go here
    };

    # Mount sops-decrypted secrets as an env file (optional)
    # environmentFiles = [ config.sops.secrets."${appName}/env".path ];

    extraOptions = [
      "--network=proxy-net"
      "--add-host=host.docker.internal:host-gateway"
    ];

    labels = {
      "traefik.enable" = "true";
      "traefik.http.routers.${appName}.rule" = "Host(`${domain}`)";
      "traefik.http.routers.${appName}.entrypoints" = "websecure";
      "traefik.http.routers.${appName}.tls.certresolver" = "letsencrypt";
      "traefik.http.routers.${appName}.middlewares" = "forward-auth@file,rate-limit@file,secure-headers@file";
      "traefik.http.services.${appName}.loadbalancer.server.port" = appPort;
    };

    dependsOn = [ "traefik" ];
  };

  # Ensure the container starts after the proxy network exists
  systemd.services."docker-${appName}" = {
    after = [ "docker-network-proxy-net.service" ];
    requires = [ "docker-network-proxy-net.service" ];
  };
}
