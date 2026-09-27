import QtQuick
import Quickshell
import Quickshell.Wayland

import "./components"

// shell.qml — PRODUCTION PAM LOCKSCREEN. Video wallpaper + frosted HUD.
// This is the real ext-session-lock surface. Test visuals with test.qml first.
ShellRoot {
    id: root

    property var config: ({
        videoDirectory: Quickshell.env("HOME") + "/qSets/qLock/",
        mode: "random",
        fixedFile: "",
        repeat: true,
        volume: 20
    })

    Component.onCompleted: root._loadConfig()

    function _configCandidates() {
        // Priority: $QLOCK_CONFIG > $XDG_CONFIG_HOME/qlock > ~/.config/qlock
        //   > /etc/qlock (NixOS module) > bundled ./config/config.json
        const candidates = [];
        const override = Quickshell.env("QLOCK_CONFIG") || "";
        if (override.length > 0) {
            candidates.push(override.startsWith("file://") ? override : "file://" + override);
        }
        const xdg = Quickshell.env("XDG_CONFIG_HOME") || "";
        const home = Quickshell.env("HOME") || "";
        if (xdg.length > 0) {
            candidates.push("file://" + xdg + "/qlock/config.json");
        } else if (home.length > 0) {
            candidates.push("file://" + home + "/.config/qlock/config.json");
        }
        candidates.push("file:///etc/qlock/config.json");
        candidates.push(Qt.resolvedUrl("./config/config.json"));
        return candidates;
    }

    function _loadConfig() {
        root._tryConfigUrl(root._configCandidates(), 0);
    }

    function _tryConfigUrl(urls, i) {
        if (i >= urls.length) {
            console.warn("qLock: no config.json found, using built-in defaults:", JSON.stringify(root.config));
            return;
        }
        const xhr = new XMLHttpRequest();
        xhr.open("GET", urls[i]);
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            if (xhr.status === 200) {
                try {
                    const parsed = JSON.parse(xhr.responseText);
                    // Merge over built-in defaults so partial configs work.
                    root.config = Object.assign({}, root.config, parsed);
                    console.log("qLock: config loaded from", urls[i], JSON.stringify(root.config));
                } catch (e) {
                    console.warn("qLock: failed to parse", urls[i], e, "- trying next");
                    root._tryConfigUrl(urls, i + 1);
                }
            } else {
                if (i === urls.length - 1) {
                    console.warn("qLock: bundled config unreachable — check QML_XHR_ALLOW_FILE_READ=1; using defaults", JSON.stringify(root.config));
                }
                root._tryConfigUrl(urls, i + 1);
            }
        };
        xhr.send();
    }

    function _handleUnlock() {
        // Restore the pre-lock sink gain first; the EXIT trap in the `qlock`
        // wrapper is the backstop if quit ever outruns the async restore.
        // Unlock is delayed ~800ms so wpctl lands before we exit (the
        // success fade covers the wait).
        sysVol.restore();
        unlockTimer.start();
    }

    Timer {
        id: unlockTimer
        interval: 800
        repeat: false
        onTriggered: {
            lock.locked = false;
            Qt.quit();
        }
    }

    SuspendWatcher {
        id: suspendWatcher
    }

    SystemVolumeWatcher {
        id: sysVol
        // Pin the sink while locked so bg loudness is exactly `volume`,
        // immune to volume buttons. `!== false` keeps pinning on for
        // legacy configs lacking the key. Preview (test.qml) never pins.
        pinned: root.config.pinSink !== false
    }

    PlaylistEngine {
        id: playlist
        videoDirectory: root.config.videoDirectory
        mode: root.config.mode
        fixedFile: root.config.fixedFile
    }

    // MAIN LOCKSHELL — video as wallpaper
    WlSessionLock {
        id: lock
        locked: true

        WlSessionLockSurface {
            color: "black"

            VideoBackground {
                anchors.fill: parent
                z: 0
                source: playlist.currentVideoUrl
                volume: root.config.volume
                sinkVolume: sysVol.sinkVolume
                sinkMuted: sysVol.sinkMuted
                pinActive: sysVol.pinActive
                suspended: suspendWatcher.suspended
                loop: root.config.repeat !== false
                onEnded: playlist.next()
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

            AuthOverlay {
                z: 2
                onAuthSucceeded: root._handleUnlock()
            }
        }
    }
}
