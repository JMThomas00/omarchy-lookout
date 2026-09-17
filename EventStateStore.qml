import QtQuick
import Quickshell
import Quickshell.Io
import "Notify.js" as Notify

// ~/.local/state/lookout/events.json -- per-device unseen counts, last-event
// timestamps, and a capped recent-event-id ring buffer so a Pub/Sub
// redelivery (see bin/pubsub-listener.py's own comment on emit-then-ack
// ordering) never double-counts the badge. Outside the watched plugin
// directory for the same hot-reload-safety reason as every other store here.
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: root.home + "/.local/state/lookout"
  readonly property string path: root.stateDir + "/events.json"
  // bin/pubsub-listener.py writes here directly (its own independent copy
  // of this exact path convention, since it's plain stdlib Python with no
  // access to this file) whenever an event carries a CameraClipPreview --
  // not every camera/event has one. See its own module docstring.
  readonly property string _clipDir: root.stateDir + "/last-event"

  readonly property int _maxRecentIds: 200

  property bool loaded: false
  // { "<deviceId>": { motion: {count, last}, person: {...}, sound: {...}, chime: {...} } }
  property var byDevice: ({})
  property int totalUnseen: 0
  property var recentEventIds: []
  // { "<deviceId>:<trait>": lastNotifiedAtMs } -- kept only in memory; a
  // restart re-arming the dedupe window for one event is an acceptable
  // trade against the complexity of persisting it too.
  property var _lastNotifiedAt: ({})

  signal notifiableEvent(string deviceId, string trait)

  // Returns true if this event was newly recorded (i.e. not a Pub/Sub
  // redelivery of one already seen).
  function recordEvent(deviceId, trait, eventId, tsMs) {
    if (root.recentEventIds.indexOf(eventId) !== -1) return false
    var ids = root.recentEventIds.concat([eventId])
    if (ids.length > root._maxRecentIds) ids = ids.slice(ids.length - root._maxRecentIds)
    root.recentEventIds = ids

    var short = Notify.shortTrait(trait)
    var device = Object.assign({}, root.byDevice[deviceId] || {})
    var bucket = Object.assign({ count: 0, last: 0 }, device[short] || {})
    bucket.count += 1
    bucket.last = tsMs || Date.now()
    device[short] = bucket
    var next = Object.assign({}, root.byDevice)
    next[deviceId] = device
    root.byDevice = next
    root.totalUnseen += 1
    root._scheduleSave()

    root.notifiableEvent(deviceId, trait)
    return true
  }

  function shouldNotify(deviceId, trait, windowSeconds) {
    var short = Notify.shortTrait(trait)
    var dedupeKey = deviceId + ":" + short
    var last = root._lastNotifiedAt[dedupeKey] || 0
    if (!Notify.pastDedupeWindow(last, windowSeconds, Date.now())) return false
    var updated = Object.assign({}, root._lastNotifiedAt)
    updated[dedupeKey] = Date.now()
    root._lastNotifiedAt = updated
    return true
  }

  // Opening the grid panel calls this: zeroes unseen counts, preserves
  // "last" timestamps so a tile can still show "last motion 2m ago".
  function markAllSeen() {
    var next = {}
    for (var deviceId in root.byDevice) {
      var device = root.byDevice[deviceId]
      var clearedDevice = {}
      for (var trait in device) {
        clearedDevice[trait] = { count: 0, last: device[trait].last }
      }
      next[deviceId] = clearedDevice
    }
    root.byDevice = next
    root.totalUnseen = 0
    root._scheduleSave()
  }

  function unseenCountForDevice(deviceId) {
    var device = root.byDevice[deviceId]
    if (!device) return 0
    var sum = 0
    for (var trait in device) sum += device[trait].count || 0
    return sum
  }

  function hasUnseenPersonForDevice(deviceId) {
    var device = root.byDevice[deviceId]
    return !!(device && device.person && device.person.count > 0)
  }

  // Most recent event across ALL traits for one camera, as
  // {trait, lastMs}, or null if this camera has never reported one.
  // markAllSeen() only zeroes counts, not `last`, so this still answers
  // correctly after the badge has been cleared -- that's the whole point
  // of keeping `last` separate from `count` in the stored shape.
  function _sanitizeDeviceId(deviceId) {
    return String(deviceId).replace(/[^A-Za-z0-9_-]/g, "_")
  }

  function lastEventClipPath(deviceId) {
    return root._clipDir + "/" + root._sanitizeDeviceId(deviceId) + ".mp4"
  }

  // No cache-busting query needed here, unlike the snapshot JPEGs
  // (BackendManager.snapshotUrl) -- that one exists specifically to defeat
  // Qt's pixmap cache for a QML `Image` source, which doesn't apply to
  // QtMultimedia's MediaPlayer/decoder pipeline. Each CameraTile instance
  // sets this once, at mount time, and gets whatever's on disk then.
  function lastEventClipUrl(deviceId) {
    return "file://" + root.lastEventClipPath(deviceId)
  }

  function lastEventForDevice(deviceId) {
    var device = root.byDevice[deviceId]
    if (!device) return null
    var bestTrait = null
    var bestLast = 0
    for (var trait in device) {
      var last = device[trait].last || 0
      if (last > bestLast) { bestLast = last; bestTrait = trait }
    }
    if (!bestTrait) return null
    return { trait: bestTrait, lastMs: bestLast }
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
      root.byDevice = doc.byDevice || {}
      root.totalUnseen = Number(doc.totalUnseen) || 0
      root.recentEventIds = Array.isArray(doc.recentEventIds) ? doc.recentEventIds : []
    } catch (e) {
      root.byDevice = {}
      root.totalUnseen = 0
      root.recentEventIds = []
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
    file.setText(JSON.stringify({
      byDevice: root.byDevice,
      totalUnseen: root.totalUnseen,
      recentEventIds: root.recentEventIds
    }))
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.stateDir]
    onExited: file.reload()
  }

  Component.onCompleted: mkdirProc.running = true
}
