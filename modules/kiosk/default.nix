# Design section 5: SDDM autologin -> session loop -> cage -> ES-DE.
{ pkgs, ... }:
let
  # The session loop. Runs as `player`; relaunches ES-DE if it exits.
  emubox-session = pkgs.writeShellApplication {
    name = "emubox-session";
    runtimeInputs = [ pkgs.cage ];
    text = ''
      while true; do
        mode=$(cat /run/emubox/mode 2>/dev/null || echo kiosk)
        # TODO(design 11, open question 1): desktop mode hands over to Plasma.
        [ "$mode" = desktop ] && exec startplasma-wayland
        # TODO(design 4): emubox-prepare (seed/assert configs, bind saves, refresh gamelists)
        ESDE_APPDATA_DIR=/data/es-de cage -- es-de --force-kiosk || true
        # TODO(design 9): emubox-leakcheck
        sleep 2
      done
    '';
  };
  session = pkgs.writeTextDir "share/wayland-sessions/emubox.desktop" ''
    [Desktop Entry]
    Name=emubox
    Comment=Controller-driven game library
    Exec=${emubox-session}/bin/emubox-session
    Type=Application
  '';
in
{
  users.users.player = {
    isNormalUser = true;
    home = "/data/home/player";
    createHome = true;
    extraGroups = [
      "video"
      "input"
      "audio"
    ];
  };

  services.displayManager = {
    sddm = {
      enable = true;
      wayland.enable = true;
    };
    autoLogin = {
      enable = true;
      user = "player";
    };
    defaultSession = "emubox";
    sessionPackages = [ (session // { providedSessions = [ "emubox" ]; }) ];
  };

  # ES-DE powers off and reboots through logind.
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (subject.user == "player" &&
          (action.id == "org.freedesktop.login1.power-off" ||
           action.id == "org.freedesktop.login1.power-off-multiple-sessions" ||
           action.id == "org.freedesktop.login1.reboot" ||
           action.id == "org.freedesktop.login1.reboot-multiple-sessions")) {
        return polkit.Result.YES;
      }
    });
  '';

  # TODO(pkgs/es-de): ES-DE itself, once vendored. Until then the session
  # script references `es-de` by name and the loop simply retries.
  environment.systemPackages = [ pkgs.cage ];
}
