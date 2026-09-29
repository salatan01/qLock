import QtQuick
import Quickshell

import "./components"

// test.qml — SAFE PREVIEW ONLY. No WlSessionLock, never locks the session.
// Run with: quickshell --path /home/superkat01/qlock/test.qml
ShellRoot {
    id: root

    ConfigLoader {
        id: cfg
    }

    AuthContext {
        id: authCtx
        // In preview, PAM success just quits so visuals can be tested safely
        onAuthSucceeded: Qt.quit()
    }

    SuspendWatcher {
        id: suspendWatcher
    }

    SystemVolumeWatcher {
        id: sysVol
    }

    PlaylistEngine {
        id: playlist
        videoDirectory: cfg.config.videoDirectory
        mode: cfg.config.mode
        fixedFile: cfg.config.fixedFile

        onCountChanged: console.log("qLock[test]: PlaylistEngine count", count, "dir", playlist.resolvedDirectory, "(raw:", cfg.config.videoDirectory + ")")
    }

    Connections {
        target: playlist
        function onCurrentVideoUrlChanged() {
            console.log("qLock[test]: currentVideoUrl →", playlist.currentVideoUrl, " (count", playlist.count, ")");
        }
    }

    Connections {
        target: cfg
        function onConfigLoaded(from) {
            const n = cfg.effectivePlayCount()
            console.log("qLock[test]: playback →", n === 0 ? "Infinite" : n + "x per video",
                "(mode", cfg.config.mode + ", repeat", cfg.config.repeat + ")")
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
            volume: cfg.config.volume
            sinkVolume: sysVol.sinkVolume
            sinkMuted: sysVol.sinkMuted
            pinActive: sysVol.pinActive
            suspended: suspendWatcher.suspended
            loop: cfg.config.repeat !== false
            playCount: cfg.config.mode === "fixed" ? 0 : cfg.effectivePlayCount()
            debug: cfg.debug
            onEnded: {
                if (playlist.mode === "fixed") previewVideo.restart()
                else playlist.next()
            }
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
                        text: "add *.mp4 / *.mkv / *.webm to preview"
                        color: "#88ffffff"
                        font.pixelSize: 11
                    }
                }
            }
        }

        AuthOverlay {
            id: previewAuth
            z: 5
            authContext: authCtx
            // QLOCK_PREVIEW_MOUSE=0 previews the mouse-free lock build:
            // keyboard only (any key reveals, Enter submits). Quit via
            // successful auth (real PAM) or kill the process.
            mouseEnabled: (Quickshell.env("QLOCK_PREVIEW_MOUSE") || "1") !== "0"
        }

        // Same invisible-cursor layer as the real lock, preview-only and
        // only when mouse is disabled. Below the quit pill (z:10) so the
        // pill stays visible; clicks pass through everywhere (NoButton).
        MouseArea {
            anchors.fill: parent
            z: 6
            visible: !previewAuth.mouseEnabled
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            cursorShape: Qt.BlankCursor
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
                Text { text: "• hover/Enter to reveal • click quit"; color: "#88ffffff"; font.pixelSize: 10 }
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: Qt.quit()
            }
        }
    }
}
