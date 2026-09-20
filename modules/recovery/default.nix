# Design section 11: Plasma 6 for the admin, mode switch, recovery specialisation.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  clearMode = pkgs.writeShellApplication {
    name = "emubox-clear-mode";
    text = ''
      rm -f /run/emubox/mode
    '';
  };

  emuboxMode = pkgs.writeShellApplication {
    name = "emubox-mode";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      selected_mode() {
        mode=$(cat /run/emubox/mode 2>/dev/null || echo kiosk)
        if [ "$mode" = desktop ]; then
          printf 'desktop'
        else
          printf 'kiosk'
        fi
      }

      fail() {
        printf 'emubox-mode: %s; the mode selected for the next automatic session is %s\n' "$1" "$(selected_mode)" >&2
        exit 1
      }

      if [ "$#" -ne 1 ]; then
        fail "usage: emubox-mode {kiosk|desktop}; exactly one argument is required"
      fi

      case "$1" in
        kiosk | desktop)
          requested_mode=$1
          ;;
        *)
          fail "usage: emubox-mode {kiosk|desktop}; exactly one argument is required"
          ;;
      esac

      if [ "$(id -u)" -ne 0 ]; then
        fail "administrative privilege is required; from the box's desktop run 'su - admin' and then use sudo"
      fi

      if ! grep -q '^\[Autologin\]$' /etc/sddm.conf.d/00-nixos.conf; then
        fail "automatic login is not enabled, so nothing here would read the mode"
      fi

      temporary_mode_file=
      write_mode() {
        { [ -d /run/emubox ] || mkdir -m 0755 /run/emubox; } \
          && temporary_mode_file=$(mktemp /run/emubox/.mode.XXXXXX) \
          && printf '%s\n' "$requested_mode" > "$temporary_mode_file" \
          && chmod 0644 "$temporary_mode_file" \
          && mv -fT "$temporary_mode_file" /run/emubox/mode
      }

      if ! write_mode; then
        if [ -n "$temporary_mode_file" ]; then
          rm -f "$temporary_mode_file" || true
        fi
        fail "could not write the mode flag; the selection is unchanged"
      fi

      printf 'emubox-mode: switching to %s; the current session is about to end\n' "$requested_mode"
      systemctl reset-failed display-manager.service || true
      if ! systemctl restart --no-block display-manager.service; then
        fail "the mode was recorded but the session was not restarted"
      fi
      printf 'emubox-mode: mode %s was recorded and the restart was accepted\n' "$requested_mode"
    '';
  };
in
{
  options.emubox.modeClearCommand = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    internal = true;
    default = "${clearMode}/bin/emubox-clear-mode";
    description = ''
      The privileged command the kiosk session uses to clear a pending mode
      selection before starting the desktop.
    '';
  };

  config = {
    services.desktopManager.plasma6.enable = true;

    # Plasma also ships an XDG autostart entry for this binary. It carries
    # X-systemd-skip=true, so it stays inert while Plasma delegates autostart
    # to the user manager; the VM test also watches for the process itself.
    systemd.user.services.kde-baloo.enable = false;

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
    security.sudo = {
      wheelNeedsPassword = false;
      extraRules = [
        {
          users = [ "player" ];
          commands = [
            {
              command = config.emubox.modeClearCommand;
              options = [ "NOPASSWD" ];
            }
          ];
        }
      ];
    };

    environment.systemPackages = with pkgs; [
      clearMode
      emuboxMode
      kdePackages.konsole
      kdePackages.dolphin
    ];

    systemd.tmpfiles.rules = [ "d /run/emubox 0755 root root -" ];

    # Last resort from the boot menu: same system, greeter + Plasma, no kiosk.
    specialisation.recovery.configuration = {
      services.displayManager.autoLogin.enable = lib.mkForce false;
      services.displayManager.defaultSession = lib.mkForce "plasma";
    };
  };
}
