{ config, pkgs, lib, ... }:

{
  networking.firewall = {
    enable = true;

    allowedTCPPorts = [ 22 80 443 ];
    allowedUDPPorts = [];

    # Block Docker containers from reaching the home LAN.
    # Allow containers to reach PgBouncer (6432) and allow established connections (for docker-proxy).
    extraCommands = ''
      iptables -C FORWARD -s 172.16.0.0/12 -d 192.168.0.0/16 -j DROP 2>/dev/null || \
        iptables -I FORWARD -s 172.16.0.0/12 -d 192.168.0.0/16 -j DROP

      iptables -C INPUT -s 172.16.0.0/12 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -s 172.16.0.0/12 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

      iptables -C INPUT -s 172.16.0.0/12 -p tcp --dport 6432 -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -s 172.16.0.0/12 -p tcp --dport 6432 -j ACCEPT

      iptables -C INPUT -s 172.16.0.0/12 -p tcp -j DROP 2>/dev/null || \
        iptables -I INPUT -s 172.16.0.0/12 -p tcp -j DROP
    '';

    extraStopCommands = ''
      iptables -D FORWARD -s 172.16.0.0/12 -d 192.168.0.0/16 -j DROP 2>/dev/null || true
      iptables -D INPUT -s 172.16.0.0/12 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
      iptables -D INPUT -s 172.16.0.0/12 -p tcp --dport 6432 -j ACCEPT 2>/dev/null || true
      iptables -D INPUT -s 172.16.0.0/12 -p tcp -j DROP 2>/dev/null || true
    '';
  };
}
