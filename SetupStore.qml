import QtQuick
import Quickshell
import Quickshell.Io

// ~/.config/lookout/setup.json -- non-secret setup state: project/topic/
// subscription ids and the loopback port to use for future re-auth. No
// secret ever lives here; the Google credential blob lives in the OS
// keyring (CredentialStore.qml).
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: root.home + "/.config/lookout"
  readonly property string path: root.configDir + "/setup.json"

  property bool loaded: false
  property bool completed: false
  property string deviceAccessProjectId: ""
  property string gcpProjectId: ""
  property string pubsubTopicId: ""
  property string pubsubSubscriptionName: "lookout-events"
  property int oauthPort: 8912

  function markComplete(fields) {
    root.deviceAccessProjectId = fields.deviceAccessProjectId
    root.gcpProjectId = fields.gcpProjectId
    root.pubsubTopicId = fields.pubsubTopicId
    root.pubsubSubscriptionName = fields.pubsubSubscriptionName || root.pubsubSubscriptionName
    root.oauthPort = fields.oauthPort || root.oauthPort
    root.completed = true
    root._save()
  }

  function reset() {
    root.completed = false
    root._save()
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
      root.completed = !!doc.completed
      root.deviceAccessProjectId = String(doc.deviceAccessProjectId || "")
      root.gcpProjectId = String(doc.gcpProjectId || "")
      root.pubsubTopicId = String(doc.pubsubTopicId || "")
      root.pubsubSubscriptionName = String(doc.pubsubSubscriptionName || "lookout-events")
      root.oauthPort = Number(doc.oauthPort) || 8912
    } catch (e) {
      // leave defaults
    }
  }

  function _save() {
    file.setText(JSON.stringify({
      completed: root.completed,
      deviceAccessProjectId: root.deviceAccessProjectId,
      gcpProjectId: root.gcpProjectId,
      pubsubTopicId: root.pubsubTopicId,
      pubsubSubscriptionName: root.pubsubSubscriptionName,
      oauthPort: root.oauthPort
    }))
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.configDir]
    onExited: file.reload()
  }

  Component.onCompleted: mkdirProc.running = true
}
