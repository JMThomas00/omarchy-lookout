import QtQuick
import Quickshell
import Quickshell.Io

// ~/.config/lookout/settings.json -- global (not per-camera) preferences.
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: root.home + "/.config/lookout"
  readonly property string path: root.configDir + "/settings.json"

  property bool loaded: false
  property bool notificationsEnabled: true
  property int dedupeWindowSeconds: 60
  property bool attachSnapshot: true
  property int idleTeardownSeconds: 15
  // Extra bar-icon tint strength for "person" vs. plain "motion" events.
  property bool strongerTintForPerson: true
  // Thumbnail tile width in pixels; height follows a fixed aspect ratio.
  property int thumbnailWidth: 180
  // "horizontal" (Flow, wraps) or "vertical" (single column).
  property string gridOrientation: "horizontal"

  readonly property int minThumbnailWidth: 100
  readonly property int maxThumbnailWidth: 360

  function _save() {
    file.setText(JSON.stringify({
      notificationsEnabled: root.notificationsEnabled,
      dedupeWindowSeconds: root.dedupeWindowSeconds,
      attachSnapshot: root.attachSnapshot,
      idleTeardownSeconds: root.idleTeardownSeconds,
      strongerTintForPerson: root.strongerTintForPerson,
      thumbnailWidth: root.thumbnailWidth,
      gridOrientation: root.gridOrientation
    }))
  }

  function setNotificationsEnabled(value) { root.notificationsEnabled = !!value; root._scheduleSave() }
  function setDedupeWindowSeconds(value) { root.dedupeWindowSeconds = Math.max(0, Number(value) || 0); root._scheduleSave() }
  function setAttachSnapshot(value) { root.attachSnapshot = !!value; root._scheduleSave() }
  function setIdleTeardownSeconds(value) { root.idleTeardownSeconds = Math.max(5, Number(value) || 15); root._scheduleSave() }
  function setStrongerTintForPerson(value) { root.strongerTintForPerson = !!value; root._scheduleSave() }
  function setThumbnailWidth(value) {
    root.thumbnailWidth = Math.max(root.minThumbnailWidth, Math.min(root.maxThumbnailWidth, Number(value) || 180))
    root._scheduleSave()
  }
  function setGridOrientation(value) {
    root.gridOrientation = value === "vertical" ? "vertical" : "horizontal"
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
      root.notificationsEnabled = doc.notificationsEnabled !== false
      root.dedupeWindowSeconds = Number(doc.dedupeWindowSeconds) || 60
      root.attachSnapshot = doc.attachSnapshot !== false
      root.idleTeardownSeconds = Math.max(5, Number(doc.idleTeardownSeconds) || 15)
      root.strongerTintForPerson = doc.strongerTintForPerson !== false
      root.thumbnailWidth = Math.max(root.minThumbnailWidth,
        Math.min(root.maxThumbnailWidth, Number(doc.thumbnailWidth) || 180))
      root.gridOrientation = doc.gridOrientation === "vertical" ? "vertical" : "horizontal"
    } catch (e) {
      // leave defaults
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

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.configDir]
    onExited: file.reload()
  }

  Component.onCompleted: mkdirProc.running = true
}
