import QtQuick
import QtQuick.Controls
import qs.Ui
import qs.Commons

// Shown instead of the camera grid whenever go2rtc is missing or fails
// fail-closed verification -- a hard, unmissable message rather than
// silently hiding the plugin's whole feature set, matching uplink's own
// "one clearly-required dependency errors, everything else gates by
// visibility" convention.
Item {
  id: root

  required property string reason
  // Only true for the "go2rtc missing/unverified" failure path -- shown
  // stacked with a completely unrelated reason (e.g. a keyring/credential
  // failure) otherwise, which is confusing: found live when a real
  // credential-lookup failure showed this go2rtc-install hint right below
  // it with nothing to do with go2rtc.
  property bool showGo2rtcHint: false
  signal retryRequested()

  // Fixed, not content-derived like CameraGridPanel's -- see its own note.
  implicitWidth: Style.space(560)
  implicitHeight: column.implicitHeight + Style.spacing.popupPadding * 2

  Column {
    id: column
    anchors.centerIn: parent
    width: parent.width - Style.spacing.popupPadding * 2
    spacing: Style.spacing.md

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: "Lookout can't start"
      font.family: Style.font.family
      font.pixelSize: Style.font.title
      font.bold: true
      color: Color.foreground
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: root.reason
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      color: Color.muted
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      visible: root.showGo2rtcHint
      width: parent.width
      text: "Install go2rtc from the AUR (go2rtc-bin, not go2rtc -- see README.md's "
        + "Security section for why the source-built package won't verify), then retry."
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      color: Color.muted
      wrapMode: Text.WordWrap
    }

    Button {
      text: "Retry"
      onClicked: root.retryRequested()
    }
  }
}
