.pragma library

// Thin REST wrappers around the Smart Device Management (SDM) API and the
// Pub/Sub subscription-management calls the setup wizard needs once. Every
// function here takes an already-valid access token and calls back with
// (ok, result) -- none of these ever touch a subprocess, so a bearer token
// never has a chance to land on any process's argv or environment.

var SDM_BASE = "https://smartdevicemanagement.googleapis.com/v1"
var PUBSUB_BASE = "https://pubsub.googleapis.com/v1"

var CAMERA_TYPES = [
  "sdm.devices.types.CAMERA",
  "sdm.devices.types.DOORBELL",
  "sdm.devices.types.DISPLAY"
]

function _request(method, url, accessToken, body, callback) {
  var xhr = new XMLHttpRequest()
  xhr.onreadystatechange = function () {
    if (xhr.readyState !== XMLHttpRequest.DONE) return
    var payload = null
    try { payload = JSON.parse(xhr.responseText || "{}") } catch (e) { payload = null }
    callback(xhr.status >= 200 && xhr.status < 300, xhr.status, payload)
  }
  xhr.open(method, url)
  xhr.setRequestHeader("Authorization", "Bearer " + accessToken)
  if (body !== undefined) {
    xhr.setRequestHeader("Content-Type", "application/json")
    xhr.send(JSON.stringify(body))
  } else {
    xhr.send()
  }
}

// Resolves each camera's supported live-stream protocol (webrtc vs rtsp)
// from its own trait set -- CameraLiveStream carries either
// supportedProtocols: ["WEB_RTC"] or ["RTSP"] depending on which app the
// camera is migrated to (see README's Requirements section). A camera with
// neither trait present is skipped: it isn't a live-viewable camera at all.
function listCameras(accessToken, deviceAccessProjectId, callback) {
  var url = SDM_BASE + "/enterprises/" + encodeURIComponent(deviceAccessProjectId) + "/devices"
  _request("GET", url, accessToken, undefined, function (ok, status, payload) {
    if (!ok || !payload) { callback(false, status, [], payload); return }
    var devices = payload.devices || []
    var cameras = []
    for (var i = 0; i < devices.length; i++) {
      var device = devices[i]
      if (CAMERA_TYPES.indexOf(device.type) === -1) continue
      var traits = device.traits || {}
      var liveStream = traits["sdm.devices.traits.CameraLiveStream"]
      if (!liveStream) continue
      var protocols = liveStream.supportedProtocols || []
      var protocol = protocols.indexOf("WEB_RTC") !== -1 ? "webrtc"
        : (protocols.indexOf("RTSP") !== -1 ? "rtsp" : "")
      if (!protocol) continue
      var nameParts = String(device.name || "").split("/")
      var deviceId = nameParts[nameParts.length - 1]
      if (!deviceId) continue
      var info = traits["sdm.devices.traits.Info"] || {}
      var roomInfo = traits["sdm.devices.traits.RoomInfo"] || {}
      cameras.push({
        deviceId: deviceId,
        displayName: info.customName || device.parentRelations && device.parentRelations[0]
          && device.parentRelations[0].displayName || deviceId,
        room: roomInfo.roomName || "",
        protocol: protocol
      })
    }
    callback(true, status, cameras)
  })
}

// Accepts either a bare topic id ("nest-events") or the full resource path
// ("projects/X/topics/nest-events") -- the Device Access Console's own
// "Enable events" field asks for the full path in exactly that format, so a
// user who pastes what THAT screen asked for should not end up with it
// doubled into "projects/X/topics/projects/X/topics/nest-events" here (a
// malformed resource name that fails subscription creation with a 400 --
// found live against a real Device Access project).
function normalizeTopicPath(gcpProjectId, topicIdOrPath) {
  var trimmed = String(topicIdOrPath || "").trim()
  if (trimmed.indexOf("projects/") === 0) return trimmed
  return "projects/" + gcpProjectId + "/topics/" + trimmed
}

function createPullSubscription(accessToken, gcpProjectId, subscriptionName, topicName, callback) {
  var url = PUBSUB_BASE + "/projects/" + encodeURIComponent(gcpProjectId)
    + "/subscriptions/" + encodeURIComponent(subscriptionName) + ":create"
  // Google's subscriptions.create is actually PUT keyed by the full
  // resource name, not a POST with a body id -- passing "name" in the body
  // documents intent even though the URL is what addresses it.
  var putUrl = PUBSUB_BASE + "/projects/" + encodeURIComponent(gcpProjectId)
    + "/subscriptions/" + encodeURIComponent(subscriptionName)
  var xhr = new XMLHttpRequest()
  xhr.onreadystatechange = function () {
    if (xhr.readyState !== XMLHttpRequest.DONE) return
    var payload = null
    try { payload = JSON.parse(xhr.responseText || "{}") } catch (e) { payload = null }
    callback(xhr.status >= 200 && xhr.status < 300, xhr.status, payload)
  }
  xhr.open("PUT", putUrl)
  xhr.setRequestHeader("Authorization", "Bearer " + accessToken)
  xhr.setRequestHeader("Content-Type", "application/json")
  xhr.send(JSON.stringify({ topic: topicName }))
}

// Used to VERIFY a subscription name actually resolves to something real
// before trusting it -- see SetupWizard.qml's skipSubscription() for why:
// found live that "Skip" previously just recorded whatever name had been
// GUESSED/attempted, with no check that a subscription by that name
// actually existed. In this exact case the user's own manual
// gcloud/Console subscription creation ended up named differently than
// the guess, so the recorded name pointed at nothing -- the listener
// pulled a 404 forever, silently, with zero visible notifications for
// weeks of real camera events.
function getSubscription(accessToken, gcpProjectId, subscriptionName, callback) {
  var url = PUBSUB_BASE + "/projects/" + encodeURIComponent(gcpProjectId)
    + "/subscriptions/" + encodeURIComponent(subscriptionName)
  _request("GET", url, accessToken, undefined, callback)
}

function gcloudCreateCommand(gcpProjectId, subscriptionName, topicName) {
  return "gcloud pubsub subscriptions create " + subscriptionName
    + " --topic=" + topicName + " --project=" + gcpProjectId
}
