pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io

Item {
    id: root

    required property string videoDirectory
    required property string mode        // "fixed" | "random"
    property string fixedFile: ""        // used when mode == "fixed"
    // Long-memory shuffle: when true (production lock), played filenames
    // persist per-folder in $XDG_STATE_HOME/qlock/history.json so a video
    // played days ago is excluded until every video has played once, then
    // the cycle auto-reshuffles. Preview sets false: isolated, never writes.
    property bool enableHistory: true

    // videoDirectory from config.json may contain a leading "~" (e.g. "~/qSets/qLock/").
    // Qt/QML does NOT expand "~" — "file://~/..." resolves to nothing, so
    // FolderListModel finds 0 files and the lock sits on a black screen.
    // Expand it here centrally so both shell.qml and test.qml benefit.
    readonly property string resolvedDirectory: root._expandPath(root.videoDirectory)

    readonly property alias currentVideoUrl: internal.currentUrl
    readonly property int count: folderModel.count
    // Exposed so shells can distinguish "still scanning" (Loading) from
    // "directory is genuinely empty" (Ready + count 0) and render the right
    // empty-state instead of a bare black screen.
    readonly property int loadStatus: folderModel.status
    readonly property bool loading: folderModel.status === FolderListModel.Loading
    readonly property bool ready: folderModel.status === FolderListModel.Ready

    // In-memory cycle order (indices into folderModel). Persistent played
    // set lives in _playedMap + on disk; corrupt files live in _badMap
    // (session-only, never persisted, never retried after reshuffle).
    property var _shuffleBag: []
    property int _shuffleIndex: 0
    property var _playedMap: ({})
    property var _badMap: ({})
    // Full history file content, preserved across dirs so saving one
    // folder never clobbers another: { version: 1, dirs: { dir: { played: [] } } }.
    property var _historyData: ({ version: 1, dirs: ({}) })
    property bool _folderReady: false
    property bool _historyReady: false
    property bool _initialPicked: false
    property string _lastFileName: ""
    property string _historyDir: ""
    property string _historyPath: ""

    QtObject {
        id: internal
        property string currentUrl: ""
        property string currentFileName: ""
    }

    Component.onCompleted: {
        if (!root.enableHistory) {
            root._historyReady = true;
            root._maybePickInitial();
            return;
        }
        const base = root._stateBase();
        if (base.length === 0) {
            console.warn("qLock: no HOME, history disabled for this session");
            root._historyReady = true;
            root._maybePickInitial();
            return;
        }
        root._historyDir = base + "/qlock";
        root._historyPath = base + "/qlock/history.json";
        // Best-effort dir creation for `quickshell --path` dev runs.
        // The packaged `qlock` launcher already mkdir -p's this dir.
        mkdirProc.command = ["mkdir", "-p", "-m", "0700", root._historyDir];
        if (!mkdirProc.running) mkdirProc.running = true;
        // FileView auto-loads; onLoaded / onLoadFailed flip _historyReady.
        // If path binding somehow never resolves, the 3s backstop below
        // unblocks the first frame with in-memory shuffle (no hang).
        historyBackstop.restart();
    }

    // Deterministic history location shared with `qlock clear-cache`.
    // NOT Quickshell.statePath(): that nests under by-shell/<id>/ which
    // differs between shell.qml and test.qml and is undiscoverable by CLI.
    function _stateBase() {
        const xdg = Quickshell.env("XDG_STATE_HOME") || "";
        if (xdg.length > 0 && !xdg.includes("\n")) return xdg;
        const home = Quickshell.env("HOME") || "";
        if (home.length === 0) return "";
        return home + "/.local/state";
    }

    FileView {
        id: histFile
        // Empty path while disabled / unresolved: no load, no write.
        path: (root.enableHistory && root._historyPath.length > 0) ? root._historyPath : ""
        atomicWrites: true
        watchChanges: false
        printErrors: false
        onLoaded: root._onHistoryLoaded(histFile.text())
        onLoadFailed: (error) => root._onHistoryLoadFailed()
    }

    Process {
        id: mkdirProc
    }

    Timer {
        id: historyBackstop
        interval: 3000
        repeat: false
        onTriggered: {
            if (!root._historyReady && root.enableHistory) {
                console.warn("qLock: history load timeout, continuing with in-memory shuffle");
                root._historyReady = true;
                root._maybePickInitial();
            }
        }
    }

    // Debounced async persist: next() assigns currentUrl synchronously
    // (zero added frame latency), the disk write lands ~400ms later,
    // coalescing rapid error-skips into one atomic rename.
    Timer {
        id: saveTimer
        interval: 400
        repeat: false
        onTriggered: root._flushHistory()
    }

    FolderListModel {
        id: folderModel
        folder: root.resolvedDirectory.length > 0 ? "file://" + root.resolvedDirectory : ""
        nameFilters: ["*.mp4", "*.mkv", "*.webm"]
        showDirs: false
        sortField: FolderListModel.Name

        onStatusChanged: {
            if (status === FolderListModel.Ready) {
                root._folderReady = true;
                if (count === 0) {
                    console.warn("qLock: no videos found in", root.resolvedDirectory, "(raw config value:", JSON.stringify(root.videoDirectory) + ")");
                }
                root._maybePickInitial();
            } else if (status === FolderListModel.Loading) {
                root._folderReady = false;
            }
        }
        onCountChanged: root._onCountChanged()
    }

    onResolvedDirectoryChanged: {
        // Config arrived late (async XHR) or user changed folder:
        // switch played set to the new dir, await rescan.
        root._folderReady = false;
        root._initialPicked = false;
        root._shuffleBag = [];
        root._shuffleIndex = 0;
        internal.currentUrl = "";
        internal.currentFileName = "";
        root._lastFileName = "";
        root._badMap = ({});
        root._loadPlayedForDir(root.resolvedDirectory);
    }

    onModeChanged: {
        root._initialPicked = false;
        root._shuffleBag = [];
        root._shuffleIndex = 0;
        root._badMap = ({});
        root._maybePickInitial();
    }

    function _expandPath(p) {
        if (!p || p.length === 0) return p;
        // Already a file:// URL — strip scheme, expand, caller re-adds it.
        let path = p;
        if (path.startsWith("file://")) path = path.slice("file://".length);
        if (path[0] === "~") {
            const home = Quickshell.env("HOME") || "";
            if (path.length === 1) return home;
            if (path[1] === "/") return home + path.slice(1);
            // "~otheruser/..." — not supported, return as-is and warn.
            console.warn("qLock: unsupported ~user path, using as-is:", JSON.stringify(p));
            return path;
        }
        // $HOME / ${HOME} prefix expansion for convenience.
        if (path.startsWith("$HOME/")) {
            const home = Quickshell.env("HOME") || "";
            return home + path.slice("$HOME".length);
        }
        if (path.startsWith("${HOME}/")) {
            const home = Quickshell.env("HOME") || "";
            return home + path.slice("${HOME}".length);
        }
        return path;
    }

    function _urlAt(i) {
        // Qt docs: role is "fileUrl" (since Qt 5.15, lower-case 'rl'), not "fileURL"
        // — using wrong case returns undefined → "Cannot assign [undefined] to QString"
        if (i < 0 || i >= folderModel.count) return "";
        try {
            const u = folderModel.get(i, "fileUrl");
            return u === undefined ? "" : u;
        } catch (e) {
            return "";
        }
    }

    function _fileNameAt(i) {
        if (i < 0 || i >= folderModel.count) return "";
        try {
            const n = folderModel.get(i, "fileName");
            return (n === undefined || n === null) ? "" : String(n);
        } catch (e) {
            return "";
        }
    }

    function _indexOfFileName(name) {
        if (!name) return -1;
        for (let i = 0; i < folderModel.count; i++) {
            if (root._fileNameAt(i) === name) return i;
        }
        return -1;
    }

    function _allFileNames() {
        const out = [];
        for (let i = 0; i < folderModel.count; i++) {
            const n = root._fileNameAt(i);
            if (n.length > 0) out.push(n);
        }
        return out;
    }

    function _shuffled(arr) {
        // Fisher-Yates, in place. Fast O(N), N is file count (tiny).
        for (let i = arr.length - 1; i > 0; i--) {
            const j = Math.floor(Math.random() * (i + 1));
            const t = arr[i]; arr[i] = arr[j]; arr[j] = t;
        }
        return arr;
    }

    // ---- Persistent history ----

    function _onHistoryLoaded(text) {
        historyBackstop.stop();
        try {
            const parsed = JSON.parse(text);
            if (parsed && typeof parsed === "object") {
                // Accept { dirs: {...} } or legacy flat { played: [] }.
                if (parsed.dirs && typeof parsed.dirs === "object") {
                    root._historyData = { version: 1, dirs: parsed.dirs };
                } else if (Array.isArray(parsed.played)) {
                    const d = {};
                    d[root.resolvedDirectory] = { played: parsed.played };
                    root._historyData = { version: 1, dirs: d };
                }
            }
        } catch (e) {
            console.warn("qLock: history corrupt, starting fresh:", String(e).slice(0, 120));
            root._historyData = { version: 1, dirs: ({}) };
        }
        root._loadPlayedForDir(root.resolvedDirectory);
        root._historyReady = true;
        root._maybePickInitial();
    }

    function _onHistoryLoadFailed() {
        // Empty-path probe before onCompleted assigned the real path:
        // ignore, the real load is still incoming (backstop covers hangs).
        if (root.enableHistory && root._historyPath.length === 0) return;
        historyBackstop.stop();
        // First run: missing file == empty history. Not an error.
        root._historyReady = true;
        root._loadPlayedForDir(root.resolvedDirectory);
        root._maybePickInitial();
    }

    function _loadPlayedForDir(dir) {
        root._playedMap = ({});
        if (!root.enableHistory || !dir) return;
        try {
            const entry = root._historyData.dirs ? root._historyData.dirs[dir] : undefined;
            const arr = entry && Array.isArray(entry.played) ? entry.played : [];
            for (let i = 0; i < arr.length; i++) {
                if (typeof arr[i] === "string" && arr[i].length > 0 && arr[i].length < 256)
                    root._playedMap[arr[i]] = true;
            }
        } catch (e) {
            root._playedMap = ({});
        }
        root._prunePlayed();
    }

    function _prunePlayed() {
        // Drop entries for deleted files so a renamed library can't pin
        // the cycle full forever. O(N).
        if (folderModel.count === 0) return;
        const live = {};
        for (let i = 0; i < folderModel.count; i++) live[root._fileNameAt(i)] = true;
        let pruned = false;
        for (const k in root._playedMap) {
            if (!live[k]) { delete root._playedMap[k]; pruned = true; }
        }
        for (const k in root._badMap) {
            if (!live[k]) { delete root._badMap[k]; }
        }
        if (pruned && root.enableHistory) root._scheduleSave();
    }

    function _recordPlayed(name) {
        if (!root.enableHistory || root.mode === "fixed" || !name) return;
        if (!root._playedMap[name]) {
            root._playedMap[name] = true;
            root._scheduleSave();
        }
        root._lastFileName = name;
    }

    function _scheduleSave() {
        if (!root.enableHistory || root._historyPath.length === 0) return;
        if (!saveTimer.running) saveTimer.restart();
    }

    function _flushHistory() {
        if (!root.enableHistory || root._historyPath.length === 0) return;
        if (!root.resolvedDirectory) return;
        try {
            const played = [];
            for (const k in root._playedMap) played.push(k);
            // Cap: pathological 10k-file libraries stay small (<300KB).
            // Newest-first not tracked; cap drops oldest arbitrarily — still
            // correct (worst case: one early repeat after 5000 plays).
            const capped = played.length > 5000 ? played.slice(played.length - 5000) : played;
            if (!root._historyData.dirs) root._historyData.dirs = {};
            root._historyData.dirs[root.resolvedDirectory] = { played: capped, updated: Date.now() };
            histFile.setText(JSON.stringify({ version: 1, dirs: root._historyData.dirs }));
        } catch (e) {
            console.warn("qLock: history save failed:", String(e).slice(0, 120));
        }
    }

    // Immediate persist (unlock path): cancels the debounce and writes now
    // so Qt.quit() can't outrun a pending save. No-op when disabled.
    function flushHistory() {
        if (!root.enableHistory) return;
        saveTimer.stop();
        root._flushHistory();
    }

    // ---- Cycle construction ----

    function _maybePickInitial() {
        if (root._initialPicked) return;
        if (!root._folderReady || !root._historyReady) return;
        if (folderModel.count === 0) return;
        if (root.mode === "fixed") {
            const idx = root._resolveFixedIndex();
            const url = root._urlAt(idx);
            if (!url) return;
            internal.currentUrl = url;
            internal.currentFileName = root._fileNameAt(idx);
            root._initialPicked = true;
            return;
        }
        root._prunePlayed();
        const bag = root._buildCycleBag("");
        if (bag.length === 0) return;
        root._shuffleBag = bag;
        root._shuffleIndex = 0;
        const url = root._urlAt(bag[0]);
        if (!url) return;
        // Assign URL first (zero added latency), persist after.
        internal.currentUrl = url;
        internal.currentFileName = root._fileNameAt(bag[0]);
        root._initialPicked = true;
        root._recordPlayed(internal.currentFileName);
    }

    // Shuffled indices of unplayed & healthy files. Empty only when
    // everything is played/bad — caller triggers auto-reshuffle.
    function _buildCycleBag(excludeFirst) {
        const all = root._allFileNames();
        const avail = [];
        for (let i = 0; i < all.length; i++) {
            const n = all[i];
            if (!root._playedMap[n] && !root._badMap[n]) avail.push(n);
        }
        if (avail.length === 0) return [];
        root._shuffled(avail);
        // Across auto-reshuffles avoid A,…,A boundary repeat when possible.
        if (excludeFirst && avail.length > 1 && avail[0] === excludeFirst) {
            const t = avail[0]; avail[0] = avail[avail.length - 1]; avail[avail.length - 1] = t;
        }
        const bag = [];
        for (let i = 0; i < avail.length; i++) {
            const idx = root._indexOfFileName(avail[i]);
            if (idx >= 0) bag.push(idx);
        }
        return bag;
    }

    function _startFreshCycle() {
        // Auto-reshuffle: every video played once → new cycle, keep going.
        // Bad (corrupt) files stay excluded for this process lifetime.
        const keepBad = root._badMap;
        root._playedMap = ({});
        root._badMap = keepBad;
        const bag = root._buildCycleBag(root._lastFileName);
        if (bag.length === 0) return [];
        if (root.enableHistory) root._scheduleSave();
        return bag;
    }

    function _resolveFixedIndex() {
        if (!root.fixedFile || root.fixedFile.length === 0) return 0;
        // fixedFile is a bare name, never a path (no traversal).
        const base = root.fixedFile.split("/").pop().split("\\").pop();
        for (let i = 0; i < folderModel.count; i++) {
            if (root._fileNameAt(i) === base) return i;
        }
        console.warn("qLock: fixedFile not found, falling back to first video:", root.fixedFile);
        return 0;
    }

    function _advance(markBad) {
        if (folderModel.count === 0) return false;
        if (root.mode === "fixed") return false;
        if (!root._initialPicked) {
            root._maybePickInitial();
            return root._initialPicked;
        }
        const cur = internal.currentFileName;
        if (markBad && cur) root._badMap[cur] = true;
        // Fast path: consume remaining tail of current cycle.
        let nextIdx = root._shuffleIndex + 1;
        // Skip stale indices (deleted mid-cycle) without rescanning.
        while (nextIdx < root._shuffleBag.length) {
            const cand = root._shuffleBag[nextIdx];
            const nm = root._fileNameAt(cand);
            if (nm && !root._badMap[nm]) break;
            nextIdx++;
        }
        if (nextIdx < root._shuffleBag.length) {
            root._shuffleIndex = nextIdx;
            const url = root._urlAt(root._shuffleBag[nextIdx]);
            if (!url) return root._advance(false);
            internal.currentUrl = url;
            internal.currentFileName = root._fileNameAt(root._shuffleBag[nextIdx]);
            root._recordPlayed(internal.currentFileName);
            return true;
        }
        // Cycle exhausted → fresh cycle (auto-reshuffle). If even a fresh
        // cycle is empty, all files are bad/played: stop, don't spin.
        const fresh = root._startFreshCycle();
        if (fresh.length === 0) {
            console.warn("qLock: no playable videos (all corrupt or empty)");
            return false;
        }
        root._shuffleBag = fresh;
        root._shuffleIndex = 0;
        const url2 = root._urlAt(fresh[0]);
        if (!url2) return false;
        internal.currentUrl = url2;
        internal.currentFileName = root._fileNameAt(fresh[0]);
        root._recordPlayed(internal.currentFileName);
        return true;
    }

    function _onCountChanged() {
        // Library changed mid-session (USB pull, download finish):
        // keep playing current, append genuinely new files to the tail.
        // No full reshuffle → no repeat, no visible hitch.
        if (!root._initialPicked || folderModel.count === 0) return;
        root._prunePlayed();
        if (root.mode !== "random") return;
        const cur = internal.currentFileName;
        if (cur && root._indexOfFileName(cur) < 0) {
            // Current file deleted: jump to next healthy immediately.
            root._advance(false);
            return;
        }
        // Collect tail + known names to find truly new files.
        const known = {};
        for (const k in root._playedMap) known[k] = true;
        for (const k in root._badMap) known[k] = true;
        if (cur) known[cur] = true;
        for (let i = 0; i < root._shuffleBag.length; i++) {
            const n = root._fileNameAt(root._shuffleBag[i]);
            if (n) known[n] = true;
        }
        const fresh = [];
        for (let i = 0; i < folderModel.count; i++) {
            const n = root._fileNameAt(i);
            if (n && !known[n]) fresh.push(i);
        }
        if (fresh.length > 0) {
            root._shuffled(fresh);
            // Insert right after current position: new videos play soon,
            // current tail order untouched (no repeat).
            const before = root._shuffleBag.slice(0, root._shuffleIndex + 1);
            const after = root._shuffleBag.slice(root._shuffleIndex + 1);
            root._shuffleBag = before.concat(fresh, after);
        }
    }

    function _pickInitial() {
        root._maybePickInitial();
    }

    function _rebuildShuffleBag() {
        const bag = root._buildCycleBag("");
        if (bag.length > 0) {
            root._shuffleBag = bag;
            root._shuffleIndex = 0;
        }
    }

    // Called by VideoBackground on MediaPlayer.EndOfMedia (i.e. after
    // effectiveLoops plays — see VideoBackground.playCount). Returns true
    // when the URL changed (random: advanced to the next unplayed video),
    // false when there is nothing to advance to (empty library, or fixed
    // mode where the single video is already looping infinitely in-player).
    //
    // Fixed mode is deliberately a no-op: the old blank-and-restore hack
    // ("" → same URL) never restarted playback — VideoBackground's
    // onSourceChanged guard correctly skips same-URL reloads, so the player
    // just sat at EndOfMedia forever. Fixed + repeat:true uses
    // playCount=0 → Infinite and never reaches here; if it ever does (e.g.
    // repeat:false), the shell restarts in place via VideoBackground.restart()
    // instead of churning the URL.
    function next() {
        return root._advance(false);
    }

    // Corrupt/undecodable file: exclude for this session, jump immediately.
    // Never persisted (a transient codec miss shouldn't ban a file forever);
    // `qlock clear-cache` only clears played history, bad-files reset on boot.
    function skipFailed() {
        return root._advance(true);
    }
}
