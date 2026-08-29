# Design section 11: Plasma 6 for the admin, mode switch, recovery specialisation.
{ lib, pkgs, ... }:
{
  services.desktopManager.plasma6.enable = true;

  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    # TODO(design 4): hashedPasswordFile from secrets; SSH key below.
    openssh.authorizedKeys.keys = [ ];
  };
  security.sudo.wheelNeedsPassword = false;

  # TODO(design 11): `emubox-mode {kiosk|desktop}` writing /run/emubox/mode.
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
