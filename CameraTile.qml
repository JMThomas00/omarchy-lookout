import QtQuick
import QtMultimedia
import qs.Ui
import qs.Commons
import "Notify.js" as Notify

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
// genuinely live video via QtMultimedia) if revisiting this. That failure
// was specific to a continuous LIVE RTSP source -- QtMultimedia playing a
// short, already-downloaded, static local mp4 file (the clipPlayer below)
// is a genuinely different case, confirmed working live before building
// this: a local test clip went LoadedMedia -> BufferingMedia ->
// BufferedMedia -> smooth playback to EndOfMedia with zero stalling.
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
  required property EventStateStore eventStateStoreRef
  property bool connecting: false
  property int tileWidth: 180
  property int tileHeight: 140
  // {trait, lastMs} from EventStateStore.lastEventForDevice, or null if
  // this camera has never reported one -- shown in place of the bare "…"
  // placeholder while waiting on the first snapshot of the popup session,
  // per direct request, so there's something meaningful to look at during
  // that wait (which can be several seconds -- see the header comment on
  // why this plugin doesn't try to hide that latency with a background
  // relay anymore).
  property var lastEvent: null

  signal clicked()

  implicitWidth: tileWidth
  implicitHeight: tileHeight

  property int _fetchGeneration: 0
  property bool _everReady: false
  property bool _activeIsA: true
  property bool _retriedOnce: false
  property bool _hasClip: false

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

  // Only stops the clip player on the FIRST transition to ready -- called
  // from imgA/imgB's onStatusChanged, which fires on every successful
  // refresh, not just the first.
  function _markEverReady() {
    if (root._everReady) return
    root._everReady = true
    if (clipPlayer.playbackState === MediaPlayer.PlayingState) clipPlayer.stop()
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
      onStatusChanged: if (status === Image.Ready) { root._activeIsA = true; root._markEverReady() }
    }

    Image {
      id: imgB
      anchors.fill: parent
      anchors.margins: 2
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      visible: !root._activeIsA && status === Image.Ready
      onStatusChanged: if (status === Image.Ready) { root._activeIsA = false; root._markEverReady() }
    }

    // The actual clip from the last camera event, looping, while waiting
    // on the first live snapshot -- per direct request, in place of (not
    // just alongside) a text-only placeholder wherever a clip exists. Not
    // every event has one (depends on the camera's own Nest clip-history
    // support -- see bin/pubsub-listener.py's own comment), so this stays
    // hidden and _hasClip stays false for a camera that's never provided
    // one, falling back to the plain "…" dots below.
    MediaPlayer {
      id: clipPlayer
      // Gated on lastEvent, not unconditional -- a camera that has never
      // recorded any event yet (the common case right after first setup)
      // has no clip file to even attempt, and binding the URL anyway just
      // produces a pointless FFmpeg "No such file or directory" warning in
      // the journal on every popup open. A camera WITH an event but no
      // clip for that specific event type still hits the same fallback
      // once, which onMediaStatusChanged below already handles cleanly.
      source: root.lastEvent ? root.eventStateStoreRef.lastEventClipUrl(root.deviceId) : ""
      videoOutput: clipVideoOutput
      loops: MediaPlayer.Infinite
      onMediaStatusChanged: {
        if (mediaStatus === MediaPlayer.LoadedMedia || mediaStatus === MediaPlayer.BufferedMedia) {
          root._hasClip = true
          if (!root._everReady && playbackState !== MediaPlayer.PlayingState) play()
        } else if (mediaStatus === MediaPlayer.InvalidMedia || mediaStatus === MediaPlayer.NoMedia) {
          root._hasClip = false
        }
      }
    }

    VideoOutput {
      id: clipVideoOutput
      anchors.fill: parent
      anchors.margins: 2
      fillMode: VideoOutput.PreserveAspectCrop
      visible: root._hasClip && !root._everReady
    }

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      // Only shown before the very first successful frame ever, and only
      // when there's no clip to show instead -- once a camera has shown
      // anything, it keeps showing that last good frame/clip rather than
      // reverting to a placeholder on a failed refresh.
      visible: !root._everReady && !root._hasClip
      text: "…"
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.title
    }

    // The last known event for this camera, as a corner caption -- shown
    // whether or not a clip is playing behind it (top-left is otherwise
    // unused: the name label already owns bottom-left, the unseen badge
    // owns top-right).
    Rectangle {
      visible: !root._everReady && !!root.lastEvent
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.margins: 4
      radius: 3
      color: "#B0000000"
      width: lastEventText.implicitWidth + 8
      height: lastEventText.implicitHeight + 4

      Text {
        id: lastEventText
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: root.lastEvent
          ? (Notify.labelForShortTrait(root.lastEvent.trait) + " · " + Notify.timeAgo(root.lastEvent.lastMs, Date.now()))
          : ""
        color: "white"
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    Rectangle {
      visible: root.connecting
      anchors.fill: parent
      radius: Style.cornerRadius
      color: "#A0000000"

      Text {
        textFormat: Text.PlainText
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
      width: nameText.width + 8
      height: nameText.implicitHeight + 4

      Text {
        id: nameText
        textFormat: Text.PlainText
        // Names come from Google (up to 100 chars, Sdm.js) -- an untrusted
        // length must not push this pill past its own tile and over the
        // neighboring one, so it elides at the tile's width instead.
        width: Math.min(implicitWidth, root.tileWidth - 24)
        elide: Text.ElideRight
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
        textFormat: Text.PlainText
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
