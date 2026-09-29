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
        if (!pam.start()) {
            pamTimeout.stop();
            root.pendingPassword = "";
            root.authenticating = false;
            root.handleFailure();
            return;
        }
        // NOTE: the password is sent in onResponseRequiredChanged when PAM
        // actually prompts. Responding immediately after start() races the
        // prompt and the reply gets dropped → stuck forever.
    }

    function handleFailure() {
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

    function handleSuccess() {
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
        onTriggered: {
            if (!root.authenticating) return;
            pam.abort();
            root.pendingPassword = "";
            root.authenticating = false;
            root.statusText = "Authentication timed out — try again";
            root.handleFailure();
        }
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
    PamContext {
        id: pam
        config: "login"
        onResponseRequiredChanged: {
            if (pam.responseRequired && root.authenticating) {
                pam.respond(root.pendingPassword);
                root.pendingPassword = "";
            }
        }
        onPamMessage: {
            if (pam.responseRequired && root.authenticating) {
                pam.respond(root.pendingPassword);
                root.pendingPassword = "";
            } else if (pam.messageIsError) {
                root.statusText = pam.message;
            }
        }
        onError: {
            // PAM backend error: onCompleted may never fire, unstick here.
            pamTimeout.stop();
            root.pendingPassword = "";
            if (root.authenticating) {
                root.statusText = "Authentication unavailable — try again";
                root.handleFailure();
            }
        }
        onCompleted: (result) => {
            pamTimeout.stop();
            if (result === PamResult.Success) {
                root.handleSuccess();
            } else {
                root.handleFailure();
            }
        }
    }
}
