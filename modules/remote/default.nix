# Design section 12: Cloudflare Tunnel, loopback-only sshd, pull deploys,
# gated auto-update with boot assessment.
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

  # TODO(design 12.1): services.cloudflared.tunnels.emubox with the
  # credentials file from secrets and ingress "emubox-ssh.<domain>".
  # TODO(design 12.4): emubox-update, system.autoUpgrade tracking `release`
  # (operation = "boot"), emubox-boot-ok / emubox-boot-assess, kill switch.
}
