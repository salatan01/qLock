pragma ComponentBehavior: Bound

import QtQuick
import QtMultimedia

Item {
    id: root

    required property string source
    // Human-friendly 0-100 scale: 20 = 20% (0.2 to AudioOutput).
    // Back-compat: values <= 1.0 are treated as the old 0-1 fraction
    // (e.g. 0.15 = 15%), so existing configs keep working.
    property real volume: 20
    // Live default-sink gain (0-1, up to 1.5) from SystemVolumeWatcher.
    // Qt applies AudioOutput.volume BEFORE the sink gain, so unpinned
    // playback divides the sink back out (see below). While PINNED the
    // sink is anchored at the lock-time level, so the stream must be the
    // raw target — compensating on top would multiply the anchor away.
    property real sinkVolume: 1.0
    property bool sinkMuted: false
    property bool pinActive: false
    // Config value normalized to 0-1, before sink compensation.
    readonly property real targetVolume: {
        var v = Number(root.volume);
        if (isNaN(v)) return 0.2;
        if (v <= 1.0) return Math.max(0, Math.min(1, v));
        return Math.max(0, Math.min(1, v / 100.0));
    }
    // What actually goes to AudioOutput. Pinned (real lock): raw target —
    // the anchored sink IS the reference, any extra math redefines "20".
    // Unpinned (preview/transitions): divide out the cubic sink curve.
    // Muted/near-zero sink: hold target (silent anyway — avoids div-by-zero
    // and full-blast on unmute). Sink quieter than target: clamps at 1.0,
    // sink gain is the floor.
    readonly property real effectiveVolume: {
        if (root.pinActive) return root.targetVolume;
        if (root.sinkMuted || root.sinkVolume <= 0.01) return root.targetVolume;
        const g = root.sinkVolume * root.sinkVolume * root.sinkVolume;
        return Math.max(0, Math.min(1, root.targetVolume / Math.max(g, 0.001)));
    }
    property bool suspended: false   // set true by suspend-hook to pause safely
    // Seamless repeat: the backend loops the decoded stream internally —
    // no stop/reload/rebuffer, so no black flash between iterations.
    // When false, plays once and emits ended() for playlist advance.
    property bool loop: true

    signal ended()

    onVolumeChanged: console.log("qLock: volume", root.volume, "-> target", root.targetVolume.toFixed(3), "effective", root.effectiveVolume.toFixed(3), "@ sink", root.sinkVolume.toFixed(2), root.pinActive ? "[PINNED]" : "");
    // NOTE: read effectiveVolume here, not in onSinkVolumeChanged — change
    // handlers run before dependent bindings re-evaluate, so that would log
    // the previous (stale) value.
    onEffectiveVolumeChanged: console.log("qLock: volume", root.volume, "-> target", root.targetVolume.toFixed(3), "effective", root.effectiveVolume.toFixed(3), "@ sink", root.sinkVolume.toFixed(2), root.pinActive ? "[PINNED]" : "");

    MediaPlayer {
        id: player
        source: root.source
        audioOutput: AudioOutput {
            volume: root.effectiveVolume
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
        console.log("qLock: volume", root.volume, "-> target", root.targetVolume.toFixed(3), "effective", root.effectiveVolume.toFixed(3), "@ sink", root.sinkVolume.toFixed(2), root.pinActive ? "[PINNED]" : "");
        if (root.source.length > 0) player.play();
    }
}
