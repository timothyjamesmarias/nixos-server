{ config, pkgs, lib, ... }:

let
  # Docker networks shared across the stack
  # internal = true means no outbound internet access from that network
  # All networks use default (bridge) mode.
  # Docker→LAN isolation is handled by iptables rules in firewall.nix.
  networks = [
    { name = "proxy-net";      internal = false; }
    { name = "postgres-net";   internal = false; }
    { name = "monitoring-net"; internal = false; }
  ];

  # Generate a systemd oneshot service that creates a Docker network if it doesn't exist
  mkNetworkService = net: {
    "docker-network-${net.name}" = {
      description = "Create Docker network ${net.name}";
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "create-network-${net.name}" ''
          ${pkgs.docker}/bin/docker network create ${lib.optionalString net.internal "--internal"} ${net.name} || true
        '';
        ExecStop = pkgs.writeShellScript "remove-network-${net.name}" ''
          ${pkgs.docker}/bin/docker network rm ${net.name} || true
        '';
      };
    };
  };
in
{
  virtualisation.oci-containers.backend = "docker";

  virtualisation.docker = {
    enable = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
      flags = [ "--all" "--volumes" ];
    };
  };

  # Docker socket proxy — restricts API access for Traefik
  virtualisation.oci-containers.containers.docker-socket-proxy = {
    image = "tecnativa/docker-socket-proxy:0.3.0";
    volumes = [
      "/var/run/docker.sock:/var/run/docker.sock:ro"
    ];
    environment = {
      CONTAINERS = "1";
      NETWORKS = "1";
      SERVICES = "0";
      TASKS = "0";
      SWARM = "0";
      NODES = "0";
      BUILD = "0";
      COMMIT = "0";
      CONFIGS = "0";
      DISTRIBUTION = "0";
      EXEC = "0";
      IMAGES = "0";
      INFO = "0";
      PLUGINS = "0";
      SECRETS = "0";
      SYSTEM = "0";
      VOLUMES = "0";
      POST = "0";
    };
    extraOptions = [
      "--network=proxy-net"
    ];
  };

  # Create shared Docker networks
  systemd.services = lib.mkMerge (map mkNetworkService networks ++ [
    {
      # Login to GHCR on boot using sops-decrypted token
      docker-ghcr-login = {
        description = "Login to GitHub Container Registry";
        after = [ "docker.service" "sops-nix.service" ];
        requires = [ "docker.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "ghcr-login" ''
            ${pkgs.docker}/bin/docker login ghcr.io \
              -u timothyjamesmarias \
              --password-stdin < ${config.sops.secrets."ghcr-token".path}
          '';
        };
      };
    }
    {
      # Ensure socket proxy starts after proxy-net exists
      docker-docker-socket-proxy.after = [ "docker-network-proxy-net.service" ];
      docker-docker-socket-proxy.requires = [ "docker-network-proxy-net.service" ];
    }
  ]);
}
