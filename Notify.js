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
