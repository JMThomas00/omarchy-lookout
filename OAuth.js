.pragma library

// OAuth helpers for Google's Device Access authorization flow. Shaped after
// io.github.jeremylanger.omaspotify's OAuth.js/Api.js pair (MIT -- see
// THIRD_PARTY_LICENSES.md), adapted for the differences Device Access
// requires: a client_secret is unavoidably part of the token exchange
// (Device Access only supports "Web application" OAuth clients, which are
// confidential clients), the authorization endpoint is Device Access's own
// partner-connections page rather than a bare Google consent screen, and
// the callback's query string can carry an "error" the caller must surface.

var TOKEN_URL = "https://oauth2.googleapis.com/token"
var SCOPES = [
  "https://www.googleapis.com/auth/sdm.service",
  "https://www.googleapis.com/auth/pubsub"
]

function authUrl(deviceAccessProjectId, params) {
  var base = "https://nestservices.google.com/partnerconnections/"
    + encodeURIComponent(String(deviceAccessProjectId || "")) + "/auth"
  return appendQuery(base, params)
}

function normalizedPort(value) {
  var port = Math.floor(Number(value))
  return port >= 1024 && port <= 65535 ? port : 8912
}

function decode(value) {
  try { return decodeURIComponent(String(value || "").replace(/\+/g, " ")) }
  catch (e) { return "" }
}

function encode(value) {
  return encodeURIComponent(String(value === undefined || value === null ? "" : value))
}

function queryString(values) {
  var pairs = []
  for (var key in values) {
    if (values[key] === undefined || values[key] === null || values[key] === "") continue
    pairs.push(encode(key) + "=" + encode(values[key]))
  }
  return pairs.join("&")
}

function appendQuery(path, values) {
  var query = queryString(values)
  if (!query) return String(path || "")
  return String(path || "") + (String(path || "").indexOf("?") >= 0 ? "&" : "?") + query
}

function formBody(values) {
  return queryString(values)
}

function parseQuery(raw) {
  var result = {}
  var query = String(raw || "")
  if (query.charAt(0) === "?") query = query.substring(1)
  var parts = query.split("&")
  for (var i = 0; i < parts.length; i++) {
    if (!parts[i]) continue
    var separator = parts[i].indexOf("=")
    var key = separator < 0 ? parts[i] : parts[i].substring(0, separator)
    var value = separator < 0 ? "" : parts[i].substring(separator + 1)
    result[decode(key)] = decode(value)
  }
  return result
}

// Parses the raw request line bin/oauth-callback.py hands back (that
// listener only checks the path -- everything past "?" is untouched, and
// validated here, not there). Returns {ok, code, state, error} -- the
// caller (SetupWizard.qml) is responsible for comparing `state` against the
// value it generated before trusting `code` for anything.
function parseCallbackRequestLine(line, expectedPath) {
  var match = String(line || "").match(/^GET\s+([^\s]+)\s+HTTP\/\d(?:\.\d)?$/)
  if (!match) return { ok: false, error: "Invalid OAuth callback request" }
  var target = match[1]
  var separator = target.indexOf("?")
  var path = separator < 0 ? target : target.substring(0, separator)
  var requiredPath = String(expectedPath || "/oauth/callback")
  if (path !== requiredPath) return { ok: false, error: "Unexpected OAuth callback path" }
  var values = parseQuery(separator < 0 ? "" : target.substring(separator + 1))
  if (values.error) return { ok: false, error: values.error_description || values.error, state: values.state || "" }
  if (!values.code) return { ok: false, error: "Google did not return an authorization code", state: values.state || "" }
  return { ok: true, code: values.code, state: values.state || "" }
}

function parsePkceOutput(line) {
  var parts = String(line || "").trim().split("\t")
  if (parts.length !== 3) return { ok: false, error: "Could not create PKCE parameters" }
  if (!/^[A-Za-z0-9._~-]{43,128}$/.test(parts[0])) return { ok: false, error: "Invalid PKCE verifier" }
  if (!/^[A-Za-z0-9_-]{43,128}$/.test(parts[1])) return { ok: false, error: "Invalid PKCE challenge" }
  if (!/^[A-Fa-f0-9]{32,128}$/.test(parts[2])) return { ok: false, error: "Invalid OAuth state" }
  return { ok: true, verifier: parts[0], challenge: parts[1], state: parts[2] }
}

