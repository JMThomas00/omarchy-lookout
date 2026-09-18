import QtQuick
import Quickshell
import Quickshell.Io
import "Go2rtcConfigGen.js" as Go2rtcConfigGen

// Owns go2rtc's entire lifecycle: fail-closed binary verification before
// every single spawn, fresh config generation from the keyring on every
// start, and a refcounted start/stop so the grid popup and any number of
// floating views can come and go independently while go2rtc itself only
// ever runs when at least one of them actually needs it. See README.md's
// Security > Backend binding section for the verification rationale.
Item {
  id: root

  required property string pluginDir
  required property CredentialStore credentialStoreRef
  required property CameraListStore cameraListStoreRef
  required property SetupStore setupStoreRef
  required property SettingsStore settingsStoreRef

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: root.home + "/.local/state/lookout/go2rtc"
  readonly property string configPath: root.stateDir + "/go2rtc.yaml"
  readonly property string configTmpPath: root.stateDir + "/go2rtc.yaml.tmp"

  // "stopped" | "verifying" | "starting" | "running" | "error"
  property string backendState: "stopped"
  property string errorReason: ""
  property var _refs: []

  readonly property bool running: root.backendState === "running"

  function acquire(refName) {
    if (root._refs.indexOf(refName) === -1) root._refs = root._refs.concat([refName])
    idleTeardownTimer.stop()
    if (root.backendState === "stopped" || root.backendState === "error") root._beginStart()
  }

  function release(refName) {
    var idx = root._refs.indexOf(refName)
    if (idx === -1) return
    var next = root._refs.slice()
    next.splice(idx, 1)
    root._refs = next
    if (root._refs.length === 0 && root.backendState === "running") {
      idleTeardownTimer.interval = Math.max(5, root.settingsStoreRef.idleTeardownSeconds) * 1000
      idleTeardownTimer.restart()
    }
  }

  function thumbnailUrl(deviceId, cacheBust) {
    return "http://127.0.0.1:1984/api/frame.jpeg?src=" + encodeURIComponent("cam_" + deviceId)
      + "&t=" + encodeURIComponent(String(cacheBust || 0))
  }

  function rtspUrl(deviceId) {
    return "rtsp://127.0.0.1:8554/" + encodeURIComponent("cam_" + deviceId)
  }

  // --------------------------------------------------------------- snapshot
  //
  // One frame.jpeg fetch per camera per popup-open, not a continuous feed.
  // A prior version of this file kept a background ffmpeg process
  // continuously re-decoding each camera's RTSP restream to a local file
  // for a near-live (~1fps) thumbnail, plus a second background process
  // ("keyframe solicitor") just to keep go2rtc's RTSP restream fed at all
  // (see git history / [[omarchy_lookout_project]] for the full diagnostic
  // trail -- it worked, but needed real per-camera background processes,
  // retry-with-backoff logic, and still had a visible flicker on every
  // refresh). Simplified back to this after direct user feedback: a single
  // on-open snapshot, with the true live feed one click away in the
  // floating mpv view, is worth far less machinery than a "near-live"
  // thumbnail that still isn't actually live.
  //
  // The fetched file is saved to a fixed local path and, deliberately,
  // never deleted -- only ever overwritten by a NEW successful fetch (via
  // a temp file + atomic rename, so a failed/slow fetch can never corrupt
  // the last good frame). That's what makes CameraTile's very first read
  // on opening the popup instant: it just reads whatever's already there
  // from last time while this fetch runs in the background.

  readonly property string _snapshotDir: root.stateDir + "/live"
  signal snapshotFetched(string deviceId, bool ok)

  function _sanitizeDeviceId(deviceId) {
    return String(deviceId).replace(/[^A-Za-z0-9_-]/g, "_")
  }

  function snapshotPath(deviceId) {
    return root._snapshotDir + "/" + root._sanitizeDeviceId(deviceId) + ".jpg"
  }

  function snapshotUrl(deviceId, cacheBust) {
    return "file://" + root.snapshotPath(deviceId) + "?t=" + encodeURIComponent(String(cacheBust || 0))
  }

  Component { id: _snapshotFetchProcComponent; BoundedProcess {} }

  // Devices with a fetch already in flight -- guards against two callers
  // (a CameraTile's own retry and a notification's fresh-snapshot request,
  // or two notifications close together, e.g. motion then person on the
  // same camera) racing two curl processes against the SAME temp file
  // path, which could genuinely corrupt each other's write, not just
  // waste a redundant request. The second caller gets the same eventual
  // `snapshotFetched` broadcast as everyone else already listening for
  // this deviceId -- it doesn't need its own fetch to know the outcome.
  property var _snapshotFetchesInFlight: ({})

  // curl downloads to a temp file; only a successful (`&&`-gated) download
  // gets renamed over the real path, so a failed or cancelled fetch never
  // corrupts the last good cached frame. Positional args, not string
  // interpolation, for the same reason writeConfigProc below uses them --
  // nothing here is untrusted (deviceId is our own verified device list,
  // sanitized in snapshotPath above), but the pattern stays consistent
  // project-wide. 25s deadline: measured go2rtc's own frame.jpeg taking up
  // to ~26s in the worst case against this user's real cameras.
  function fetchSnapshot(deviceId) {
    if (root._snapshotFetchesInFlight[deviceId]) return
    var inFlight = Object.assign({}, root._snapshotFetchesInFlight)
    inFlight[deviceId] = true
    root._snapshotFetchesInFlight = inFlight

    var finalPath = root.snapshotPath(deviceId)
    var tmpPath = finalPath + ".tmp"
    var proc = _snapshotFetchProcComponent.createObject(root, { deadlineSeconds: 28, maxBytes: 4096 })
    proc.program = ["/usr/bin/bash", "-c",
      "mkdir -p -- \"$(dirname -- \"$1\")\" && curl -s -m 25 -o \"$1\" \"$2\" && mv -f -- \"$1\" \"$3\"",
      "_", tmpPath, root.thumbnailUrl(deviceId, Date.now()), finalPath]
    proc.finishedWith.connect(function (text, tooLarge) {
      var ok = !tooLarge && proc.lastExitCode === 0
      proc.destroy()
      var next = Object.assign({}, root._snapshotFetchesInFlight)
      delete next[deviceId]
      root._snapshotFetchesInFlight = next
      root.snapshotFetched(deviceId, ok)
    })
    proc.running = true
  }

  // ------------------------------------------------------------ floating view
  //
  // Tracked here (not in CameraGridPanel/CameraTile) because those are
  // recreated by a Loader every time the popup swaps content -- a floating
  // mpv window the user leaves open across a popup close/reopen still needs
  // "click the same tile again -> focus, don't duplicate" to work, which
  // means this map has to outlive the grid UI itself.

  readonly property string _mpvTitlePrefix: "lookout-cam-"
  property bool mpvAvailable: true
  property var _floatingViewByDevice: ({})
  signal floatingViewFailed(string reason)

  // Set true while a camera's mpv window is still negotiating and hasn't
  // mapped a real window yet -- RTSP negotiation against a live camera
  // measured ~7s real-world (go2rtc's own RTSP server rejects mpv's first
  // transport attempt with "461 Unsupported Transport", falls back, then
  // waits for the stream's next keyframe), with zero visual feedback
  // otherwise. Cleared on a fixed timeout rather than by detecting the
  // actual window map, to avoid adding a second polling loop for what's
  // purely a UX affordance.
  readonly property int _connectingTimeoutMs: 10000
  property var connectingDevices: ({})

  function _markConnecting(deviceId) {
    var next = Object.assign({}, root.connectingDevices)
    next[deviceId] = true
    root.connectingDevices = next
    var timer = _connectingTimeoutComponent.createObject(root, { deviceId: deviceId })
    timer.start()
  }

  function _clearConnecting(deviceId) {
    if (!root.connectingDevices[deviceId]) return
    var next = Object.assign({}, root.connectingDevices)
    delete next[deviceId]
    root.connectingDevices = next
  }

  Component {
    id: _connectingTimeoutComponent
    Timer {
      property string deviceId: ""
      interval: root._connectingTimeoutMs
      repeat: false
      onTriggered: { root._clearConnecting(deviceId); destroy() }
    }
  }

  Process {
    id: mpvProbeProc
    command: ["which", "mpv"]
    onExited: function (exitCode) { root.mpvAvailable = exitCode === 0 }
  }

  // Devices with an openFloatingView() call already acquired and waiting on
  // go2rtc to become ready -- distinct from _floatingViewByDevice, which
  // only gets an entry once _spawnMpv actually runs. Found on review (no
  // live report): without this, a second openFloatingView for the SAME
  // device landing in that gap (a rapid double-click, or a doorbell chime
  // racing a manual tile click) would fall through the
  // `existing && existing.running` check below -- since existing is still
  // undefined at that point -- and register a second backendStateChanged
  // listener, spawning two mpv processes for the same camera once go2rtc
  // came up.
  property var _pendingFloatingViews: ({})

  function openFloatingView(deviceId, displayName) {
    if (!root.mpvAvailable) {
      root.floatingViewFailed("mpv is not installed -- install it to view a full-size camera feed")
      return
    }
    var existing = root._floatingViewByDevice[deviceId]
    if (existing && existing.running) {
      root._runOnce(["hyprctl", "dispatch", "focuswindow",
        "title:^(" + root._mpvTitlePrefix + deviceId + ")$"])
      return
    }
    if (root._pendingFloatingViews[deviceId]) return
    root.acquire("view:" + deviceId)
    root._markConnecting(deviceId)
    if (root.running) {
      root._spawnMpv(deviceId)
      return
    }
    // go2rtc wasn't already warm (no grid popup or other floating view had
    // acquired it first) -- found live via the doorbell-chime auto-open
    // feature, which is always a cold call: mpv was being spawned
    // immediately, right alongside acquire() kicking off go2rtc's own
    // verify->spawn sequence, and connecting to 127.0.0.1:8554 before
    // go2rtc was actually listening on it. Confirmed directly (isolated
    // debug IPC calls + `ps` polling): mpv just exits immediately on
    // connection-refused rather than retrying, so the window never
    // appeared and nothing ever surfaced as a visible failure. This path
    // previously went unnoticed because every existing caller (tile
    // clicks) only becomes clickable after CameraGridPanel has already
    // acquired go2rtc on the grid's own Component.onCompleted, so go2rtc
    // was always already warm by the time a real click could happen.
    var pending = Object.assign({}, root._pendingFloatingViews)
    pending[deviceId] = true
    root._pendingFloatingViews = pending
    function onBackendStateChanged() {
      if (root.backendState === "running") {
        root.backendStateChanged.disconnect(onBackendStateChanged)
        root._clearPendingFloatingView(deviceId)
        // The view may have been released (popup closed, user backed out)
        // while this was waiting on go2rtc -- don't spawn a window for a
        // request that's no longer wanted.
        if (!root.connectingDevices[deviceId]) return
        root._spawnMpv(deviceId)
      } else if (root.backendState === "error") {
        root.backendStateChanged.disconnect(onBackendStateChanged)
        root._clearPendingFloatingView(deviceId)
        root._clearConnecting(deviceId)
        root.release("view:" + deviceId)
        root.floatingViewFailed(root.errorReason || "Could not start the camera bridge")
      }
    }
    root.backendStateChanged.connect(onBackendStateChanged)
  }

  function _clearPendingFloatingView(deviceId) {
    if (!root._pendingFloatingViews[deviceId]) return
    var pending = Object.assign({}, root._pendingFloatingViews)
    delete pending[deviceId]
    root._pendingFloatingViews = pending
  }

  function _spawnMpv(deviceId) {
    // A fresh Process per call, not a shared/reused instance -- clicking a
    // second tile while the first click's `hyprctl keyword` call was still
    // in flight could silently drop the second command entirely (reassigning
    // .command/.running on an already-running Process doesn't reliably
    // restart it), which would leave that camera's mpv window un-floated
    // and lost in the tiling layout instead of showing as a visible failure.
    // Found live: reported as "the third camera never opens" when the real
    // cause was rapid successive clicks racing this exact shared Process.
    root._runOnce(["hyprctl", "keyword", "windowrule",
      "float, title:^(" + root._mpvTitlePrefix + deviceId + ")$"])
    var proc = mpvProcComponent.createObject(root, {
      command: ["mpv", root.rtspUrl(deviceId), "--title=" + root._mpvTitlePrefix + deviceId,
        "--force-window=yes", "--really-quiet"]
    })
    var nextMap = Object.assign({}, root._floatingViewByDevice)
    nextMap[deviceId] = proc
    root._floatingViewByDevice = nextMap
    proc.exited.connect(function () {
      root.release("view:" + deviceId)
      root._clearConnecting(deviceId)
      var m = Object.assign({}, root._floatingViewByDevice)
      delete m[deviceId]
      root._floatingViewByDevice = m
      proc.destroy()
    })
    proc.running = true
  }

  Component { id: mpvProcComponent; Process {} }
  Component { id: _oneShotProcComponent; Process {} }

  // A brand-new Process per call -- see openFloatingView's own comment on
  // why a shared/reused instance is unsafe for calls that can happen in
  // rapid succession (one per tile, clicked quickly).
  function _runOnce(command) {
    var proc = _oneShotProcComponent.createObject(root, { command: command })
    proc.exited.connect(function () { proc.destroy() })
    proc.running = true
  }

  // ---------------------------------------------------------------- verify

  FileView {
    id: trustRootFile
    path: root.pluginDir + "/Go2rtcTrustRoot.json"
    watchChanges: false
    printErrors: false
  }

  function _trustRoot() {
    try { return JSON.parse(trustRootFile.text() || "{}") } catch (e) { return {} }
  }

  function _beginStart() {
    if (root.backendState === "verifying" || root.backendState === "starting") return
    root.backendState = "verifying"
    root.errorReason = ""
    verifyProc.program = [root.pluginDir + "/bin/go2rtc-verify.sh"]
    verifyProc.running = true
  }

  BoundedProcess {
    id: verifyProc
    deadlineSeconds: 8
    maxBytes: 4096
    onFinishedWith: function (text, tooLarge) {
      if (tooLarge) { root._fail("go2rtc verification produced too much output"); return }
      if (verifyProc.lastExitCode !== 0) { root._fail("go2rtc was not found. Install it from the AUR: go2rtc-bin"); return }
      var parts = String(text || "").trim().split(/\s+/)
      if (parts.length !== 3) { root._fail("go2rtc verification helper returned an unexpected result"); return }
      root._checkAgainstTrustRoot(parts[0], parts[1], parts[2])
    }
  }

  function _checkAgainstTrustRoot(arch, sha256, realPath) {
    var trustRoot = root._trustRoot()
    var asset = trustRoot.assets ? trustRoot.assets[arch] : null
    if (!asset || !asset.sha256) {
      root._fail("No trusted hash is pinned for architecture " + arch)
      return
    }
    // Case-insensitive: sha256sum's own output is lowercase hex, matched
    // exactly, but this guards against a trust-root file hand-edited with
    // different casing.
    if (String(asset.sha256).toLowerCase() !== String(sha256).toLowerCase()) {
      root._fail("Installed go2rtc does not match the pinned release hash. "
        + "Only the AUR go2rtc-bin package (prebuilt, byte-identical to upstream) "
        + "is supported -- a source-built go2rtc will not match.")
      return
    }
    // Captured from THIS verification pass, never cached across runs --
    // the next acquire() after a stop() re-verifies from scratch, matching
    // linecast's "cached OK is UX only, never authorization" rule.
    root.verifiedGo2rtcPath = realPath
    root._generateConfigAndSpawn()
  }

  function _fail(reason) {
    root.backendState = "error"
    root.errorReason = reason
  }

  // ----------------------------------------------------------- config+spawn

  function _generateConfigAndSpawn() {
    root.backendState = "starting"
    root.credentialStoreRef.lookupFinished.connect(root._onCredentialsForSpawn)
    root.credentialStoreRef.lookup()
  }

  function _onCredentialsForSpawn(ok, credentials) {
    root.credentialStoreRef.lookupFinished.disconnect(root._onCredentialsForSpawn)
    if (!ok || !credentials) {
      root._fail("Could not read Google credentials from the keyring. Try re-authorizing in Settings.")
      return
    }
    var cameras = root.cameraListStoreRef.cameras.filter(function (c) { return !c.hidden })
    if (cameras.length === 0) {
      root._fail("No cameras to show")
      return
    }
    var yaml = Go2rtcConfigGen.generateConfig(credentials, cameras, root.setupStoreRef.deviceAccessProjectId)
    // `cat > file` (or `base64 -d > file` fed directly from this process's
    // own stdin) blocks waiting for EOF, and Quickshell's Process has no
    // confirmed way to signal that -- verified the hard way elsewhere in
    // this author's own plugins (see uplink's DEV_TESTING.md: a Python
    // harness held a child's stdin open on purpose and confirmed `cat`
    // never returns, while `read -r`/`head -n1` do, on exactly one
    // newline-terminated line, no EOF needed). The YAML is multi-line, so
    // it's base64-encoded to a single line first (same trick already used
    // for the OAuth callback's HTML response elsewhere in this plugin) and
    // decoded on the other side of a `read -r`, never from the process's
    // own stdin stream directly.
    writeConfigProc.pendingWrite = Qt.btoa(yaml)
    // /usr/bin/bash, not a bare "bash" -- bin/supervise.sh requires an
    // absolute path for its own direct target and refuses to start
    // otherwise (see CredentialStore.qml's _secretTool comment for the
    // full explanation of this exact bug class, found live).
    writeConfigProc.program = ["/usr/bin/bash", "-c",
      "umask 077 && mkdir -p -- \"$1\" && IFS= read -r b64 "
      + "&& printf '%s' \"$b64\" | base64 -d > \"$2\" && mv -f -- \"$2\" \"$3\"",
      "_", root.stateDir, root.configTmpPath, root.configPath]
    writeConfigProc.running = true
  }

  BoundedProcess {
    id: writeConfigProc
    deadlineSeconds: 8
    maxBytes: 4096
    stdinEnabled: true
    property string pendingWrite: ""
    onFinishedWith: function (text, tooLarge) {
      if (tooLarge || writeConfigProc.lastExitCode !== 0) {
        root._fail("Could not write go2rtc's config file")
        return
      }
      root._spawnGo2rtc()
    }
  }

  Connections {
    target: writeConfigProc
    function onStarted() {
      // Trailing newline is what lets `read -r` on the other end return
      // without waiting for EOF -- see the comment where pendingWrite is set.
      writeConfigProc.write(writeConfigProc.pendingWrite + "\n")
      writeConfigProc.pendingWrite = ""
    }
  }

  function _spawnGo2rtc() {
    go2rtcProc.program = [verifiedGo2rtcPath, "-c", root.configPath]
    go2rtcProc.running = true
  }

  property string verifiedGo2rtcPath: ""

  // go2rtc is meant to run indefinitely, torn down explicitly by
  // refcount/idle-teardown, never by a timer -- see SupervisedProcess.qml.
  SupervisedProcess {
    id: go2rtcProc
  }

  // `Process.started` fires once the OS has forked/exec'd go2rtc, not once
  // go2rtc has finished its own internal init and actually bound its HTTP
  // listener -- found live: the very first thumbnail request(s) after a
  // fresh spawn raced ahead of that and failed with "Connection refused"
  // every time, only self-healing several retries and ~15+ seconds later
  // once go2rtc caught up. Declaring "running" only once a real request to
  // go2rtc's own API succeeds removes the race instead of just tolerating
  // it via retries.
  readonly property int _readinessMaxAttempts: 25
  property int _readinessAttempt: 0

  Connections {
    target: go2rtcProc
    function onStarted() {
      root._readinessAttempt = 0
      root._pollReadiness()
    }
    function onExited(exitCode) {
      readinessPollTimer.stop()
      if (root.backendState !== "stopped") {
        // go2rtc exited on its own (crash, killed externally) while we
        // still had refs -- surface it rather than silently sitting in a
        // "running" state nothing is actually backing.
        root._fail("go2rtc exited unexpectedly (code " + exitCode + ")")
      }
      root._removeConfig()
    }
  }

  function _pollReadiness() {
    if (!go2rtcProc.running) return
    root._readinessAttempt += 1
    // A per-attempt deadline, not just the overall attempt cap below: a
    // go2rtc that accepted the connection but never answered would
    // otherwise leave this poll chain (and backendState, stuck at
    // "starting") waiting forever, since no retry is scheduled until a
    // response or an error actually arrives. A timeout counts as a failed
    // attempt like any other (status 0).
    http.request({ method: "GET", url: "http://127.0.0.1:1984/api/streams", timeoutMs: 3000 },
      function (status) {
        if (!go2rtcProc.running) return
        if (status >= 200 && status < 300) {
          root.backendState = "running"
          return
        }
        root._scheduleReadinessRetry()
      })
  }

  HttpRequester { id: http }

  function _scheduleReadinessRetry() {
    if (root._readinessAttempt >= root._readinessMaxAttempts) {
      root._fail("go2rtc did not become ready in time")
      return
    }
    readinessPollTimer.restart()
  }

  Timer {
    id: readinessPollTimer
    interval: 200
    repeat: false
    onTriggered: root._pollReadiness()
  }

  function stop() {
    idleTeardownTimer.stop()
    readinessPollTimer.stop()
    if (go2rtcProc.running) go2rtcProc._tearDown()
    root.backendState = "stopped"
    root._removeConfig()
  }

  Timer {
    id: idleTeardownTimer
    interval: 15000
    repeat: false
    onTriggered: {
      if (root._refs.length === 0) root.stop()
    }
  }

  Process {
    id: removeConfigProc
    command: []
  }

  function _removeConfig() {
    removeConfigProc.command = ["rm", "-f", root.configPath, root.configTmpPath]
    removeConfigProc.running = true
  }

  Component.onCompleted: mpvProbeProc.running = true

  Component.onDestruction: {
    if (go2rtcProc.running) go2rtcProc._tearDown()
    for (var deviceId in root._floatingViewByDevice) {
      var proc = root._floatingViewByDevice[deviceId]
      if (proc && proc.running) proc.signal(15)
    }
  }
}
