{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.qlock;
in {
  options.services.qlock = {
    enable = lib.mkEnableOption "qLock video-wallpaper lockscreen (Quickshell ext-session-lock)";

    package = lib.mkPackageOption pkgs "qlock" {};

    settings = lib.mkOption {
      type = lib.types.submodule {
        options = {
          videoDirectory = lib.mkOption {
            type = lib.types.str;
            default = "~/qSets/qLock/";
            example = "/home/alice/Videos/lockscreen";
            description = ''
              Directory scanned for *.mp4/*.mkv/*.webm.
              Leading `~`, `$HOME/` and `''${HOME}/` are expanded by PlaylistEngine.
            '';
          };
          mode = lib.mkOption {
            type = lib.types.enum ["random" "fixed"];
            default = "random";
            description = "Playlist mode: shuffled non-repeating random, or a single fixed file.";
          };
          fixedFile = lib.mkOption {
            type = lib.types.str;
            default = "";
            example = "cantarella.mp4";
            description = "File name (not path) used when mode is \"fixed\". Empty falls back to first video.";
          };
          repeat = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Seamless in-player loop. When false, advances the playlist at end-of-media.";
          };
          volume = lib.mkOption {
            type = lib.types.numbers.between 0 100;
            default = 20;
            description = "Background audio on the human 0-100 scale (20 = 20%). Values ≤ 1 keep legacy 0-1 meaning.";
          };
          pinSink = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Hold the default sink at full gain while locked (saving and
              restoring the user's volume/mute on unlock) so bg loudness is
              exactly `volume`, immune to volume buttons. Disable for plain
              sink-relative playback with cubic compensation only.
            '';
          };
        };
      };
      default = {};
      example = {
        videoDirectory = "~/Videos/lockscreen";
        mode = "random";
        volume = 20;
      };
      description = "qLock settings, written to /etc/qlock/config.json and merged over built-in defaults.";
    };

    writeConfig = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Write settings to /etc/qlock/config.json. Disable if you manage that file out-of-band.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.settings.videoDirectory != "";
        message = "services.qlock.settings.videoDirectory must not be empty.";
      }
      {
        assertion = cfg.settings.mode != "fixed" || cfg.settings.fixedFile != "" || true;
        message = "services.qlock: fixed mode with empty fixedFile falls back to first video (allowed, but check intent).";
      }
    ];

    environment.systemPackages = [cfg.package];

    environment.etc."qlock/config.json" = lib.mkIf cfg.writeConfig {
      # writeText + toJSON keeps this independent of the formats API and
      # produces byte-stable output for /etc.
      source = pkgs.writeText "qlock-config.json" (builtins.toJSON cfg.settings);
      mode = "0444";
    };

    # qLock authenticates via Quickshell.Services.Pam with the stock
    # `login` stack, so no custom PAM service is required. The session
    # must run on a compositor with ext-session-lock support (e.g. Niri).
    # Suggested bind (Niri): Mod+L spawn "qlock".
  };
}
