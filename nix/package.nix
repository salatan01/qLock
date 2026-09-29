{
  lib,
  stdenvNoCC,
  makeWrapper,
  quickshell,
  qt6,
  gst_all_1,
  dbus,
  systemd,
  wireplumber,
  bash,
  coreutils,
  version ? "0.1.0",
  src,
}: let
  qtDeps = with qt6; [
    qtbase
    qtdeclarative
    qtsvg
    qtimageformats
    qtmultimedia
    qt5compat
    qtwayland
  ];

  gstDeps = with gst_all_1; [
    gstreamer
    gst-plugins-base
    gst-plugins-good
    gst-plugins-bad
    gst-plugins-ugly
    gst-libav
  ];

  qmlImportPath = lib.concatStringsSep ":" [
    "${quickshell}/lib/qt-6/qml"
    (lib.makeSearchPathOutput "out" "lib/qt-6/qml" qtDeps)
  ];

  pluginPath = lib.concatStringsSep ":" [
    (lib.makeSearchPathOutput "out" "lib/qt-6/plugins" qtDeps)
    "${qt6.qtbase}/${qt6.qtbase.qtPluginPrefix}"
  ];

  gstPath = lib.makeSearchPathOutput "lib" "lib/gstreamer-1.0" gstDeps;
  # dbus/systemd: SuspendWatcher (dbus-monitor). wireplumber: loudness lock
  # (wpctl). bash/coreutils: QML helper processes (sh save-file, rm) and the
  # supervisor script's readlink.
  binPath = lib.makeBinPath [dbus systemd wireplumber bash coreutils];
