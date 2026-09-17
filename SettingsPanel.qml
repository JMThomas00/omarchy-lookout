import QtQuick
import QtQuick.Controls
import qs.Ui
import qs.Commons

Item {
  id: root

  required property CredentialStore credentialStoreRef
  required property CameraListStore cameraListStoreRef
  required property SetupStore setupStoreRef
  required property SettingsStore settingsStoreRef

  signal backRequested()
  signal signOutRequested()

  property bool _confirmingSignOut: false

  // Fixed, not content-derived like CameraGridPanel's -- see its own note.
  implicitWidth: Style.space(560)
  implicitHeight: column.implicitHeight

  Column {
    id: column
    width: parent.width
    spacing: Style.spacing.md

    Row {
      width: parent.width
      Button { text: "← Back"; onClicked: root.backRequested() }
      Item { width: Style.spacing.md; height: 1 }
      Text {
        text: "Settings"
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.bold: true
        color: Color.foreground
      }
    }

    Text {
      text: "Cameras"
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
      color: Color.foreground
    }

    Repeater {
      model: root.cameraListStoreRef.cameras
      // Explicit `required property` on the outer delegate root -- bare
      // `modelData` inside the inner trait Repeater below would otherwise
      // resolve against ITS OWN (unrelated) modelData, a documented gotcha
      // this author's own uplink plugin hit building nested Repeaters.
      delegate: Column {
        id: cameraRow
        required property var modelData
        readonly property var camera: modelData
        width: column.width
        spacing: Style.spacing.xs

        Row {
          spacing: Style.spacing.sm
          Text {
            text: cameraRow.camera.displayName + (cameraRow.camera.room ? (" (" + cameraRow.camera.room + ")") : "")
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          Button {
            text: cameraRow.camera.hidden ? "Show" : "Hide"
            onClicked: root.cameraListStoreRef.setHidden(cameraRow.camera.deviceId, !cameraRow.camera.hidden)
          }
        }

        Row {
          spacing: Style.spacing.sm
          Repeater {
            model: ["motion", "person", "sound", "chime"]
            delegate: Button {
              required property string modelData
              readonly property string trait: modelData
              readonly property bool isOn: cameraRow.camera.notify ? cameraRow.camera.notify[trait] !== false : true
              text: trait + (isOn ? " ✓" : " ✗")
              onClicked: root.cameraListStoreRef.setNotifyTrait(cameraRow.camera.deviceId, trait, !isOn)
            }
          }
        }
      }
    }

    Rectangle { width: parent.width; height: 1; color: Color.popups.border }

    Text {
      text: "Display"
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
      color: Color.foreground
    }

    Row {
      spacing: Style.spacing.sm
      Text { text: "Thumbnail size:"; color: Color.foreground; font.family: Style.font.family }
      Button {
        text: "−"
        onClicked: root.settingsStoreRef.setThumbnailWidth(root.settingsStoreRef.thumbnailWidth - 20)
      }
      Text {
        text: root.settingsStoreRef.thumbnailWidth + "px"
        color: Color.foreground
        font.family: Style.font.family
        anchors.verticalCenter: parent.verticalCenter
      }
      Button {
        text: "+"
        onClicked: root.settingsStoreRef.setThumbnailWidth(root.settingsStoreRef.thumbnailWidth + 20)
      }
    }

    Row {
      spacing: Style.spacing.sm
      Text { text: "Layout:"; color: Color.foreground; font.family: Style.font.family }
      Button {
        text: root.settingsStoreRef.gridOrientation === "horizontal" ? "Horizontal ✓" : "Horizontal"
        onClicked: root.settingsStoreRef.setGridOrientation("horizontal")
      }
      Button {
        text: root.settingsStoreRef.gridOrientation === "vertical" ? "Vertical ✓" : "Vertical"
        onClicked: root.settingsStoreRef.setGridOrientation("vertical")
      }
    }

    Rectangle { width: parent.width; height: 1; color: Color.popups.border }

    Text {
      text: "Notifications"
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
      color: Color.foreground
    }

    Row {
      spacing: Style.spacing.sm
      Button {
        text: root.settingsStoreRef.notificationsEnabled ? "Notifications: On" : "Notifications: Off"
        onClicked: root.settingsStoreRef.setNotificationsEnabled(!root.settingsStoreRef.notificationsEnabled)
      }
      Button {
        text: "Stronger badge for person: " + (root.settingsStoreRef.strongerTintForPerson ? "On" : "Off")
        onClicked: root.settingsStoreRef.setStrongerTintForPerson(!root.settingsStoreRef.strongerTintForPerson)
      }
    }

    Row {
      spacing: Style.spacing.sm
      Text { text: "Dedupe window (seconds):"; color: Color.foreground; font.family: Style.font.family }
      TextField {
        width: 60
        text: String(root.settingsStoreRef.dedupeWindowSeconds)
        onEditingFinished: root.settingsStoreRef.setDedupeWindowSeconds(parseInt(text) || 60)
      }
    }

    Row {
      spacing: Style.spacing.sm
      Text { text: "go2rtc idle teardown (seconds):"; color: Color.foreground; font.family: Style.font.family }
      TextField {
        width: 60
        text: String(root.settingsStoreRef.idleTeardownSeconds)
        onEditingFinished: root.settingsStoreRef.setIdleTeardownSeconds(parseInt(text) || 15)
      }
    }

    Rectangle { width: parent.width; height: 1; color: Color.popups.border }

    Row {
      spacing: Style.spacing.sm
      Button { text: "Re-run setup"; onClicked: root.signOutRequested() }
      Button {
        text: root._confirmingSignOut ? "Really sign out?" : "Sign out"
        onClicked: {
          if (!root._confirmingSignOut) { root._confirmingSignOut = true; return }
          root.credentialStoreRef.clear()
          root.signOutRequested()
        }
      }
    }
  }
}
