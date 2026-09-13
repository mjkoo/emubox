# Per-host facts every module may read. Declared here so the software stack
# evaluates on its own (VM test, a second host); values are set per host.
{ lib, ... }:
{
  options.emubox.facts = {
    binaryCachePublicKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Public key of the `emubox` Cachix cache (`emubox.cachix.org-1:...`),
        which holds the store paths cache.nixos.org never has (the unfree
        emulator cores and what pkgs/ builds). Null until the cache exists;
        the substituter is only configured once it is set.
      '';
    };
    disk = lib.mkOption {
      type = lib.types.str;
      default = "/dev/disk/by-diskseq/1";
      description = "The single M.2 SSD, as seen by disko / nixos-anywhere.";
    };
    controllerPorts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "ID_PATH of USB-A ports 1..4, in player order. Empty = no slot symlinks.";
    };
    controllerIdentities = lib.mkOption {
      type = lib.types.submodule {
        options = {
          sdlGamepadName = lib.mkOption {
            type = lib.types.nullOr lib.types.nonEmptyStr;
            default = null;
            description = ''
              The SDL device name a connected pad reports
              (`SDL_GetGamepadName`, or `SDL_GetJoystickName` when there is
              no mapping) - the form every Dolphin `Device = SDL/<n>/<name>`
              line has to carry, since Dolphin has no device-selector form
              free of the pad's own name. Null until bring-up records it
              from the real pad under Linux; a binding that depends on this
              fact is declared nowhere at all while it is null, rather than
              with a placeholder or another machine's value. An empty name
              is refused rather than taken as a recorded one.
            '';
          };
          sdlJoystickGuid = lib.mkOption {
            type = lib.types.nullOr (lib.types.strMatching "[0-9a-f]{32}");
            default = null;
            description = ''
              The SDL joystick GUID a connected pad reports
              (`SDL_JoystickGetGUIDString`) - the form Azahar's own SDL
              bindings carry (`guid:<G>`), since an unmatched GUID gives
              Azahar a placeholder joystick that never delivers input. Null
              until bring-up records it from the real pad under Linux, with
              the same "declared nowhere while null" rule as
              `sdlGamepadName` above. Exactly 32 lowercase hexadecimal
              digits, the form `sdl2-jstest` prints; any other shape is
              refused at evaluation, since a mis-copied GUID would
              otherwise bind a joystick that never exists.
            '';
          };
        };
      };
      default = { };
      description = ''
        Pad-identity values a binding may have to name directly because the
        emulator's own grammar carries no identity-free form. Two are
        recorded: the SDL device name and the SDL joystick GUID - the two
        forms `sdl2-jstest` (nixpkgs `sdl-jstest`) prints for a connected
        pad, one for each emulator input backend that needs one. Both are
        null until a host's own facts record real values captured on that
        host's own hardware.
      '';
    };
    hdmiOutput = lib.mkOption {
      type = lib.types.str;
      default = "HDMI-A-1";
      description = "DRM connector the TV is attached to.";
    };
  };
}
