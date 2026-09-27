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
// 2) PIN (only when `pinned`, i.e. the real lock surface): hold the sink
//    at the LOCK-TIME level for the whole session, re-asserting if anything
//    (volume buttons, other agents) moves it. Anchoring — not pinning to
//    1.0 — is load-bearing for safety: "20" must sound like it always did
//    (0.2 x lock-time sink gain). Pinning to full scale redefines 20 as
//    20%-of-full-scale, ~13 dB hotter than a 35%-sink user's norm: a
//    speaker-buster. With anchoring the sink NEVER exceeds the pre-lock
//    level, so blasting is structurally impossible; buttons are neutralized
//    by snapping back within ~0.5s. Mute state at lock time is preserved
//    too (lock muted -> stays silent). On restore, pre-lock volume+mute
//    come back. Crash safety: pre-pin state is also mirrored to
//    $XDG_RUNTIME_DIR/qlock-volpin so the `qlock` wrapper's EXIT trap can
//    restore it even if quickshell dies (no in-process language — QML,
//    Rust, anything — can run code after SIGKILL).
//    The preview (test.qml) never pins: pinned stays false there.
// Requires `wpctl` (wireplumber) + `sh`/`rm` on PATH — the nix wrapper
// provides all three. Without wpctl we keep defaults (sinkVolume 1.0 =
// plain relative volume) and pinning degrades to a warning.
Item {
    id: root

    // Live sink state
    property real sinkVolume: 1.0
    property bool sinkMuted: false
    property bool available: false
    property int pollIntervalMs: 1000

    // Pinning (lock surface only). pinLevel is the ANCHOR: captured from
    // the live sink at engage time, never 1.0 (see header).
    property bool pinned: false
    property real pinLevel: 1.0
    readonly property bool pinActive: root._pinActive
    // _wantPin starts true so the first live reading engages even if the
    // initial `pinned` binding never emits a change; _engagePin itself
    // re-checks `pinned`, so a pinSink:false config can never engage.
    property bool _wantPin: true
    // _pinActive holds the STREAM at target (what VideoBackground reads).
    // _enforcing fights the SINK back to the anchor. restore() stops the
    // fight but leaves the stream frozen: otherwise unlock would drop into
    // cubic math for the 800ms fade (0.2/0.125 -> clamped 1.0 at sink 0.5:
    // a 5x parting blip). The process exits right after anyway.
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
        root._savedVolume = root.sinkVolume;
        root._savedMuted = root.sinkMuted;
        root._haveSaved = true;
        // Anchor: hold exactly what the user had. The sink can only ever
        // be returned here, never raised above it.
        root.pinLevel = root.sinkVolume;
        root._pinActive = true;
        root._enforcing = true;
        root._writeSaveFile();
        console.log("qLock: anchored sink at " + root.pinLevel.toFixed(2) + (root._savedMuted ? " [staying MUTED]" : ""));
        root._enforcePin();
    }

    function _enforcePin() {
        if (!root._pinActive || !root._enforcing) return;
        if (Math.abs(root.sinkVolume - root.pinLevel) > 0.005 || root.sinkMuted !== root._savedMuted) {
            console.log("qLock: re-pinning sink ->", root.pinLevel.toFixed(2));
            root._setSink(root.pinLevel, root._savedMuted);
        }
    }

    // Idempotent: safe to call on every unlock path. Stops enforcement
    // and restores the sink, but leaves the stream frozen at target so the
    // unlock fade has no parting blip (see _enforcing note above).
    function restore() {
        root._wantPin = false;
        root._enforcing = false;
        if (!root._pinActive && !root._haveSaved) return;
        console.log("qLock: restoring sink", root._savedVolume.toFixed(2), root._savedMuted ? "[MUTED]" : "");
        root._setSink(root._savedVolume, root._savedMuted);
        const p = root._saveFilePath();
        if (p.length > 0) {
            cleaner.command = ["rm", "-f", p];
            if (!cleaner.running) cleaner.running = true;
        }
        root._haveSaved = false;
        // NOTE: _pinActive stays true on purpose — the stream stays frozen
        // at target through the unlock fade (no parting blip). The process
        // exits right after anyway.
    }

    function _setSink(vol, muted) {
        if (setter.running) return;
        // mute intent is recorded only when the volume half is accepted,
        // so a skipped (busy) call can't leave a stale mute behind.
        root._pendingMute = muted;
        root._havePendingMute = true;
        setter.command = ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", vol.toFixed(3)];
        setter.running = true;
    }

    property bool _pendingMute: false
    property bool _havePendingMute: false

    function _saveFilePath() {
        const rt = Quickshell.env("XDG_RUNTIME_DIR") || "";
        if (rt.length === 0 || rt.includes("'") || rt.includes("\n")) return "";
        return rt + "/qlock-volpin";
    }

    function _writeSaveFile() {
        const p = root._saveFilePath();
        if (p.length === 0) return;
        saver.command = ["sh", "-c", "printf '%s %s\n' '" + root._savedVolume.toFixed(3) + "' '" + (root._savedMuted ? "1" : "0") + "' > '" + p + "'"];
        if (!saver.running) saver.running = true;
    }

    onPinnedChanged: {
        if (root.pinned) {
            root._wantPin = true;
            if (root.available) root._engagePin();
        } else {
            root.restore();
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
    // volume change lands so both apply in order.
    Process {
        id: setter
        stdout: SplitParser {
            onRead: (line) => {}
        }
        onExited: {
            if (root._havePendingMute) {
                root._havePendingMute = false;
                muter.command = ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", root._pendingMute ? "1" : "0"];
                if (!muter.running) muter.running = true;
            }
        }
    }

    Process {
        id: muter
    }

    Process {
        id: saver
    }

    Process {
        id: cleaner
    }

    Timer {
        id: pollTimer
        // Sense faster while holding the anchor so button fights end quickly.
        interval: root._pinActive ? 500 : root.pollIntervalMs
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: {
            if (!poller.running) poller.running = true;
        }
    }
}
