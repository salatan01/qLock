pragma ComponentBehavior: Bound

import QtQuick
import QtMultimedia

Item {
    id: root

    required property string source
    property real volume: 0.15
    property bool suspended: false   // set true by suspend-hook to pause safely

    signal ended()

    MediaPlayer {
        id: player
        source: root.source
        audioOutput: AudioOutput {
            volume: root.volume
        }
        videoOutput: videoOutput
        loops: 1

        onMediaStatusChanged: {
            if (mediaStatus === MediaPlayer.EndOfMedia) {
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
        if (source.length > 0) {
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
