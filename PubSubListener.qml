import QtQuick
import Quickshell.Io

// Owns the one indefinitely-running process this plugin has: the Pub/Sub
// pull loop. Independent of BackendManager/go2rtc and of the popup's own
// open/closed state -- this is what makes the bar badge and notifications
// work even when the grid has never been opened. Restarts itself with
// capped backoff on an unexpected exit; a fatal auth error (refresh token
// revoked/expired) stops it instead of looping forever, and is surfaced so
// the UI can prompt re-authorization.
Item {
  id: root

  required property string pluginDir
  required property CredentialStore credentialStoreRef
  required property SetupStore setupStoreRef
  required property EventStateStore eventStateStoreRef

  readonly property var _backoffStepsSeconds: [5, 15, 60, 300]
  property int _backoffIndex: 0
  property double _startedAtMs: 0
  // How long a run has to last before a subsequent failure resets the
  // backoff back to its shortest step -- otherwise one long-lived session
  // that eventually drops (network blip, laptop suspend) would face the
  // same long backoff as a persistently broken one.
  readonly property int _healthyRunThresholdMs: 60000

  property bool authExpired: false
  property bool active: false

  function start() {
    if (root.active) return
    root.active = true
    root.authExpired = false
    root._backoffIndex = 0
    root._beginRun()
  }

  function stop() {
    root.active = false
    restartTimer.stop()
    if (listenerProc.running) listenerProc._tearDown()
  }

  function _beginRun() {
    if (!root.active || root.authExpired) return
    root.credentialStoreRef.lookupFinished.connect(root._onCredentialsForRun)
    root.credentialStoreRef.lookup()
  }

  function _onCredentialsForRun(ok, credentials) {
    root.credentialStoreRef.lookupFinished.disconnect(root._onCredentialsForRun)
    if (!root.active) return
    if (!ok || !credentials) {
      // No process ever started this cycle -- reset _startedAtMs to now so
      // _scheduleRestart's "was this a healthy long run" check evaluates
      // against a fresh mark, not whatever a much-earlier successful run
      // left behind. Found on review: without this, a persistent keyring
      // failure (e.g. gnome-keyring not running) would see
      // `Date.now() - _startedAtMs` stay well past the 60s healthy
      // threshold forever, resetting backoff to its shortest step every
      // time and retrying every 5s indefinitely instead of backing off.
      root._startedAtMs = Date.now()
      root._scheduleRestart()
      return
    }
    listenerProc._pendingLine = JSON.stringify({
      client_id: credentials.clientId,
      client_secret: credentials.clientSecret,
      refresh_token: credentials.refreshToken,
      gcp_project_id: root.setupStoreRef.gcpProjectId,
      subscription_name: root.setupStoreRef.pubsubSubscriptionName
    })
    listenerProc.program = [root.pluginDir + "/bin/pubsub-listener.py"]
    listenerProc.running = true
  }

  // Meant to run indefinitely, stopped explicitly via stop() or restarted
  // by this component's own backoff logic, never by a timer -- see
  // SupervisedProcess.qml. This component owns stdout directly (a plain
  // line-splitting SplitParser), since SupervisedProcess has no generic
  // budget/accumulator logic of its own to route through.
  SupervisedProcess {
    id: listenerProc
    stdinEnabled: true
    property string _pendingLine: ""

    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (line) { root._handleLine(line) }
    }
  }

  Connections {
    target: listenerProc
    function onStarted() {
      root._startedAtMs = Date.now()
      listenerProc.write(listenerProc._pendingLine + "\n")
      listenerProc._pendingLine = ""
    }
    function onExited(exitCode) {
      if (!root.active) return
      if (exitCode === 2) {
        // Fatal auth error (invalid_grant) -- bin/pubsub-listener.py exits
        // 2 specifically for this, per its own docstring. Don't loop
        // forever retrying a refresh token that's been revoked.
        root.authExpired = true
        root.active = false
        return
      }
      root._scheduleRestart()
    }
  }

  // Bounded line length before JSON.parse -- this process's own stdout is
  // trusted-ish (it's this plugin's own helper script), but a length cap
  // here costs nothing and matches linecast's own byte-capped-relay
  // discipline for any subprocess output reaching JSON.parse.
  readonly property int _maxLineBytes: 4096

  function _handleLine(line) {
    if (String(line).length > root._maxLineBytes) return
    var parsed = null
    try { parsed = JSON.parse(line) } catch (e) { return }
    if (!parsed || typeof parsed !== "object") return
    if (parsed.type === "event" && parsed.deviceId && parsed.trait && parsed.eventId) {
      var tsMs = Date.parse(parsed.ts)
      root.eventStateStoreRef.recordEvent(String(parsed.deviceId), String(parsed.trait),
        String(parsed.eventId), isNaN(tsMs) ? Date.now() : tsMs)
    }
    // "ready" is purely informational; no action needed.
  }

  function _scheduleRestart() {
    var wasHealthy = (Date.now() - root._startedAtMs) >= root._healthyRunThresholdMs
    if (wasHealthy) root._backoffIndex = 0
    var delaySeconds = root._backoffStepsSeconds[Math.min(root._backoffIndex, root._backoffStepsSeconds.length - 1)]
    root._backoffIndex = Math.min(root._backoffIndex + 1, root._backoffStepsSeconds.length - 1)
    restartTimer.interval = delaySeconds * 1000
    restartTimer.restart()
  }

  Timer {
    id: restartTimer
    repeat: false
    onTriggered: root._beginRun()
  }

  Component.onDestruction: {
    if (listenerProc.running) listenerProc._tearDown()
  }
}
