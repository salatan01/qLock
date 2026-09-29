pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// ConfigLoader — one place for layered config + playback normalization.
//
// Resolution order (first hit wins, merged over built-ins so partial JSON
// works): $QLOCK_CONFIG > $XDG_CONFIG_HOME/qlock (else ~/.config/qlock) >
// /etc/qlock (NixOS module) > bundled ./config/config.json.
//
// Extracted from shell.qml/test.qml which duplicated ~50 lines. Instantiate
// once per entry point: `ConfigLoader { id: cfg }`, then bind
// `playlist.videoDirectory: cfg.config.videoDirectory` etc.
//
// Playback semantics (see effectivePlayCount):
//   repeat:false            → 1 (play once, advance; playback ignored)
//   repeat:true + playback N → N plays then advance (2 = "2playback")
//   repeat:true, no playback → 0 = loop current video forever (legacy)
//
// NOTE: root is an Item, not QtObject — uniform with every other component
// here, and safe as a direct child of ShellRoot in any Quickshell version.
Item {
    id: root

    property var config: ({
        videoDirectory: (Quickshell.env("HOME") || "") + "/qSets/qLock/",
        mode: "random",
        fixedFile: "",
        repeat: true,
        playback: 0,
        volume: 20,
        pinSink: true,
        showTitle: true
    })

    // Set QLOCK_DEBUG=1 to get per-change volume/sink logs.
    readonly property bool debug: (Quickshell.env("QLOCK_DEBUG") || "").length > 0

    signal configLoaded(var loadedFrom)

    Component.onCompleted: root._loadConfig()

    // Normalized repeat count for VideoBackground.playCount:
    //   0 = infinite (legacy repeat:true without playback)
    //   N = play exactly N times per video, then `ended` fires.
    // Aliases accepted so user configs using any obvious name keep working.
    function effectivePlayCount() {
        var c = root.config || {};
        if (c.repeat === false) {
            if (Number(c.playback || c.playbackCount || c.repeatCount || c.playCount || 0) > 1
                && root.debug) {
                console.log("qLock: repeat=false forces single playback; ignoring playback=",
                    JSON.stringify(c.playback));
            }
            return 1;
        }
        var raw = c.playback;
        if (raw === undefined) raw = c.playbackCount;
        if (raw === undefined) raw = c.repeatCount;
        if (raw === undefined) raw = c.playCount;
        if (raw === undefined || raw === null || raw === "") return 0;
        var n = Number(raw);
        if (isNaN(n)) {
            console.warn("qLock: ignoring invalid playback", JSON.stringify(raw), "- using infinite loop");
            return 0;
        }
        // 0 = infinite by design (legacy default) — never warn for it.
        if (n === 0) return 0;
        if (n < 0) {
            console.warn("qLock: ignoring negative playback", JSON.stringify(raw), "- using infinite loop");
            return 0;
        }
        n = Math.floor(n);
        if (n > 100) {
            console.warn("qLock: playback", n, "clamped to 100");
            n = 100;
        }
        return n;
    }

    function _configCandidates() {
        // Priority: $QLOCK_CONFIG > $XDG_CONFIG_HOME/qlock > ~/.config/qlock
        //   > /etc/qlock (NixOS module) > bundled ./config/config.json
        const candidates = [];
        const override = Quickshell.env("QLOCK_CONFIG") || "";
        if (override.length > 0) {
            candidates.push(override.startsWith("file://") ? override : "file://" + override);
        }
        const xdg = Quickshell.env("XDG_CONFIG_HOME") || "";
        const home = Quickshell.env("HOME") || "";
        if (xdg.length > 0) {
            candidates.push("file://" + xdg + "/qlock/config.json");
        } else if (home.length > 0) {
            candidates.push("file://" + home + "/.config/qlock/config.json");
        }
        candidates.push("file:///etc/qlock/config.json");
        candidates.push(Qt.resolvedUrl("../config/config.json"));
        return candidates;
    }

    function _loadConfig() {
        root._tryConfigUrl(root._configCandidates(), 0);
    }

    function _tryConfigUrl(urls, i) {
        if (i >= urls.length) {
            console.warn("qLock: no config.json found, using built-in defaults:", JSON.stringify(root.config));
            return;
        }
        const xhr = new XMLHttpRequest();
        xhr.open("GET", urls[i]);
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            if (xhr.status === 200) {
                try {
                    const parsed = JSON.parse(xhr.responseText);
                    // Merge over built-in defaults so partial configs work.
                    root.config = Object.assign({}, root.config, parsed);
                    console.log("qLock: config loaded from", urls[i], JSON.stringify(root.config));
                    root.configLoaded(urls[i]);
                } catch (e) {
                    console.warn("qLock: failed to parse", urls[i], e, "- trying next");
                    root._tryConfigUrl(urls, i + 1);
                }
            } else {
                if (i === urls.length - 1) {
                    console.warn("qLock: bundled config unreachable — check QML_XHR_ALLOW_FILE_READ=1; using defaults", JSON.stringify(root.config));
                }
                root._tryConfigUrl(urls, i + 1);
            }
        };
        xhr.send();
    }
}
