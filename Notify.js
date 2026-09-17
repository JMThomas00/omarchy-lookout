.pragma library

// Pure trait -> human text mapping and dedupe-window logic. No I/O here --
// EventStateStore.qml calls these to decide what to show and whether enough
// time has passed since the last notification for the same camera+trait.

var TRAIT_LABELS = {
  "CameraMotion": "Motion detected",
  "CameraPerson": "Person detected",
  "CameraSound": "Sound detected",
  "DoorbellChime": "Doorbell pressed"
}

function labelForTrait(trait) {
  return TRAIT_LABELS[trait] || (String(trait || "") + " event")
}

// Normalizes the SDM trait name ("CameraMotion", "CameraPerson",
// "CameraSound", "DoorbellChime") to the short keys EventStateStore/UI use.
function shortTrait(trait) {
  switch (String(trait || "")) {
    case "CameraMotion": return "motion"
    case "CameraPerson": return "person"
    case "CameraSound": return "sound"
    case "DoorbellChime": return "chime"
    default: return "other"
  }
}

// True once at least `windowSeconds` have elapsed since `lastNotifiedAtMs`
// (0 meaning "never notified for this camera+trait yet").
function pastDedupeWindow(lastNotifiedAtMs, windowSeconds, nowMs) {
  var last = Number(lastNotifiedAtMs) || 0
  if (last === 0) return true
  var elapsedSeconds = (Number(nowMs) - last) / 1000
  return elapsedSeconds >= Math.max(0, Number(windowSeconds) || 0)
}

function notificationTitle(cameraName, trait) {
  return String(cameraName || "Camera") + ": " + labelForTrait(trait)
}

// Compact label for the SHORT trait key (EventStateStore.byDevice's own
// keys -- "motion"/"person"/"sound"/"chime"), for a small on-tile summary
// rather than notificationTitle's fuller "Camera: X detected" phrasing.
var SHORT_TRAIT_LABELS = {
  motion: "Motion",
  person: "Person",
  sound: "Sound",
  chime: "Doorbell"
}

function labelForShortTrait(short) {
  return SHORT_TRAIT_LABELS[String(short || "")] || "Activity"
}

// Compact relative-time string for a tile overlay -- deliberately coarse
// (minutes/hours/days only), not a live-ticking countdown.
function timeAgo(sinceMs, nowMs) {
  var diffSeconds = Math.max(0, ((Number(nowMs) || Date.now()) - Number(sinceMs)) / 1000)
  if (diffSeconds < 60) return "just now"
  var minutes = Math.floor(diffSeconds / 60)
  if (minutes < 60) return minutes + (minutes === 1 ? " min ago" : " mins ago")
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + (hours === 1 ? " hour ago" : " hours ago")
  var days = Math.floor(hours / 24)
  return days + (days === 1 ? " day ago" : " days ago")
}