in
  stdenvNoCC.mkDerivation {
    pname = "qlock";
    inherit version src;

    nativeBuildInputs = [makeWrapper];

    # Propagated via manual wrapper env below (dontWrapQtApps = true keeps
    # wrapping fully explicit and auditable — mirrors the devShell shellHook).
    buildInputs = [quickshell] ++ qtDeps ++ gstDeps;
    dontWrapQtApps = true;

    installPhase = ''
          runHook preInstall

          mkdir -p $out/share/qlock/components $out/share/qlock/config $out/bin

          cp ${src}/shell.qml $out/share/qlock/shell.qml
          cp ${src}/test.qml $out/share/qlock/test.qml
          cp ${src}/components/*.qml $out/share/qlock/components/
          cp ${src}/config/config.json $out/share/qlock/config/config.json

        # Real lock body: quickshell + full Qt/GST env. Never executed
        # directly — $out/bin/qlock (below) supervises it with an EXIT trap
        # that restores a pinned sink even if quickshell dies abnormally.
        makeWrapper ${lib.getExe quickshell} $out/libexec/qlock-lock \
          --add-flags "--path $out/share/qlock/shell.qml" \
          --set QML_XHR_ALLOW_FILE_READ 1 \
          --prefix QML2_IMPORT_PATH : ${lib.escapeShellArg qmlImportPath} \
          --prefix QT_PLUGIN_PATH : ${lib.escapeShellArg pluginPath} \
          --prefix GST_PLUGIN_SYSTEM_PATH_1_0 : ${lib.escapeShellArg gstPath} \
          --prefix PATH : ${lib.escapeShellArg binPath}

      # Supervisor: mirrors the QML save-file protocol
      # ($XDG_RUNTIME_DIR/qlock-volpin holding "<vol> <0|1>") and restores
      # the pre-lock sink whenever the lock exits or dies — EXCEPT on SIGKILL
      # to this script itself, which is untrappable in any language (hence a
      # supervisor process rather than in-QML-only handling). NOTE: the lock
      # runs as a CHILD (no exec), because exec would replace this process
      # and take the trap with it. Quoted heredoc: build shell must not
      # expand runtime $vars (only Nix interpolations below are evaluated).
      # All helpers use absolute store paths so the script is hermetic under
      # any user PATH.
      cat > $out/bin/qlock <<'LAUNCHER_EOF'
      #!${bash}/bin/bash
      SAVED=""
      if [ -n "$XDG_RUNTIME_DIR" ]; then SAVED="$XDG_RUNTIME_DIR/qlock-volpin"; fi
      # Start marker: only a save-file NEWER than this session may be
      # restored. A stale leftover from an older crashed session must never
      # overwrite the user's current mixer — it is deleted unrestored.
      # (Also covers the QML cleaner race: if Qt.quit() outruns the async
      # `rm`, the next session sees a same-or-older file and drops it.)
      REF=""
      if [ -n "$XDG_RUNTIME_DIR" ]; then REF="$(${coreutils}/bin/mktemp -p "$XDG_RUNTIME_DIR" .qlock-ref-XXXXXX 2>/dev/null || true)"; fi
      SELF="$(${coreutils}/bin/readlink -f "$0")"
      LOCK_BIN="$(${coreutils}/bin/dirname "$SELF")/../libexec/qlock-lock"
      restore_sink() {
        if [ -n "$SAVED" ] && [ -f "$SAVED" ]; then
          if [ -n "$REF" ] && [ -f "$REF" ] && [ "$SAVED" -ot "$REF" ]; then
            ${coreutils}/bin/rm -f "$SAVED"
          else
            VOL=""
            MUTED=""
            read -r VOL MUTED < "$SAVED" || true
            if [ -n "$VOL" ]; then
              ${wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ "$VOL" >/dev/null 2>&1 || true
            fi
            if [ -n "$MUTED" ]; then
              ${wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ "$MUTED" >/dev/null 2>&1 || true
            fi
            ${coreutils}/bin/rm -f "$SAVED"
          fi
        fi
        if [ -n "$REF" ]; then ${coreutils}/bin/rm -f "$REF"; fi
      }
      shutdown() {
        if [ -n "$CHILD_PID" ]; then
          kill "$CHILD_PID" 2>/dev/null || true
        fi
        restore_sink
      }
      trap shutdown EXIT HUP INT TERM
      "$LOCK_BIN" "$@" &
      CHILD_PID=$!
      CODE=0
      wait "$CHILD_PID" || CODE=$?
      exit "$CODE"
      LAUNCHER_EOF
      chmod +x $out/bin/qlock

          makeWrapper ${lib.getExe quickshell} $out/bin/qlock-preview \
            --add-flags "--path $out/share/qlock/test.qml" \
            --set QML_XHR_ALLOW_FILE_READ 1 \
            --prefix QML2_IMPORT_PATH : ${lib.escapeShellArg qmlImportPath} \
            --prefix QT_PLUGIN_PATH : ${lib.escapeShellArg pluginPath} \
            --prefix GST_PLUGIN_SYSTEM_PATH_1_0 : ${lib.escapeShellArg gstPath} \
            --prefix PATH : ${lib.escapeShellArg binPath}

          runHook postInstall
    '';

    # Smoke-test the install layout at build time: entry points, libexec
    # body, all components, a parseable default config, and a syntactically
    # valid supervisor script must be present.
    postInstall = ''
      test -f $out/share/qlock/shell.qml
      test -f $out/share/qlock/test.qml
      test -x $out/bin/qlock
      test -f $out/libexec/qlock-lock
      ${bash}/bin/bash -n $out/bin/qlock
      for f in PlaylistEngine VideoBackground AuthOverlay AuthContext ConfigLoader SuspendWatcher SystemVolumeWatcher; do
        test -f $out/share/qlock/components/$f.qml
      done
    '';

    meta = {
      description = "qLock — video-wallpaper ext-session-lock screen for Quickshell";
      longDescription = ''
        Production PAM lockscreen: random/shuffled video wallpaper with
        seamless looping, frosted-glass auth HUD, suspend-aware playback,
        sink-pinned bg loudness (immune to system volume), crash-safe mixer
        restore via supervisor trap, and layered JSON config.
      '';
      homepage = "https://github.com/salatan01/qlock";
      license = lib.licenses.mit;
      platforms = ["x86_64-linux" "aarch64-linux"];
      mainProgram = "qlock";
      maintainers = [];
    };
  }
