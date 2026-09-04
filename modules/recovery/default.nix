# Design section 11: Plasma 6 for the admin, mode switch, recovery specialisation.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  services.desktopManager.plasma6.enable = true;

  users.users.admin = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      # Write access to the group-owned /data layout for ROM ingest.
      "player"
    ];
    # The hash lives in the secrets file and is decrypted before users are
    # created (modules/secrets), so a fresh root gets the password at boot.
    hashedPasswordFile = config.sops.secrets.admin_password_hash.path;
    # TODO: the admin's SSH public key for the tunnel.
    openssh.authorizedKeys.keys = [ ];
  };
  security.sudo.wheelNeedsPassword = false;

  # TODO: `emubox-mode {kiosk|desktop}` writing /run/emubox/mode.
  environment.systemPackages = with pkgs; [
    kdePackages.konsole
    kdePackages.dolphin
  ];

  # Last resort from the boot menu: same system, greeter + Plasma, no kiosk.
  specialisation.recovery.configuration = {
    services.displayManager.autoLogin.enable = lib.mkForce false;
    services.displayManager.defaultSession = lib.mkForce "plasma";
  };
}
