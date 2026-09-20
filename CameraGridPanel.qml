import QtQuick
import QtQuick.Controls
import qs.Ui
import qs.Commons

// Thumbnail grid -- the popup's normal-operation view. Acquires a
// BackendManager ref for as long as this component is alive (i.e. only
// while it's the active Loader item in BarWidget.qml), which is what makes
// go2rtc/the thumbnail refresh both start on open and stop shortly after
// close, per the "live only while the popup is open" design.
Item {
  id: root

  required property string pluginDir
  required property BackendManager backendManagerRef
  required property CameraListStore cameraListStoreRef
  required property EventStateStore eventStateStoreRef
  required property SettingsStore settingsStoreRef

  signal settingsRequested()

  readonly property int _tileWidth: root.settingsStoreRef.thumbnailWidth
  // Same aspect ratio as the original fixed 180x140 tiles -- individual
  // cameras have different native aspect ratios (this user's doorbell is
  // portrait, 3:4; the other two are 16:9), so every tile crops to this one
  // shared shape (fillMode: PreserveAspectCrop in CameraTile.qml) rather
  // than each tile having its own size, which would look inconsistent in a
  // grid.
  readonly property int _tileHeight: Math.round(root._tileWidth * 140 / 180)

  // The popup's own border used to stay pinned at a fixed maximum width
  // (BarWidget.qml's contentWidth was hardcoded to "desire exactly 560"
  // regardless of what was actually shown) -- found live from user
  // screenshots comparing 100px and 360px thumbnails in the vertical
  // layout: both rendered at the same wide popup width, with the tiles
  // themselves correctly centered inside all that extra space, but the
  // popup itself never shrank to match. This is what BarWidget.qml's
  // contentWidth now actually measures, so it has to reflect this view's
  // REAL natural width for whichever orientation/camera-count/thumbnail-
  // size is current -- not just fill whatever width it's given (`column`
  // below still does that internally, same as before; this is the
  // separate, outward-facing "how wide do I actually want to be" signal).
  readonly property int _visibleCameraCount: root.cameraListStoreRef.visibleCamerasSorted.length
  readonly property int _naturalContentWidth: root.settingsStoreRef.gridOrientation === "vertical"
    ? root._tileWidth
    : Math.max(1, root._visibleCameraCount) * (root._tileWidth + Style.spacing.md) - Style.spacing.md

  // noCamerasText's own implicitWidth only counts toward the floor while
  // it's actually the thing being shown -- found live: counting it
  // unconditionally made the vertical layout's popup stay pinned to that
  // one long sentence's width (~450px) even with real cameras showing at
  // a much narrower thumbnail size, which looked identical to the original
  // "popup never shrinks" bug this whole implicitWidth mechanism exists to
  // fix, just with a different fixed number behind it.
  implicitWidth: Math.max(settingsButton.width,
    root._visibleCameraCount === 0 ? noCamerasText.implicitWidth : 0,
    root._naturalContentWidth, Style.space(160))
  // column no longer starts at y=0 -- see settingsButton's own comment on
  // why the settings icon moved out of the normal document flow.
  implicitHeight: column.y + column.implicitHeight

  Component.onCompleted: root.backendManagerRef.acquire("grid")
  Component.onDestruction: root.backendManagerRef.release("grid")

  Connections {
    target: root.backendManagerRef
    function onFloatingViewFailed(reason) { statusText.text = reason }
  }

  Component {
    id: tileDelegate
    CameraTile {
      required property var modelData
      deviceId: modelData.deviceId
      displayName: modelData.displayName
      unseenCount: root.eventStateStoreRef.unseenCountForDevice(modelData.deviceId)
      // Shown in place of the "…" placeholder while this tile is waiting
      // on its first snapshot of the popup session -- per direct request,
      // so there's something meaningful to look at during that wait
      // instead of blank dots. Reactive the same way unseenCount already
      // is: a function call read directly in the binding, which QML still
      // tracks as depending on whatever properties that function reads
      // internally (here, eventStateStoreRef.byDevice).
      lastEvent: root.eventStateStoreRef.lastEventForDevice(modelData.deviceId)
      eventStateStoreRef: root.eventStateStoreRef
      // One on-open snapshot, not a continuous feed -- see CameraTile.qml's
      // own header comment and [[omarchy_lookout_project]] for why (Nest's
      // own snapshot latency is the real bottleneck; a background relay
      // process worked but wasn't worth the complexity for a result that
      // still wasn't genuinely live). Click a tile for the real live view.
      backendManagerRef: root.backendManagerRef
      connecting: root.backendManagerRef.connectingDevices[modelData.deviceId] === true
      tileWidth: root._tileWidth
      tileHeight: root._tileHeight
      onClicked: root.backendManagerRef.openFloatingView(modelData.deviceId, modelData.displayName)
    }
  }

  // Settings icon: an absolute top-right overlay, not a Column child, so it
  // takes up no space of its own in the vertical flow -- found live that
  // giving it a dedicated row (even just an icon-sized one) added a whole
  // extra row-height-plus-spacing gap above the camera grid that read as
  // "unexplained empty space" once the "Cameras" title text next to it was
  // removed. `column` below starts right under it with just enough margin
  // to clear the icon, not a full row's worth of space.
  //
  // A plain Text+MouseArea, not a Button: this needs to render explicitly
  // white regardless of whatever accent color the ambient QQC2 style gives
  // Button (it was rendering a theme blue, standing out from the rest of
  // the bar's white icons), and a Button's palette isn't guaranteed to
  // honor a per-instance color override across every style Omarchy might
  // apply.
  //
  // A real icon glyph, not the "⚙" character -- even with the U+FE0E
  // "text presentation" variation selector (tried first), this font still
  // renders it with a faint blue-gray tint baked into its own color-glyph
  // table, confirmed live side by side against a plain icon glyph in an
  // isolated test window (screenshot comparison, not just code reading).
  // U+F013 is nf-fa-cog -- the same Font Awesome Nerd Font set
  // BarWidget.qml's own bar icon uses (nf-fa-video_camera, U+F03D) -- and
  // `Style.font.family` resolves to "monospace", which `fc-match` confirms
  // is JetBrainsMono Nerd Font on this system, so no extra font needs
  // bundling or requiring: nerd-font glyphs are plain vector icons, not
  // color emoji, so `color` actually applies.
  Item {
    id: settingsButton
    anchors.top: parent.top
    anchors.right: parent.right
    width: gearText.implicitWidth + Style.spacing.sm * 2
    height: gearText.implicitHeight + Style.spacing.sm * 2
    z: 1

    Text {
      id: gearText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: ""
      color: "white"
      font.family: Style.font.family
      font.pixelSize: Style.font.title
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.settingsRequested()
    }
  }

  Column {
    id: column
    y: settingsButton.height + Style.spacing.xs
    width: parent.width
    spacing: Style.spacing.md

    Text {
      id: statusText
      textFormat: Text.PlainText
      width: parent.width
      visible: text.length > 0
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      visible: root.backendManagerRef.backendState === "verifying" || root.backendManagerRef.backendState === "starting"
      text: "Connecting to your cameras…"
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    // Horizontal: a Flow, but width-capped to its own content (not the
    // full popup width) and then centered -- a plain full-width Flow lays
    // tiles out left-aligned, which looks unbalanced (a lopsided right
    // margin) whenever the tiles don't exactly fill the row. Capping width
    // to "however much this many tiles actually need" and centering that
    // gives a balanced margin on both sides for the common case (everything
    // fits on one row); once there are enough tiles to wrap, the cap
    // saturates at the full width and it behaves like an ordinary Flow.
    Item {
      visible: root.backendManagerRef.running && root.settingsStoreRef.gridOrientation === "horizontal"
      width: parent.width
      implicitHeight: hFlow.implicitHeight

      Flow {
        id: hFlow
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width,
          root.cameraListStoreRef.visibleCamerasSorted.length * (root._tileWidth + Style.spacing.md) - Style.spacing.md)
        spacing: Style.spacing.md

        // Gated on orientation too, not just the parent Item's `visible` --
        // a Repeater still instantiates its delegates while invisible, so
        // without this both layouts would run their own independent set of
        // CameraTiles (and their own independent thumbnail fetches) at
        // once, doubling the load on go2rtc for no reason.
        Repeater {
          model: root.settingsStoreRef.gridOrientation === "horizontal"
            ? root.cameraListStoreRef.visibleCamerasSorted : []
          delegate: tileDelegate
        }
      }
    }

    // Vertical: a single centered column, one tile per row. Wrapped in a
    // plain Item, not anchored directly as a child of the outer `column`
    // positioner above -- Row/Column/Grid/Flow positioners forcibly set
    // their direct children's `x` themselves, silently overriding any
    // anchor put directly on one (this is what made the vertical layout
    // stick to the left edge instead of centering, confirmed live: the
    // exact same `anchors.horizontalCenter` binding worked fine one level
    // down, on the Flow inside the horizontal layout's own wrapper Item
    // below, which is a plain Item and not a positioner). A plain Item
    // isn't a positioner, so anchoring inside it behaves normally.
    Item {
      visible: root.backendManagerRef.running && root.settingsStoreRef.gridOrientation === "vertical"
      width: parent.width
      implicitHeight: vColumn.implicitHeight

      Column {
        id: vColumn
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.spacing.md

        Repeater {
          model: root.settingsStoreRef.gridOrientation === "vertical"
            ? root.cameraListStoreRef.visibleCamerasSorted : []
          delegate: tileDelegate
        }
      }
    }

    Text {
      id: noCamerasText
      textFormat: Text.PlainText
      visible: root.cameraListStoreRef.visibleCamerasSorted.length === 0 && root.backendManagerRef.running
      text: "No cameras to show. Check Settings to unhide a camera."
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
  }
}
