import QtQuick

// The one place this plugin makes an HTTP request from QML. Each request runs
// through bin/http-request.py in its own bounded child process rather than
// QML's XMLHttpRequest, for two confirmed reasons:
//
// 1. XMLHttpRequest buffers the ENTIRE response body inside the shared
//    Quickshell process before any callback -- and so any size check -- can
//    run. A compromised endpoint or an oversized/chunked response could
//    exhaust the shell's memory first. The helper enforces the byte ceiling
//    (limit + 1 bytes, success AND error bodies, refused rather than
//    truncated) in the producer, and this component's BoundedProcess budget
//    caps what it may write back a second time.
// 2. `XMLHttpRequest.timeout` is accepted but never enforced by this Qt
//    build (tested against a socket that accepts and never answers), and QML
//    JS has no setTimeout. Here the deadline is enforced twice over: by the
//    helper's own wall-clock deadline, and by bin/supervise.sh killing the
//    whole process group if the helper itself is ever wedged.
//
// The request -- bearer token, client secret, refresh token and all -- is one
// JSON line written to the helper's stdin, never argv or the environment.
// The helper refuses any origin outside a short allowlist and any cross-
// origin redirect (see its own header for why).
Item {
  id: root

  property int defaultTimeoutMs: 20000

  // Mirrors the helper's own default (bin/http-request.py); every Google
  // response this plugin reads (a token, a subscription, a device list of a
  // handful of cameras) is a few KB at most.
  readonly property int maxResponseBytes: 262144
  // The helper writes JSON, and JSON escaping can expand a raw byte up to 6x
  // (a control character becomes \u00XX) -- the worst case for a response at
  // exactly the ceiling, plus a little for the envelope.
  readonly property int _maxOutputBytes: root.maxResponseBytes * 6 + 4096
  readonly property string _helper: Qt.resolvedUrl("bin/http-request.py").toString().replace("file://", "")

  // spec: {method, url, headers?: {name: value}, body?: string,
  //        timeoutMs?: number, discardBody?: bool}
  // callback(status, responseText, timedOut). status is 0 for anything
  // without a usable HTTP response (timeout, unreachable, refused as too
  // large or not allowlisted); timedOut distinguishes the deadline case.
  // Called exactly once per request. discardBody is for status-only checks
  // (the loopback go2rtc readiness poll): the body is never read at all.
  function request(spec, callback) {
    var timeoutMs = spec.timeoutMs > 0 ? spec.timeoutMs : root.defaultTimeoutMs
    var line = JSON.stringify({
      method: spec.method,
      url: spec.url,
      headers: spec.headers || {},
      body: spec.body === undefined || spec.body === null ? null : spec.body,
      timeout: timeoutMs / 1000,
      max_bytes: root.maxResponseBytes,
      discard_body: spec.discardBody === true
    })
    var settled = false
    var proc = processComponent.createObject(root, {
      program: [root._helper],
      // supervise.sh's group deadline is the backstop for a wedged helper,
      // so it sits a little past the helper's own deadline.
      deadlineSeconds: Math.ceil(timeoutMs / 1000) + 3,
      maxBytes: root._maxOutputBytes,
      stdinEnabled: true
    })

    function settle(status, text, timedOut) {
      if (settled) return
      settled = true
      proc.destroy()
      callback(status, text, timedOut)
    }

    // Through .connect (an external connection), not a literal onStarted:
    // BoundedProcess has its own literal onStarted that resets its budget
    // counters, and a literal handler here would replace it.
    proc.started.connect(function () { proc.write(line + "\n") })

    proc.finishedWith.connect(function (text, tooLarge) {
      if (tooLarge) { settle(0, "", false); return }
      var code = proc.lastExitCode
      // 124: supervise.sh's own deadline fired; 137/143: the group had to be
      // killed. Either way the helper never answered in time.
      if (code === 124 || code === 137 || code === 143) { settle(0, "", true); return }
      var result = null
      try { result = JSON.parse(String(text).trim()) } catch (e) { result = null }
      if (!result || typeof result.status !== "number") { settle(0, "", false); return }
      if (result.error) { settle(0, "", result.error === "timeout"); return }
      settle(result.status, typeof result.body === "string" ? result.body : "", false)
    })

    proc.running = true
  }

  Component {
    id: processComponent
    BoundedProcess {}
  }

  // Nothing here tears down an in-flight request when this component is
  // destroyed, on purpose: an explicit signal from QML cannot be made
  // reliable (Quickshell's Process destructor kills its direct child,
  // supervise.sh, immediately, racing any teardown and orphaning the helper
  // beneath it -- confirmed by sampling `ps` after destroying an owner
  // mid-request). Instead the helper exits by itself when the stdin pipe
  // this component holds open closes, which happens the instant the owner is
  // destroyed or Quickshell dies; see bin/http-request.py. No callback is
  // ever delivered for a destroyed owner's request.
}
