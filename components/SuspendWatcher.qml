pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// Watches org.freedesktop.login1.Manager.PrepareForSleep by shelling out to
// dbus-monitor, since Quickshell has no first-party generic DBus signal
// listener exposed to QML. PrepareForSleep is emitted with `true` right
// before suspend and `false` on resume.
Item {
    id: root

    property bool suspended: false

    Process {
        id: monitor
        command: [
            "dbus-monitor",
            "--system",
            "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'"
        ]
        running: true

        stdout: SplitParser {
            onRead: (line) => {
                // dbus-monitor prints the signal header line, then a
                // "   boolean true"/"   boolean false" line right after.
                if (line.includes("boolean true")) {
                    root.suspended = true;
                } else if (line.includes("boolean false")) {
                    root.suspended = false;
                }
            }
        }

        onExited: (exitCode, exitStatus) => {
            console.warn("qLock: dbus-monitor exited (code", exitCode, "), suspend hook inactive. Restarting in 3s.");
            restartTimer.start();
        }
    }

    Timer {
        id: restartTimer
        interval: 3000
        repeat: false
        onTriggered: monitor.running = true
    }
}
