# The emubox software stack, one directory per design section. Each module
# is self-contained and reads shared facts from `config.emubox`.
{
  imports = [
    ./facts.nix
    ./hardware
    ./persistence
    ./kiosk
    ./recovery
    ./emulators
    ./controllers
    ./library
    ./saves
    ./remote
    ./secrets
  ];
}
