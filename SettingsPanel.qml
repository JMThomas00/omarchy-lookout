import QtQuick
import QtQuick.Controls
import qs.Ui
import qs.Commons
import "Sdm.js" as Sdm
import "OAuth.js" as OAuth

Item {
  id: root

  required property CredentialStore credentialStoreRef
  required property CameraListStore cameraListStoreRef
  required property SetupStore setupStoreRef
  required property SettingsStore settingsStoreRef

  signal backRequested()
  signal signOutRequested()

  property bool _confirmingSignOut: false

  property bool _testingConnection: false
  property string _testStatus: ""
  property color _testStatusColor: Color.muted

  // One-shot verification: refresh a real access token from the stored
  // refresh_token, then GET the Pub/Sub subscription -- the same check
  // SetupWizard.qml's skipSubscription() already trusts (Sdm.getSubscription)
  // reused here so "Test connection" and setup's own verification can never
  // disagree about what "working" means. No long-running process is
  // involved on purpose: this needs an answer right now, not on
  // PubSubListener's own ~10-15s pull cadence, and PubSubListener has no
  // command channel to ask it for an out-of-band pull anyway.
  function _testConnection() {
    if (root._testingConnection) return
    root._testingConnection = true
    root._testStatus = "Testing…"
    root._testStatusColor = Color.muted
    root.credentialStoreRef.lookupFinished.connect(root._onTestCredentials)
    root.credentialStoreRef.lookup()
  }

  function _onTestCredentials(ok, credentials) {
    root.credentialStoreRef.lookupFinished.disconnect(root._onTestCredentials)
    if (!ok) { root._testFailed("No saved Google credentials found. Try \"Re-run setup\" below."); return }
    OAuth.refreshAccessToken(credentials.clientId, credentials.clientSecret, credentials.refreshToken,
      function (result) {
        if (!result.ok) { root._testFailed("Could not refresh Google sign-in: " + result.error); return }
        Sdm.getSubscription(result.accessToken, root.setupStoreRef.gcpProjectId, root.setupStoreRef.pubsubSubscriptionName,
          function (ok2, status, payload) {
            if (ok2) { root._testSucceeded(); return }
            var message = payload && payload.error && payload.error.message ? payload.error.message
              : "the subscription could not be reached"
            root._testFailed("Status " + status + ": " + message)
          })
      })
  }

  function _testSucceeded() {
    root._testingConnection = false
    root._testStatus = "✓ Connected -- your subscription is reachable and events should come through normally."
    root._testStatusColor = Color.foreground
  }

  function _testFailed(message) {
    root._testingConnection = false
    root._testStatus = "✗ " + message
    root._testStatusColor = Color.urgent
  }

  // Fixed, not content-derived like CameraGridPanel's -- see its own note.
  implicitWidth: Style.space(420)
  implicitHeight: column.implicitHeight

  // A small toggle Button shared by every on/off setting on this page --
  // one definition instead of re-typing the same text/color logic on each
  // one, and what keeps them visually consistent. `isOn` drives both the
  // text and a dim/bright color cue, so scanning the page for "what's off"
  // doesn't require reading every word.
  component SettingToggle: Button {
    required property string label
    required property bool isOn
    text: label + (isOn ? " ✓" : " ✗")
    opacity: isOn ? 1.0 : 0.6
  }

  component SectionHeading: Text {
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    font.bold: true
    color: Color.foreground
  }

  component HelpText: Text {
    width: parent ? parent.width : implicitWidth
    wrapMode: Text.WordWrap
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.spacing.lg

    Row {
      width: parent.width
      spacing: Style.spacing.sm
      Button { text: "← Back"; onClicked: root.backRequested() }
      Text {
        text: "Settings"
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.bold: true
        color: Color.foreground
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    // ---------------------------------------------------------- cameras
    Column {
      width: parent.width
      spacing: Style.spacing.sm

      SectionHeading { text: "Cameras" }

      Repeater {
        model: root.cameraListStoreRef.cameras
        // Explicit `required property` on the outer delegate root -- bare
        // `modelData` inside the inner trait Repeater below would otherwise
        // resolve against ITS OWN (unrelated) modelData, a documented
        // gotcha this author's own uplink plugin hit building nested
        // Repeaters.
        delegate: Column {
          id: cameraRow
          required property var modelData
          readonly property var camera: modelData
          width: column.width
          spacing: Style.spacing.xxs

          Row {
            width: parent.width
            Text {
              text: cameraRow.camera.displayName + (cameraRow.camera.room ? (" (" + cameraRow.camera.room + ")") : "")
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }
            Item { width: Style.spacing.sm; height: 1 }
            Button {
              text: cameraRow.camera.hidden ? "Show" : "Hide"
              fontSize: Style.font.caption
              onClicked: root.cameraListStoreRef.setHidden(cameraRow.camera.deviceId, !cameraRow.camera.hidden)
            }
          }

          Flow {
            width: parent.width
            spacing: Style.spacing.xs
            Repeater {
              model: ["motion", "person", "sound", "chime"]
              delegate: SettingToggle {
                required property string modelData
                readonly property string trait: modelData
                label: trait
                isOn: cameraRow.camera.notify ? cameraRow.camera.notify[trait] !== false : true
                onClicked: root.cameraListStoreRef.setNotifyTrait(cameraRow.camera.deviceId, trait, !isOn)
              }
            }
          }
        }
      }
    }

    Rectangle { width: parent.width; height: 1; color: Color.popups.border }

    // ---------------------------------------------------------- display
    Column {
      width: parent.width
      spacing: Style.spacing.sm

      SectionHeading { text: "Display" }

      Row {
        spacing: Style.spacing.sm
        Text {
          text: "Thumbnail size"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
        Button {
          text: "−"
          onClicked: root.settingsStoreRef.setThumbnailWidth(root.settingsStoreRef.thumbnailWidth - 20)
        }
        Text {
          text: root.settingsStoreRef.thumbnailWidth + "px"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
        Button {
          text: "+"
          onClicked: root.settingsStoreRef.setThumbnailWidth(root.settingsStoreRef.thumbnailWidth + 20)
        }
        Item { width: Style.spacing.md; height: 1 }
        SettingToggle {
          label: "Horizontal"
          isOn: root.settingsStoreRef.gridOrientation === "horizontal"
          onClicked: root.settingsStoreRef.setGridOrientation("horizontal")
        }
        SettingToggle {
          label: "Vertical"
          isOn: root.settingsStoreRef.gridOrientation === "vertical"
          onClicked: root.settingsStoreRef.setGridOrientation("vertical")
        }
      }
    }

    Rectangle { width: parent.width; height: 1; color: Color.popups.border }

    // ------------------------------------------------------ notifications
    Column {
      width: parent.width
      spacing: Style.spacing.sm

      SectionHeading { text: "Notifications" }

      // Flow, not Row -- three toggles at their natural width ran past the
      // popup's own edge on a Row, which never wraps. Direct fix for that,
      // plus shorter labels so the common case still fits on one line.
      Flow {
        width: parent.width
        spacing: Style.spacing.xs
        SettingToggle {
          label: "Notifications"
          isOn: root.settingsStoreRef.notificationsEnabled
          onClicked: root.settingsStoreRef.setNotificationsEnabled(!isOn)
        }
        SettingToggle {
          label: "Person badge tint"
          isOn: root.settingsStoreRef.strongerTintForPerson
          onClicked: root.settingsStoreRef.setStrongerTintForPerson(!isOn)
        }
        SettingToggle {
          label: "Attach snapshot"
          isOn: root.settingsStoreRef.attachSnapshot
          onClicked: root.settingsStoreRef.setAttachSnapshot(!isOn)
        }
        SettingToggle {
          label: "Auto-open on doorbell"
          isOn: root.settingsStoreRef.autoOpenOnChime
          onClicked: root.settingsStoreRef.setAutoOpenOnChime(!isOn)
        }
      }

      Row {
        spacing: Style.spacing.sm
        Text {
          text: "Notification cooldown"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
        TextField {
          width: 50
          text: String(root.settingsStoreRef.dedupeWindowSeconds)
          onEditingFinished: root.settingsStoreRef.setDedupeWindowSeconds(parseInt(text) || 60)
        }
        Text {
          text: "seconds"
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
      }
      HelpText {
        text: "Minimum time between two notification popups for the same camera and event type. Every event still counts toward the badge regardless -- this only limits how often a popup interrupts you."
      }

      Row {
        spacing: Style.spacing.sm
        Text {
          text: "Camera bridge shutdown delay"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
        TextField {
          width: 50
          text: String(root.settingsStoreRef.idleTeardownSeconds)
          onEditingFinished: root.settingsStoreRef.setIdleTeardownSeconds(parseInt(text) || 15)
        }
        Text {
          text: "seconds"
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
      }
      HelpText {
        text: "go2rtc (the background bridge that talks to your cameras) only runs while something needs it. This is how long it waits, idle, before shutting down -- long enough that reopening the popup right away doesn't force a cold restart."
      }

      Row {
        spacing: Style.spacing.sm
        Button {
          text: root._testingConnection ? "Testing…" : "Test connection"
          enabled: !root._testingConnection
          onClicked: root._testConnection()
        }
      }
      Text {
        width: parent.width
        visible: root._testStatus.length > 0
        text: root._testStatus
        color: root._testStatusColor
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
      HelpText {
        text: "Confirms Google sign-in still works and your Pub/Sub subscription is reachable, without waiting for a real camera event. Doesn't test individual cameras -- if this passes but one camera never notifies, check that camera's own toggles above."
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
