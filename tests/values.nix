# Plaintext values for the VM tests. Test-only, not secrets: the box's real
# values live only in secrets/secrets.yaml. This file is the single source
# for everything that needs a plaintext test value: secrets/test.yaml is
# encrypted from it (`just test-secrets-edit`) and both test nodes decrypt
# it, the install test compares the decrypted secrets against the values
# here, and the closure-no-secrets check greps the system closure for
# `psk` and `hash`.
#
# `hash` is the yescrypt hash of `password`, generated once with
#   nix shell nixpkgs#mkpasswd -c mkpasswd -m yescrypt
#
# `raUsername`/`raPassword` are the test RetroAchievements account the kiosk
# test's mock `login2` endpoint (design D7) is posted with `emubox-prepare`'s
# real login path - never patched out. The mock does not check the password
# against anything (it is a static responder that always succeeds), so the
# value only has to be distinctive enough that "no config carries the
# password" is a meaningful assertion rather than a vacuous one.
{
  ssid = "emubox-test";
  psk = "emubox-test-psk";
  password = "emubox";
  hash = "$y$j9T$zr7MqokZ5LgjQCW77ICHl/$PEA2Wl7JW5Vhx.nxmbmmh6ZhEzrNKKMdrLWYlOodJsD";
  raUsername = "emubox-test-ra";
  raPassword = "emubox-test-ra-password";
}
