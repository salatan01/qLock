pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Services.Pam

Item {
    id: root

    signal authSucceeded()
    signal authFailed()

    anchors.fill: parent
    focus: true

    // ── Clock state ──
    property string timeStr: Qt.formatDateTime(new Date(), "hh:mm")
    property string dateStr: Qt.formatDateTime(new Date(), "dddd, MMMM d")
    property string username: (Quickshell.env("USER") || "user")

    Timer {
        id: clockTimer
        interval: 1000
        running: true
        repeat: true
        onTriggered: {
            root.timeStr = Qt.formatDateTime(new Date(), "hh:mm")
            root.dateStr = Qt.formatDateTime(new Date(), "dddd, MMMM d")
        }
    }

    // ── Reveal state ──
    property bool revealed: false
    property bool hoveringHUD: false
    property bool authenticating: false
    property bool showError: false

    // ── Throttle / lockout state ──
    // Wrong password → 2s cooldown; 5 consecutive fails → 30s lockout.
    property int failCount: 0
    property bool coolingDown: false
    property bool lockedOut: false
    property int lockoutRemaining: 0
    property string pendingPassword: ""
    property string statusText: ""

    Timer {
        id: idleTimer
        interval: 10000
        repeat: false
        onTriggered: {
            if (!root.hoveringHUD && passwordField.text.length === 0 && root.canAttempt())
                root.revealed = false
        }
    }

    onRevealedChanged: {
        if (revealed) {
            idleTimer.stop()
            // Keyboard-revealed (mouse not over HUD): auto-hide after 10s idle.
            // Hover-revealed: hover-away closes it, so no timer needed.
            if (!root.hoveringHUD && passwordField.text.length === 0 && root.canAttempt())
                idleTimer.start()
            focusTimer.restart()
            sheenAnim.restart()
            fieldSheenAnim.restart()
        } else {
            idleTimer.stop()
            // return focus to root so next keypress is caught
            root.forceActiveFocus()
        }
    }

    Timer {
        id: focusTimer
        interval: 80
        onTriggered: passwordField.forceActiveFocus()
    }

    // ── Attempt throttling ──
    function canAttempt() {
        return !root.authenticating && !root.coolingDown && !root.lockedOut
    }

    function submitPassword() {
        if (passwordField.text.length === 0) return
        if (!root.canAttempt()) return
        root.pendingPassword = passwordField.text
        root.authenticating = true
        root.showError = false
        root.statusText = ""
        // Safety net: if PAM never answers, unstick after 12s
        pamTimeout.restart()
        if (!pam.start()) {
            // start() failed synchronously (bad config, no backend, …)
            pamTimeout.stop()
            root.pendingPassword = ""
            root.authenticating = false
            root.handleFailure()
            return
        }
        // NOTE: the password is sent in onMessage when PAM actually
        // prompts (responseRequired). Responding immediately after start()
        // races the prompt and the reply gets dropped → stuck forever.
    }

    function handleFailure() {
        root.authenticating = false
        root.pendingPassword = ""
        root.failCount += 1
        root.showError = true
        errorResetTimer.start()
        shakeAnim.start()
        passwordField.text = ""
        root.revealed = true
        if (root.failCount >= 5) {
            root.lockedOut = true
            root.lockoutRemaining = 30
            lockoutTimer.start()
            lockoutTick.start()
        } else {
            root.coolingDown = true
            cooldownTimer.start()
        }
        passwordField.forceActiveFocus()
        root.authFailed()
    }

    function handleSuccess() {
        pamTimeout.stop()
        root.authenticating = false
        root.pendingPassword = ""
        root.failCount = 0
        root.coolingDown = false
        root.lockedOut = false
        cooldownTimer.stop()
        lockoutTimer.stop()
        lockoutTick.stop()
        successAnim.start()
    }

    Timer {
        id: cooldownTimer
        interval: 2000
        repeat: false
        onTriggered: {
            root.coolingDown = false
            // Mouse long gone and field empty: let idle timer hide the box
            if (root.revealed && !root.hoveringHUD && passwordField.text.length === 0)
                idleTimer.start()
            else
                passwordField.forceActiveFocus()
        }
    }

    Timer {
        id: lockoutTimer
        interval: 30000
        repeat: false
        onTriggered: {
            root.lockedOut = false
            root.failCount = 0
            root.lockoutRemaining = 0
            lockoutTick.stop()
            if (root.revealed && !root.hoveringHUD && passwordField.text.length === 0)
                idleTimer.start()
            else
                passwordField.forceActiveFocus()
        }
    }

    Timer {
        id: lockoutTick
        interval: 1000
        repeat: true
        onTriggered: {
            root.lockoutRemaining = Math.max(0, root.lockoutRemaining - 1)
            if (root.lockoutRemaining <= 0) lockoutTick.stop()
        }
    }

    // If PAM goes silent (dropped response, backend hang), abort + fail
    // instead of sitting on "Authenticating…" forever.
    Timer {
        id: pamTimeout
        interval: 12000
        repeat: false
        onTriggered: {
            if (!root.authenticating) return
            pam.abort()
            root.pendingPassword = ""
            root.authenticating = false
            root.statusText = "Authentication timed out — try again"
            root.handleFailure()
        }
    }

    // ── PAM ──
    // Correct flow: start() → wait for onMessage(responseRequired) →
    // respond(). The old code called respond() immediately after start(),
    // which races the prompt; the reply is dropped, onCompleted never
    // fires, and the UI sticks on "Authenticating…" even for the right
    // password (plus the authenticating guard then blocks all retries).
    PamContext {
        id: pam
        config: "login"
        // This Quickshell version exposes the prompt via properties, not
        // an onMessage handler: when PAM needs the password it sets
        // responseRequired=true and emits pamMessage/responseRequiredChanged.
        onResponseRequiredChanged: {
            if (pam.responseRequired && root.authenticating) {
                pam.respond(root.pendingPassword)
                root.pendingPassword = ""
            }
        }
        onPamMessage: {
            if (pam.responseRequired && root.authenticating) {
                pam.respond(root.pendingPassword)
                root.pendingPassword = ""
            } else if (pam.messageIsError) {
                root.statusText = pam.message
            }
        }
        onError: (error) => {
            // PAM backend error (StartFailed/TryAuthFailed/InternalError):
            // onCompleted may never fire, so unstick here explicitly.
            pamTimeout.stop()
            root.pendingPassword = ""
            if (root.authenticating) {
                root.statusText = "Authentication unavailable — try again"
                root.handleFailure()
            }
        }
        onCompleted: (result) => {
            pamTimeout.stop()
            if (result === PamResult.Success) {
                root.handleSuccess()
            } else {
                root.handleFailure()
            }
        }
    }

    Timer {
        id: errorResetTimer
        interval: 2000
        onTriggered: root.showError = false
    }

    // ── Global keys on root (single handler, no competing catcher) ──
    // Esc: clear typed text first, else close the passbox (when idle).
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Escape) {
            if (!root.revealed || root.authenticating) return
            if (passwordField.text.length > 0) {
                passwordField.text = ""
            } else if (root.canAttempt()) {
                root.revealed = false
            }
            event.accepted = true
            return
        }
        if (!root.revealed) {
            root.revealed = true
            if (event.text.length > 0 && event.text.charCodeAt(0) >= 32) {
                const ch = event.text
                Qt.callLater(() => {
                    passwordField.text = ch
                    passwordField.cursorPosition = passwordField.text.length
                    passwordField.forceActiveFocus()
                })
                event.accepted = true
                return
            }
            focusTimer.restart()
            event.accepted = true
        }
    }

    // ── Fullscreen backdrop — click anywhere reveals ──
    MouseArea {
        id: backdropArea
        anchors.fill: parent
        hoverEnabled: false
        z: 0
        onClicked: {
            if (!root.revealed) {
                root.revealed = true
            } else {
                passwordField.forceActiveFocus()
            }
        }
    }

    // ── Bottom-right HUD ──
    // FIX: container now has explicit height bound to card, so it sits
    // fully on-screen (previously height 0 → card extended off-screen
    // + hover area was 0px so hover could never fire).
    Item {
        id: hudContainer
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: 40
        anchors.bottomMargin: 40
        width: 360
        height: card.height
        z: 5

        // Card — liquid frosted glass. Pure-QtQuick frost illusion:
        // opaque-ish base (legible over video) + top sheen + drifting
        // liquid light blobs (clipped) + hairline highlight + outer glow.
        Rectangle {
            id: card
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: contentCol.implicitHeight + 28
            radius: 18
            // Transparent glass: ~38% opaque base so the video blends
            // through, while text/borders stay fully crisp on top.
            color: "#61101418"
            border.color: root.showError ? "#ff5566" : (passwordField.activeFocus ? "#9adcff" : "#55ffffff")
            border.width: passwordField.activeFocus ? 1.5 : 1
            Behavior on border.color { ColorAnimation { duration: 220; easing.type: Easing.OutQuad } }
            clip: true

            // Rounded-corner mask: clip:true only clips children to a SQUARE
            // bounding box, so full-bleed decor layers (blobs, sheen sweep)
            // leaked translucent pixels into the corner cutouts. Masking the
            // flattened card to a rounded shape removes the visible corners.
            layer.enabled: true
            layer.effect: OpacityMask {
                maskSource: Item {
                    width: card.width
                    height: card.height
                    visible: false
                    Rectangle {
                        anchors.fill: parent
                        radius: card.radius
                    }
                }
            }

            // shake transform for error
            transform: Translate { id: shakeTranslate }

            // ── frosted-glass light layers (all clipped to card) ──
            // top sheen: soft white falloff like light catching glass
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: parent.height * 0.45
                radius: parent.radius
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "#2effffff" }
                    GradientStop { position: 1.0; color: "transparent" }
                }
                opacity: 0.9
            }
            // bottom hairline highlight
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: 14
                anchors.rightMargin: 14
                anchors.bottomMargin: 1
                height: 1
                color: "#1affffff"
            }
            // liquid blobs: slow-drifting soft light, clipped → refraction feel
            Item {
                anchors.fill: parent
                clip: true
                z: 1
                Rectangle {
                    id: blobA
                    width: 220; height: 220; radius: 110
                    color: "#14bfefff"
                    x: -70; y: -90
                    NumberAnimation on x { from: -70; to: 190; duration: 9000; loops: Animation.Infinite; easing.type: Easing.InOutSine }
                    NumberAnimation on y { from: -90; to: -40; duration: 7000; loops: Animation.Infinite; easing.type: Easing.InOutSine }
                }
                Rectangle {
                    id: blobB
                    width: 170; height: 170; radius: 85
                    color: "#10ffffff"
                    x: 220; y: 60
                    NumberAnimation on x { from: 220; to: 40; duration: 11000; loops: Animation.Infinite; easing.type: Easing.InOutSine }
                    NumberAnimation on y { from: 60; to: 10; duration: 8000; loops: Animation.Infinite; easing.type: Easing.InOutSine }
                }
                // sheen sweep on reveal: thin light bar glides once
                Rectangle {
                    id: sheenSweep
                    width: 70; height: parent.height * 2
                    rotation: 18
                    color: "#22ffffff"
                    x: -100
                    y: -parent.height * 0.5
                }
                NumberAnimation {
                    id: sheenAnim
                    target: sheenSweep
                    property: "x"
                    from: -100; to: 420
                    duration: 700
                    easing.type: Easing.OutCubic
                }
            }

            Column {
                id: contentCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 14
                spacing: 10

                // ── Header: time + date ──
                Column {
                    width: parent.width
                    spacing: 2
                    Text {
                        text: root.timeStr
                        color: "white"
                        font.pixelSize: 42
                        font.weight: Font.Light
                        font.letterSpacing: -1.2
                        renderType: Text.NativeRendering
                    }
                    Text {
                        text: root.dateStr
                        color: "#ccffffff"
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                        font.letterSpacing: 0.4
                        opacity: 0.95
                    }
                }

                // ── User pill ──
                Rectangle {
                    width: userRow.implicitWidth + 18
                    height: 26
                    radius: 13
                    color: "#1affffff"
                    border.color: "#22ffffff"
                    Row {
                        id: userRow
                        anchors.centerIn: parent
                        spacing: 6
                        Text {
                            text: "●"
                            color: "#55ff88"
                            font.pixelSize: 10
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: root.username
                            color: "white"
                            font.pixelSize: 12
                            font.weight: Font.Medium
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }

                // ── Password reveal container ──
                Item {
                    id: passwordContainer
                    width: parent.width
                    height: root.revealed ? 56 : 0
                    opacity: root.revealed ? 1 : 0
                    clip: true
                    // FIX: keep visible while revealed (even mid-animation) so
                    // focusTimer can focus the field. Previously
                    // visible: height>0||opacity>0 started false and focus failed.
                    visible: root.revealed

                    Behavior on height {
                        NumberAnimation { duration: 320; easing.type: Easing.OutCubic }
                    }
                    Behavior on opacity {
                        NumberAnimation { duration: 240; easing.type: Easing.OutQuad }
                    }

                    // Pass box — liquid frosted glass: frosted base + top
                    // sheen + drifting liquid highlight + focus glow.
                    Rectangle {
                        id: fieldBg
                        anchors.fill: parent
                        radius: 12
                        // Transparent glass field: video shows through, text stays solid
                        color: root.authenticating ? "#663a6ea8" : (passwordField.activeFocus ? "#40232a44" : "#331e2833")
                        border.color: root.showError ? "#ff6677" : (passwordField.activeFocus ? "#a8e4ff" : "#55ffffff")
                        border.width: passwordField.activeFocus ? 1.6 : 1
                        Behavior on color { ColorAnimation { duration: 200 } }
                        Behavior on border.color { ColorAnimation { duration: 200 } }
                        clip: true

                        // Same square-clip corner leak as the card: mask the
                        // flattened field to its rounded shape.
                        layer.enabled: true
                        layer.effect: OpacityMask {
                            maskSource: Item {
                                width: fieldBg.width
                                height: fieldBg.height
                                visible: false
                                Rectangle {
                                    anchors.fill: parent
                                    radius: fieldBg.radius
                                }
                            }
                        }

                        // frost sheen across top of the field
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            height: parent.height * 0.52
                            radius: parent.radius
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: "#30ffffff" }
                                GradientStop { position: 1.0; color: "transparent" }
                            }
                        }
                        // liquid highlight drifting inside the field
                        Rectangle {
                            id: fieldBlob
                            width: 130; height: 130; radius: 65
                            color: "#16aee6ff"
                            x: -40; y: -70
                            NumberAnimation on x { from: -40; to: 220; duration: 6000; loops: Animation.Infinite; easing.type: Easing.InOutSine }
                        }
                        Rectangle {
                            id: fieldSheen
                            width: 44; height: parent.height * 2.4
                            rotation: 18
                            color: "#2effffff"
                            x: -70
                            y: -parent.height * 0.7
                        }
                        NumberAnimation {
                            id: fieldSheenAnim
                            target: fieldSheen
                            property: "x"
                            from: -70; to: 380
                            duration: 600
                            easing.type: Easing.OutCubic
                        }
                        // focus glow (inner ring: stays inside the mask,
                        // so no overhang gets clipped and no corners leak)
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 3
                            radius: Math.max(1, parent.radius - 3)
                            color: "transparent"
                            border.color: "#7fd4ff"
                            border.width: 1.5
                            opacity: passwordField.activeFocus && !root.showError ? 0.55 : 0
                            Behavior on opacity { NumberAnimation { duration: 250 } }
                        }

                        Text {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 12
                            text: root.authenticating ? "◐" : "🔒"
                            color: root.authenticating ? "#8ad6ff" : "#b0ffffff"
                            font.pixelSize: 14
                            RotationAnimation on rotation {
                                running: root.authenticating
                                loops: Animation.Infinite
                                from: 0; to: 360; duration: 800
                            }
                        }

                        TextField {
                            id: passwordField
                            anchors.fill: parent
                            anchors.leftMargin: 36
                            anchors.rightMargin: 44
                            anchors.topMargin: 6
                            anchors.bottomMargin: 6
                            echoMode: TextInput.Password
                            placeholderText: root.lockedOut ? ("Locked — try again in " + root.lockoutRemaining + "s") : (root.coolingDown ? "Wait…" : (root.authenticating ? "Authenticating…" : "Enter password"))
                            placeholderTextColor: "#aaffffff"
                            color: "white"
                            font.pixelSize: 15
                            font.weight: Font.Medium
                            verticalAlignment: TextInput.AlignVCenter
                            background: Item {}
                            readOnly: root.authenticating || root.coolingDown || root.lockedOut
                            Keys.onEscapePressed: {
                                if (root.authenticating) return
                                if (text.length > 0) {
                                    text = ""
                                } else if (root.canAttempt()) {
                                    root.revealed = false
                                    root.forceActiveFocus()
                                }
                            }
                            onAccepted: root.submitPassword()
                            onTextChanged: {
                                if (text.length > 0) idleTimer.stop()
                                else if (root.revealed && !root.hoveringHUD && root.canAttempt()) idleTimer.start()
                                if (root.showError) root.showError = false
                                if (root.statusText.length > 0) root.statusText = ""
                            }
                            onActiveFocusChanged: if (activeFocus) idleTimer.stop()
                        }

                        Rectangle {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.rightMargin: 8
                            width: 28; height: 28; radius: 14
                            color: passwordField.text.length > 0 ? "#66ccff" : "#22ffffff"
                            border.color: "#44ffffff"
                            opacity: root.canAttempt() ? 1 : 0.4
                            Behavior on color { ColorAnimation { duration: 180 } }
                            Text {
                                anchors.centerIn: parent
                                text: root.authenticating ? "…" : "→"
                                color: passwordField.text.length > 0 ? "black" : "#88ffffff"
                                font.pixelSize: 14
                                font.weight: Font.Bold
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.submitPassword()
                            }
                        }
                    }
                }

                // Hint row — only when revealed
                Item {
                    width: parent.width
                    height: root.revealed ? 14 : 0
                    opacity: root.revealed ? 1 : 0
                    clip: true
                    visible: root.revealed
                    Behavior on height { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                    Behavior on opacity { NumberAnimation { duration: 200 } }
                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.lockedOut ? ("Too many attempts — wait " + root.lockoutRemaining + "s") : (root.coolingDown ? "Wrong password — wait…" : (root.authenticating ? "Verifying…" : (root.statusText.length > 0 ? root.statusText : "Press Enter to unlock • Esc to hide")))
                        color: root.lockedOut || root.coolingDown ? "#ffaaaa" : "#aaffffff"
                        font.pixelSize: 10
                    }
                }
            }

            SequentialAnimation {
                id: shakeAnim
                NumberAnimation { target: shakeTranslate; property: "x"; to: -10; duration: 55; easing.type: Easing.InOutQuad }
                NumberAnimation { target: shakeTranslate; property: "x"; to: 10; duration: 55; easing.type: Easing.InOutQuad }
                NumberAnimation { target: shakeTranslate; property: "x"; to: -8; duration: 55; easing.type: Easing.InOutQuad }
                NumberAnimation { target: shakeTranslate; property: "x"; to: 8; duration: 55; easing.type: Easing.InOutQuad }
                NumberAnimation { target: shakeTranslate; property: "x"; to: -4; duration: 50; easing.type: Easing.InOutQuad }
                NumberAnimation { target: shakeTranslate; property: "x"; to: 0; duration: 50; easing.type: Easing.InOutQuad }
            }
            SequentialAnimation {
                id: successAnim
                ParallelAnimation {
                    NumberAnimation { target: card; property: "scale"; to: 0.98; duration: 100; easing.type: Easing.OutQuad }
                }
                ParallelAnimation {
                    NumberAnimation { target: root; property: "opacity"; to: 0; duration: 220; easing.type: Easing.InOutQuad }
                    NumberAnimation { target: card; property: "scale"; to: 1.04; duration: 220; easing.type: Easing.OutCubic }
                }
                ScriptAction { script: root.authSucceeded() }
            }
        }

        // Outer glow halo: sibling of card (not child) so the card's
        // rounded-corner mask can't clip its overhanging ring.
        // Border-only rounded rect renders its own corners cleanly.
        Rectangle {
            id: glowHalo
            anchors.fill: card
            anchors.margins: -6
            radius: card.radius + 6
            color: "transparent"
            border.color: "#66ccff"
            border.width: 2
            opacity: root.revealed && !root.showError ? 0.30 : 0
            Behavior on opacity { NumberAnimation { duration: 350; easing.type: Easing.OutQuad } }
            z: -1
        }

        // Hover layer ABOVE card: NoButton so clicks pass through,
        // hover still fires even over TextField/buttons.
        MouseArea {
            id: hudHover
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            z: 100
            onEntered: {
                root.hoveringHUD = true
                idleTimer.stop()
                if (!root.revealed) root.revealed = true
            }
            onExited: {
                root.hoveringHUD = false
                // Hover away closes the passbox immediately (same open/close
                // animation — the height/opacity Behaviors reverse automatically).
                // Guarded: never close while typing, verifying, or in cooldown/lockout
                // so the countdown stays visible.
                if (root.revealed && passwordField.text.length === 0 && root.canAttempt())
                    root.revealed = false
            }
        }

        // entrance
        NumberAnimation on opacity { from: 0; to: 1; duration: 520; easing.type: Easing.OutQuad; running: true }
    }

    Component.onCompleted: {
        root.revealed = false
        root.forceActiveFocus()
    }
}
