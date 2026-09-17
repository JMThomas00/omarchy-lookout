import QtQuick
import Quickshell
import Quickshell.Io

// ~/.config/lookout/cameras.json -- non-secret per-camera display/notify
// prefs, discovered once during setup and editable afterward from
// SettingsPanel. Deliberately outside
// ~/.config/omarchy/plugins/lookout/ (this plugin's own watched source
// directory): writing state there fires a hot-reload that has previously
// torn down in-flight async work in this author's other plugins.
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: root.home + "/.config/lookout"
  readonly property string path: root.configDir + "/cameras.json"

  property bool loaded: false
  // [{deviceId, displayName, room, protocol, hidden, sortIndex,
  //   notify: {motion, person, sound, chime}}]
  property var cameras: []

  readonly property var visibleCamerasSorted: {
    var list = root.cameras.filter(function (c) { return !c.hidden })
    list.sort(function (a, b) { return (a.sortIndex || 0) - (b.sortIndex || 0) })
    return list
  }

  function cameraById(deviceId) {
    for (var i = 0; i < root.cameras.length; i++)
      if (root.cameras[i].deviceId === deviceId) return root.cameras[i]
    return null
  }

  // Called once after setup's devices.list discovery. Preserves any
  // existing per-camera prefs (hidden/sortIndex/notify) for a device id that
  // was already known -- a re-run of setup (re-authorize) shouldn't reset a
  // user's existing hide/reorder/notification choices.
  function replaceFromDiscovery(discovered) {
    var existingById = {}
    for (var i = 0; i < root.cameras.length; i++) existingById[root.cameras[i].deviceId] = root.cameras[i]
    var next = []
    for (var j = 0; j < discovered.length; j++) {
      var d = discovered[j]
      var existing = existingById[d.deviceId]
      next.push({
        deviceId: d.deviceId,
        displayName: existing ? existing.displayName : d.displayName,
        room: d.room,
        protocol: d.protocol,
        hidden: existing ? !!existing.hidden : false,
        sortIndex: existing ? existing.sortIndex : j,
        notify: existing ? existing.notify : { motion: true, person: true, sound: false, chime: true }
      })
    }
    root.cameras = next
    root._scheduleSave()
  }

  function setHidden(deviceId, hidden) {
    root.cameras = root.cameras.map(function (c) {
      return c.deviceId === deviceId ? Object.assign({}, c, { hidden: !!hidden }) : c
    })
    root._scheduleSave()
  }

  function setDisplayName(deviceId, name) {
    root.cameras = root.cameras.map(function (c) {
      return c.deviceId === deviceId ? Object.assign({}, c, { displayName: String(name || c.displayName) }) : c
    })
    root._scheduleSave()
  }

  function setSortIndex(deviceId, index) {
    root.cameras = root.cameras.map(function (c) {
      return c.deviceId === deviceId ? Object.assign({}, c, { sortIndex: index }) : c
    })
    root._scheduleSave()
  }

  function setNotifyTrait(deviceId, trait, enabled) {
    root.cameras = root.cameras.map(function (c) {
      if (c.deviceId !== deviceId) return c
      var notify = Object.assign({}, c.notify)
      notify[trait] = !!enabled
      return Object.assign({}, c, { notify: notify })
    })
    root._scheduleSave()
  }

  FileView {
    id: file
    path: root.path
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root._applyLoaded(text())
    onLoadFailed: root._applyLoaded("")
  }

  function _applyLoaded(raw) {
    if (root.loaded) return
    root.loaded = true
    try {
      var doc = JSON.parse(raw || "{}")
      root.cameras = Array.isArray(doc.cameras) ? doc.cameras : []
    } catch (e) {
      root.cameras = []
    }
  }

  Timer {
    id: saveTimer
    interval: 300
    repeat: false
    onTriggered: root._save()
  }

  function _scheduleSave() {
    if (!root.loaded) return
    saveTimer.restart()
  }

  function _save() {
    file.setText(JSON.stringify({ cameras: root.cameras }))
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.configDir]
    onExited: file.reload()
  }

  Component.onCompleted: mkdirProc.running = true
}
