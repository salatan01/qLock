pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Two jobs:
//
// 1) SENSE (always): poll the default sink gain via wpctl so
//    VideoBackground can compensate. Qt's AudioOutput.volume is a
//    per-stream multiplier applied BEFORE the sink gain — and the sink
//    gain follows a CUBIC curve (35% on the slider = 0.35^3 = -27.4 dB,
//    verified against pactl). Compensation must divide by sink^3, not
//    sink — linear math audibly under-compensates.
//
// 2) PIN (only when `pinned`, i.e. the real lock surface): save the
//    pre-lock sink, force the sink to the configured `volume` for the whole
//    session, re-asserting if anything (volume buttons, other agents) moves
//    it. On restore (unlock), the pre-lock volume+mute come back via
//    one-shot _setSink + supervisor EXIT trap — no loop, so nothing keeps
//    enforcing after the process exits. If the session was muted at lock
//    time it stays silent (mute preserved, never blasted). Forcing to the
//    config value (not anchoring at lock-time) is the whole point: `volume:
//    20` must sound like 20% while locked, then hand 90% back on unlock.
//    Crash safety: pre-pin state is also mirrored to
//    $XDG_RUNTIME_DIR/qlock-volpin so the `qlock` wrapper's EXIT trap can
//    restore it even if quickshell dies (no in-process language — QML,
//    Rust, anything — can run code after SIGKILL).
//    The preview (test.qml) never pins: pinned stays false there.
// Requires `wpctl` (wireplumber) + `rm` on PATH — the nix wrapper
// provides both. The crash-save file is written via FileView (atomic
// temp+rename, no shell, no quoting risk). Without wpctl we keep defaults
// (sinkVolume 1.0 = plain relative volume) and pinning degrades to a warning.
Item {
    id: root

    // Live sink state
    property real sinkVolume: 1.0
    property bool sinkMuted: false
    property bool available: false
    property int pollIntervalMs: 1000

    // Pinning (lock surface only). pinLevel is the CONFIGURED target
    // (normalized `volumeConfig`), NOT the lock-time level: while locked
    // the sink IS the config value (verifiable via `wpctl get-volume`),
    // then pre-lock comes back on unlock.
    property bool pinned: false
    property real pinLevel: 1.0
    // Raw config value (0-100 human scale, <=1 legacy fraction), bound by
    // the shell to cfg.config.volume. Normalized to targetSink below.
    property real volumeConfig: 20
    // Normalized 0-1 sink target. Same scale as VideoBackground.targetVolume.
    // Clamped to 0-1 (never overdrive 1.5: config 100 = full, never blast).
    readonly property real targetSink: {
        var v = Number(root.volumeConfig);
        if (isNaN(v)) return 0.2;
        if (v <= 1.0) return Math.max(0, Math.min(1, v));
        return Math.max(0, Math.min(1, v / 100.0));
    }
    readonly property bool pinActive: root._pinActive
    // Mute captured at lock time. VideoBackground forces stream 0 while
    // this is true (muted lock stays silent even if sink is unmuted
    // mid-lock). Exposed readonly so shells can bind it through.
    readonly property bool pinMuted: root._savedMuted
    // Set true by restore(): the unlock fade must be silent no matter what
    // the sink does. Why: restore() fires async `wpctl set-volume <saved>`
    // (e.g. 0.20 -> 0.60) but QML only learns the sink via polling —
    // without this, full stream (1.0) hits the loud sink for ~100-200ms =
    // an explosive blast right before exit. Synchronous flag -> stream 0
    // instantly, polls can't re-raise it. Never reset: process exits ~1.2s
    // after restore anyway.
    property bool streamSilenced: false
    // _wantPin starts true so the first live reading engages even if the
    // initial `pinned` binding never emits a change; _engagePin itself
    // re-checks `pinned`, so a pinSink:false config can never engage.
    property bool _wantPin: true
    // _pinActive means the sink is being held at pinLevel (config value)
    // and the STREAM compensates live sink moves (see VideoBackground) so
    // bg never follows buttons, even in the poll window before the sink is
    // snapped back. _enforcing fights the SINK back to pinLevel. restore()
    // stops the fight, restores pre-lock, but leaves _pinActive true through
    // the 800ms fade so the stream math stays stable (live == restored sink
    // gives a quiet fade, never a blast). The process exits right after.
    property bool _pinActive: false
    property bool _enforcing: false
    property real _savedVolume: 1.0
    property bool _savedMuted: false
    property bool _haveSaved: false

    function _apply(v, muted) {
        const changed = Math.abs(v - root.sinkVolume) > 0.005 || muted !== root.sinkMuted;
        root.sinkVolume = v;
        root.sinkMuted = muted;
        if (!root.available) root.available = true;
        if (changed) console.log("qLock: sink volume", v.toFixed(2), muted ? "[MUTED]" : "");
        // First good reading while pinning is wanted: engage using it.
        // Enforcement is a separate gate so restore() can stop the fight
        // while keeping the stream frozen.
        if (root._wantPin && root.pinned && !root._pinActive) {
            root._engagePin();
        } else if (root._pinActive && root._enforcing) {
            root._enforcePin();
        }
    }

    function _parseWpctl(line) {
        // "Volume: 0.35" or "Volume: 0.35 [MUTED]"
        const m = line.match(/Volume:\s+([0-9]*\.?[0-9]+)/);
        if (!m) return;
        const v = Number(m[1]);
        if (isNaN(v)) return;
        root._apply(Math.max(0, Math.min(1.5, v)), line.includes("[MUTED]"));
    }

    function _engagePin() {
        if (!root.pinned) return;
        // Fresh lock: clear any previous session's terminal state (restore()
        // never resets these — the process normally exits right after).
        root.streamSilenced = false;
        root._restorePhase = 0;
        // Save pre-lock first — this is what restore() hands back.
        root._savedVolume = root.sinkVolume;
        root._savedMuted = root.sinkMuted;
        root._haveSaved = true;
        // Force target: sink becomes the configured volume. Mute preserved:
        // a muted session stays silent (enforced muted, stream 0).
        root.pinLevel = root.targetSink;
        root._pinActive = true;
        root._enforcing = true;
        root._writeSaveFile();
        console.log("qLock: saved sink " + root._savedVolume.toFixed(2) + (root._savedMuted ? " [MUTED]" : "")
            + ", forcing sink to " + root.pinLevel.toFixed(2) + (root._savedMuted ? " [staying MUTED]" : ""));
        root._setSink(root.pinLevel, root._savedMuted);
    }

    function _enforcePin() {
        if (!root._pinActive || !root._enforcing) return;
        if (Math.abs(root.sinkVolume - root.pinLevel) > 0.005 || root.sinkMuted !== root._savedMuted) {
            console.log("qLock: re-pinning sink ->", root.pinLevel.toFixed(2));
            root._setSink(root.pinLevel, root._savedMuted);
        }
    }

    // Idempotent: safe to call on every unlock path. Silences the video
    // stream FIRST (synchronous — see streamSilenced), then restores the
    // pre-lock sink via a MUTE-TRANSIT chain: mute -> set volume -> set
    // saved mute. The transit matters: restoring 0.20 -> 0.75 unmuted would
    // blast not just our (already silenced) video but ANY background audio
    // still playing underneath. Muted throughout the jump, nothing surges.
    // The crash-save file is deleted only after the chain lands, so the
    // supervisor EXIT trap stays armed as backstop mid-transit.
    // On completion _pinActive flips false: enforcement is structurally
    // over even if Qt.quit() stalls and the process lingers — volume keys
    // work again immediately, poll drops back to 1s. streamSilenced stays
    // true so a lingering process stays silent.
    function restore() {
        root.streamSilenced = true;
        root._wantPin = false;
        root._enforcing = false;
        if (!root._pinActive && !root._haveSaved) return;
        // No pin was ever engaged (wpctl missing, pinSink:false, early
        // unlock): just release the flag so polling goes idle.
        if (!root._haveSaved) {
            root._pinActive = false;
            return;
        }
        console.log("qLock: restoring sink", root._savedVolume.toFixed(2), root._savedMuted ? "[MUTED]" : "");
        // Restore supersedes any in-flight enforce: drop queued/en-route
        // enforce intents so the transit chain owns setter/muter now.
        root._haveQueued = false;
        root._havePendingMute = false;
        root._restorePhase = 1;
        root._runRestorePhase();
    }

    // Mute-transit state machine. 1 = pre-mute sent, 2 = volume sent,
    // 3 = final mute sent, 0 = idle/done. Advanced by setter/muter onExited.
    property int _restorePhase: 0
    function _runRestorePhase() {
        if (root._restorePhase === 1) {
            // If an enforce op is still in flight, don't pile on: its exit
            // advances us (pre-mute skipped — rare, only if the user hit a
            // volume key within ~100ms of auth; stream is silenced anyway).
            if (setter.running || muter.running) return;
            muter.command = ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "1"];
            muter.running = true;
        } else if (root._restorePhase === 2) {
            if (setter.running || muter.running) return;
            setter.command = ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", root._savedVolume.toFixed(3)];
            setter.running = true;
        } else if (root._restorePhase === 3) {
            if (setter.running || muter.running) return;
            muter.command = ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", root._savedMuted ? "1" : "0"];
            muter.running = true;
        } else if (root._restorePhase >= 4) {
            root._restorePhase = 0;
            root._haveSaved = false;
            // Fully released: even if the process lingers past unlock,
            // _enforcePin() can never fire again (needs _pinActive) and
            // the poll interval drops back to 1s. Volume keys are free.
            root._pinActive = false;
            const p = root._saveFilePath();
            if (p.length > 0) {
                cleaner.command = ["rm", "-f", p];
                if (!cleaner.running) cleaner.running = true;
            }
        }
    }
    function _advanceRestore() {
        if (root._restorePhase <= 0) return;
        root._restorePhase++;
        root._runRestorePhase();
    }

    function _setSink(vol, muted) {
        // Never drop a request: wpctl is fast (<100ms) but volume-button
        // spam or a slow daemon can overlap a previous set. The old code
        // returned early when setter was busy, silently losing restores.
        // Latest request wins — queue it and dispatch when the chain drains.
        if (setter.running || muter.running) {
            root._queuedVol = vol;
            root._queuedMute = muted;
            root._haveQueued = true;
            return;
        }
        root._dispatchSink(vol, muted);
    }

    function _dispatchSink(vol, muted) {
        // mute intent is recorded only when the volume half is accepted,
        // so a skipped (busy) call can't leave a stale mute behind.
        root._pendingMute = muted;
        root._havePendingMute = true;
        setter.command = ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", vol.toFixed(3)];
        setter.running = true;
    }

    function _drainQueue() {
        if (!root._haveQueued) return;
        if (setter.running || muter.running) return;
        root._haveQueued = false;
        root._dispatchSink(root._queuedVol, root._queuedMute);
    }

    property bool _pendingMute: false
    property bool _havePendingMute: false
    // Latest overwritten request waiting while setter/muter are busy.
    property real _queuedVol: 1.0
    property bool _queuedMute: false
    property bool _haveQueued: false

    readonly property string savePath: root._saveFilePath()

    function _saveFilePath() {
        const rt = Quickshell.env("XDG_RUNTIME_DIR") || "";
        // Strict: runtime dir must be a plain absolute path. Anything with
        // shell metachars, newline or traversal is rejected (no write).
        if (rt.length === 0 || !rt.startsWith("/")) return "";
        if (/[\n'"`$\\|;&()<>!]/.test(rt) || rt.includes("..")) return "";
        return rt + "/qlock-volpin";
    }

    function _writeSaveFile() {
        if (root.savePath.length === 0) return;
        // Numeric-only payload, fixed format "<vol> <0|1>\n". Atomic via
        // FileView so the supervisor never sees a torn write.
        const v = Number(root._savedVolume);
        if (isNaN(v)) return;
        volpinFile.setText(v.toFixed(3) + " " + (root._savedMuted ? "1" : "0") + "\n");
    }

    onPinnedChanged: {
        if (root.pinned) {
            root._wantPin = true;
            if (root.available) root._engagePin();
        } else {
            root.restore();
        }
    }

    // Config arrives async (XHR) — engage may have used the built-in default
    // (20). If the real config differs, retarget mid-lock: update pinLevel
    // and force the sink to the true target immediately.
    onTargetSinkChanged: {
        if (root._pinActive && root._enforcing && root.pinned) {
            if (Math.abs(root.pinLevel - root.targetSink) > 0.005) {
                console.log("qLock: retargeting sink", root.pinLevel.toFixed(2), "->", root.targetSink.toFixed(2));
                root.pinLevel = root.targetSink;
                root._setSink(root.pinLevel, root._savedMuted);
            }
        } else if (!root._pinActive && root._wantPin && root.pinned && root.available) {
            root._engagePin();
        }
    }

    Process {
        id: poller
        command: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]

        stdout: SplitParser {
            onRead: (line) => root._parseWpctl(line)
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0 && !root.available) {
                console.warn("qLock: wpctl unavailable (code", exitCode, ") — loudness lock disabled, volume stays relative to system mixer");
            }
        }
    }

    // One-shot setter for pin/restore. Chains the mute change after the
    // volume change lands so both apply in order, then drains any request
    // that arrived mid-flight (latest wins). While a mute-transit restore
    // is running (_restorePhase > 0) the transit owns both processes.
    Process {
        id: setter
        stdout: SplitParser {
            onRead: (line) => {}
        }
        onExited: {
            if (root._restorePhase > 0) {
                root._advanceRestore();
                return;
            }
            if (root._havePendingMute) {
                root._havePendingMute = false;
                muter.command = ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", root._pendingMute ? "1" : "0"];
                if (!muter.running) muter.running = true;
            } else {
                root._drainQueue();
            }
        }
    }

    Process {
        id: muter
        onExited: {
            if (root._restorePhase > 0) {
                root._advanceRestore();
                return;
            }
            root._drainQueue();
        }
    }

    // Crash-save mirror for the supervisor EXIT trap. Atomic writes only.
    FileView {
        id: volpinFile
        path: root.savePath.length > 0 ? root.savePath : ""
        atomicWrites: true
        watchChanges: false
        printErrors: false
    }

    Process {
        id: cleaner
    }

    Timer {
        id: pollTimer
        // Sense faster while holding the forced level so button fights end
        // quickly. 100ms + instant stream compensation (VideoBackground
        // ratio math) = bg never audibly follows buttons; sink snaps back
        // right after. Unlock fade is separately hard-silenced (streamSilenced)
        // so the async restore can't blast regardless of poll timing.
        interval: root._pinActive ? 100 : root.pollIntervalMs
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: {
            if (!poller.running) poller.running = true;
        }
    }
}
