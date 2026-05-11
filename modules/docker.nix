{ config, pkgs, lib, ... }:

let
  # Docker networks shared across the stack
  # internal = true means no outbound internet access from that network
  networks = [
    { name = "proxy-net";      internal = false; } # Traefik <-> app containers (needs internet for ACME)
    { name = "postgres-net";   internal = true; }  # Reserved for exporters
    { name = "monitoring-net"; internal = true; }   # Monitoring stack internal communication
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
  ]);
}
