pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// Watches org.freedesktop.login1.Manager.PrepareForSleep by shelling out to
// dbus-monitor, since Quickshell has no first-party generic DBus signal
// listener exposed to QML. PrepareForSleep is emitted with `true` right
// before suspend and `false` on resume.
//
// Resume detection is belt-and-braces, because a missed edge used to freeze
// the lockscreen video until the next playlist change:
//   1. logind PrepareForSleep(false) via dbus-monitor (the normal path).
//   2. An always-on wall-clock watchdog. Qt timers do not run while the
//      machine sleeps, so a tick whose wall-clock gap is much larger than
//      the interval proves the machine slept — even when suspended was never
//      set (the `true` edge was missed) or the `false` edge was lost.
//   3. A stale-flag fallback: if `suspended` stays true for 30s of continuous
//      running, no real sleep happened (a real one would have produced the
//      clock jump above), so the flag is cleared.
// Every inferred resume increments resumeCount; VideoBackground rebuilds its
// pipeline on each increment, and AuthOverlay re-grabs keyboard focus.
Item {
    id: root

    property bool suspended: false
    property int resumeCount: 0
    // Tests set this false so merely loading the component does not spawn a
    // real dbus-monitor. Production keeps the default (true).
    property bool monitorEnabled: true

    // Wall-clock gap that cannot be event-loop jitter: the process was not
    // running, i.e. the machine slept. Checked on every 1s tick, whether or
    // not `suspended` is set (missed-edge coverage).
    readonly property int resumeJumpThresholdMs: 3000
    // A real sleep produces a clock jump. If we stay marked suspended this
    // long while running normally, the flag is stale (e.g. a suspend was
    // announced and then aborted).
    readonly property int staleSuspendMs: 30000
    // logind's resume edge and the watchdog jump describe the same wake;
    // don't count/reload twice.
    readonly property int resumeDebounceMs: 2000

    property real _lastTickWallMs: Date.now()
    property real _suspendedSinceWallMs: 0
    property real _lastResumeWallMs: 0

    function _isDuplicateResume(now) {
        return root._lastResumeWallMs > 0
            && now - root._lastResumeWallMs < root.resumeDebounceMs
    }

    // Single entry point for every resume path. Always clears `suspended`
    // (so a late/duplicate edge is harmless) but increments resumeCount only
    // once per wake.
    function _markResumed(reason) {
        const now = Date.now()
        const duplicate = root._isDuplicateResume(now)
        root.suspended = false
        if (duplicate) return
        root._lastResumeWallMs = now
        root.resumeCount += 1
        console.log("qLock: resumed (" + reason + ")")
    }

    function _onWatchdogTick() {
        const now = Date.now()
        const elapsed = now - root._lastTickWallMs
        root._lastTickWallMs = now

        if (elapsed >= root.resumeJumpThresholdMs) {
            // Either suspended was still set and the resume edge was lost,
            // or the suspend edge itself was missed. Both need a rebuild.
            console.warn("qLock: wall clock jumped", Math.round(elapsed), "ms — assuming resume");
            root._markResumed("wall-clock jump");
            return
        }
        if (root.suspended
                && root._suspendedSinceWallMs > 0
                && now - root._suspendedSinceWallMs >= root.staleSuspendMs) {
            console.warn("qLock: suspend flag stale for",
                Math.round((now - root._suspendedSinceWallMs) / 1000) + "s — clearing");
            root._markResumed("stale suspend flag");
        }
    }

    onSuspendedChanged: {
        root._lastTickWallMs = Date.now()
        if (root.suspended) {
            root._suspendedSinceWallMs = Date.now()
        } else {
            root._suspendedSinceWallMs = 0
        }
    }

    onMonitorEnabledChanged: {
        restartTimer.stop()
        monitor.running = root.monitorEnabled
    }

    Component.onCompleted: {
        root._lastTickWallMs = Date.now()
        if (root.monitorEnabled) monitor.running = true
    }

    // Always on: a missed suspend edge means a suspended-gated timer would
    // never run at all.
    Timer {
        id: watchdog
        interval: 1000
        repeat: true
        running: true
        onTriggered: root._onWatchdogTick()
    }

    Process {
        id: monitor
        command: [
            "dbus-monitor",
            "--system",
            "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'"
        ]
        running: false

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: (line) => {
                // dbus-monitor prints the signal header line, then a
                // "   boolean true"/"   boolean false" line right after.
                if (line.includes("boolean true")) {
                    root.suspended = true;
                } else if (line.includes("boolean false")) {
                    root._markResumed("logind PrepareForSleep(false)");
                }
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (!root.monitorEnabled) return;
            console.warn("qLock: dbus-monitor exited (code", exitCode, "), suspend hook inactive. Restarting in 3s.");
            restartTimer.start();
        }
    }

    Timer {
        id: restartTimer
        interval: 3000
        repeat: false
        onTriggered: {
            if (root.monitorEnabled) monitor.running = true;
        }
    }
}
