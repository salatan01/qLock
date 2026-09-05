pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.folderlistmodel

Item {
    id: root

    required property string videoDirectory
    required property string mode        // "fixed" | "random"
    property string fixedFile: ""        // used when mode == "fixed"

    readonly property alias currentVideoUrl: internal.currentUrl
    readonly property int count: folderModel.count

    // History for non-repeating random order
    property var _shuffleBag: []
    property int _shuffleIndex: 0

    QtObject {
        id: internal
        property string currentUrl: ""
    }

    FolderListModel {
        id: folderModel
        folder: "file://" + root.videoDirectory
        nameFilters: ["*.mp4", "*.mkv", "*.webm"]
        showDirs: false
        sortField: FolderListModel.Name

        onStatusChanged: {
            if (status === FolderListModel.Ready && count > 0) {
                root._pickInitial();
            }
        }
    }

    function _urlAt(i) {
        // Qt docs: role is "fileUrl" (since Qt 5.15, lower-case 'rl'), not "fileURL"
        // — using wrong case returns undefined → "Cannot assign [undefined] to QString"
        return folderModel.get(i, "fileUrl");
    }

    function _pickInitial() {
        if (root.mode === "fixed") {
            internal.currentUrl = root._resolveFixed();
            return;
        }
        root._rebuildShuffleBag();
        internal.currentUrl = root._urlAt(root._shuffleBag[0]);
        root._shuffleIndex = 0;
    }

    function _resolveFixed() {
        if (root.fixedFile.length === 0) {
            return root._urlAt(0);
        }
        for (let i = 0; i < folderModel.count; i++) {
            const name = folderModel.get(i, "fileName");
            if (name === root.fixedFile) {
                return root._urlAt(i);
            }
        }
        console.warn("qLock: fixedFile not found, falling back to first video:", root.fixedFile);
        return root._urlAt(0);
    }

    function _rebuildShuffleBag() {
        let bag = [];
        for (let i = 0; i < folderModel.count; i++) bag.push(i);
        // Fisher-Yates shuffle
        for (let i = bag.length - 1; i > 0; i--) {
            const j = Math.floor(Math.random() * (i + 1));
            [bag[i], bag[j]] = [bag[j], bag[i]];
        }
        root._shuffleBag = bag;
    }

    // Called by VideoBackground on MediaPlayer.EndOfMedia
    function next() {
        if (folderModel.count === 0) return;

        if (root.mode === "fixed") {
            // RepeatOne behavior: just re-signal the same URL so the
            // player restarts it (see VideoBackground's onCurrentVideoUrlChanged guard).
            internal.currentUrl = "";
            internal.currentUrl = root._resolveFixed();
            return;
        }

        // random, non-repeating until the bag is exhausted, then reshuffle
        root._shuffleIndex++;
        if (root._shuffleIndex >= root._shuffleBag.length) {
            root._rebuildShuffleBag();
            root._shuffleIndex = 0;
        }
        internal.currentUrl = root._urlAt(root._shuffleBag[root._shuffleIndex]);
    }
}
