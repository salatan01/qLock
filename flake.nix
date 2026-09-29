{
  description = "qLock — video-wallpaper ext-session-lock screen for Quickshell";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    forAllSystems = nixpkgs.lib.genAttrs systems;
    pkgsFor = system: import nixpkgs {inherit system;};

    version = "0.1.0";

    # Ship only runtime inputs: QML + default config. Flake/nix/*.md churn
    # must not rebuild the package.
    qlockSrc = pkgs:
      pkgs.lib.fileset.toSource {
        root = ./.;
        fileset = pkgs.lib.fileset.unions [
          ./shell.qml
          ./test.qml
          ./components
          ./config
        ];
      };

    # Mirrors nix/package.nix: minimal runtime set (see comment there).
    qtDepsFor = pkgs:
      with pkgs.qt6; [
        qtbase
        qtdeclarative # QML core + qmlls
        qtmultimedia
        qt5compat
        qtwayland # WlSessionLock
      ];

    gstDepsFor = pkgs:
      with pkgs.gst_all_1; [
        gstreamer
        gst-plugins-base
        gst-plugins-good
        gst-plugins-bad
        gst-libav
      ];
  in {
    packages = forAllSystems (system: let
      pkgs = pkgsFor system;
    in {
      qlock = pkgs.callPackage ./nix/package.nix {
        inherit version;
        src = qlockSrc pkgs;
      };
      default = self.packages.${system}.qlock;
    });

    apps = forAllSystems (system: {
      qlock = {
        type = "app";
        program = "${self.packages.${system}.qlock}/bin/qlock";
        meta.description = "Lock the session (production ext-session-lock surface)";
      };
      preview = {
        type = "app";
        program = "${self.packages.${system}.qlock}/bin/qlock-preview";
        meta.description = "Safe preview window (no session lock)";
      };
      default = self.apps.${system}.qlock;
    });

    nixosModules = {
      qlock = import ./nix/module.nix;
      default = self.nixosModules.qlock;
    };

    homeManagerModules = {
      qlock = import ./nix/hm-module.nix;
      default = self.homeManagerModules.qlock;
    };
    # Alias for managers that expect `homeManagerModules` under this name.
    homeModules = self.homeManagerModules;

    overlays.default = final: _prev: {
      qlock = final.callPackage ./nix/package.nix {
        inherit version;
        src = qlockSrc final;
      };
    };

    devShells = forAllSystems (system: let
      pkgs = pkgsFor system;
      qtDeps = qtDepsFor pkgs;
      gstDeps = gstDepsFor pkgs;
    in {
      default = pkgs.mkShell {
        packages = with pkgs;
          [
            quickshell
            qt6.qtdeclarative
            libva
            libva-utils
            wireplumber
            pulseaudio
            bluez
            networkmanager
            niri
            jq
            alejandra
            systemd
            socat
          ]
          ++ qtDeps ++ gstDeps;

        shellHook = ''
          export QML_XHR_ALLOW_FILE_READ=1
          export QML2_IMPORT_PATH="${pkgs.quickshell}/lib/qt-6/qml:${pkgs.lib.makeSearchPathOutput "out" "lib/qt-6/qml" qtDeps}"
          export QT_PLUGIN_PATH="${pkgs.lib.makeSearchPathOutput "out" "lib/qt-6/plugins" qtDeps}:${pkgs.qt6.qtbase}/${pkgs.qt6.qtbase.qtPluginPrefix}"
          export GST_PLUGIN_SYSTEM_PATH_1_0="${pkgs.lib.makeSearchPathOutput "lib" "lib/gstreamer-1.0" gstDeps}"

          echo "qLock dev environment active."
          echo "  nix run .#preview  — safe preview (no lock)"
          echo "  nix run .#qlock    — REAL LOCK, use from a second TTY first"
        '';
      };
    });

    formatter = forAllSystems (system: (pkgsFor system).alejandra);

    checks = forAllSystems (system: let
      pkgs = pkgsFor system;
    in {
      config-json-valid = pkgs.runCommand "qlock-config-json-valid" {} ''
        ${pkgs.lib.getExe pkgs.jq} -e . ${./config/config.json} > /dev/null
        touch $out
      '';
      qml-present = pkgs.runCommand "qlock-qml-present" {} ''
        for f in shell.qml test.qml components/PlaylistEngine.qml components/VideoBackground.qml components/VideoTitle.qml components/AuthOverlay.qml components/AuthContext.qml components/ConfigLoader.qml components/SuspendWatcher.qml components/SystemVolumeWatcher.qml config/config.json; do
          test -f ${./.}/$f || (echo "missing $f" && exit 1)
        done
        touch $out
      '';
    });
  };
}
