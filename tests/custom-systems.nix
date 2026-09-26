{
  self,
  pkgs,
}:
let
  lib = pkgs.lib;
  host = self.nixosConfigurations.emubox.extendModules {
    modules = [ { disabledModules = [ "${self}/modules/library" ]; } ];
  };
  first = ''
    <system>
      <name>first-contribution</name>
      <path>/data/roms/first-contribution</path>
    </system>
  '';
  second = ''
    <system>
      <name>second-contribution</name>
      <path>/data/roms/second-contribution</path>
    </system>
  '';
  contributed = [
    { emubox.kiosk.customSystems = lib.mkAfter [ first ]; }
    { emubox.kiosk.customSystems = lib.mkAfter [ second ]; }
  ];
  one = host.extendModules { modules = contributed; };
  empty = host.extendModules {
    modules = [ { emubox.kiosk.customSystems = lib.mkForce [ ]; } ];
  };
  invalidWrapper = host.extendModules {
    modules = [ { emubox.kiosk.customSystems = lib.mkForce [ "<systemList></systemList>" ]; } ];
  };
  invalidDeclaration = host.extendModules {
    modules = [
      { emubox.kiosk.customSystems = lib.mkForce [ "<?xml version=\"1.0\"?><system></system>" ]; }
    ];
  };
  rejects =
    system:
    lib.any (
      check: lib.hasInfix "emubox.kiosk.customSystems accepts only" check.message && !check.assertion
    ) system.config.assertions;
  document = one.config.emubox.kiosk.customSystemsFile;
  shippedDocument = host.config.emubox.kiosk.customSystemsFile;
  sessionOf =
    system:
    builtins.head (
      builtins.filter (
        p: (p.providedSessions or [ ]) == [ "emubox" ]
      ) system.config.services.displayManager.sessionPackages
    );
in
assert lib.assertMsg (
  let
    fragments = one.config.emubox.kiosk.customSystems;
  in
  lib.length fragments == lib.length host.config.emubox.kiosk.customSystems + 2
  && lib.count (fragment: fragment == first) fragments == 1
  && lib.count (fragment: fragment == second) fragments == 1
) "custom system fragments did not merge";
assert lib.assertMsg (
  empty.config.emubox.kiosk.customSystemsFile == ""
) "an empty custom system list must have no file path";
assert lib.assertMsg (
  rejects invalidWrapper && rejects invalidDeclaration
) "wrappers and declarations must be rejected";
assert lib.assertMsg (
  host.config.emubox.kiosk.preFrontendStep == ""
) "the pre-frontend step must be empty without modules/library";
pkgs.runCommand "emubox-custom-systems" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  # Without modules/library the session carries no library step; the shipped
  # host's session is the control that the probe finds the step at all.
  exec_of() { sed -n 's/^Exec=//p' "$1/share/wayland-sessions/emubox.desktop"; }
  if grep -q emubox-library-generate "$(exec_of ${sessionOf host})"; then
    echo "session without modules/library still carries a library step" >&2
    exit 1
  fi
  grep -q emubox-library-generate "$(exec_of ${sessionOf self.nixosConfigurations.emubox})"
  python3 - ${document} ${shippedDocument} ${./emulator-custom-systems.xml} <<'PY'
  import pathlib
  import re
  import sys
  import xml.etree.ElementTree as ET

  contributed, shipped, original = (pathlib.Path(p).read_text() for p in sys.argv[1:])
  root = ET.fromstring(contributed)
  assert root.tag == "systemList"
  names = [system.findtext("name") for system in root]
  assert names.count("first-contribution") == 1, names
  assert names.count("second-contribution") == 1, names
  assert len(root) == 16, names

  shipped_root = ET.fromstring(shipped)
  assert shipped_root.tag == "systemList"
  assert len(shipped_root) == 14
  blocks = lambda xml: re.findall(r"<system>.*?</system>", xml, re.DOTALL)
  by_name = lambda xml: {
      ET.fromstring(block).findtext("name"): block for block in blocks(xml)
  }
  previous = by_name(original)
  current = by_name(shipped)
  assert len(previous) == 14
  assert all(current.get(name) == block for name, block in previous.items()), (
      "one of the shipped emulator system blocks changed"
  )
  PY
  touch "$out"
''
