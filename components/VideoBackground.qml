pragma ComponentBehavior: Bound

import QtQuick
import QtMultimedia

Item {
    id: root

    required property string source
    property real volume: 0.15
    property bool suspended: false   // set true by suspend-hook to pause safely
    // Seamless repeat: the backend loops the decoded stream internally —
    // no stop/reload/rebuffer, so no black flash between iterations.
    // When false, plays once and emits ended() for playlist advance.
    property bool loop: true

    signal ended()

    MediaPlayer {
        id: player
        source: root.source
        audioOutput: AudioOutput {
            volume: root.volume
        }
        videoOutput: videoOutput
        loops: root.loop ? MediaPlayer.Infinite : 1

        onMediaStatusChanged: {
            if (!root.loop && mediaStatus === MediaPlayer.EndOfMedia) {
                root.ended();
            }
        }

        onErrorOccurred: (error, errorString) => {
            console.warn("qLock: MediaPlayer error:", errorString);
        }
    }

    VideoOutput {
        id: videoOutput
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
    }

    onSourceChanged: {
        // Skip redundant reloads (e.g. fixed-mode re-signalling the same URL):
        // a needless stop()/play() cycle is itself a visible stutter.
        if (source.length > 0 && player.source.toString() !== source) {
            player.stop();
            player.source = source;
            if (!root.suspended) player.play();
        }
    }

    onSuspendedChanged: {
        if (suspended) {
            player.pause();
        } else if (player.source.toString().length > 0) {
            player.play();
        }
    }

    Component.onCompleted: {
        if (root.source.length > 0) player.play();
    }
}
