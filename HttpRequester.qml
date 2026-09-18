import QtQuick

// The one place this plugin makes an HTTP request from QML. Every
// XMLHttpRequest here has a hard deadline and an explicit abort path, so a
// peer that accepts a connection and then never answers (or a network that
// silently drops packets) can't leave a credential-bearing OAuth/Google API
// call -- or whatever setup/readiness state is waiting on it -- hanging
// forever.
//
// Deliberately NOT `xhr.timeout`: confirmed directly against this Qt build
// (an isolated `qs -p` harness against a local socket that accepts and never
// responds) that the property reads back what you set but is never
// enforced -- no `ontimeout`, no state change, nothing, well past the
// deadline. An explicit abort() driven by a Timer is what actually works
// (readyState 4, status 0). QML JS also has no setTimeout, so this can't
// live in a .pragma library file -- Sdm.js/OAuth.js take an instance of this
// as an explicit argument instead of making requests themselves.
Item {
  id: root

  property int defaultTimeoutMs: 20000

  // spec: {method, url, headers?: {name: value}, body?: string, timeoutMs?}
  // callback(status, responseText, timedOut). status is 0 for anything
  // without an HTTP response at all (timeout, refused/unreachable, abort);
  // timedOut distinguishes the deadline case from the rest. Called exactly
  // once per request, never after this component has been destroyed.
  function request(spec, callback) {
    var xhr = new XMLHttpRequest()
    var settled = false
    var timedOut = false
    root._nextRequestId += 1
    var requestId = root._nextRequestId
    var timer = timeoutComponent.createObject(root, {
      interval: spec.timeoutMs > 0 ? spec.timeoutMs : root.defaultTimeoutMs
    })

    function settle(status, text) {
      if (settled) return
      settled = true
      timer.stop()
      timer.destroy()
      delete root._abortByRequest[requestId]
      callback(status, text, timedOut)
    }

    function abort(suppressCallback) {
      if (suppressCallback) settled = true
      xhr.abort()
    }

    root._abortByRequest[requestId] = abort

    timer.triggered.connect(function () {
      timedOut = true
      // Settle FIRST: abort() itself fires a DONE state change, which
      // settle() would otherwise report as a plain network error.
      settle(0, "")
      xhr.abort()
    })

    xhr.onreadystatechange = function () {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      settle(xhr.status, xhr.responseText)
    }

    xhr.open(spec.method, spec.url)
    var headers = spec.headers || {}
    for (var name in headers) xhr.setRequestHeader(name, headers[name])
    timer.start()
    if (spec.body !== undefined && spec.body !== null) xhr.send(spec.body)
    else xhr.send()
  }

  property int _nextRequestId: 0
  property var _abortByRequest: ({})

  Component {
    id: timeoutComponent
    Timer { repeat: false }
  }

  // A request still in flight when its owner goes away (the popup closing
  // mid-setup, the shell reloading) is aborted outright, not left running
  // with a callback pointing at a dead object.
  Component.onDestruction: {
    var pending = root._abortByRequest
    root._abortByRequest = ({})
    for (var id in pending) pending[id](true)
  }
}
