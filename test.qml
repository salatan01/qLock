import QtQuick
import Quickshell

import "./components"

// test.qml — SAFE PREVIEW ONLY. No WlSessionLock, never locks the session.
// Run with: quickshell --path /home/superkat01/qlock/test.qml
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
            console.warn("qLock[test]: no config.json found, using built-in defaults:", JSON.stringify(root.config));
            return;
        }
        const xhr = new XMLHttpRequest();
        xhr.open("GET", urls[i]);
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            if (xhr.status === 200) {
                try {
                    const parsed = JSON.parse(xhr.responseText);
                    root.config = Object.assign({}, root.config, parsed);
                    console.log("qLock[test]: config loaded from", urls[i], JSON.stringify(parsed));
                } catch (e) {
                    console.warn("qLock[test]: failed to parse", urls[i], e, "- trying next");
                    root._tryConfigUrl(urls, i + 1);
                }
            } else {
                if (i === urls.length - 1) {
                    console.warn("qLock[test]: config.json XHR failed — check QML_XHR_ALLOW_FILE_READ=1; using defaults", JSON.stringify(root.config));
                }
                root._tryConfigUrl(urls, i + 1);
            }
        };
        xhr.send();
    }

    SuspendWatcher {
        id: suspendWatcher
    }

    SystemVolumeWatcher {
        id: sysVol
    }

    PlaylistEngine {
        id: playlist
        videoDirectory: root.config.videoDirectory
        mode: root.config.mode
        fixedFile: root.config.fixedFile

        onCountChanged: console.log("qLock[test]: PlaylistEngine count", count, "dir", playlist.resolvedDirectory, "(raw:", root.config.videoDirectory + ")")
    }

    Connections {
        target: playlist
        function onCurrentVideoUrlChanged() {
            console.log("qLock[test]: currentVideoUrl →", playlist.currentVideoUrl, " (count", playlist.count, ")");
        }
    }

    PanelWindow {
        id: previewWindow

        anchors { left: true; right: true; top: true; bottom: true }
        margins { left: 0; right: 0; top: 0; bottom: 0 }
        exclusionMode: ExclusionMode.Ignore
        exclusiveZone: 0
        color: "black"

        VideoBackground {
            id: previewVideo
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

        Rectangle {
            anchors.fill: parent
            z: 1
            gradient: Gradient {
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 0.55; color: "transparent" }
                GradientStop { position: 1.0; color: "#66000000" }
            }
        }

        AuthOverlay {
            id: previewAuth
            z: 5
            // In preview, PAM success just quits so visuals can be tested safely
            onAuthSucceeded: Qt.quit()
        }

        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.margins: 14
            height: 28
            width: quitRow.implicitWidth + 18
            radius: 14
            color: "#66000000"
            border.color: "#22ffffff"
            z: 10
            Row {
                id: quitRow
                anchors.centerIn: parent
                spacing: 6
                Text { text: "Preview"; color: "#ffcc00"; font.pixelSize: 11; font.weight: Font.DemiBold }
                Text { text: "• hover/key to reveal • click quit"; color: "#88ffffff"; font.pixelSize: 10 }
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: Qt.quit()
            }
        }
    }
}
