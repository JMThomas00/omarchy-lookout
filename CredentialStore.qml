import QtQuick

// Owns the one keyring entry Lookout ever stores: a JSON blob of
// {clientId, clientSecret, refreshToken} under
// `service lookout kind google-credentials account default`. Nothing here
// ever puts a secret on argv -- lookup reads secret-tool's own stdout,
// store pipes the JSON in via stdin (bin/keyring-store.sh), clear passes
// no secret at all. All three are short-lived, bounded helpers.
//
// Exit codes are read via BoundedProcess's own `lastExitCode` property
// (set synchronously right before `finishedWith` fires) rather than a
// separately-tracked flag updated through a `Connections { onExited }`
// listener -- the latter is a real bug this file shipped with initially:
// QML connects a type's own literal signal handler (BoundedProcess.qml's
// internal onExited, which is what fires finishedWith) before an external
// Connections block declared here, so a flag updated only by that external
// listener was always one run stale by the time onFinishedWith read it --
// every keyring save falsely reported failure. See BoundedProcess.qml's own
// comment on `lastExitCode` for the full explanation.
//
// `onStarted:` still goes through Connections here (not a literal handler)
// -- BoundedProcess.qml has no internal onStarted logic of its own beyond
// resetting its budget counters, so there's no ordering hazard for that one,
// but a literal onStarted: here would still clobber that reset. Connections
// is the uniformly safe choice for any signal a caller wants to observe
// without owning the object's own declaration.
Item {
  id: root

  required property string pluginDir

  signal lookupFinished(bool ok, var credentials)
  signal storeFinished(bool ok)
  signal clearFinished(bool ok)

  // /usr/bin/secret-tool, not a bare "secret-tool" -- bin/supervise.sh
  // requires an absolute path for exactly the reason its own header comment
  // gives ("make sure PATH never gets to decide which secret-tool... is the
  // one holding a credential") and refuses to even start otherwise. A bare
  // command name here doesn't get resolved against PATH and fail loudly --
  // it fails supervise.sh's own usage check immediately (exit 64, no
  // secret-tool ever invoked), which silently looked identical to "no
  // credentials found" until traced directly.
  readonly property string _secretTool: "/usr/bin/secret-tool"

  function lookup() {
    if (lookupProc.running) return
    lookupProc.program = [root._secretTool, "lookup",
      "service", "lookout", "kind", "google-credentials", "account", "default"]
    lookupProc.running = true
  }

  function store(credentials) {
    if (storeProc.running) return
    storeProc._pendingWrite = JSON.stringify({
      client_id: credentials.clientId,
      client_secret: credentials.clientSecret,
      refresh_token: credentials.refreshToken
    })
    storeProc.program = [root.pluginDir + "/bin/keyring-store.sh"]
    storeProc.running = true
  }

  function clear() {
    if (clearProc.running) return
    clearProc.program = [root._secretTool, "clear",
      "service", "lookout", "kind", "google-credentials", "account", "default"]
    clearProc.running = true
  }

  BoundedProcess {
    id: lookupProc
    deadlineSeconds: 8
    maxBytes: 8192
    onFinishedWith: function (text, tooLarge) {
      if (tooLarge || lookupProc.lastExitCode !== 0) { root.lookupFinished(false, null); return }
      var trimmed = String(text || "").trim()
      if (!trimmed) { root.lookupFinished(false, null); return }
      var parsed = null
      try { parsed = JSON.parse(trimmed) } catch (e) { parsed = null }
      if (!parsed || !parsed.client_id || !parsed.client_secret || !parsed.refresh_token) {
        root.lookupFinished(false, null)
        return
      }
      root.lookupFinished(true, {
        clientId: String(parsed.client_id),
        clientSecret: String(parsed.client_secret),
        refreshToken: String(parsed.refresh_token)
      })
    }
  }

  BoundedProcess {
    id: storeProc
    deadlineSeconds: 8
    maxBytes: 4096
    stdinEnabled: true
    property string _pendingWrite: ""
    onFinishedWith: function (text, tooLarge) {
      root.storeFinished(!tooLarge && storeProc.lastExitCode === 0)
    }
  }

  Connections {
    target: storeProc
    function onStarted() {
      storeProc.write(storeProc._pendingWrite + "\n")
      storeProc._pendingWrite = ""
    }
  }

  BoundedProcess {
    id: clearProc
    deadlineSeconds: 8
    maxBytes: 4096
    onFinishedWith: function (text, tooLarge) {
      root.clearFinished(!tooLarge && clearProc.lastExitCode === 0)
    }
  }
}
