import QtQuick
import Quickshell
import Quickshell.Wayland

import "./components"

// shell.qml — PRODUCTION PAM LOCKSCREEN. Video wallpaper + frosted HUD.
// This is the real ext-session-lock surface. Test visuals with test.qml first.
ShellRoot {
    id: root

    property var config: ({
        videoDirectory: "/home/nightkat/Videos/lockscreen",
        mode: "random",
        fixedFile: "",
        repeat: true,
        volume: 0.15
    })

    Component.onCompleted: root._loadConfig()

    function _loadConfig() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("./config/config.json"));
        xhr.onreadystatechange = () => {
            if (xhr.readyState === XMLHttpRequest.DONE && xhr.status === 200) {
                try {
                    root.config = JSON.parse(xhr.responseText);
                    console.log("qLock: config loaded", JSON.stringify(root.config));
                } catch (e) {
                    console.warn("qLock: failed to parse config.json, using defaults:", e);
                }
            }
        };
        xhr.send();
    }

    function _handleUnlock() {
        lock.locked = false;
        Qt.quit();
    }

    SuspendWatcher {
        id: suspendWatcher
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
