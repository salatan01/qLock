{
  description = "qLock Development Environment (Quickshell + QtMultimedia video lockscreen)";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };
  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      # Full suite of Qt6 dependencies required for SVG, multimedia, and visual effects
      qtDeps = with pkgs.qt6; [
        qtdeclarative  # Includes qmlls (LSP) and QML core modules
        qtsvg          # Rendering SVG icons/graphics
        qtimageformats # Support for WebP and extended image formats
        qtmultimedia   # Audio/video widget playback (QML MediaPlayer/VideoOutput)
        qt5compat      # Additional graphical effects (e.g., Blur)
      ];

      # GStreamer backend for QtMultimedia. Without this, MediaPlayer either
      # fails silently or falls back to software decode.
      gstDeps = with pkgs.gst_all_1; [
        gstreamer
        gst-plugins-base
        gst-plugins-good
        gst-plugins-bad
        gst-plugins-ugly
        gst-libav        # broad codec coverage (h264/h265/etc via ffmpeg)
      ];
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          # Core shell pulled directly from nixpkgs
          quickshell
          # LSP & Tooling
          qt6.qtdeclarative
          # VA-API hardware decode verification/support
          libva
          libva-utils     # gives you `vainfo` to verify HW decode is active
          # Common IPC utilities for status bar / desktop shell scripting
          wireplumber
          pulseaudio      # pactl / audio control
          bluez           # bluetoothctl
          networkmanager
          niri            # niri msg IPC (this machine runs Niri, not Hyprland)
          jq
          # For the suspend-hook (PrepareForSleep) listener via Process{}
          systemd         # busctl / dbus-monitor equivalents
          socat
        ] ++ qtDeps ++ gstDeps;

        shellHook = ''
          # 1) Allow QML XMLHttpRequest to read local files.
          # Qt disables GET on file:// by default for security, which makes
          # shell.qml's XHR loader for ./config/config.json silently fail and
          # fall back to the hardcoded /home/nightkat/... object.
          export QML_XHR_ALLOW_FILE_READ=1

          # Export QML2_IMPORT_PATH so qmlls and Qt runtime find all packages
          export QML2_IMPORT_PATH="${pkgs.quickshell}/lib/qt-6/qml:${pkgs.lib.makeSearchPathOutput "out" "lib/qt-6/qml" qtDeps}"

          # 2) Expose Qt plugin backends to the runtime.
          # nixpkgs' qt6.qtmultimedia ships libffmpegmediaplugin.so /
          # libgstreamermediaplugin.so under lib/qt-6/plugins/multimedia, but
          # mkShell doesn't run Qt's wrapper hooks that normally set
          # QT_PLUGIN_PATH. Without this, MediaPlayer fails with
          # "No QtMultimedia backends found / Failed to initialize QMediaPlayer".
          export QT_PLUGIN_PATH="${pkgs.lib.makeSearchPathOutput "out" "lib/qt-6/plugins" qtDeps}:${pkgs.qt6.qtbase}/${pkgs.qt6.qtbase.qtPluginPrefix}"

          # GStreamer needs its plugin path exported explicitly under Nix —
          # it isn't discoverable via PATH the way it is on FHS distros.
          export GST_PLUGIN_SYSTEM_PATH_1_0="${pkgs.lib.makeSearchPathOutput "lib" "lib/gstreamer-1.0" gstDeps}"

          # Quickshell requires a local .qmlls.ini file to auto-populate module paths
          if [ ! -f .qmlls.ini ]; then
            touch .qmlls.ini
          fi

          echo "qLock dev environment active."
          echo "qmlls location: $(which qmlls)"
          echo "Run 'vainfo' to confirm VA-API hardware decode is available."
        '';
      };
    };
}
