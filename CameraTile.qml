import QtQuick
import qs.Ui
import qs.Commons

// One camera's thumbnail in the grid: a single frame.jpeg snapshot fetched
// once per popup-open (via BackendManager.fetchSnapshot), not a continuous
// feed. Click the tile for the real, actually-live floating mpv view.
//
// A prior version of this file kept a background ffmpeg process
// continuously re-decoding each camera's RTSP restream to get a near-live
// (~1fps) thumbnail, plus a second background "keyframe solicitor" process
// just to keep go2rtc's own RTSP restream fed at all. It worked, but it
// meant two background processes per visible camera, retry-with-backoff
// logic, and a visible flicker on every refresh -- simplified back to this
// after direct user feedback: given Nest's own snapshot latency (measured
// live at 0.6-26s per request, entirely outside this plugin's control) is
// the real bottleneck either way, a single on-open snapshot plus a true
// live view one click away is worth far less machinery than a "near-live"
// thumbnail that still isn't actually live. See
// [[omarchy_lookout_project]]/[[omarchy_plugin_dev_gotchas]] for the full
// diagnostic trail (including the earlier, separately-abandoned attempt at
// genuinely live video via QtMultimedia) if revisiting this.
//
// The fetched frame is cached to a fixed local file
// (BackendManager.snapshotPath) that's never deleted, only overwritten on a
// new successful fetch -- so the very first read on opening the popup is
// often instantly whatever frame was cached from a previous session, not a
// blank tile. Display uses two alternating Image elements (imgA/imgB) so
// the CURRENTLY VISIBLE one's `source` is never reassigned while it's on
// screen -- reassigning a visible Image's own source still forces it
// through a brief reload/decode cycle even when the bytes are already on
// disk, which is what caused a visible flicker on every refresh in the
// single-Image design this replaced.
Item {
  id: root

  required property string deviceId
  required property string displayName
  required property int unseenCount
  required property BackendManager backendManagerRef
  property bool connecting: false
  property int tileWidth: 180
  property int tileHeight: 140

  signal clicked()

  implicitWidth: tileWidth
  implicitHeight: tileHeight

  property int _fetchGeneration: 0
  property bool _everReady: false
  property bool _activeIsA: true
  property bool _retriedOnce: false

  // Reloads whichever Image is currently NOT the visible one from disk --
  // safe to call any time, whether or not a fresh fetch has actually
  // landed yet, since it's just a local file read.
  function _reloadInactiveFromDisk() {
    root._fetchGeneration += 1
    var url = root.backendManagerRef.snapshotUrl(root.deviceId, root._fetchGeneration)
    if (root._activeIsA) imgB.source = url
    else imgA.source = url
  }

  function _requestFreshSnapshot() {
    if (!root.backendManagerRef.running) return
    root.backendManagerRef.fetchSnapshot(root.deviceId)
  }

  Component.onCompleted: {
    root._reloadInactiveFromDisk()
    if (root.backendManagerRef.running) root._requestFreshSnapshot()
  }

  Connections {
    target: root.backendManagerRef
    function onRunningChanged() {
      if (root.backendManagerRef.running) {
        root._retriedOnce = false
        root._requestFreshSnapshot()
      }
    }
    function onSnapshotFetched(deviceId, ok) {
      if (deviceId !== root.deviceId) return
      if (ok) {
        root._reloadInactiveFromDisk()
      } else if (!root._retriedOnce) {
        // One retry, not an ongoing loop -- go2rtc may just still be
        // finishing its own startup readiness the very first time a tile
        // asks. A camera that's genuinely unreachable just keeps showing
        // its last cached frame (or the placeholder, if there's never been
        // one), which is the honest answer rather than spinning forever.
        root._retriedOnce = true
        root._requestFreshSnapshot()
      }
    }
  }

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Color.popups.background
    border.width: 1
    border.color: Color.popups.border

    Image {
      id: imgA
      anchors.fill: parent
      anchors.margins: 2
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      visible: root._activeIsA && status === Image.Ready
      onStatusChanged: if (status === Image.Ready) { root._activeIsA = true; root._everReady = true }
    }

    Image {
      id: imgB
      anchors.fill: parent
      anchors.margins: 2
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      visible: !root._activeIsA && status === Image.Ready
      onStatusChanged: if (status === Image.Ready) { root._activeIsA = false; root._everReady = true }
    }

    Text {
      anchors.centerIn: parent
      // Only shown before the very first successful frame ever -- once a
      // camera has shown anything, it keeps showing that last good frame
      // rather than reverting to a placeholder on a failed refresh.
      visible: !root._everReady
      text: "…"
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.title
    }

    Rectangle {
      visible: root.connecting
      anchors.fill: parent
      radius: Style.cornerRadius
      color: "#A0000000"

      Text {
        anchors.centerIn: parent
        text: "Connecting…"
        color: "white"
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }

    Rectangle {
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      anchors.margins: 4
      radius: 3
      color: "#B0000000"
      width: nameText.implicitWidth + 8
      height: nameText.implicitHeight + 4

      Text {
        id: nameText
        anchors.centerIn: parent
        text: root.displayName
        color: "white"
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    Rectangle {
      visible: root.unseenCount > 0
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: 4
      radius: height / 2
      width: Math.max(16, countText.implicitWidth + 8)
      height: 16
      color: Color.urgent

      Text {
        id: countText
        anchors.centerIn: parent
        text: String(root.unseenCount)
        color: "white"
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.clicked()
    }
  }
}
