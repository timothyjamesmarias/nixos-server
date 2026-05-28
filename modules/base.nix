{ config, pkgs, lib, ... }:

{
  # Flakes
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Garbage collection
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Persistent system logs
  services.journald.extraConfig = ''
    Storage=persistent
    SystemMaxUse=1G
  '';

  # Locale
  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # Base packages
  environment.systemPackages = with pkgs; [
    vim
    htop
    curl
    git
    jq
    tmux
    ripgrep
    fd
    openssl
  ];

  # Declarative user management — passwords are set from sops on every rebuild
  users.mutableUsers = false;

  # Root password from sops (safety net for manual administration)
  users.users.root.hashedPasswordFile = config.sops.secrets."root-password".path;

  # Deploy user — SSH key auth only, no password
  users.users.deploy = {
    isNormalUser = true;
    hashedPassword = "!";
    extraGroups = [ "docker" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEJvpe/fxnamo6zzOVoxK3WfouV1LyIrd5JCHXvfyH+v timmarias@Tims-MacBook-Pro.local"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIWlqtmRbbVgArHuUumeHGb5vsGBW+dFsQVVUTKHJBCs github-actions-deploy"
    ];
  };

  security.sudo.extraRules = [
    {
      users = [ "deploy" ];
      commands = [
        { command = "/run/current-system/sw/bin/nixos-rebuild *"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/systemctl restart *"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/systemctl start *"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/systemctl stop *"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/systemctl status *"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/nix-collect-garbage *"; options = [ "NOPASSWD" ]; }
      ];
    }
    {
      users = [ "deploy" ];
      runAs = "postgres";
      commands = [
        { command = "ALL"; options = [ "NOPASSWD" ]; }
      ];
    }
  ];
}
