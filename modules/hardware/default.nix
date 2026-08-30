# Design section 4: base system. Boot, graphics, audio, power, no sleep.
{
  config,
  lib,
  pkgs,
  ...
}:
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
    # HDMI is the default sink by declaration: WirePlumber has no "default
    # sink by name" setting, so the HDMI sink's session priority is raised
    # above every other ALSA sink (WirePlumber's alsa monitor computes
    # playback priorities in the 744-1109 range; 1500 is the ceiling it
    # advises), and restoring a remembered choice is off so a fresh root or
    # a re-plugged cable cannot route audio elsewhere.
    wireplumber.extraConfig."51-emubox-hdmi-default" = {
      "monitor.alsa.rules" = [
        {
          matches = [ { "node.name" = "~alsa_output\\.pci-.*hdmi.*"; } ];
          actions.update-props."priority.session" = 1500;
        }
      ];
      "wireplumber.settings"."node.restore-default-targets" = false;
    };
  };

  # Bounded and persistent: /var/log is on the persisted list.
  services.journald.extraConfig = ''
    SystemMaxUse=256M
    MaxRetentionSec=1month
  '';

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

  networking.networkmanager = {
    enable = true;
    # The family WiFi as a declared profile. The SSID and PSK are
    # substituted at service start from the sops-rendered env file, so the
    # generated .nmconnection lives on /run and neither value is in the
    # store. Wired links need no profile: NetworkManager's default DHCP
    # handling covers the install and any later cable.
    ensureProfiles = {
      environmentFiles = [ config.sops.templates."wifi.env".path ];
      profiles.family-wifi = {
        connection = {
          id = "family-wifi";
          type = "wifi";
          autoconnect = true;
        };
        wifi = {
          mode = "infrastructure";
          ssid = "$WIFI_SSID";
        };
        wifi-security = {
          key-mgmt = "wpa-psk";
          psk = "$WIFI_PSK";
        };
        ipv4.method = "auto";
        ipv6.method = "auto";
      };
    };
  };
  # On, with nothing opened: every service that listens binds to loopback.
  # Asserted here, next to the firewall, so the invariant guards the system
  # that ships and not only the VM tests' variants of it.
  networking.firewall.enable = true;
  assertions = [
    {
      assertion =
        with config.networking.firewall;
        allowedTCPPorts == [ ]
        && allowedUDPPorts == [ ]
        && allowedTCPPortRanges == [ ]
        && allowedUDPPortRanges == [ ]
        && interfaces == { };
      message = "networking.firewall opens a port; the emubox firewall must open none (networking spec)";
    }
  ];

  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      # The project's binary cache, on top of cache.nixos.org (extra-*, so
      # the defaults stay): the redistributable unfree cores and everything
      # pkgs/ builds, vendored or the project's own, which CI pushes (flake
      # output `cache-roots`). Gated on the key so a host without one
      # evaluates and simply builds those paths itself - which for this box
      # means compiling ES-DE and FreeImage from source on an N150, so the
      # key is what keeps a first install to minutes rather than hours.
      extra-substituters = lib.mkIf (config.emubox.facts.binaryCachePublicKey != null) [
        "https://emubox.cachix.org"
      ];
      extra-trusted-public-keys = lib.mkIf (config.emubox.facts.binaryCachePublicKey != null) [
        config.emubox.facts.binaryCachePublicKey
      ];
    };
    gc = {
      automatic = true;
      options = "--delete-older-than 14d";
    };
    optimise.automatic = true;
  };

  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";
}
