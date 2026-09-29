{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.qlock;
in {
  options.programs.qlock = {
    enable = lib.mkEnableOption "qLock video-wallpaper lockscreen (user config)";

    package = lib.mkPackageOption pkgs "qlock" {};

    settings = lib.mkOption {
      type = lib.types.submodule {
        options = {
          videoDirectory = lib.mkOption {
            type = lib.types.str;
            default = "~/qSets/qLock/";
            example = "/home/alice/Videos/lockscreen";
            description = "Directory scanned for *.mp4/*.mkv/*.webm (`~`/`$HOME` expanded).";
          };
          mode = lib.mkOption {
            type = lib.types.enum ["random" "fixed"];
            default = "random";
            description = "Playlist mode.";
          };
          fixedFile = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "File name used when mode is \"fixed\".";
          };
          repeat = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Seamless in-player loop. When false, each video plays once and the playlist advances.";
          };
          playback = lib.mkOption {
            type = lib.types.numbers.between 0 100;
            default = 0;
            example = 2;
            description = "Plays per video in random mode before advancing (2 = 2playback, 3 = 3playback). 0 loops forever, 1 plays once. Ignored when repeat is false or mode is fixed.";
          };
          volume = lib.mkOption {
            type = lib.types.numbers.between 0 100;
            default = 20;
            description = "Background audio on the 0-100 scale.";
          };
          pinSink = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Anchor the default sink at its lock-time level while locked (restore on unlock). Never raised above the anchor.";
          };
          showTitle = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Show a bottom-center now-playing pill with the current video's file name.";
          };
        };
      };
      default = {};
      description = "qLock settings, written to ~/.config/qlock/config.json (highest-priority file config).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.settings.videoDirectory != "";
        message = "programs.qlock.settings.videoDirectory must not be empty.";
      }
    ];

    home.packages = [cfg.package];
    xdg.configFile."qlock/config.json".source =
      pkgs.writeText "qlock-config.json" (builtins.toJSON cfg.settings);
  };
}
