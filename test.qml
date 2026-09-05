import QtQuick
import Quickshell

import "./components"

// test.qml — SAFE PREVIEW ONLY. No WlSessionLock, never locks the session.
// Run with: quickshell --path /home/superkat01/qlock/test.qml
ShellRoot {
    id: root

    property var config: ({
        videoDirectory: "/home/nightkat/Videos/lockscreen",
        mode: "random",
        fixedFile: "",
        volume: 0.15
    })

    Component.onCompleted: root._loadConfig()

    function _loadConfig() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("./config/config.json"));
        xhr.onreadystatechange = () => {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                if (xhr.status === 200) {
                    try {
                        const parsed = JSON.parse(xhr.responseText);
                        root.config = parsed;
                        console.log("qLock[test]: config loaded", JSON.stringify(parsed));
                    } catch (e) {
                        console.warn("qLock[test]: failed to parse config.json, using defaults:", e);
                    }
                } else {
                    console.warn("qLock[test]: config.json XHR failed — status", xhr.status, "— check QML_XHR_ALLOW_FILE_READ=1; using defaults", root.config);
                }
            }
        };
        xhr.send();
    }

    SuspendWatcher {
        id: suspendWatcher
    }

    PlaylistEngine {
        id: playlist
        videoDirectory: root.config.videoDirectory
        mode: root.config.mode
        fixedFile: root.config.fixedFile

        onCountChanged: console.log("qLock[test]: PlaylistEngine count", count, "dir", root.config.videoDirectory)
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
            suspended: suspendWatcher.suspended
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
