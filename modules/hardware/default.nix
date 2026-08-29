# Design section 4: base system. Boot, graphics, audio, power, no sleep.
{ lib, pkgs, ... }:
{
  boot = {
    loader.systemd-boot = {
      enable = true;
      configurationLimit = 10;
    };
    loader.efi.canTouchEfiVariables = true;
    # 0 = no menu unless a key is held; generation rollback stays reachable.
    loader.timeout = 0;
    plymouth.enable = true;
    # mkDefault: the VM test instrumentation raises this.
    consoleLogLevel = lib.mkDefault 3;
    kernelParams = [
      "quiet"
      # Escape hatch if i915 ever refuses the N150's 8086:46d4:
      # "i915.force_probe=46d4"
    ];
  };

  hardware = {
    graphics = {
      enable = true;
      extraPackages = with pkgs; [
        intel-media-driver
        vpl-gpu-rt
      ];
    };
    enableRedistributableFirmware = true;
    cpu.intel.updateMicrocode = true;
    bluetooth.enable = true;
  };

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
    # TODO(design 4): pin the HDMI sink as default.
  };

  zramSwap.enable = true;
  services.fstrim.enable = true;

  # The box is either on or off. ADL-N loses HDMI audio after suspend.
  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowHybridSleep = "no";
    AllowSuspendThenHibernate = "no";
  };
  services.logind.settings.Login = {
    HandlePowerKey = "poweroff";
    HandleLidSwitch = "ignore";
  };
  systemd.settings.Manager.RuntimeWatchdogSec = "30s";

  networking.networkmanager.enable = true;
  # TODO(design 4): declared WiFi connection with the PSK from secrets.
  networking.firewall.enable = true;

  nix = {
    settings.experimental-features = [
      "nix-command"
      "flakes"
    ];
    gc = {
      automatic = true;
      options = "--delete-older-than 14d";
    };
    optimise.automatic = true;
  };

  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";
}
