# Builder-side proof that no test secret value reached the Nix store: grep
# every store path in the closure of the test-extended host toplevel for the
# test PSK and the test password hash from values.nix.
#
# The patterns go through a file and `grep -F -f`, never through the shell:
# the yescrypt hash is `$y$j9T$<salt>$<hash>`, and interpolated into a
# double-quoted script bash would expand `$y`, `$j9T` and `$<salt>` to
# nothing, leaving grep a fragment that matches nowhere while the check
# reports green.
{ pkgs, toplevel }:
let
  values = import ./values.nix;
  patterns = pkgs.writeText "emubox-test-secret-patterns" ''
    ${values.psk}
    ${values.hash}
  '';
  closure = pkgs.closureInfo { rootPaths = [ toplevel ]; };
in
pkgs.runCommand "emubox-closure-no-secrets" { } ''
  status=0
  grep -rlF -f ${patterns} -- $(cat ${closure}/store-paths) > matches || status=$?
  case "$status" in
    1)
      echo "no test secret value in $(wc -l < ${closure}/store-paths) store paths"
      touch "$out"
      ;;
    0)
      echo "test secret values found in the system closure:" >&2
      cat matches >&2
      exit 1
      ;;
    *)
      echo "grep failed with status $status" >&2
      exit 1
      ;;
  esac
''
