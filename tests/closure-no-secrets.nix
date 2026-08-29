# Builder-side proof that no test secret value reached the Nix store: grep
# every store path in the closure of the test-extended host toplevel for the
# test PSK and the test password hash from values.nix.
#
# It proves the mechanism (nothing routes a decrypted value into a store
# path), with the test values standing in for the box's; the box's real
# values are only ever in secrets/secrets.yaml and on /run.
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
  # xargs keeps the argument list under ARG_MAX however large the closure
  # grows. Each batch exits 0 for "match" and "no match" alike (grep's 0
  # and 1) and non-zero only when grep itself failed, so xargs's status
  # means "every grep ran" and the matches file carries the verdict.
  if ! xargs -a ${closure}/store-paths -d '\n' -n 200 \
      sh -c 'grep -rlF -f "$0" -- "$@"; s=$?; [ "$s" -le 1 ]' ${patterns} \
      > matches; then
    echo "grep failed over the closure" >&2
    exit 1
  fi
  if [ -s matches ]; then
    echo "test secret values found in the system closure:" >&2
    cat matches >&2
    exit 1
  fi
  echo "no test secret value in $(wc -l < ${closure}/store-paths) store paths"
  touch "$out"
''
