# Design section 12: Cloudflare Tunnel, loopback-only sshd, pull deploys,
# gated auto-update with boot assessment.
{
  services.openssh = {
    enable = true;
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