function parseJson(text, fallback) {
  try { return JSON.parse(text) } catch (e) { return fallback }
}

function redact(value) {
  var text = String(value || "")
  text = text.replace(/(authorization\s*:\s*bearer\s+)[^\s]+/ig, "$1<redacted>")
  text = text.replace(/(^|[?&\s])((?:code|access_token|refresh_token|code_verifier|client_secret|password)=)[^&#\s]+/ig, "$1$2<redacted>")
  text = text.replace(/("(?:access_token|refresh_token|code|code_verifier|client_secret|password)"\s*:\s*")[^"]+/ig, "$1<redacted>")
  return text
}

function responseError(status, payload, fallback) {
  var message = ""
  if (payload && typeof payload === "object") {
    if (typeof payload.error === "object" && payload.error) {
      message = payload.error.message || payload.error.status || ""
    } else if (typeof payload.error === "string") {
      message = payload.error_description || payload.error
    } else {
      message = payload.message || ""
    }
  }
  if (!message) message = fallback || "Google could not complete this request"
  return redact(message)
}

// Google's token endpoint response shape is the same for both the
// authorization_code and refresh_token grants used here.
function parseTokenResponse(status, text, previousRefreshToken) {
  var payload = parseJson(text, null)
  if (status < 200 || status >= 300 || !payload || !payload.access_token) {
    return {
      ok: false,
      invalidGrant: !!payload && payload.error === "invalid_grant",
      error: responseError(status, payload, "Could not complete Google sign-in. Please try again")
    }
  }
  return {
    ok: true,
    accessToken: String(payload.access_token),
    refreshToken: String(payload.refresh_token || previousRefreshToken || ""),
    expiresIn: Math.max(60, Number(payload.expires_in) || 3600)
  }
}

// Exchanges a stored refresh_token for a fresh access token, in-process
// (never a subprocess -- same rationale as _exchangeCode in SetupWizard.qml:
// nothing is safer than never spawning a process for a secret at all). Used
// by SettingsPanel.qml's "Test connection" button, which needs a live
// access token on demand and has no long-running listener process of its
// own to delegate to.
function refreshAccessToken(clientId, clientSecret, refreshToken, callback) {
  var body = formBody({
    client_id: clientId,
    client_secret: clientSecret,
    refresh_token: refreshToken,
    grant_type: "refresh_token"
  })
  var xhr = new XMLHttpRequest()
  xhr.onreadystatechange = function () {
    if (xhr.readyState !== XMLHttpRequest.DONE) return
    var result = parseTokenResponse(xhr.status, xhr.responseText, refreshToken)
    callback(result)
  }
  xhr.open("POST", TOKEN_URL)
  xhr.setRequestHeader("Content-Type", "application/x-www-form-urlencoded")
  xhr.send(body)
}

function successResponse() {
  var body = "<!doctype html><meta charset=\"utf-8\"><title>Lookout</title>"
    + "<style>:root{color-scheme:light dark}body{font-family:system-ui;background:Canvas;color:CanvasText;display:grid;place-items:center;height:100vh;margin:0}"
    + "main{max-width:32rem;padding:2rem;border:1px solid GrayText;border-radius:.5rem}</style>"
    + "<main><h1>Authorization complete</h1><p>Returning to Lookout…</p>"
    + "<p><small>If this tab stays open, it is safe to close.</small></p></main>"
    + "<script>setTimeout(function(){window.close()},150)</script>"
  return "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: "
    + body.length + "\r\nConnection: close\r\n\r\n" + body
}

function failureResponse() {
  var body = "<!doctype html><meta charset=\"utf-8\"><title>Authorization failed</title>"
    + "<p>Authorization failed. Return to Omarchy for details.</p>"
  return "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: "
    + body.length + "\r\nConnection: close\r\n\r\n" + body
}
