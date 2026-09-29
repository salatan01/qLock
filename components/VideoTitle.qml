pragma ComponentBehavior: Bound

import QtQuick

// VideoTitle — "now playing" pill, bottom-center of the lock surface.
//
// Toggle with `show` (shells bind `cfg.config.showTitle !== false`).
// Design: the auth card's frosted-glass language, miniaturized — translucent
// dark pill + hairline border + accent ♪ glyph + humanized filename
// (underscores→spaces, extension stripped, %XX decoded, middle-elided).
// A soft opacity pulse marks track changes; with N-playback the title
// simply persists while the same video repeats.
Item {
    id: root

    required property string videoUrl
    property bool show: true

    visible: root.show && root.videoUrl.length > 0

    width: pill.width
    height: pill.height

    function displayName(url) {
        if (!url || url.length === 0) return "";
        var s = url.toString();
        var slash = Math.max(s.lastIndexOf("/"), s.lastIndexOf("\\"));
        if (slash >= 0) s = s.slice(slash + 1);
        try {
            s = decodeURIComponent(s);
        } catch (e) {
            // keep raw on malformed escapes
        }
        var dot = s.lastIndexOf(".");
        if (dot > 0) s = s.slice(0, dot);
        s = s.replace(/[_+]+/g, " ").replace(/\s+/g, " ").trim();
        return s;
    }

    Rectangle {
        id: pill
        width: titleRow.width + 26
        height: 26
        radius: 13
        color: "#55101418"
        border.color: "#33ffffff"
        border.width: 1

        Row {
            id: titleRow
            anchors.centerIn: parent
            spacing: 7
            Text {
                text: "♪"
                color: "#8ad6ff"
                font.pixelSize: 12
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                id: titleText
                width: Math.min(implicitWidth, 380)
                text: root.displayName(root.videoUrl)
                color: "#d8ffffff"
                font.pixelSize: 11
                font.weight: Font.Medium
                font.letterSpacing: 0.3
                elide: Text.ElideMiddle
                anchors.verticalCenter: parent.verticalCenter
                onTextChanged: pulse.restart()
            }
        }

        // Track-change pulse: dip and recover, never fully invisible.
        SequentialAnimation {
            id: pulse
            NumberAnimation { target: pill; property: "opacity"; to: 0.35; duration: 130; easing.type: Easing.OutQuad }
            NumberAnimation { target: pill; property: "opacity"; to: 1.0; duration: 280; easing.type: Easing.OutQuad }
        }
    }

    // entrance (targets root; pulse targets pill — no conflict)
    NumberAnimation on opacity { from: 0; to: 1; duration: 600; easing.type: Easing.OutQuad; running: visible }
}
