.pragma library

// Builds go2rtc's YAML config as plain text, entirely in JS -- never a shell
// template, never string concatenation that lets an untrusted value break
// out of its own field. Every scalar is emitted via a JSON string literal
// (a valid YAML flow scalar under both YAML 1.1 and 1.2), which is what
// makes this safe regardless of what characters a device id or a query
// value happens to contain: JSON.stringify's own escaping is exactly the
// escaping YAML expects for a double-quoted scalar.
//
// Every listener is bound to 127.0.0.1 only -- see README.md's Security >
// Network boundary section for why this is non-negotiable, not a default
// that happens to be safe.

function _yamlString(value) {
  return JSON.stringify(String(value === undefined || value === null ? "" : value))
}

function _nestStreamUrl(credentials, projectId, deviceId) {
  var params = [
    "client_id=" + encodeURIComponent(credentials.clientId),
    "client_secret=" + encodeURIComponent(credentials.clientSecret),
    "refresh_token=" + encodeURIComponent(credentials.refreshToken),
    "project_id=" + encodeURIComponent(projectId),
    "device_id=" + encodeURIComponent(deviceId)
  ]
  return "nest:?" + params.join("&")
}

// `credentials`: {clientId, clientSecret, refreshToken} from the keyring.
// `cameras`: [{deviceId, ...}] from CameraListStore.
// `dacProjectId`: the Device Access project id (not the GCP project id --
// go2rtc's nest source authenticates directly against Device Access).
function generateConfig(credentials, cameras, dacProjectId) {
  var lines = []
  lines.push("# Generated fresh by Lookout on every start -- never hand-edit.")
  lines.push("# Deleted on stop/idle-teardown; not a long-term source of truth.")
  lines.push("api:")
  lines.push("  listen: " + _yamlString("127.0.0.1:1984"))
  lines.push("rtsp:")
  lines.push("  listen: " + _yamlString("127.0.0.1:8554"))
  lines.push("webrtc:")
  lines.push("  listen: " + _yamlString("127.0.0.1:8555"))
  lines.push("streams:")
  for (var i = 0; i < cameras.length; i++) {
    var camera = cameras[i]
    var streamKey = "cam_" + camera.deviceId
    var streamUrl = _nestStreamUrl(credentials, dacProjectId, camera.deviceId)
    lines.push("  " + _yamlString(streamKey) + ": " + _yamlString(streamUrl))
  }
  return lines.join("\n") + "\n"
}
