# Plaintext values for the VM test. Test-only, not secrets: the box's real
# values live only in secrets/secrets.yaml. This file is the single source
# for everything that needs a plaintext test value: secrets/test.yaml is
# encrypted from it (`just test-secrets-edit`), the VM test compares the
# decrypted secrets against it, and the closure-no-secrets check greps the
# system closure for `psk` and `hash`.
#
# `hash` is the yescrypt hash of `password`, generated once with
#   nix shell nixpkgs#mkpasswd -c mkpasswd -m yescrypt
{
  ssid = "emubox-test";
  psk = "emubox-test-psk";
  password = "emubox";
  hash = "$y$j9T$zr7MqokZ5LgjQCW77ICHl/$PEA2Wl7JW5Vhx.nxmbmmh6ZhEzrNKKMdrLWYlOodJsD";
}
