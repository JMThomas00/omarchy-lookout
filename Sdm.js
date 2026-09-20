.pragma library

// Thin REST wrappers around the Smart Device Management (SDM) API and the
// Pub/Sub subscription-management calls the setup wizard needs once. Every
// function here takes an already-valid access token and calls back with
// (ok, status, payload).
//
// Every function's first argument is an HttpRequester.qml instance, which is
// what actually makes the request: it runs each one in a bounded helper
// process (bin/http-request.py) that takes the request -- bearer token
// included -- over stdin only, never argv or the environment, and enforces
// the response-size ceiling and the deadline before QML sees anything. A
// timeout, network failure, or refused (oversized/disallowed) request comes
// back through the same callback as any other failure: ok=false, status=0,
// payload=null.

var SDM_BASE = "https://smartdevicemanagement.googleapis.com/v1"
var PUBSUB_BASE = "https://pubsub.googleapis.com/v1"

var CAMERA_TYPES = [
  "sdm.devices.types.CAMERA",
  "sdm.devices.types.DOORBELL",
  "sdm.devices.types.DISPLAY"
]

function _request(http, method, url, accessToken, body, callback) {
  var headers = { "Authorization": "Bearer " + accessToken }
  if (body !== undefined) headers["Content-Type"] = "application/json"
  http.request({
    method: method,
    url: url,
    headers: headers,
    body: body === undefined ? undefined : JSON.stringify(body)
  }, function (status, text) {
    var payload = null
    try { payload = JSON.parse(text || "{}") } catch (e) { payload = null }
    callback(status >= 200 && status < 300, status, payload)
  })
}

// Resolves each camera's supported live-stream protocol (webrtc vs rtsp)
// from its own trait set -- CameraLiveStream carries either
// supportedProtocols: ["WEB_RTC"] or ["RTSP"] depending on which app the
// camera is migrated to (see README's Requirements section). A camera with
// neither trait present is skipped: it isn't a live-viewable camera at all.
// Everything in the response is treated as untrusted input even though the
// body has already been size-capped by the helper process that fetched it
// (bin/http-request.py): a device count and every string that ends up in a
// file path, a go2rtc stream key, a notification, or the UI is bounded and
// shape-checked here, so a response that is merely small enough still can't
// smuggle in an unbounded list or a path/config-hostile identifier.
var MAX_DEVICES = 64
var MAX_NAME_CHARS = 100
// The FULL resource name, not just its last segment: taking only the tail of
// an arbitrary string would happily accept "anything/at/all/x" as device "x".
var DEVICE_NAME_PATTERN = /^enterprises\/[A-Za-z0-9_-]{1,128}\/devices\/([A-Za-z0-9_-]{1,256})$/

// Control characters, zero-width characters, and the bidirectional
// override/isolate controls (which can visually reorder or hide text, e.g. a
// name that DISPLAYS as something it isn't). None belong in a camera name;
// each becomes a plain space. Everything that renders these strings also
// forces Text.PlainText, so markup is never interpreted either -- this is
// the second layer, at ingestion.
var UNSAFE_NAME_CHARS = /[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]/g

function _boundedString(value, fallback) {
  var text = typeof value === "string" ? value.replace(UNSAFE_NAME_CHARS, " ").trim() : ""
  if (!text) return fallback
  return text.length > MAX_NAME_CHARS ? text.substring(0, MAX_NAME_CHARS) : text
}

function listCameras(http, accessToken, deviceAccessProjectId, callback) {
  var url = SDM_BASE + "/enterprises/" + encodeURIComponent(deviceAccessProjectId) + "/devices"
  _request(http, "GET", url, accessToken, undefined, function (ok, status, payload) {
    if (!ok || !payload) { callback(false, status, [], payload); return }
    var devices = Array.isArray(payload.devices) ? payload.devices : []
    var cameras = []
    var scanned = Math.min(devices.length, MAX_DEVICES)
    for (var i = 0; i < scanned; i++) {
      var device = devices[i]
      if (!device || typeof device !== "object") continue
      if (CAMERA_TYPES.indexOf(device.type) === -1) continue
      var traits = device.traits && typeof device.traits === "object" ? device.traits : {}
      var liveStream = traits["sdm.devices.traits.CameraLiveStream"]
      if (!liveStream) continue
      var protocols = Array.isArray(liveStream.supportedProtocols) ? liveStream.supportedProtocols : []
      var protocol = protocols.indexOf("WEB_RTC") !== -1 ? "webrtc"
        : (protocols.indexOf("RTSP") !== -1 ? "rtsp" : "")
      if (!protocol) continue
      // Device IDs become file names and go2rtc stream keys -- anything that
      // isn't exactly the documented resource-name shape, in the URL-safe
      // alphabet a real one uses, is dropped, not sanitized into something
      // that might collide with a real device.
      var nameMatch = DEVICE_NAME_PATTERN.exec(typeof device.name === "string" ? device.name : "")
      if (!nameMatch) continue
      var deviceId = nameMatch[1]
      var info = traits["sdm.devices.traits.Info"] || {}
      var roomInfo = traits["sdm.devices.traits.RoomInfo"] || {}
      var parent = Array.isArray(device.parentRelations) && device.parentRelations[0]
        ? device.parentRelations[0] : {}
      cameras.push({
        deviceId: deviceId,
        displayName: _boundedString(info.customName, _boundedString(parent.displayName, deviceId)),
        room: _boundedString(roomInfo.roomName, ""),
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

function createPullSubscription(http, accessToken, gcpProjectId, subscriptionName, topicName, callback) {
  // Google's subscriptions.create is actually PUT keyed by the full
  // resource name, not a POST with a body id.
  var putUrl = PUBSUB_BASE + "/projects/" + encodeURIComponent(gcpProjectId)
    + "/subscriptions/" + encodeURIComponent(subscriptionName)
  _request(http, "PUT", putUrl, accessToken, { topic: topicName }, callback)
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
function getSubscription(http, accessToken, gcpProjectId, subscriptionName, callback) {
  var url = PUBSUB_BASE + "/projects/" + encodeURIComponent(gcpProjectId)
    + "/subscriptions/" + encodeURIComponent(subscriptionName)
  _request(http, "GET", url, accessToken, undefined, callback)
}

function gcloudCreateCommand(gcpProjectId, subscriptionName, topicName) {
  return "gcloud pubsub subscriptions create " + subscriptionName
    + " --topic=" + topicName + " --project=" + gcpProjectId
}
