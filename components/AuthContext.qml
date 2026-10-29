pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.Pam

// AuthContext — SINGLETON auth state shared by every lock surface.
//
// WlSessionLock instantiates its surface component once PER SCREEN, so any
// PAM/throttle state living inside AuthOverlay would be duplicated N times:
// N concurrent PamContexts, N fail counters, focus fights. This object is
// created ONCE in ShellRoot (shell.qml / test.qml) and passed to each
// AuthOverlay via `context:`. Overlays stay dumb views (clock, reveal,
// password field); all PAM + throttle decisions live here.
//
// Lifecycle: submit(password) → PamContext.start() → respond on
// responseRequired → onCompleted → authSucceeded/authFailed. Overlays listen
// to those signals for animations + field clearing.
//
// NOTE: root is an Item, not QtObject — QtObject has no default property,
// so the Timer/PamContext children below would fail with
// "Cannot assign to non-existent default property".
Item {
    id: root

    signal authSucceeded()
    signal authFailed()
    // An in-flight attempt was canceled by the environment (suspend), not
    // by a wrong password. Overlays clear the typed buffer without shake.
    signal authCanceled()

    // Injectable PAM backend: production uses the child PamContext below;
    // tests swap in a fake. Every backend access goes through this object so
    // the attempt state machine stays testable without real PAM prompts.
    property var pamBackend: pam

    property bool authenticating: false
    property bool showError: false

    // Throttle / lockout: wrong password → 2s cooldown; 5 fails → 30s lockout.
    property int failCount: 0
    property bool coolingDown: false
    property bool lockedOut: false
    property int lockoutRemaining: 0
    property string pendingPassword: ""
    property string statusText: ""

    function canAttempt() {
        return !root.authenticating && !root.coolingDown && !root.lockedOut;
    }

    // ---- PAM backend boundary -------------------------------------------------
    // Kept behind functions so a fake backend can be injected by tests and so
    // every call site shares the same null/guards.
    function _pamStart() {
        if (!root.pamBackend) return false;
        return root.pamBackend.start() === true;
    }
    function _pamRespond(password) {
        if (root.pamBackend) root.pamBackend.respond(password);
    }
    function _pamAbort() {
        if (root.pamBackend) root.pamBackend.abort();
    }
    function _pamResponseRequired() {
        return !!(root.pamBackend && root.pamBackend.responseRequired);
    }
    function _pamMessageIsError() {
        return !!(root.pamBackend && root.pamBackend.messageIsError);
    }
    function _pamMessageText() {
        return root.pamBackend ? String(root.pamBackend.message || "") : "";
    }

    // One password, one response. Clearing the buffer BEFORE respond() is
    // deliberate: respond() can synchronously emit another prompt/message,
    // and either handler must then see an empty buffer instead of sending "".
    function _respondPending() {
        if (!root.authenticating) return;
        if (!root._pamResponseRequired()) return;
        if (root.pendingPassword.length === 0) return;
        const password = root.pendingPassword;
        root.pendingPassword = "";
        root._pamRespond(password);
    }

    // Password is passed in by the calling surface so this object never
    // touches UI. Empty passwords are rejected by the overlay already, but
    // guard here too — concurrent surfaces must not start PAM with "".
    function submit(password) {
        if (!password || password.length === 0) return;
        if (!root.canAttempt()) return;
        root.pendingPassword = password;
        root.authenticating = true;
        root.showError = false;
        root.statusText = "";
        // Safety net: if PAM never answers, unstick after 12s.
        pamTimeout.restart();
        if (!root._pamStart()) {
            // The backend may have synchronously reported an error (which
            // already closed the attempt); only count it here if still open.
            if (root.authenticating) root._finishFailure();
            return;
        }
        // A synchronous completion/error may already have closed the attempt.
        if (!root.authenticating) pamTimeout.stop();
    }

    // Terminal transition with NO active-attempt guard: callers that need to
    // close the gate before aborting (timeout) still need to count the
    // failure. All signal/async paths go through handleFailure(), which does
    // guard.
    function _finishFailure() {
        pamTimeout.stop();
        root.authenticating = false;
        root.pendingPassword = "";
        root.failCount += 1;
        root.showError = true;
        errorResetTimer.restart();
        if (root.failCount >= 5) {
            root.lockedOut = true;
            root.lockoutRemaining = 30;
            lockoutTimer.restart();
            lockoutTick.restart();
        } else {
            root.coolingDown = true;
            cooldownTimer.restart();
        }
        root.authFailed();
    }

    function handleFailure() {
        // Late PAM completion/error after timeout/abort/another attempt must
        // not increment the fail counter a second time.
        if (!root.authenticating) return;
        root._finishFailure();
    }

    function _finishSuccess() {
        pamTimeout.stop();
        root.authenticating = false;
        root.pendingPassword = "";
        root.failCount = 0;
        root.coolingDown = false;
        root.lockedOut = false;
        cooldownTimer.stop();
        lockoutTimer.stop();
        lockoutTick.stop();
        root.authSucceeded();
    }

    function handleSuccess() {
        // A late success (after the 12s timeout closed the attempt) must
        // never unlock. Only the currently active attempt may succeed.
        if (!root.authenticating) return;
        root._finishSuccess();
    }

    function _onPamTimeout() {
        if (!root.authenticating) return;
        // Close the gate BEFORE abort(): abort() can synchronously emit
        // completed/error, which would otherwise double-count this failure.
        root.authenticating = false;
        root.pendingPassword = "";
        root._pamAbort();
        root.statusText = "Authentication timed out — try again";
        root._finishFailure();
    }

    // Suspend / teardown while a password is in flight: close the attempt
    // without counting a failure (the password was never judged). Aborting
    // matters: a PAM helper stuck across sleep could otherwise complete
    // later and unlock, and the next attempt would be blocked by the
    // authenticating guard. Quickshell's abort() SIGKILLs the conversation,
    // so no late completion can race this transition.
    function cancelPending(reason) {
        if (!root.authenticating) return;
        // Close the gate BEFORE abort() — abort() can emit synchronously.
        root.authenticating = false;
        root.pendingPassword = "";
        pamTimeout.stop();
        root._pamAbort();
        root.statusText = reason || "Authentication canceled — try again";
        root.authCanceled();
    }

    function _onPamResponseRequired() {
        root._respondPending();
    }

    function _onPamMessage() {
        if (!root.authenticating) return;
        if (root._pamResponseRequired() && root.pendingPassword.length > 0) {
            root._respondPending();
        } else if (root._pamMessageIsError()) {
            const msg = root._pamMessageText();
            if (msg.length > 0) root.statusText = msg;
        }
    }

    function _onPamError() {
        // PAM backend error: onCompleted may never fire, unstick here.
        if (!root.authenticating) return;
        root.statusText = "Authentication unavailable — try again";
        root.handleFailure();
    }

    function _onPamCompleted(result) {
        // Ignore completions from an attempt that timeout/abort already
        // closed. This is the double-failure / late-success guard.
        if (!root.authenticating) return;
        if (result === PamResult.Success) root.handleSuccess();
        else root.handleFailure();
    }

    // Called by overlays when the user types: clears stale error/status so
    // a new attempt starts with a clean hint row on ALL surfaces.
    function clearTransient() {
        if (root.showError) root.showError = false;
        if (root.statusText.length > 0) root.statusText = "";
    }

    Timer {
        id: cooldownTimer
        interval: 2000
        repeat: false
        onTriggered: root.coolingDown = false
    }

    Timer {
        id: lockoutTimer
        interval: 30000
        repeat: false
        onTriggered: {
            root.lockedOut = false;
            root.failCount = 0;
            root.lockoutRemaining = 0;
            lockoutTick.stop();
        }
    }

    Timer {
        id: lockoutTick
        interval: 1000
        repeat: true
        onTriggered: {
            root.lockoutRemaining = Math.max(0, root.lockoutRemaining - 1);
            if (root.lockoutRemaining <= 0) lockoutTick.stop();
        }
    }

    // If PAM goes silent (dropped response, backend hang), abort + fail
    // instead of sitting on "Authenticating…" forever.
    Timer {
        id: pamTimeout
        interval: 12000
        repeat: false
        onTriggered: root._onPamTimeout()
    }

    Timer {
        id: errorResetTimer
        interval: 2000
        repeat: false
        onTriggered: root.showError = false
    }

    // Correct flow: start() → wait for responseRequired → respond(). The old
    // code called respond() immediately after start(), which races the
    // prompt; the reply is dropped, onCompleted never fires, and the UI
    // sticks on "Authenticating…" even for the right password (plus the
    // authenticating guard then blocks all retries).
    //
    // Signals are routed through Connections (not attached handlers) so the
    // same state machine can be driven by an injected test backend.
    PamContext {
        id: pam
        config: "login"
    }

    Connections {
        target: root.pamBackend
        ignoreUnknownSignals: true
        function onResponseRequiredChanged() { root._onPamResponseRequired() }
        function onPamMessage() { root._onPamMessage() }
        function onError() { root._onPamError() }
        function onCompleted(result) { root._onPamCompleted(result) }
    }
}
