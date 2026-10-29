import QtQuick
import Quickshell
import Quickshell.Services.Pam
import "../components"

// Quickshell integration tests. qmltestrunner cannot load Quickshell's
// statically-linked QML plugins, so this file is run with:
//   quickshell --path tests/harness.qml
// It uses injected fake backends and exits non-zero on failure.
ShellRoot {
    id: root

    property int failures: 0
    property var authComp: null
    property var suspendComp: null
    property var overlayComp: null
    property var volComp: null

    function check(ok, message) {
        if (ok) {
            console.log("PASS:", message)
        } else {
            root.failures += 1
            console.error("FAIL:", message)
        }
    }

    Component {
        id: fakePamComponent
        QtObject {
            property bool responseRequired: false
            property bool messageIsError: false
            property string message: ""
            property int startCalls: 0
            property int respondCalls: 0
            property int abortCalls: 0
            property var responses: []
            property bool startResult: true

            signal pamMessage()
            signal errorOccurred()
            signal completed(int result)

            function reset() {
                responseRequired = false
                messageIsError = false
                message = ""
                startCalls = 0
                respondCalls = 0
                abortCalls = 0
                responses = []
                startResult = true
            }
            function start() {
                startCalls += 1
                return startResult
            }
            function respond(password) {
                respondCalls += 1
                responses = responses.concat([password])
            }
            function abort() {
                abortCalls += 1
            }
        }
    }

    function newFake() {
        return fakePamComponent.createObject(root)
    }

    function newAuth(fake) {
        const auth = root.authComp.createObject(root)
        if (!auth || auth.pamBackend === undefined) {
            root.check(false, "AuthContext exposes an injectable pamBackend")
            if (auth) auth.destroy()
            return null
        }
        auth.pamBackend = fake
        return auth
    }

    function findChildByName(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        const kids = item.children || []
        for (let i = 0; i < kids.length; i++) {
            const hit = root.findChildByName(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    function newOverlay(auth) {
        const overlay = root.overlayComp.createObject(root, {
            authContext: auth,
            mouseEnabled: false
        })
        if (!overlay) {
            root.check(false, "AuthOverlay instantiates")
            return null
        }
        const field = root.findChildByName(overlay, "passwordField")
        if (!field) {
            root.check(false, "AuthOverlay exposes its password field")
            overlay.destroy()
            return null
        }
        return { overlay: overlay, field: field }
    }

    function testDoubleResponseGuard() {
        const fake = root.newFake()
        const auth = root.newAuth(fake)
        if (!auth) return
        const counts = { ok: 0, fail: 0 }
        auth.authSucceeded.connect(function() { counts.ok += 1 })
        auth.authFailed.connect(function() { counts.fail += 1 })

        root.check(fake.startCalls === 0, "fake PAM starts idle")
        auth.submit("correct horse")
        root.check(fake.startCalls === 1, "submit starts PAM exactly once")
        root.check(auth.authenticating, "submit marks the attempt active")

        fake.responseRequired = true
        root.check(fake.respondCalls === 1, "first prompt sends exactly one response")
        root.check(fake.responses.length === 1 && fake.responses[0] === "correct horse",
            "response carries the submitted password")
        root.check(auth.pendingPassword === "", "password buffer is cleared after responding")

        // A second prompt/message for the same request must never send "".
        fake.pamMessage()
        root.check(fake.respondCalls === 1, "duplicate prompt does not send an empty response")

        fake.completed(PamResult.Success)
        root.check(counts.ok === 1 && counts.fail === 0, "success completes exactly once")
        root.check(!auth.authenticating, "success clears the active attempt")
        auth.destroy()
        fake.destroy()
    }

    function testTimeoutIgnoresLateSuccess() {
        const fake = root.newFake()
        const auth = root.newAuth(fake)
        if (!auth) return
        const counts = { ok: 0, fail: 0 }
        auth.authSucceeded.connect(function() { counts.ok += 1 })
        auth.authFailed.connect(function() { counts.fail += 1 })

        auth.submit("pw")
        auth._onPamTimeout()
        root.check(fake.abortCalls === 1, "timeout aborts the PAM attempt")
        root.check(!auth.authenticating, "timeout closes the active attempt")
        root.check(auth.failCount === 1, "timeout counts as one failure")
        root.check(auth.statusText.indexOf("timed out") >= 0, "timeout reports a visible reason")

        fake.completed(PamResult.Success)
        root.check(counts.ok === 0, "late success after timeout cannot unlock")
        root.check(counts.fail === 1 && auth.failCount === 1,
            "late completion cannot double-count the timeout failure")
        auth.destroy()
        fake.destroy()
    }

    function testDuplicateCompletionDoesNotDoubleCount() {
        const fake = root.newFake()
        const auth = root.newAuth(fake)
        if (!auth) return
        const counts = { ok: 0, fail: 0 }
        auth.authSucceeded.connect(function() { counts.ok += 1 })
        auth.authFailed.connect(function() { counts.fail += 1 })

        auth.submit("wrong")
        fake.completed(PamResult.Failed)
        root.check(auth.failCount === 1 && counts.fail === 1, "first failure counts once")
        fake.completed(PamResult.Failed)
        fake.completed(PamResult.Success)
        root.check(auth.failCount === 1 && counts.fail === 1,
            "duplicate/late completions are ignored")
        root.check(counts.ok === 0, "late success after failure cannot unlock")
        auth.destroy()
        fake.destroy()
    }

    function testStartFailureCountsOnce() {
        const fake = root.newFake()
        const auth = root.newAuth(fake)
        if (!auth) return
        const counts = { ok: 0, fail: 0 }
        auth.authSucceeded.connect(function() { counts.ok += 1 })
        auth.authFailed.connect(function() { counts.fail += 1 })

        fake.startResult = false
        auth.submit("pw")
        root.check(fake.startCalls === 1, "failed start is attempted once")
        root.check(!auth.authenticating, "failed start closes the attempt")
        root.check(auth.failCount === 1 && counts.fail === 1, "failed start counts one failure")
        auth.destroy()
        fake.destroy()
    }

    function testEmptySubmitIgnored() {
        const fake = root.newFake()
        const auth = root.newAuth(fake)
        if (!auth) return
        auth.submit("")
        root.check(fake.startCalls === 0, "empty password never starts PAM")
        auth.destroy()
        fake.destroy()
    }

    function testOverlayKeepsFailureVisible() {
        const fake = root.newFake()
        const auth = root.newAuth(fake)
        if (!auth) return
        const ui = root.newOverlay(auth)
        if (!ui) {
            auth.destroy()
            fake.destroy()
            return
        }
        ui.field.text = "wrong"
        ui.overlay.submitPassword()
        root.check(fake.startCalls === 1, "overlay submit starts PAM")
        fake.completed(PamResult.Failed)
        root.check(ui.field.text === "", "failure clears the password field")
        root.check(auth.failCount === 1, "overlay failure is counted once")
        root.check(auth.showError, "failure styling survives the programmatic field clear")
        ui.overlay.destroy()
        auth.destroy()
        fake.destroy()
    }

    function testOverlayKeepsTimeoutVisible() {
        const fake = root.newFake()
        const auth = root.newAuth(fake)
        if (!auth) return
        const ui = root.newOverlay(auth)
        if (!ui) {
            auth.destroy()
            fake.destroy()
            return
        }
        ui.field.text = "pw"
        ui.overlay.submitPassword()
        auth._onPamTimeout()
        root.check(ui.field.text === "", "timeout clears the password field")
        root.check(auth.showError, "timeout error styling survives the programmatic field clear")
        root.check(auth.statusText.indexOf("timed out") >= 0,
            "timeout reason survives the programmatic field clear")
        ui.overlay.destroy()
        auth.destroy()
        fake.destroy()
    }

    function testSuspendClockJump() {
        const watcher = root.suspendComp.createObject(root, { monitorEnabled: false })
        if (!watcher) {
            root.check(false, "SuspendWatcher monitor can be disabled for tests")
            return
        }
        if (watcher._onWatchdogTick === undefined) {
            root.check(false, "SuspendWatcher has a resume watchdog hook")
            watcher.destroy()
            return
        }
        root.check(watcher.resumeCount === 0, "resume counter starts at zero")

        // Resume edge lost: still marked suspended, wall clock jumped.
        watcher.suspended = true
        watcher._lastTickWallMs = Date.now() - 60000
        watcher._onWatchdogTick()
        root.check(!watcher.suspended, "wall-clock jump clears a stale suspend pause")
        root.check(watcher.resumeCount === 1, "wall-clock resume increments the counter")

        // Normal tick: no jump, still suspended.
        watcher.suspended = true
        watcher._lastTickWallMs = Date.now() - 1000
        watcher._suspendedSinceWallMs = Date.now()
        watcher._onWatchdogTick()
        root.check(watcher.suspended, "normal watchdog tick keeps the suspend pause")
        root.check(watcher.resumeCount === 1, "normal tick is not a resume")

        // Suspend was announced then aborted: no clock jump, flag goes stale.
        watcher._lastResumeWallMs = 0
        watcher._suspendedSinceWallMs = Date.now() - 31000
        watcher._lastTickWallMs = Date.now() - 1000
        watcher._onWatchdogTick()
        root.check(!watcher.suspended, "a stale suspend flag is cleared")
        root.check(watcher.resumeCount === 2, "stale-flag recovery increments the counter")

        // Suspend `true` edge missed entirely: suspended was never set, but
        // the wall clock still proves the machine slept and video must reload.
        watcher._lastResumeWallMs = 0
        watcher._onWatchdogTick()
        watcher._lastTickWallMs = Date.now() - 60000
        watcher._onWatchdogTick()
        root.check(watcher.resumeCount === 3,
            "a missed suspend edge still produces a resume after the clock jump")

        // logind's resume edge and the watchdog jump are the same wake.
        watcher._markResumed("duplicate logind edge")
        root.check(watcher.resumeCount === 3, "duplicate resume edges are debounced")
        watcher.destroy()
    }

    function testSuspendCancelsPendingAuth() {
        const fake = root.newFake()
        const auth = root.newAuth(fake)
        if (!auth) return
        let canceled = 0
        let succeeded = 0
        auth.authCanceled.connect(function() { canceled += 1 })
        auth.authSucceeded.connect(function() { succeeded += 1 })

        auth.cancelPending()
        root.check(fake.abortCalls === 0, "cancel with no attempt never aborts PAM")

        auth.submit("half-typed secret")
        root.check(auth.authenticating, "attempt is active before suspend")
        auth.cancelPending()
        root.check(fake.abortCalls === 1, "suspend aborts the in-flight PAM attempt")
        root.check(!auth.authenticating, "suspend closes the active attempt")
        root.check(auth.pendingPassword === "", "suspend discards the password buffer")
        root.check(auth.failCount === 0, "suspend is not counted as a password failure")
        root.check(auth.statusText.indexOf("canceled") >= 0, "cancel reason is visible")
        root.check(canceled === 1, "overlays are told to clear the field")

        fake.completed(PamResult.Success)
        root.check(succeeded === 0, "a late PAM completion after cancel cannot unlock")
        auth.destroy()
        fake.destroy()
    }

    function testVolumeDisengageKeepsStreamAudible() {
        const vol = root.volComp.createObject(root, { pollEnabled: false, pinned: true })
        if (!vol) {
            root.check(false, "SystemVolumeWatcher instantiates")
            return
        }
        vol.streamSilenced = true
        vol.pinned = false
        root.check(vol.streamSilenced === false,
            "switching pinSink off while locked must not mute the video")
        root.check(vol._wantPin === false, "disengage stops future pinning")
        vol.destroy()

        const vol2 = root.volComp.createObject(root, { pollEnabled: false })
        if (!vol2) {
            root.check(false, "SystemVolumeWatcher instantiates")
            return
        }
        vol2.restore()
        root.check(vol2.streamSilenced === true,
            "unlock restore still hard-silences the stream")
        vol2.restore(false)
        root.check(vol2.streamSilenced === true,
            "a later config disengage cannot un-silence the unlock fade")
        vol2.destroy()
    }

    Component.onCompleted: {
        const base = Quickshell.env("PWD") || ""
        root.authComp = Qt.createComponent("file://" + base + "/components/AuthContext.qml")
        root.suspendComp = Qt.createComponent("file://" + base + "/components/SuspendWatcher.qml")
        root.overlayComp = Qt.createComponent("file://" + base + "/components/AuthOverlay.qml")
        root.volComp = Qt.createComponent("file://" + base + "/components/SystemVolumeWatcher.qml")
        if (root.authComp.status !== Component.Ready) {
            root.check(false, "AuthContext component loads: " + root.authComp.errorString())
        } else if (root.suspendComp.status !== Component.Ready) {
            root.check(false, "SuspendWatcher component loads: " + root.suspendComp.errorString())
        } else if (root.overlayComp.status !== Component.Ready) {
            root.check(false, "AuthOverlay component loads: " + root.overlayComp.errorString())
        } else if (root.volComp.status !== Component.Ready) {
            root.check(false, "SystemVolumeWatcher component loads: " + root.volComp.errorString())
        } else {
            root.testDoubleResponseGuard()
            root.testTimeoutIgnoresLateSuccess()
            root.testDuplicateCompletionDoesNotDoubleCount()
            root.testStartFailureCountsOnce()
            root.testEmptySubmitIgnored()
            root.testOverlayKeepsFailureVisible()
            root.testOverlayKeepsTimeoutVisible()
            root.testSuspendClockJump()
            root.testSuspendCancelsPendingAuth()
            root.testVolumeDisengageKeepsStreamAudible()
        }
        console.log("qLock tests:", root.failures === 0 ? "ALL PASS" : root.failures + " FAILURE(S)")
        Qt.callLater(Qt.quit)
    }

    PanelWindow {
        anchors { top: true; left: true }
        width: 1
        height: 1
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
    }
}
