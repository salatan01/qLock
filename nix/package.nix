{
  lib,
  stdenvNoCC,
  makeWrapper,
  quickshell,
  qt6,
  gst_all_1,
  dbus,
  wireplumber,
  bash,
  coreutils,
  procps,
  util-linux,
  version ? "0.1.1",
  src,
}: let
  # Minimal runtime set — keep this lean, every entry lands in the closure:
  # - qtbase/declarative/multimedia/wayland/5compat: QML core, video,
  #   session-lock, OpacityMask glass. (NOT qtsvg/qtimageformats: no SVG or
  #   raster images anywhere in the QML.)
  # - base/good/bad/libav: mp4 demux (good), h264/aac parse+decode
  #   (bad/libav). (NOT ugly: only mpeg2/asf/dvd legacy formats.)
  qtDeps = with qt6; [
    qtbase
    qtdeclarative
    qtmultimedia
    qt5compat
    qtwayland
  ];

  gstDeps = with gst_all_1; [
    gstreamer
    gst-plugins-base
    gst-plugins-good
    gst-plugins-bad
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
  # Minimal PATH for QML helper processes: dbus-monitor (SuspendWatcher,
  # from dbus/bin), wpctl (loudness lock), sh/rm (save-file + supervisor),
  # pkill (post-unlock stall backstop in shell.qml — SIGTERMs a hung lock
  # body; supervisor EXIT trap still restores the mixer).
  # Notably NOT systemd: nothing invokes systemctl/loginctl — and it costs
  # ~190MB of closure. NOT niri either (dev-shell only, never packaged).
  binPath = lib.makeBinPath [dbus wireplumber bash coreutils procps];
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

          mkdir -p $out/share/qlock/components $out/share/qlock/config $out/bin $out/libexec

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
      # Long-memory shuffle lives here (shared with PlaylistEngine.qml
      # _stateBase): per-folder played lists, JSON, 0600-dir protected.
      HIST_BASE=""
      if [ -n "$XDG_STATE_HOME" ]; then HIST_BASE="$XDG_STATE_HOME";
      elif [ -n "$HOME" ]; then HIST_BASE="$HOME/.local/state"; fi
      HIST_FILE=""
      if [ -n "$HIST_BASE" ]; then HIST_FILE="$HIST_BASE/qlock/history.json"; fi
      if [ "''${1:-}" = "clear-cache" ] || [ "''${1:-}" = "--clear-cache" ] || [ "''${1:-}" = "clear_cache" ]; then
        if [ -n "$HIST_FILE" ] && [ -f "$HIST_FILE" ]; then
          ${coreutils}/bin/rm -f "$HIST_FILE"
          echo "qlock: cleared shuffle history ($HIST_FILE)"
        else
          echo "qlock: no shuffle history to clear"
        fi
        exit 0
      fi
      if [ "''${1:-}" = "--help" ] || [ "''${1:-}" = "-h" ] || [ "''${1:-}" = "help" ]; then
        echo "Usage: qlock [--help] [clear-cache]"
        echo "  (no args)   lock the session (production ext-session-lock surface)"
        echo "  clear-cache drop long-memory shuffle history, allow repeats again"
        exit 0
      fi
      # Single-instance guard. Caller configs (hypridle, compositor keybinds,
      # systemd) can launch qlock concurrently; two lock surfaces fight over
      # the session lock, and BOTH can keep the sink pinned after one unlocks.
      # `pidof qlock` cannot see this bash wrapper (it only matches the
      # quickshell child), so take an advisory lock that the supervisor holds
      # and the child inherits. XDG_RUNTIME_DIR is preferred; fall back to the
      # user cache when it is unset (e.g. launched from a bare TTY).
      LOCK_FILE=""
      if [ -n "$XDG_RUNTIME_DIR" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
        LOCK_FILE="$XDG_RUNTIME_DIR/qlock.lock"
      elif [ -n "$HOME" ]; then
        ${coreutils}/bin/mkdir -p -m 0700 "$HOME/.cache/qlock" 2>/dev/null || true
        ${coreutils}/bin/chmod 0700 "$HOME/.cache/qlock" 2>/dev/null || true
        LOCK_FILE="$HOME/.cache/qlock/qlock.lock"
      fi
      if [ -n "$LOCK_FILE" ]; then
        if ! exec 9>>"$LOCK_FILE"; then
          echo "qlock: cannot open lock file $LOCK_FILE; continuing without duplicate guard" >&2
        elif ! ${util-linux}/bin/flock -n 9; then
          echo "qlock: already running (lock held: $LOCK_FILE)" >&2
          exit 0
        fi
      else
        echo "qlock: no XDG_RUNTIME_DIR or HOME; duplicate-instance guard disabled" >&2
      fi
      # Ensure history dir exists for QML FileView atomic writes (best effort).
      if [ -n "$HIST_BASE" ]; then
        ${coreutils}/bin/mkdir -p -m 0700 "$HIST_BASE/qlock" 2>/dev/null || ${coreutils}/bin/mkdir -p "$HIST_BASE/qlock" 2>/dev/null || true
        ${coreutils}/bin/chmod 0700 "$HIST_BASE/qlock" 2>/dev/null || true
      fi
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
            # Mute-transit: silence first so jumping the volume back (e.g.
            # 0.20 -> 0.75) can't surge video or background audio mid-jump.
            ${wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ 1 >/dev/null 2>&1 || true
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
      CHILD_PID=""
      shutdown() {
        # Capture the triggering status BEFORE resetting traps: running
        # `trap - ...` itself overwrites $? with 0.
        local status=$?
        trap - EXIT HUP INT TERM
        # TERM the lock body and give it a moment to exit cleanly before
        # restoring the mixer. Restoring while quickshell is still alive lets
        # its own QML exit path race the wrapper's wpctl chain (or re-pin the
        # sink after we restored it). Bounded: a wedged child cannot block
        # logout/suspend forever.
        if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
          kill -TERM "$CHILD_PID" 2>/dev/null || true
          WAITED=0
          while kill -0 "$CHILD_PID" 2>/dev/null && [ "$WAITED" -lt 20 ]; do
            ${coreutils}/bin/sleep 0.1
            WAITED=$((WAITED + 1))
          done
          if kill -0 "$CHILD_PID" 2>/dev/null; then
            kill -KILL "$CHILD_PID" 2>/dev/null || true
          fi
          wait "$CHILD_PID" 2>/dev/null || true
        fi
        restore_sink
        exit "$status"
      }
      trap shutdown EXIT HUP INT TERM
      # Keep fd 9 (the flock) in the supervisor ONLY. If the child inherited
      # it, an orphaned helper after a quickshell crash (dbus-monitor
      # survives SIGKILL) would hold the lock forever and block all future
      # locks. A supervisor SIGKILL releases the guard — untrappable and
      # preferable to a permanently stuck lockscreen.
      "$LOCK_BIN" "$@" 9>&- &
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
      test -x $out/bin/qlock-preview
      test -f $out/libexec/qlock-lock
      ${bash}/bin/bash -n $out/bin/qlock
      grep -q "clear-cache" $out/bin/qlock
      grep -q "history.json" $out/bin/qlock
      grep -q "flock -n 9" $out/bin/qlock
      grep -q "qlock.lock" $out/bin/qlock
      for f in PlaylistEngine VideoBackground VideoTitle AuthOverlay AuthContext ConfigLoader SuspendWatcher SystemVolumeWatcher; do
        test -f $out/share/qlock/components/$f.qml
      done
    '';

    meta = {
      description = "qLock — video-wallpaper ext-session-lock screen for Quickshell";
      longDescription = ''
        Production PAM lockscreen: random/shuffled video wallpaper with
        seamless looping, frosted-glass auth HUD, suspend-aware playback,
        sink-anchored bg loudness (immune to system volume), crash-safe mixer
        restore via supervisor trap, and layered JSON config.
      '';
      homepage = "https://github.com/salatan01/qlock";
      license = lib.licenses.mit;
      platforms = ["x86_64-linux" "aarch64-linux"];
      mainProgram = "qlock";
      maintainers = [];
    };
  }
