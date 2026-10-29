pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Qt5Compat.GraphicalEffects
import Quickshell

// AuthOverlay — per-SCREEN view. The surface component is instantiated once
// per monitor by WlSessionLock, so everything in here is per-surface UI:
// clock, reveal/hover state, password field, animations.
//
// Shared auth (PAM + throttle + lockout) lives in AuthContext, created ONCE
// in ShellRoot and passed in as `authContext:`. Concurrent surfaces submit
// to the same context, so there is exactly one PamContext, one fail counter,
// one cooldown — no competing logins from multi-monitor setups.
//
// Mouse-free operation: set `mouseEnabled: false` (the production lock does)
// and ALL mouse paths (backdrop click, hover reveal, arrow click) go dead —
// reveal is keyboard-only (any key), submit is Enter, Esc hides. Pair with a
// topmost BlankCursor MouseArea (see shell.qml) so the cursor is invisible
// too. Preview keeps mouseEnabled:true.
Item {
    id: root

    required property AuthContext authContext
    property bool mouseEnabled: true
    // Incremented by SuspendWatcher on resume (including a resume inferred
    // from a missed logind edge). Keyboard focus can be lost across sleep;
    // the lock must accept input immediately when the screen comes back.
    property int resumeCount: 0

    anchors.fill: parent
    focus: true

    // ── Clock state ──
    // 24h HH:mm: unambiguous on a lockscreen (no AM/PM glyph to miss).
    property string timeStr: Qt.formatDateTime(new Date(), "HH:mm")
    property string dateStr: Qt.formatDateTime(new Date(), "dddd, MMMM d")
    property string username: (Quickshell.env("USER") || "user")

    Timer {
        id: clockTimer
        interval: 1000
        running: true
        repeat: true
        onTriggered: {
            root.timeStr = Qt.formatDateTime(new Date(), "HH:mm")
            root.dateStr = Qt.formatDateTime(new Date(), "dddd, MMMM d")
        }
    }

    // ── Per-surface reveal state ──
    property bool revealed: false
    property bool hoveringHUD: false
    // CapsLock heuristic (QML has no CapsLock API): set when an uppercase
    // letter arrives without Shift held, cleared on any lowercase letter.
    // Best-effort hint only — never blocks input.
    property bool capsHint: false

    function _capsHeuristic(event) {
        if (!event || event.text.length !== 1) return
        const ch = event.text
        if (!/[A-Za-z]/.test(ch)) return
        const shift = (event.modifiers & Qt.ShiftModifier) !== 0
        if (/[A-Z]/.test(ch) && !shift) root.capsHint = true
        else if (/[a-z]/.test(ch)) root.capsHint = false
    }

    function _hintText() {
        const ctx = root.authContext
        let s
        if (ctx.lockedOut) s = "Too many attempts — wait " + ctx.lockoutRemaining + "s"
        else if (ctx.coolingDown) s = "Wrong password — wait…"
        else if (ctx.authenticating) s = "Verifying…"
        else if (ctx.statusText.length > 0) s = ctx.statusText
        else s = "Type password, Enter to unlock • Esc to hide"
        if (root.capsHint && ctx.canAttempt() && !ctx.authenticating) s += " • Caps Lock?"
        return s
    }

    function _hintColor() {
        const ctx = root.authContext
        if (ctx.lockedOut || ctx.coolingDown) return "#ffaaaa"
        if (root.capsHint && ctx.canAttempt()) return "#ffd98a"
        return "#aaffffff"
    }

    Timer {
        id: idleTimer
        interval: 10000
        repeat: false
        onTriggered: {
            if (!root.hoveringHUD && passwordField.text.length === 0 && root.authContext.canAttempt())
                root.revealed = false
        }
    }

    onRevealedChanged: {
        if (revealed) {
            idleTimer.stop()
            // Keyboard-revealed (mouse not over HUD): auto-hide after 10s idle.
            // Hover-revealed: hover-away closes it, so no timer needed.
            if (!root.hoveringHUD && passwordField.text.length === 0 && root.authContext.canAttempt())
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

    // Focus guard: lost keyboard focus = dead input (the #1 "password box
    // not taking inputs" cause — e.g. clicking another window while
    // previewing). Re-grab ONLY when nothing at all has focus, so it never
    // steals from the password field mid-typing. Always on: preview needs it
    // most (no mouse-free guarantee there), lock keeps it as backstop.
    //
    // NOTE: the check lives in root._refocusIfLost(), NOT inline in the
    // Timer: Window.* attached properties don't exist on Timer scope
    // ("Window.window only supports types derived from Item") and silently
    // evaluate to undefined, which would brick the guard. Item scope only.
    function _refocusIfLost() {
        if (Window.activeFocusItem === null) root.forceActiveFocus()
    }

    Timer {
        id: focusGuard
        interval: 2000
        repeat: true
        running: true
        onTriggered: root._refocusIfLost()
    }

    // ── Shared-auth plumbing ──
    function submitPassword() {
        if (passwordField.text.length === 0) return
        root.authContext.submit(passwordField.text)
        // Field is cleared on failure via the authFailed handler below (so
        // the user sees the shake first). On success the fade covers it.
        // Focus stays so retries are instant.
        passwordField.forceActiveFocus()
    }

    Connections {
        target: root.authContext
        function onAuthFailed() {
            passwordField.text = ""
            root.revealed = true
            shakeAnim.start()
            passwordField.forceActiveFocus()
        }
        function onAuthSucceeded() {
            successAnim.start()
        }
        function onAuthCanceled() {
            // Suspend canceled the attempt: never keep a half-typed secret
            // (or resubmit it after resume). No shake — nothing was wrong.
            passwordField.text = ""
            if (root.revealed) passwordField.forceActiveFocus()
            else root.forceActiveFocus()
        }
    }

    onResumeCountChanged: {
        // Do not rely on the compositor restoring keyboard focus across a
        // suspend. Re-grab it so the first keypress after wake is not lost.
        root.forceActiveFocus()
        if (root.revealed) focusTimer.restart()
    }

    // ── Global keys on root (single handler, no competing catcher) ──
    // Enter-only reveal: the box opens on Enter/Return, closes on Esc.
    // Stray keys while hidden are deliberately IGNORED (never accepted, never
    // injected) — the old any-key injection raced focusTimer via Qt.callLater
    // and could swallow the first character; this path has no race at all.
    // Esc: clear typed text first, else close the passbox (when idle).
    Keys.onPressed: (event) => {
        root._capsHeuristic(event)
        if (event.key === Qt.Key_Escape) {
            if (!root.revealed || root.authContext.authenticating) return
            if (passwordField.text.length > 0) {
                passwordField.text = ""
            } else if (root.authContext.canAttempt()) {
                root.revealed = false
            }
            event.accepted = true
            return
        }
        if (event.key === Qt.Key_Enter || event.key === Qt.Key_Return) {
            if (!root.revealed) {
                // Reveal even mid-cooldown/lockout: the countdown stays
                // visible instead of keys appearing dead.
                root.revealed = true
                event.accepted = true
                return
            }
            // Revealed but focus drifted off the field (shouldn't happen —
            // focusGuard covers it — belt and braces): pull it back so Enter
            // submits instead of vanishing. Field's onAccepted submits.
            if (!passwordField.activeFocus && root.authContext.canAttempt()) {
                passwordField.forceActiveFocus()
                event.accepted = true
            }
            return
        }
    }

    // ── Fullscreen backdrop — click anywhere reveals (mouse builds only) ──
    MouseArea {
        id: backdropArea
        anchors.fill: parent
        hoverEnabled: false
        enabled: root.mouseEnabled
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
            border.color: root.authContext.showError ? "#ff5566" : (passwordField.activeFocus ? "#9adcff" : "#55ffffff")
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
            // liquid blobs: slow-drifting soft light, clipped → refraction feel.
            // `running: revealed` freezes them while the HUD is hidden — an
            // infinite animation on a lockscreen is a constant GPU/CPU wake
            // for zero visible benefit.
            Item {
                anchors.fill: parent
                clip: true
                z: 1
                Rectangle {
                    id: blobA
                    width: 220; height: 220; radius: 110
                    color: "#14bfefff"
                    x: -70; y: -90
                    NumberAnimation on x { running: root.revealed; from: -70; to: 190; duration: 9000; loops: Animation.Infinite; easing.type: Easing.InOutSine }
                    NumberAnimation on y { running: root.revealed; from: -90; to: -40; duration: 7000; loops: Animation.Infinite; easing.type: Easing.InOutSine }
                }
                Rectangle {
                    id: blobB
                    width: 170; height: 170; radius: 85
                    color: "#10ffffff"
                    x: 220; y: 60
                    NumberAnimation on x { running: root.revealed; from: 220; to: 40; duration: 11000; loops: Animation.Infinite; easing.type: Easing.InOutSine }
                    NumberAnimation on y { running: root.revealed; from: 60; to: 10; duration: 8000; loops: Animation.Infinite; easing.type: Easing.InOutSine }
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

                // ── Idle affordance — the ONLY keyboard hint while hidden ──
                // (Enter-only reveal means users must know to press Enter.)
                Item {
                    width: parent.width
                    height: !root.revealed ? 14 : 0
                    opacity: !root.revealed ? 1 : 0
                    clip: true
                    visible: !root.revealed
                    Behavior on height { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                    Behavior on opacity { NumberAnimation { duration: 200 } }
                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Press Enter to unlock"
                        color: "#aaffffff"
                        font.pixelSize: 10
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
                        color: root.authContext.authenticating ? "#663a6ea8" : (passwordField.activeFocus ? "#40232a44" : "#331e2833")
                        border.color: root.authContext.showError ? "#ff6677" : (passwordField.activeFocus ? "#a8e4ff" : "#55ffffff")
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
                            NumberAnimation on x { running: root.revealed; from: -40; to: 220; duration: 6000; loops: Animation.Infinite; easing.type: Easing.InOutSine }
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
                            opacity: passwordField.activeFocus && !root.authContext.showError ? 0.55 : 0
                            Behavior on opacity { NumberAnimation { duration: 250 } }
                        }

                        Text {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 12
                            // Geometric glyphs only: emoji (🔒) renders as
                            // tofu on minimal NixOS closures without an emoji
                            // font. ◈/◐ are in DejaVu by default.
                            text: root.authContext.authenticating ? "◐" : "◈"
                            color: root.authContext.authenticating ? "#8ad6ff" : "#b0ffffff"
                            font.pixelSize: 14
                            RotationAnimation on rotation {
                                running: root.authContext.authenticating
                                loops: Animation.Infinite
                                from: 0; to: 360; duration: 800
                            }
                        }

                        TextField {
                            id: passwordField
                            objectName: "passwordField"
                            anchors.fill: parent
                            anchors.leftMargin: 36
                            anchors.rightMargin: 44
                            anchors.topMargin: 6
                            anchors.bottomMargin: 6
                            echoMode: TextInput.Password
                            placeholderText: root.authContext.lockedOut ? ("Locked — try again in " + root.authContext.lockoutRemaining + "s") : (root.authContext.coolingDown ? "Wait…" : (root.authContext.authenticating ? "Authenticating…" : "Enter password"))
                            placeholderTextColor: "#aaffffff"
                            color: "white"
                            font.pixelSize: 15
                            font.weight: Font.Medium
                            verticalAlignment: TextInput.AlignVCenter
                            background: Item {}
                            readOnly: root.authContext.authenticating || root.authContext.coolingDown || root.authContext.lockedOut
                            Keys.onEscapePressed: {
                                if (root.authContext.authenticating) return
                                if (text.length > 0) {
                                    text = ""
                                } else if (root.authContext.canAttempt()) {
                                    root.revealed = false
                                    root.forceActiveFocus()
                                }
                            }
                            // Caps heuristic must also run when the field has
                            // focus (root Keys never sees those keypresses).
                            Keys.onPressed: (event) => root._capsHeuristic(event)
                            onAccepted: root.submitPassword()
                            onTextChanged: {
                                if (text.length > 0) idleTimer.stop()
                                else if (root.revealed && !root.hoveringHUD && root.authContext.canAttempt()) idleTimer.start()
                            }
                            // Only REAL typing clears an active error/status.
                            // textChanged also fires for the programmatic clear
                            // in onAuthFailed, which used to wipe the error
                            // styling and "timed out" message in the same tick
                            // they appeared.
                            onTextEdited: root.authContext.clearTransient()
                            onActiveFocusChanged: if (activeFocus) idleTimer.stop()
                        }

                        Rectangle {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.rightMargin: 8
                            width: 28; height: 28; radius: 14
                            color: passwordField.text.length > 0 ? "#66ccff" : "#22ffffff"
                            border.color: "#44ffffff"
                            opacity: root.authContext.canAttempt() ? 1 : 0.4
                            Behavior on color { ColorAnimation { duration: 180 } }
                            Text {
                                anchors.centerIn: parent
                                text: root.authContext.authenticating ? "…" : "→"
                                color: passwordField.text.length > 0 ? "black" : "#88ffffff"
                                font.pixelSize: 14
                                font.weight: Font.Bold
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                enabled: root.mouseEnabled
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
                        text: root._hintText()
                        color: root._hintColor()
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
            // Visual only: the unlock itself is driven by AuthContext →
            // shell.qml, whose unlock timer covers this fade. Never emit
            // auth signals from here — the context already did.
            SequentialAnimation {
                id: successAnim
                ParallelAnimation {
                    NumberAnimation { target: card; property: "scale"; to: 0.98; duration: 100; easing.type: Easing.OutQuad }
                }
                ParallelAnimation {
                    NumberAnimation { target: root; property: "opacity"; to: 0; duration: 220; easing.type: Easing.InOutQuad }
                    NumberAnimation { target: card; property: "scale"; to: 1.04; duration: 220; easing.type: Easing.OutCubic }
                }
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
            opacity: root.revealed && !root.authContext.showError ? 0.30 : 0
            Behavior on opacity { NumberAnimation { duration: 350; easing.type: Easing.OutQuad } }
            z: -1
        }

        // Hover layer ABOVE card: NoButton so clicks pass through,
        // hover still fires even over TextField/buttons.
        // Dead when mouseEnabled:false (keyboard-only lock).
        MouseArea {
            id: hudHover
            anchors.fill: parent
            hoverEnabled: true
            enabled: root.mouseEnabled
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
                if (root.revealed && passwordField.text.length === 0 && root.authContext.canAttempt())
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
