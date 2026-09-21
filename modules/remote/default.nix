# Remote administration: loopback-only sshd today; the Tailscale node, pull
# deploys and gated auto-update with boot assessment are still to come.
{
  services.openssh = {
    enable = true;
    # Loopback only, so the firewall stays closed (nixpkgs would otherwise
    # open port 22 on every interface).
    openFirewall = false;
    # ed25519 only: it is the persisted host identity (modules/persistence)
    # and the sops decryption key, and nothing needs an RSA key.
    hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
    listenAddresses = [
      {
        addr = "127.0.0.1";
        port = 22;
      }
    ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ "admin" ];
    };
  };

  # TODO: services.tailscale as a tagged node, its auth key from secrets,
  # with sshd reachable over the tailnet interface only.
  # TODO: emubox-update, system.autoUpgrade tracking `release`
  # (operation = "boot"), emubox-boot-ok / emubox-boot-assess, kill switch.
}
