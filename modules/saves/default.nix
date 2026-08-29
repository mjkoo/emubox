# Design section 9: save redirection, btrbk snapshots, restic -> B2, drills.
{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.restic ];

  # TODO(design 9): services.btrbk hourly/daily snapshots of @data;
  # services.restic.backups.saves with the B2 S3 endpoint, boot-relative
  # timer, idle priority, retention; emubox-save-drill, emubox-leakcheck.
}
