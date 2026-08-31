# Design section 4: sops-nix keyed to the host SSH key, read from /persist
# directly because the bind mount into /etc/ssh may not exist yet.
#
# One file, secrets/secrets.yaml, encrypted to the admin's age key and the
# host key (recipients in .sops.yaml). Later changes add their keys to the
# same file and declare them next to these.
{ config, ... }:
{
  sops = {
    defaultSopsFile = ../../secrets/secrets.yaml;
    age.sshKeyPaths = [ "/persist/etc/ssh/ssh_host_ed25519_key" ];

    secrets = {
      # Decrypted to /run/secrets-for-users before user accounts are created,
      # which is the only way to feed a hash into user creation on a root
      # that is empty at every boot (modules/recovery reads it).
      admin_password_hash.neededForUsers = true;
      wifi_ssid = { };
      wifi_psk = { };

      # Read by `emubox-prepare` running as `player` (modules/kiosk's session
      # loop), not by a system service, so sops-nix's default - root, mode
      # 0400 - would leave prepare unable to read either file and every
      # login would fail silently on real hardware while the VM test, which
      # points prepare at its own mock credentials, kept passing. `owner`
      # rather than a wider `mode` keeps the file unreadable to anyone else
      # on the box, same as the default would if `player` were root.
      retroachievements_username.owner = "player";
      retroachievements_password.owner = "player";
    };

    # Rendered on /run at boot; NetworkManager's ensure-profiles unit loads
    # it as an EnvironmentFile and substitutes $WIFI_SSID and $WIFI_PSK into
    # the declared profile (modules/hardware).
    templates."wifi.env" = {
      content = ''
        WIFI_SSID=${config.sops.placeholder.wifi_ssid}
        WIFI_PSK=${config.sops.placeholder.wifi_psk}
      '';
      # A re-keyed PSK reaches the profile on the next switch, not the next
      # boot.
      restartUnits = [ "NetworkManager-ensure-profiles.service" ];
    };
  };
}
