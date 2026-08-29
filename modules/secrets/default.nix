# Design section 4: sops-nix keyed to the host SSH key, read from /persist
# directly because the bind mount into /etc/ssh may not exist yet.
{
  sops.age.sshKeyPaths = [ "/persist/etc/ssh/ssh_host_ed25519_key" ];
  # TODO(secrets): create secrets/secrets.yaml with `sops secrets/secrets.yaml`
  # once .sops.yaml has the admin age key and the host key, then:
  # sops.defaultSopsFile = ../../secrets/secrets.yaml;
}
