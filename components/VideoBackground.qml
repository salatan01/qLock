pragma ComponentBehavior: Bound

import QtQuick
import QtMultimedia

Item {
    id: root

    required property string source
    // Human-friendly 0-100 scale: 20 = 20% linear output.
    // Back-compat: values <= 1.0 are treated as the old 0-1 fraction
    // (e.g. 0.15 = 15%), so existing configs keep working.
    property real volume: 20
    // Live default-sink gain (0-1, up to 1.5) from SystemVolumeWatcher.
    // Qt applies AudioOutput.volume BEFORE the sink gain, and the sink
    // follows a cubic curve, so the stream divides sink^3 back out. This is
    // the SAME math pinned and unpinned: the lock must sound exactly like
    // the preview at the same `volume` (see effectiveVolume).
    property real sinkVolume: 1.0
    property bool sinkMuted: false
    property bool pinActive: false
    // Mute captured at lock time (SystemVolumeWatcher.pinMuted). While
    // pinned, a sink muted before locking keeps the stream silent even if
    // something unmutes the mixer mid-lock.
    property bool pinMuted: false
    // Unlock fade: forced silent (bound to SystemVolumeWatcher.streamSilenced).
    // Synchronous — kills the restore blast where async `wpctl set-volume`
    // jumps the real sink loud ~200ms before polling notices. Wins over everything.
    property bool silenced: false
    // Config value normalized to 0-1, before sink compensation.
    readonly property real targetVolume: {
        var v = Number(root.volume);
        if (isNaN(v)) return 0.2;
        if (v <= 1.0) return Math.max(0, Math.min(1, v));
        return Math.max(0, Math.min(1, v / 100.0));
    }
    // What actually goes to AudioOutput: the absolute configured fraction
    // divided by the cubic sink gain, clamped to Qt's 0-1 stream range.
    //
    // Pinned and unpinned are deliberately identical. The old pinned path
    // was relative to the lock-time anchor (`target * anchor^3 / live^3`),
    // so volume 5 at a 50% sink became 0.006 output (-44 dB) instead of
    // 0.05 — perceived as muted. Absolute loudness is the contract: the
    // lock must sound like the preview at the same `volume`.
    //
    // Sink muted/quiet: hold target (silent anyway; avoids div-by-zero and
    // a full-blast jump on unmute). If the sink is so quiet that the
    // required stream gain exceeds 1.0, the stream saturates at 1.0; the
    // sink enforcer snaps a transient volume-button move back shortly.
    // pinMuted only matters while pinned: muted-at-lock stays silent.
    readonly property real effectiveVolume: {
        if (root.silenced) return 0;
        if (root.pinActive && root.pinMuted) return 0;
        if (root.sinkMuted || root.sinkVolume <= 0.01) return root.targetVolume;
        const g = root.sinkVolume * root.sinkVolume * root.sinkVolume;
        return Math.max(0, Math.min(1, root.targetVolume / Math.max(g, 0.001)));
    }
    property bool suspended: false   // set true by suspend-hook to pause safely
    // Incremented by SuspendWatcher on resume, including a resume inferred
    // from a wall-clock jump when the logind edge was missed. Playback is
    // rebuilt on every increment (see _scheduleResume).
    property int resumeCount: 0
    // Multi-monitor guard: WlSessionLock instantiates its surface once per
    // screen, so every screen owns a MediaPlayer. Only one may output audio,
    // otherwise the same video mixes N times (louder + phased). The shell
    // mutes every non-primary surface.
    property bool audioMuted: false
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

    // Carries the URL that finished: WlSessionLock clones its surface (and
    // this player) per monitor, so the shared playlist must only advance once
    // per track even if every screen reports EndOfMedia.
    signal ended(string sourceUrl)
    // Undecodable file (missing codec, truncated mp4, ...). Shells route
    // this to playlist.skipFailed() for an immediate gapless jump — the
    // stall-forever warn-only path is gone. Emitted at most once per URL.
    // Carries the failing URL too: each monitor has a cloned player, so a
    // late duplicate failure must not skip a track another surface already
    // moved on to.
    signal failed(string reason, string sourceUrl)

    // Explicit in-place replay for fixed mode / single-video libraries.
    // Does NOT touch `source`, so there is no URL-reload flicker.
    function restart() {
        root._resetPlaybackHealth();
        root._restartPlayer();
    }

    function _restartPlayer() {
        if (root.suspended) return;
        player.stop();
        if (player.source.toString().length > 0) player.play();
        root._resetProgressTracking();
    }

    // Full pipeline rebuild. After a long sleep the GStreamer/PipeWire
    // device can be gone while playbackState still claims Playing; a bare
    // play() is then a no-op that leaves the frame frozen. Clearing the URL
    // forces a new stream/device association. Retry counters are preserved
    // so a dead file still hits the bound.
    function _reloadPipeline() {
        if (root.suspended || root.source.length === 0) return;
        player.stop();
        player.source = "";
        player.source = root.source;
        player.play();
        root._resetProgressTracking();
    }

    // suspended=false and resumeCount can arrive together (logind's edge
    // plus the watchdog), and a resume inferred from a clock jump has no
    // suspended transition at all. Coalesce them into one pipeline rebuild.
    property bool _resumePending: false
    function _scheduleResume() {
        if (root._resumePending) return;
        root._resumePending = true;
        Qt.callLater(root._resumePlayback);
    }

    function _resumePlayback() {
        root._resumePending = false;
        if (root.suspended) return;
        root._resetPlaybackHealth();
        root._reloadPipeline();
    }

    // Playback health state. _lastHealthPosition is compared every
    // healthIntervalMs; a player that keeps reporting PlayingState while
    // its position never advances has lost its device (classic post-sleep
    // freeze) and needs a full pipeline rebuild.
    property int _lastHealthPosition: -1
    property int _stallTicks: 0
    property int _stallRetries: 0
    property int _playbackRetries: 0
    property bool _healthGivenUp: false
    readonly property int healthIntervalMs: 2000
    readonly property int stallTickLimit: 4
    readonly property int maxStallReloads: 3
    readonly property int maxPlayRetries: 5

    function _resetProgressTracking() {
        root._lastHealthPosition = -1;
        root._stallTicks = 0;
    }

    function _resetPlaybackHealth() {
        root._resetProgressTracking();
        root._stallRetries = 0;
        root._playbackRetries = 0;
        root._healthGivenUp = false;
    }

    // Pure-ish state machine, kept free of MediaPlayer access so tests can
    // drive it. Returns "ok" | "wait" | "retry" | "reload" | "giveup".
    // isLoading: a fresh pipeline can legitimately take a while to reach
    // PlayingState; restarting it mid-load would thrash large local files.
    function _evaluatePlaybackHealth(isPlaying, isEnded, position, isLoading) {
        if (isEnded) {
            root._lastHealthPosition = -1;
            root._stallTicks = 0;
            root._playbackRetries = 0;
            return "ok";
        }
        if (!isPlaying) {
            if (isLoading) return "wait";
            if (root._playbackRetries >= root.maxPlayRetries) return "giveup";
            root._playbackRetries += 1;
            return "retry";
        }
        if (position > root._lastHealthPosition) {
            root._lastHealthPosition = position;
            root._stallTicks = 0;
            root._playbackRetries = 0;
            return "ok";
        }
        root._stallTicks += 1;
        if (root._stallTicks < root.stallTickLimit) return "wait";
        root._stallTicks = 0;
        if (root._stallRetries >= root.maxStallReloads) return "giveup";
        root._stallRetries += 1;
        return "reload";
    }

    function _checkPlaybackHealth() {
        if (root.suspended || root.source.length === 0 || root._healthGivenUp) return;
        const ended = player.mediaStatus === MediaPlayer.EndOfMedia;
        const loading = player.mediaStatus === MediaPlayer.LoadingMedia;
        const action = root._evaluatePlaybackHealth(
            player.playbackState === MediaPlayer.PlayingState, ended, player.position, loading);
        if (action === "retry") {
            console.warn("qLock: video not playing (state", player.playbackState,
                "status", player.mediaStatus + "), rebuilding pipeline, retry",
                root._playbackRetries);
            // A stopped player after device loss can ignore stop()+play();
            // a full URL rebuild gives it a fresh backend stream. Counters
            // are preserved, so a dead file still hits the bound.
            root._reloadPipeline();
        } else if (action === "reload") {
            console.warn("qLock: video position stalled for",
                (root.stallTickLimit * root.healthIntervalMs / 1000) + "s, rebuilding pipeline (reload",
                root._stallRetries, "of", root.maxStallReloads + ")");
            root._reloadPipeline();
        } else if (action === "giveup") {
            root._healthGivenUp = true;
            console.warn("qLock: video playback unhealthy after bounded retries; giving up");
        }
    }

    Timer {
        id: playbackHealth
        interval: root.healthIntervalMs
        repeat: true
        running: root.source.length > 0 && !root.suspended
        onTriggered: root._checkPlaybackHealth()
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
            muted: root.audioMuted
        }
        videoOutput: videoOutput
        loops: root.effectiveLoops

        onMediaStatusChanged: {
            // Infinite never reaches EndOfMedia (backend loops forever), so
            // `ended` fires exactly after effectiveLoops plays. No URL
            // toggling here — the shell advances the playlist (random) or
            // restarts in place (fixed).
            if (mediaStatus === MediaPlayer.EndOfMedia && root.effectiveLoops !== MediaPlayer.Infinite) {
                // root.source is the playlist's own URL string, so the
                // shell's "is this still the current track?" comparison
                // cannot be defeated by QUrl normalization differences.
                root.ended(root.source);
            }
        }

        onErrorOccurred: (error, errorString) => {
            // Pass the playlist's own URL string, not player.source: QUrl
            // toString() can normalize it and defeat the shell's equality
            // check against playlist.currentVideoUrl.
            root._handlePlayerError(errorString, root.source);
        }
    }

    VideoOutput {
        id: videoOutput
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
    }

    property string _lastErrorSrc: ""

    function _handlePlayerError(errorString, sourceUrl) {
        const src = String(sourceUrl || "");
        // Dedup: Qt can fire error repeatedly for one bad file; only the
        // first should trigger a skip (no rapid multi-skip). The URL is
        // captured now so a queued signal cannot blame a newer track.
        if (src.length === 0 || src === root._lastErrorSrc) return;
        root._lastErrorSrc = src;
        console.warn("qLock: MediaPlayer error, skipping:", errorString);
        root.failed(errorString, src);
    }

    onSourceChanged: {
        // Empty source (empty library / directory switch): stop the old
        // video instead of leaving the previous file playing forever behind
        // an empty-state card.
        if (source.length === 0) {
            root._lastErrorSrc = "";
            // Stop unconditionally: the declarative source binding may
            // already have cleared player.source before this handler runs.
            player.stop();
            player.source = "";
            root._resetPlaybackHealth();
            return;
        }
        // Skip redundant reloads (e.g. fixed-mode re-signalling the same URL):
        // a needless stop()/play() cycle is itself a visible stutter.
        if (player.source.toString() !== source) {
            // New URL arms the error guard and the health budget again.
            root._lastErrorSrc = "";
            player.stop();
            player.source = source;
            root._resetPlaybackHealth();
            if (!root.suspended) player.play();
        }
    }

    onSuspendedChanged: {
        if (suspended) {
            player.pause();
            // Position stops advancing while paused by design.
            root._resetProgressTracking();
        } else {
            // resumeCount is bumped by SuspendWatcher for this same resume;
            // _scheduleResume collapses both notifications into one rebuild.
            root._scheduleResume();
        }
    }

    // Covers a resume whose logind `false` edge was missed: `suspended` may
    // already be false, so only this counter signals that playback must be
    // rebuilt after the machine slept.
    onResumeCountChanged: root._scheduleResume()

    Component.onCompleted: {
        if (root.debug) console.log("qLock: volume", root.volume, "-> target", root.targetVolume.toFixed(3), "effective", root.effectiveVolume.toFixed(3), "@ sink", root.sinkVolume.toFixed(2), root.pinActive ? "[PINNED]" : "", "loops", root.effectiveLoops);
        root._resetPlaybackHealth();
        if (root.source.length > 0 && !root.suspended) player.play();
    }
}
