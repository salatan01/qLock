import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

import "./components"

// shell.qml — PRODUCTION PAM LOCKSCREEN. Video wallpaper + frosted HUD.
// This is the real ext-session-lock surface. Test visuals with test.qml first.
ShellRoot {
    id: root
    // Guard: PAM success must unlock exactly once. Without this a double
    // onAuthSucceeded (multi-surface race) would restart timers mid-quit
    // and delay exit — leaving the volume pin alive longer than needed.
    property bool _unlocked: false

    // Layered JSON config + playback normalization (see ConfigLoader.qml).
    ConfigLoader {
        id: cfg
    }

    // Shared auth: ONE PamContext for all screens. WlSessionLock clones its
    // surface per monitor; each AuthOverlay below is a dumb view onto this.
    AuthContext {
        id: authCtx
        onAuthSucceeded: root._handleUnlock()
    }

    function _handleUnlock() {
        // Idempotent: second success while quitting is a no-op.
        if (root._unlocked) return;
        root._unlocked = true;
        // Restore the pre-lock sink gain first; the EXIT trap in the `qlock`
        // wrapper is the backstop if quit ever outruns the async restore.
        // Flush shuffle history too: the 400ms save debounce must not be
        // outrun by quit, or this play goes unrecorded and may repeat.
        // Unlock is delayed ~800ms so wpctl + the history write land before
        // we exit (the success fade covers the wait), then 400ms more so
        // the unlock commits to the compositor before the process exits.
        // Failsafes below guarantee we can never linger pinning the sink:
        // restore() already stops enforcement synchronously, and the
        // force-quit + pkill timers kill a stalled process even if
        // lock.locked=false or Qt.quit() hangs.
        sysVol.restore()
        playlist.flushHistory()
        unlockTimer.start()
        forceQuitTimer.start()
        killerTimer.start()
    }

    Timer {
        id: unlockTimer
        interval: 800
        repeat: false
        onTriggered: {
            lock.locked = false
            quitTimer.start()
        }
    }

    Timer {
        id: quitTimer
        interval: 400
        repeat: false
        onTriggered: Qt.quit()
    }

    // Stall backstop 1: re-assert unlock + quit. Covers a compositor that
    // swallowed lock.locked=false or a Qt that ignored the first quit().
    // Enforcement is already off (restore() ran synchronously), so volume
    // keys work even before this fires — this just reaps the process.
    Timer {
        id: forceQuitTimer
        interval: 2500
        repeat: false
        onTriggered: {
            lock.locked = false
            Qt.quit()
        }
    }

    // Stall backstop 2 (your `pkill qlock` request, made precise): SIGTERM
    // the lock body if it is still alive 3.5s after auth. Pattern matches
    // ONLY the production surface (`share/qlock/shell.qml`) — never the
    // preview (`test.qml`), never the `qlock` supervisor itself. The
    // supervisor EXIT trap then runs the final mixer restore, so this is
    // safe mid-transit. Requires `pkill` (procps) on PATH — provided by
    // the nix wrapper; on failure we just fall through to Qt.quit().
    Timer {
        id: killerTimer
        interval: 3500
        repeat: false
        onTriggered: {
            if (!killer.running) killer.running = true
        }
    }

    Process {
        id: killer
        command: ["pkill", "-f", "share/qlock/shell.qml"]
        onExited: (exitCode, exitStatus) => {
            // pkill exits 0 = killed something, 1 = nothing matched
            // (already gone — ideal). Either way, we must be gone too.
            Qt.quit()
        }
    }

    SuspendWatcher {
        id: suspendWatcher
    }

    SystemVolumeWatcher {
        id: sysVol
        // Force the sink to `volume` while locked so bg loudness is exactly
        // the configured value, immune to volume buttons; pre-lock comes
        // back on unlock. `!== false` keeps pinning on for legacy configs
        // lacking the key. Preview (test.qml) never pins.
        pinned: cfg.config.pinSink !== false
        volumeConfig: cfg.config.volume
    }

    PlaylistEngine {
        id: playlist
        videoDirectory: cfg.config.videoDirectory
        mode: cfg.config.mode
        fixedFile: cfg.config.fixedFile
        enableHistory: true
    }

    // MAIN LOCKSHELL — video as wallpaper
    WlSessionLock {
        id: lock
        locked: true

        WlSessionLockSurface {
            color: "black"

            VideoBackground {
                id: bgVideo
                anchors.fill: parent
                z: 0
                source: playlist.currentVideoUrl
                volume: cfg.config.volume
                sinkVolume: sysVol.sinkVolume
                sinkMuted: sysVol.sinkMuted
                pinActive: sysVol.pinActive
                pinLevel: sysVol.pinLevel
                pinMuted: sysVol.pinMuted
                silenced: sysVol.streamSilenced
                suspended: suspendWatcher.suspended
                loop: cfg.config.repeat !== false
                // Fixed mode advances nowhere, so it loops forever in-player
                // (no EndOfMedia, no reload flicker). Random mode replays
                // each video `playback` times seamlessly, then advances:
                // playback=2 is "2playback", 3 is "3playback", 0 is forever.
                playCount: cfg.config.mode === "fixed" ? 0 : cfg.effectivePlayCount()
                debug: cfg.debug
                onEnded: {
                    if (playlist.mode === "fixed") bgVideo.restart()
                    else playlist.next()
                }
                // Corrupt file: gapless jump, no stall. Fixed mode has
                // nowhere to jump — stay put (error guard dedups, no spin).
                onFailed: {
                    if (playlist.mode !== "fixed") playlist.skipFailed()
                }
            }

            // soft vignette so HUD stays readable while video stays hero
            Rectangle {
                anchors.fill: parent
                z: 1
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 0.55; color: "transparent" }
                    GradientStop { position: 1.0; color: "#55000000" }
                }
            }

            // Empty-library / loading states: never leave a bare black
            // screen without telling the user why.
            Item {
                anchors.fill: parent
                z: 2
                visible: playlist.ready && playlist.count === 0
                Rectangle {
                    anchors.centerIn: parent
                    width: emptyCol.implicitWidth + 36
                    height: emptyCol.implicitHeight + 28
                    radius: 14
                    color: "#aa101418"
                    border.color: "#55ffffff"
                    Column {
                        id: emptyCol
                        anchors.centerIn: parent
                        spacing: 6
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "No videos found"
                            color: "white"
                            font.pixelSize: 16
                            font.weight: Font.DemiBold
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "dir: " + playlist.resolvedDirectory
                            color: "#aaffffff"
                            font.pixelSize: 11
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "add *.mp4 / *.mkv / *.webm, then re-lock"
                            color: "#88ffffff"
                            font.pixelSize: 11
                        }
                    }
                }
            }
            Item {
                anchors.fill: parent
                z: 2
                visible: playlist.loading && playlist.count === 0
                Rectangle {
                    anchors.centerIn: parent
                    width: loadingRow.implicitWidth + 36
                    height: 44
                    radius: 22
                    color: "#aa101418"
                    border.color: "#33ffffff"
                    Row {
                        id: loadingRow
                        anchors.centerIn: parent
                        spacing: 8
                        Text { text: "◐"; color: "#8ad6ff"; font.pixelSize: 14 }
                        Text { text: "Loading videos…"; color: "#ccffffff"; font.pixelSize: 12 }
                    }
                }
            }

            AuthOverlay {
                z: 3
                authContext: authCtx
                // Mouse-free lock: keyboard only (Enter reveals, Esc hides).
                // All MouseAreas inside go dead.
                mouseEnabled: false
            }

            // Now-playing title, bottom-center. Toggle: showTitle:false.
            VideoTitle {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 28
                z: 2
                videoUrl: playlist.currentVideoUrl
                show: cfg.config.showTitle !== false
            }

            // Invisible cursor: topmost, hover-enabled so its shape wins
            // everywhere (even over the password field), accepts no buttons
            // so nothing is clickable — clicks fall through to dead layers.
            // The video stays perfectly clean.
            MouseArea {
                anchors.fill: parent
                z: 100
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
                cursorShape: Qt.BlankCursor
            }
        }
    }
}
