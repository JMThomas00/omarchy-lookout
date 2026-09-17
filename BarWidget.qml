import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Notify.js" as Notify

// Lookout -- live thumbnail grid for Google Home/Nest cameras. See README.md
// for the full design and Security section.
BarWidget {
  id: root
  moduleName: "jmthomas00.lookout"

  readonly property string home: Quickshell.env("HOME")
  // Resolved from this file's own location rather than hardcoded, so this
  // works regardless of where the plugin is actually checked out.
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "").replace(/\/$/, "")

  CredentialStore { id: credentialStore; pluginDir: root.pluginDir }
  CameraListStore { id: cameraListStore }
  SetupStore { id: setupStore }
  SettingsStore { id: settingsStore }
  EventStateStore { id: eventStateStore }

  BackendManager {
    id: backendManager
    pluginDir: root.pluginDir
    credentialStoreRef: credentialStore
    cameraListStoreRef: cameraListStore
    setupStoreRef: setupStore
    settingsStoreRef: settingsStore
  }

  PubSubListener {
    id: pubSubListener
    pluginDir: root.pluginDir
    credentialStoreRef: credentialStore
    setupStoreRef: setupStore
    eventStateStoreRef: eventStateStore
  }

  // go2rtc's own verification (bin/go2rtc-verify.sh) is what actually
  // decides go2rtc's availability -- this is a fast, non-authoritative
  // `which` probe purely so ErrorBanner can show a clear message before the
  // user ever opens the popup, rather than only failing on first open.
  property bool go2rtcProbablyInstalled: true

  // "auto" derives the view from live state (go2rtc/setup/auth); any other
  // value is a manual override the gear icon / Back / Sign-out set. This
  // exists specifically because a Loader's sourceComponent cannot be BOTH a
  // live declarative binding (derived from state) AND something written to
  // imperatively from elsewhere -- mixing those two control mechanisms on
  // the same property is exactly what caused a real, live "Binding loop
  // detected for property sourceComponent" warning (found by actually
  // running the setup wizard, not by inspection).
  //
  // _activeView itself is a PLAIN property, recomputed imperatively by
  // _recomputeView() -- not a declarative multi-branch block binding.
  // Moving the sourceComponent write off of a declarative binding (above)
  // was not enough on its own: a `readonly property string: { if/return
  // chain }` block binding over several unrelated properties (go2rtc probe
  // result, backendManager state, setupStore state, pubSubListener state)
  // ALSO triggered its own "Binding loop detected" warning here, live,
  // moved rather than fixed by the first attempt. Rather than keep chasing
  // QML's loop detector through declarative bindings, view state is fully
  // imperative: every dependency's change signal calls _recomputeView(),
  // which does a single plain assignment -- no binding evaluation involved
  // at all, so there is nothing for the loop detector to flag.
  property string _manualView: "auto"
  property string _activeView: "wizard"

  function _recomputeView() {
    var auto
    if (!root.go2rtcProbablyInstalled || backendManager.backendState === "error") auto = "error"
    else if (!setupStore.completed || pubSubListener.authExpired) auto = "wizard"
    else auto = "grid"
    // "error" always wins over a manual override -- a broken go2rtc/backend
    // is more urgent than whatever screen was manually opened.
    root._activeView = auto === "error" ? "error" : (root._manualView !== "auto" ? root._manualView : auto)
  }

  function _setManualView(view) {
    root._manualView = view
    root._recomputeView()
  }

  Process {
    id: go2rtcProbeProc
    command: ["which", "go2rtc"]
    onExited: function (exitCode) { root.go2rtcProbablyInstalled = exitCode === 0; root._recomputeView() }
  }

  Component.onCompleted: {
    go2rtcProbeProc.running = true
    if (setupStore.completed) pubSubListener.start()
    root._recomputeView()
  }

  Connections {
    target: setupStore
    function onCompletedChanged() {
      if (setupStore.completed) pubSubListener.start()
      else pubSubListener.stop()
      root._recomputeView()
    }
  }

  Connections {
    target: backendManager
    function onBackendStateChanged() { root._recomputeView() }
  }

  Connections {
    target: pubSubListener
    function onAuthExpiredChanged() { root._recomputeView() }
  }

  // ------------------------------------------------------------ notifications

  Connections {
    target: eventStateStore
    function onNotifiableEvent(deviceId, trait) {
      root._maybeNotify(deviceId, trait)
      root._maybeAutoOpenChime(deviceId, trait)
    }
  }

  // A doorbell press is fundamentally different from motion/person/sound:
  // someone is standing at the door right now, so per direct request this
  // jumps straight to the real live view instead of waiting on a bar-badge
  // click. Reuses backendManager.openFloatingView unchanged -- it already
  // handles the go2rtc spawn-if-needed path, the "already open" focus
  // case, and connecting-state UX, so this only needs to decide WHEN to
  // call it. Gated by the same per-camera "chime" notify toggle
  // _maybeNotify already honors (a camera with chime notifications off
  // shouldn't have its live view pop open either) plus its own dedicated
  // Settings toggle, independent of whether desktop notifications overall
  // are enabled -- someone might want the auto-open without the popup, or
  // vice versa.
  function _maybeAutoOpenChime(deviceId, trait) {
    if (!settingsStore.autoOpenOnChime) return
    if (Notify.shortTrait(trait) !== "chime") return
    var camera = cameraListStore.cameraById(deviceId)
    if (!camera) return
    if (camera.notify && camera.notify.chime === false) return
    backendManager.openFloatingView(deviceId, camera.displayName)
  }

  function _maybeNotify(deviceId, trait) {
    if (!settingsStore.notificationsEnabled) return
    var camera = cameraListStore.cameraById(deviceId)
    if (!camera) return
    var shortTrait = Notify.shortTrait(trait)
    if (camera.notify && camera.notify[shortTrait] === false) return
    if (!eventStateStore.shouldNotify(deviceId, trait, settingsStore.dedupeWindowSeconds)) return

    var title = Notify.notificationTitle(camera.displayName, trait)
    var omarchyPath = Quickshell.env("OMARCHY_PATH")
    var urgency = shortTrait === "person" ? "critical" : "normal"
    var args = [omarchyPath + "/bin/omarchy-notification-send", "-u", urgency, "--app-name", "Lookout"]

    if (!settingsStore.attachSnapshot) {
      args.push(title, "Opening Lookout clears this alert")
      Quickshell.execDetached(args)
      return
    }
    // A cached snapshot can be badly stale -- possibly from a popup
    // session long before this event, showing nothing of whoever/whatever
    // just triggered it. Per direct feedback, a notification fires with a
    // genuinely fresh snapshot even if that means waiting for it -- the
    // whole point of a "Person detected" alert is showing the person.
    root._notifyWithFreshSnapshot(deviceId, args, title, "Opening Lookout clears this alert")
  }

  // Spins up go2rtc if it isn't already running (an event notification is
  // exactly as legitimate a reason as opening the popup -- the user turned
  // this on deliberately in Settings), fetches one fresh snapshot, then
  // sends the notification with whatever's at snapshotPath afterward
  // (freshly-fetched on success, whatever was already cached if the fetch
  // failed -- never nothing, and the notification itself is NEVER lost:
  // the watchdog below guarantees it still fires even if go2rtc/the fetch
  // never completes at all).
  readonly property int _notifyFreshSnapshotTimeoutMs: 35000
  property int _notifyRefCounter: 0

  function _notifyWithFreshSnapshot(deviceId, argsWithoutImage, title, description) {
    // A unique ref per call, not per device -- two notifications for the
    // SAME camera close together (different traits firing within
    // moments of each other, e.g. motion then person) would otherwise
    // share one "notify:<deviceId>" ref, and the FIRST one finishing
    // would release() it out from under the second one still in flight.
    root._notifyRefCounter += 1
    var refName = "notify:" + deviceId + ":" + root._notifyRefCounter
    var settled = false
    var watchdog = notifyWatchdogComponent.createObject(root)

    function finish() {
      if (settled) return
      settled = true
      backendManager.snapshotFetched.disconnect(onSnapshotFetched)
      backendManager.runningChanged.disconnect(onRunningChanged)
      watchdog.triggered.disconnect(finish)
      watchdog.stop()
      watchdog.destroy()
      var args = argsWithoutImage.concat(["--image", backendManager.snapshotPath(deviceId), title, description])
      Quickshell.execDetached(args)
      backendManager.release(refName)
    }

    function onSnapshotFetched(fetchedDeviceId, ok) {
      if (fetchedDeviceId === deviceId) finish()
    }

    function onRunningChanged() {
      if (backendManager.running) {
        backendManager.runningChanged.disconnect(onRunningChanged)
        backendManager.fetchSnapshot(deviceId)
      }
    }

    backendManager.snapshotFetched.connect(onSnapshotFetched)
    watchdog.triggered.connect(finish)
    watchdog.interval = root._notifyFreshSnapshotTimeoutMs
    watchdog.start()

    backendManager.acquire(refName)
    if (backendManager.running) backendManager.fetchSnapshot(deviceId)
    else backendManager.runningChanged.connect(onRunningChanged)
  }

  Component {
    id: notifyWatchdogComponent
    Timer { repeat: false }
  }

  // ------------------------------------------------------------------ badge

  readonly property int unseenCount: eventStateStore.totalUnseen
  readonly property bool hasUnseenPerson: {
    for (var i = 0; i < cameraListStore.cameras.length; i++)
      if (eventStateStore.hasUnseenPersonForDevice(cameraListStore.cameras[i].deviceId)) return true
    return false
  }

  // ------------------------------------------------------------- panel/bar

  function openPanel() { panel.open = true }
  function closePanel() { panel.open = false }
  function togglePanel() { panel.open ? closePanel() : openPanel() }

  readonly property bool opened: panel.open
  function open() { openPanel() }
  function close() { closePanel() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root, direction)
    return false
  }

  onOpenedChanged: {
    if (root.opened) {
      eventStateStore.markAllSeen()
      root._dismissOutstandingNotifications()
    }
  }

  // "Opening Lookout clears this alert" (the notification's own body text)
  // used to only mean the BADGE -- the toast itself stayed on screen until
  // clicked, which direct feedback flagged as misleading given what the
  // text actually says. Found live: this shell's own notification service
  // (not a separate daemon -- confirmed via `busctl --user status
  // org.freedesktop.Notifications`, owned by quickshell itself) does NOT
  // honor the standard freedesktop `CloseNotification` DBus method the way
  // a spec daemon would (tested directly: the call succeeds with no error,
  // but the toast stays visible) -- it has its OWN dismiss mechanism
  // instead, exposed over IPC as `notifications.dismiss(summary)`, which
  // removes any currently-shown toast whose summary/headline CONTAINS the
  // given substring. Every notification this plugin sends starts with the
  // camera's own display name (`Notify.notificationTitle`), so dismissing
  // by each known camera's name catches all of them without touching an
  // unrelated notification from another app. `-q`: best-effort, matching
  // `omarchy-notification-dismiss`'s own use of this same call -- nothing
  // here should ever surface as a visible error if the shell's IPC isn't
  // reachable for some reason.
  function _dismissOutstandingNotifications() {
    var omarchyPath = Quickshell.env("OMARCHY_PATH")
    for (var i = 0; i < cameraListStore.cameras.length; i++) {
      Quickshell.execDetached([omarchyPath + "/bin/omarchy-shell", "-q",
        "notifications", "dismiss", cameraListStore.cameras[i].displayName])
    }
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Nerd Font Font Awesome "video camera" glyph (nf-fa-video_camera, U+F03D).
    text: ""
    fontSize: Style.font.body
    horizontalMargin: 8
    tooltipText: root.unseenCount > 0 ? (root.unseenCount + " new camera event" + (root.unseenCount === 1 ? "" : "s")) : "Lookout"
    active: root.unseenCount > 0
    useActiveColor: true
    onPressed: root.togglePanel()

    Rectangle {
      id: unseenBadge
      visible: root.unseenCount > 0
      width: Math.max(Style.space(12), badgeText.implicitWidth + Style.space(4))
      height: Style.space(12)
      radius: height / 2
      color: root.hasUnseenPerson && settingsStore.strongerTintForPerson ? Color.urgent : Color.accent
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: -Style.space(2)
      anchors.topMargin: -Style.space(2)

      Text {
        id: badgeText
        anchors.centerIn: parent
        text: String(root.unseenCount)
        color: Color.background
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  IpcHandler {
    target: "jmthomas00.lookout"

    function open(): void { root.openPanel() }
    function close(): void { root.closePanel() }
    function toggle(): void { root.togglePanel() }
  }

  function _currentBarSection() {
    var layout = root.bar && root.bar.layoutConfig ? root.bar.layoutConfig : null
    if (!layout) return "center"
    var sections = ["left", "center", "right"]
    for (var i = 0; i < sections.length; i++) {
      var list = layout[sections[i]]
      if (!Array.isArray(list)) continue
      for (var j = 0; j < list.length; j++) {
        if (list[j] && list[j].id === root.moduleName) return sections[i]
      }
    }
    return "center"
  }
  readonly property string barSection: root._currentBarSection()

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    centerOnBar: root.barSection === "center"
    focusTarget: keyCatcher
    // Found live: this was hardcoded to "desire exactly 560" regardless of
    // what was actually loaded, so the popup's own border stayed pinned at
    // its widest possible size (matching the horizontal layout's own
    // width-capping math) even when the vertical layout, or a much smaller
    // thumbnail size, needed far less. contentHeight already measured the
    // loaded content's own implicitHeight -- width just needed the same
    // treatment: each view under contentLoader now exposes a real
    // implicitWidth (CameraGridPanel's genuinely varies with camera count/
    // orientation/thumbnail size; the other three views pin theirs to a
    // fixed width so they're unaffected).
    //
    // No fixed cap passed here -- per user request, the horizontal layout
    // should never wrap to a second row just because of an arbitrary width
    // ceiling. `fittedContentWidth` still clamps against the screen's own
    // available width on its own, so an unreasonable number of cameras/
    // thumbnail size still degrades gracefully (wraps) rather than running
    // off-screen -- this only removes the ARTIFICIAL ceiling that was
    // forcing a wrap well before the screen actually ran out of room.
    // contentHeight below got the same fix for the same reason, after a
    // tall vertical stack was found overflowing past the old 560 cap.
    //
    // `+ panel.padding * 2 + Border.left/right(...)`: found live that
    // without this, the actual content area ends up narrower than what was
    // asked for by exactly the card's own horizontal padding+border --
    // three 260px tiles (794px desired) rendered at only 758px of real
    // content width, just short enough to wrap to a second row.
    // `fittedContentHeight` already accounts for this on its own axis via
    // `verticalContentInset`; `fittedContentWidth` has no equivalent
    // horizontal counterpart, so it's added here explicitly.
    readonly property real _horizontalContentInset: panel.padding * 2
      + Border.left(panel.borderSpec) + Border.right(panel.borderSpec)
    contentWidth: panel.fittedContentWidth(
      (contentLoader.item ? contentLoader.item.implicitWidth : Style.space(320))
        + _horizontalContentInset)
    // No cap here either, for the same reason as contentWidth above --
    // found live that a tall vertical stack (3 large thumbnails) overflowed
    // past the popup's own visible bottom border once its natural height
    // exceeded the old fixed 560 ceiling: `fittedContentHeight` clamped the
    // POPUP's rendered size, but the Column inside laid out at its full,
    // un-clamped natural height regardless, so the extra content just
    // rendered past the border rather than actually being constrained by
    // it. `fittedContentHeight` still clamps against the screen's own
    // available height on its own, so this only removes the artificial
    // ceiling, not the real screen-edge safety net.
    contentHeight: panel.fittedContentHeight(
      contentLoader.item ? contentLoader.item.implicitHeight : Style.space(320))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.closePanel()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Loader {
        id: contentLoader
        anchors.fill: parent
        // Found live, independent of everything else changed today: a bare
        // Loader defaults `active` to true, so without this binding the
        // content behind whatever root._activeView resolved to (typically
        // "grid" once setup is complete) was being instantiated at SHELL
        // STARTUP -- not on first popup open -- and, just as importantly,
        // was NEVER destroyed on close (only hidden, since `panel.open`
        // only controls the popup surface's own visibility, not this
        // Loader). CameraGridPanel's Component.onDestruction is what calls
        // backendManager.release("grid"), so without this, that release
        // never fired and go2rtc ran indefinitely from the moment it first
        // started, for the rest of the session, regardless of the
        // idle-teardown setting -- confirmed live: still running 90+
        // seconds after closing the popup. Tying `active` to the popup's
        // own open state makes every view's acquire/release lifecycle
        // (grid's go2rtc ref, any future view's own resources) match its
        // actual on-screen lifetime, and is also just correct laziness:
        // nothing under this Loader exists at all until the user opens
        // the popup for the first time.
        active: panel.open
        // Pure declarative binding on root._activeView only -- nothing
        // outside this expression ever writes to sourceComponent directly.
        // Navigation instead sets root._manualView (see onSettingsRequested/
        // onBackRequested/onSignOutRequested below).
        sourceComponent: {
          switch (root._activeView) {
            case "error": return errorBannerComponent
            case "wizard": return setupWizardComponent
            case "settings": return settingsPanelComponent
            default: return cameraGridComponent
          }
        }
      }
    }
  }

  Component {
    id: errorBannerComponent
    ErrorBanner {
      reason: backendManager.backendState === "error" ? backendManager.errorReason
        : "go2rtc was not found. Install it from the AUR: go2rtc-bin"
      // Only the "not installed at all" case needs the generic install hint
      // -- every backendManager-reported failure reason (hash mismatch,
      // credential lookup, etc.) already states its own complete guidance
      // inline, and stacking the go2rtc hint under an unrelated reason
      // (e.g. a keyring failure) is confusing, not helpful.
      showGo2rtcHint: !root.go2rtcProbablyInstalled
      onRetryRequested: {
        backendManager.errorReason = ""
        backendManager.backendState = "stopped"
        go2rtcProbeProc.running = true
      }
    }
  }

  Component {
    id: setupWizardComponent
    SetupWizard {
      pluginDir: root.pluginDir
      credentialStoreRef: credentialStore
      cameraListStoreRef: cameraListStore
      setupStoreRef: setupStore
      reauthorizing: pubSubListener.authExpired
      onSetupCompleted: {
        pubSubListener.authExpired = false
        pubSubListener.start()
      }
    }
  }

  Component {
    id: cameraGridComponent
    CameraGridPanel {
      pluginDir: root.pluginDir
      backendManagerRef: backendManager
      cameraListStoreRef: cameraListStore
      eventStateStoreRef: eventStateStore
      settingsStoreRef: settingsStore
      onSettingsRequested: root._setManualView("settings")
    }
  }

  Component {
    id: settingsPanelComponent
    SettingsPanel {
      credentialStoreRef: credentialStore
      cameraListStoreRef: cameraListStore
      setupStoreRef: setupStore
      settingsStoreRef: settingsStore
      onBackRequested: root._setManualView("auto")
      onSignOutRequested: {
        backendManager.stop()
        pubSubListener.stop()
        setupStore.reset()
        // The view naturally recomputes to "wizard" once setupStore.completed
        // is false again -- no need to force a specific view here.
        root._setManualView("auto")
      }
    }
  }
}
