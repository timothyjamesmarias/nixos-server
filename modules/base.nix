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
  ];

  # Deploy user — used for SSH access and managing containers
  users.users.deploy = {
    isNormalUser = true;
    extraGroups = [ "docker" "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEJvpe/fxnamo6zzOVoxK3WfouV1LyIrd5JCHXvfyH+v timmarias@Tims-MacBook-Pro.local"
    ];
  };

  # Allow wheel group to sudo without password
  security.sudo.wheelNeedsPassword = false;

  # Root SSH access as fallback
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEJvpe/fxnamo6zzOVoxK3WfouV1LyIrd5JCHXvfyH+v timmarias@Tims-MacBook-Pro.local"
  ];
}
