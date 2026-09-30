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
    // Playback-count ("2playback" = play twice, then advance):
    //   0 = loop the current video forever (legacy repeat:true default).
    //   N = play exactly N times (MediaPlayer.loops=N is seamless — the
    //       backend loops the decoded stream internally, no stop/reload, no
    //       black flash), then MediaPlayer hits EndOfMedia and we emit ended()
    //       so the playlist advances. N=1 behaves like legacy repeat:false.
    // Qt semantics (verified): loops = total play count, default 1, 0 is a
    // no-op (never assign 0), Infinite (-1) loops forever.
    // The shell passes 0 for fixed mode (advancing is meaningless there) and
    // ConfigLoader.effectivePlayCount() for random mode.
    property int playCount: 0
    readonly property bool infinite: root.loop && root.playCount <= 0
    readonly property int effectiveLoops: {
        if (!root.loop) return 1;
        if (root.playCount <= 0) return MediaPlayer.Infinite;
        return Math.max(1, Math.min(100, Math.floor(root.playCount)));
    }
    // Seamless repeat: the backend loops the decoded stream internally —
    // no stop/reload/rebuffer, so no black flash between iterations.
    // When false, plays once and emits ended() for playlist advance.
    property bool loop: true
    // Set QLOCK_DEBUG=1 for per-change volume logs (off by default: the
    // sink poller would spam the journal every 500ms otherwise).
    property bool debug: false

    signal ended()
    // Undecodable file (missing codec, truncated mp4, ...). Shells route
    // this to playlist.skipFailed() for an immediate gapless jump — the
    // stall-forever warn-only path is gone. Emitted at most once per URL.
    signal failed(string reason)

    // Explicit in-place replay for fixed mode safety (normally never needed:
    // fixed uses playCount=0 → infinite → EndOfMedia never fires). Does NOT
    // touch `source`, so no stop()/play() URL-reload flicker and none of the
    // old blank-and-restore ("") hacks.
    function restart() {
        player.stop();
        player.play();
    }

    onVolumeChanged: if (root.debug) console.log("qLock: volume", root.volume, "-> target", root.targetVolume.toFixed(3), "effective", root.effectiveVolume.toFixed(3), "@ sink", root.sinkVolume.toFixed(2), root.pinActive ? "[PINNED]" : "", "loops", root.effectiveLoops);
    // NOTE: read effectiveVolume here, not in onSinkVolumeChanged — change
    // handlers run before dependent bindings re-evaluate, so that would log
    // the previous (stale) value.
    onEffectiveVolumeChanged: if (root.debug) console.log("qLock: volume", root.volume, "-> target", root.targetVolume.toFixed(3), "effective", root.effectiveVolume.toFixed(3), "@ sink", root.sinkVolume.toFixed(2), root.pinActive ? "[PINNED]" : "", "loops", root.effectiveLoops);
    onEffectiveLoopsChanged: {
        if (root.debug) console.log("qLock: loops →", root.effectiveLoops === MediaPlayer.Infinite ? "Infinite" : root.effectiveLoops);
        if (root.playCount > 0 && root.loop && root.debug) console.log("qLock:", root.playCount + "playback active — same video repeats", root.playCount + "x, then playlist advances");
    }

    MediaPlayer {
        id: player
        source: root.source
        audioOutput: AudioOutput {
            volume: root.effectiveVolume
        }
        videoOutput: videoOutput
        loops: root.effectiveLoops

        onMediaStatusChanged: {
            // Infinite never reaches EndOfMedia (backend loops forever), so
            // `ended` fires exactly after effectiveLoops plays. No URL
            // toggling here — the shell advances the playlist (random) or
            // restarts in place (fixed).
            if (mediaStatus === MediaPlayer.EndOfMedia && root.effectiveLoops !== MediaPlayer.Infinite) {
                root.ended();
            }
        }

        onErrorOccurred: (error, errorString) => {
            const src = player.source.toString();
            // Dedup: Qt can fire error repeatedly for one bad file; only
            // the first should trigger a skip (no rapid multi-skip).
            if (src.length > 0 && src !== root._lastErrorSrc) {
                root._lastErrorSrc = src;
                console.warn("qLock: MediaPlayer error, skipping:", errorString);
                root.failed(errorString);
            }
        }
    }

    VideoOutput {
        id: videoOutput
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
    }

    property string _lastErrorSrc: ""

    onSourceChanged: {
        // New URL arms the error guard again.
        if (player.source.toString() !== source) root._lastErrorSrc = "";
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
        if (root.debug) console.log("qLock: volume", root.volume, "-> target", root.targetVolume.toFixed(3), "effective", root.effectiveVolume.toFixed(3), "@ sink", root.sinkVolume.toFixed(2), root.pinActive ? "[PINNED]" : "", "loops", root.effectiveLoops);
        if (root.source.length > 0) player.play();
    }
}
