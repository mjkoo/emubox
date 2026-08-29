# Design section 4: ephemeral root, persistent OS state under /persist.
# User data is deliberately outside this mechanism: player's home is on
# /data and is never wiped (design section 9, layer 1).
{ lib, ... }:
{
  # TODO(design 4): roll @root back to a blank snapshot in the initrd on every
  # boot. impermanence's README carries the recipe (btrfs subvolume swap in
  # boot.initrd.postResumeCommands, or a systemd initrd service when
  # boot.initrd.systemd.enable is on).

  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/lib/nixos"
      "/var/lib/systemd"
      "/var/lib/bluetooth"
      "/var/lib/NetworkManager"
      "/var/log"
      "/var/lib/emubox"
      # TODO(design 12): cloudflared state, restic cache.
    ];
    files = [
      "/etc/machine-id"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
    ];
  };

  # Deliberately not persisted: /tmp, /root, and the mode flag on /run.
  boot.tmp.cleanOnBoot = lib.mkDefault true;
}
