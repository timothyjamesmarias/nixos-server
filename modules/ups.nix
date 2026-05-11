# ============================================================================
# UPS — CyberPower CP850PFCLCD via NUT (Network UPS Tools)
#
# Disabled by default. Enable with:
#   services.ups.enable = true;
#
# Monitors the UPS over USB. When battery drops below threshold, triggers
# a graceful shutdown to protect PostgreSQL and filesystems.
#
# After connecting the USB cable, verify detection:
#   lsusb | grep -i cyber
#   sudo upsc cyberpower
# ============================================================================
{ config, pkgs, lib, ... }:

let
  cfg = config.services.ups;
in
{
  options.services.ups.enable = lib.mkEnableOption "CyberPower UPS monitoring via NUT";

  config = lib.mkIf cfg.enable {
    power.ups = {
      enable = true;
      mode = "standalone";

      ups.cyberpower = {
        driver = "usbhid-ups";
        port = "auto";
        description = "CyberPower CP850PFCLCD";
      };
    };

    # upsmon watches the UPS and initiates shutdown when battery is critical
    power.ups.upsmon = {
      monitor.cyberpower = {
        system = "cyberpower@localhost";
        powerValue = 1;
        user = "upsmon";
        type = "primary";
      };

      settings = {
        MINSUPPLIES = 1;
        SHUTDOWNCMD = "${pkgs.systemd}/bin/shutdown -h +0";
        POLLFREQ = 5;
        POLLFREQALERT = 2;
        HOSTSYNC = 15;
        DEADTIME = 15;
        FINALDELAY = 5;
      };
    };

    # NUT user for upsmon to authenticate with upsd
    power.ups.users.upsmon = {
      upsmon = "primary";
      passwordFile = config.sops.secrets."ups/upsmon-password".path;
    };

    # Secret only declared when UPS is enabled
    sops.secrets."ups/upsmon-password" = {
      owner = "nut";
    };

    # Grant the NUT daemon access to USB devices
    services.udev.extraRules = ''
      SUBSYSTEM=="usb", ATTR{idVendor}=="0764", MODE="0660", GROUP="nut"
    '';
  };
}
