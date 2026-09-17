#!/usr/bin/env python3
"""Long-running Google Cloud Pub/Sub pull loop for Lookout camera events.

New for Lookout (not adapted from another plugin) -- stdlib only
(urllib.request/json/base64), deliberately no Google client library, so this
stays a small, fully-readable script rather than pulling in a dependency
tree this plugin's own review would then have to reason about too.

Startup: reads exactly one JSON line from stdin --
{"client_id","client_secret","refresh_token","gcp_project_id","subscription_name"}
-- and never re-reads credentials from disk or argv. Refreshes its own
OAuth access token from that refresh_token roughly every 45 minutes (well
inside the ~1 hour Google normally issues) or immediately on a 401, kept in
memory only.

Main loop: pull up to a bounded number of messages, emit ONE bounded JSON
line per camera event to stdout, flush, and only THEN acknowledge that
message -- a crash between emit and ack causes Pub/Sub redelivery, which the
QML-side EventStateStore de-dupes via a capped recent-event-id ring buffer,
so a redelivered message never double-counts. Pub/Sub pull is billed/limited
separately from the Smart Device Management API's own per-device command
quota, so running this continuously does not touch the low, battery-
protecting quota that governs live-stream commands.

Exit codes: 0 on a clean stop (SIGTERM/SIGINT/SIGHUP), 1 on an
unrecoverable local error (bad stdin, no network at all after all
attempts), 2 specifically on `invalid_grant` from a refresh attempt --
the caller (PubSubListener.qml) treats that one as "sign-in expired,
please re-authorize" rather than retrying forever.

Clip previews: a message that carries a CameraClipPreview.ClipPreview
trait (not every camera/event does -- it depends on the camera's own Nest
subscription/feature support) gets its short mp4 clip downloaded right
here, synchronously, using the same bearer access token as everything
else -- the previewUrl is short-lived, so this can't be deferred to
whenever the popup next opens. Saved to
~/.local/state/lookout/last-event/<deviceId>.mp4 (temp file + atomic
rename), overwritten by the next one, never accumulated. Best-effort: a
failed download is logged and otherwise ignored, never allowed to block
or drop the actual notification event it arrived alongside.
"""

from __future__ import annotations

import base64
import json
import os
import re
import signal
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TOKEN_URL = "https://oauth2.googleapis.com/token"
PUBSUB_BASE = "https://pubsub.googleapis.com/v1"

# One incoming stdin line (credentials) is small; this is generous headroom,
# not an expected size.
MAX_STDIN_LINE_BYTES = 8192
# Pub/Sub pull request/response bodies are bounded by MAX_MESSAGES below in
# practice, but a malformed/oversized response is refused outright rather
# than parsed.
MAX_RESPONSE_BYTES = 1024 * 1024
MAX_MESSAGES_PER_PULL = 20
# Drain quickly while there's a backlog; otherwise idle at this cadence.
EMPTY_PULL_SLEEP_SECONDS = 12
# How often a persistent pull failure (wrong subscription, permissions,
# ...) gets re-logged, so a real misconfiguration stays discoverable
# without flooding the journal on every 12s retry.
PULL_ERROR_LOG_INTERVAL_SECONDS = 600
HTTP_TIMEOUT_SECONDS = 20
TOKEN_REFRESH_MARGIN_SECONDS = 300

# CameraClipPreview.ClipPreview's previewUrl serves a short (SDM docs: "10
# frame") mp4 clip of the event -- generous but still bounded, since this is
# a real, externally-influenced download (Google's own CDN, but still not
# something to trust unboundedly).
MAX_CLIP_BYTES = 8 * 1024 * 1024
CLIP_HTTP_TIMEOUT_SECONDS = 15
LAST_EVENT_CLIP_DIR = os.path.expanduser("~/.local/state/lookout/last-event")
# previewUrl comes from the Pub/Sub message body -- externally-influenced
# content, even though reaching this code at all already requires access to
# this user's own GCP subscription. Restricting to exactly the one host
# Google's own docs specify (README.md's Security > Network boundary lists
# it) before ever attaching the live Bearer token is what keeps a
# malformed/spoofed previewUrl from being able to exfiltrate that token to
# an arbitrary host -- the fix a code-review pass on this exact pattern
# would ask for (see linecast's own review history: "validate full argument
# shapes, not just which function was called").
_ALLOWED_CLIP_HOST = "nest-camera-frontend.googleapis.com"

_stop_requested = False


def _handle_stop_signal(_signum, _frame):
    global _stop_requested
    _stop_requested = True


def _emit(obj):
    line = json.dumps(obj, separators=(",", ":"))
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def _log(message):
    print(f"pubsub-listener: {message}", file=sys.stderr, flush=True)


def _read_credentials():
    raw = sys.stdin.readline(MAX_STDIN_LINE_BYTES + 1)
    if not raw or len(raw) > MAX_STDIN_LINE_BYTES:
        _log("no credentials line on stdin (or it exceeded the size budget)")
        return None
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        _log("credentials line was not valid JSON")
        return None
    required = ("client_id", "client_secret", "refresh_token", "gcp_project_id", "subscription_name")
    if not all(isinstance(data.get(k), str) and data.get(k) for k in required):
        _log("credentials line was missing a required field")
        return None
    return data


def _http_post_form(url, fields, timeout=HTTP_TIMEOUT_SECONDS):
    body = "&".join(f"{k}={urllib.request.quote(str(v), safe='')}" for k, v in fields.items())
    request = urllib.request.Request(
        url, data=body.encode("utf-8"), method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    return _http_do(request, timeout)


def _http_post_json(url, payload, access_token, timeout=HTTP_TIMEOUT_SECONDS):
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url, data=body, method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {access_token}",
        },
    )
    return _http_do(request, timeout)


def _http_do(request, timeout):
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read(MAX_RESPONSE_BYTES + 1)
            if len(raw) > MAX_RESPONSE_BYTES:
                return 599, None
            return response.status, json.loads(raw or b"{}")
    except urllib.error.HTTPError as error:
        try:
            raw = error.read(MAX_RESPONSE_BYTES + 1)
            payload = json.loads(raw) if raw and len(raw) <= MAX_RESPONSE_BYTES else None
        except (json.JSONDecodeError, ValueError):
            payload = None
        return error.code, payload
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        _log(f"request failed: {error}")
        return 0, None


class TokenManager:
    """Refreshes and holds an access token in memory only."""

    def __init__(self, client_id, client_secret, refresh_token):
        self._client_id = client_id
        self._client_secret = client_secret
        self._refresh_token = refresh_token
        self._access_token = ""
        self._expires_at = 0.0
        self.fatal_auth_error = False  # set true on invalid_grant

    def ensure_fresh(self):
        if self._access_token and time.monotonic() < self._expires_at - TOKEN_REFRESH_MARGIN_SECONDS:
            return True
        return self._refresh()

    def force_refresh(self):
        return self._refresh()

    def _refresh(self):
        status, payload = _http_post_form(TOKEN_URL, {
            "client_id": self._client_id,
            "client_secret": self._client_secret,
            "refresh_token": self._refresh_token,
            "grant_type": "refresh_token",
        })
        if status == 200 and payload and payload.get("access_token"):
            self._access_token = payload["access_token"]
            self._expires_at = time.monotonic() + float(payload.get("expires_in", 3600))
            return True
        error_code = (payload or {}).get("error", "")
        if error_code == "invalid_grant":
            self.fatal_auth_error = True
        _log(f"token refresh failed (status={status}, error={error_code or 'unknown'})")
        return False

    @property
    def access_token(self):
        return self._access_token


def _device_id_from_resource_name(name):
    # Resource names look like "enterprises/<id>/devices/<device-id>" --
    # the tail segment is the stable per-device id this plugin keys on.
    return str(name or "").rstrip("/").rsplit("/", 1)[-1]


def _decode_message_body(message):
    try:
        data_raw = base64.b64decode(message.get("data", ""))
        return json.loads(data_raw)
    except (ValueError, TypeError, json.JSONDecodeError):
        return None


def _process_message(body):
    """Yield zero or more bounded event dicts for one already-decoded message body."""
    resource_update = body.get("resourceUpdate") or {}
    device_id = _device_id_from_resource_name(resource_update.get("name"))
    if not device_id:
        return
    events = resource_update.get("events") or {}
    timestamp = body.get("timestamp") or ""
    for trait_key, event_body in events.items():
        # e.g. "sdm.devices.events.CameraMotion.Motion" -> "CameraMotion"
        parts = str(trait_key).split(".")
        trait = parts[-2] if len(parts) >= 2 else str(trait_key)
        event_id = str((event_body or {}).get("eventId") or "")
        if not event_id:
            continue
        yield {
            "type": "event",
            "deviceId": device_id,
            "trait": trait,
            "eventId": event_id,
            "ts": timestamp,
        }


# Device IDs are Google's own opaque strings, but this is what ends up
# forming a local file path -- filtered the same way BackendManager.qml's
# own _sanitizeDeviceId does for the exact same reason, not because a real
# device id has ever contained anything else.
_SAFE_DEVICE_ID = re.compile(r"[^A-Za-z0-9_-]")


def _sanitize_device_id(device_id):
    return _SAFE_DEVICE_ID.sub("_", str(device_id or ""))


def _extract_clip_preview(body):
    """Returns (deviceId, previewUrl) if this message carries a clip preview, else (None, None)."""
    resource_update = body.get("resourceUpdate") or {}
    device_id = _device_id_from_resource_name(resource_update.get("name"))
    if not device_id:
        return None, None
    events = resource_update.get("events") or {}
    clip = events.get("sdm.devices.events.CameraClipPreview.ClipPreview")
    preview_url = (clip or {}).get("previewUrl")
    if not device_id or not preview_url:
        return None, None
    return device_id, str(preview_url)


def _download_clip_preview(preview_url, access_token, device_id):
    """Best-effort: a clip download failing must never interrupt the pull
    loop or drop the actual notification event it arrived alongside --
    this is a nice-to-have visual, not something to block on. previewUrl
    is authenticated with the SAME bearer access token as the SDM API
    itself, per Google's own docs (not Basic Auth against the OAuth client
    credentials, which was the first, wrong assumption here -- confirmed
    live: Basic Auth got a 401 "rejected", Bearer got a 404 "not found,
    but at least recognized" against an already-expired test URL)."""
    parsed = urllib.parse.urlsplit(preview_url)
    if parsed.scheme != "https" or parsed.hostname != _ALLOWED_CLIP_HOST:
        _log(f"clip preview for {device_id} had an unexpected URL host, refusing to attach a token to it")
        return
    try:
        os.makedirs(LAST_EVENT_CLIP_DIR, exist_ok=True, mode=0o700)
        request = urllib.request.Request(
            preview_url, headers={"Authorization": f"Bearer {access_token}"},
        )
        with urllib.request.urlopen(request, timeout=CLIP_HTTP_TIMEOUT_SECONDS) as response:
            raw = response.read(MAX_CLIP_BYTES + 1)
        if len(raw) > MAX_CLIP_BYTES:
            _log(f"clip preview for {device_id} exceeded the size budget, discarded")
            return
        final_path = os.path.join(LAST_EVENT_CLIP_DIR, _sanitize_device_id(device_id) + ".mp4")
        tmp_path = final_path + ".tmp"
        with open(tmp_path, "wb") as f:
            f.write(raw)
        os.replace(tmp_path, final_path)  # atomic on the same filesystem
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        _log(f"clip preview download failed for {device_id}: {error}")


def run(credentials):
    tokens = TokenManager(
        credentials["client_id"], credentials["client_secret"], credentials["refresh_token"],
    )
    project = credentials["gcp_project_id"]
    subscription = credentials["subscription_name"]
    pull_url = f"{PUBSUB_BASE}/projects/{project}/subscriptions/{subscription}:pull"
    ack_url = f"{PUBSUB_BASE}/projects/{project}/subscriptions/{subscription}:acknowledge"

    if not tokens.ensure_fresh():
        return 2 if tokens.fatal_auth_error else 1

    _emit({"type": "ready"})

    last_pull_error_logged_at = 0.0

    while not _stop_requested:
        if not tokens.ensure_fresh():
            return 2 if tokens.fatal_auth_error else 1

        status, payload = _http_post_json(
            pull_url, {"maxMessages": MAX_MESSAGES_PER_PULL}, tokens.access_token,
        )
        if status == 401:
            if not tokens.force_refresh():
                return 2 if tokens.fatal_auth_error else 1
            continue
        if status != 200 or payload is None:
            # Found live: a pull failure here (wrong/nonexistent
            # subscription name, permission error, ...) used to be
            # completely silent -- this loop just slept and retried
            # forever with nothing in any log to explain why no events
            # were ever arriving. A 404 on the wrong subscription name
            # went unnoticed for weeks of real camera events before being
            # found by manually querying the Pub/Sub API directly.
            # Throttled, not logged every attempt, so a genuinely broken
            # config doesn't spam the journal indefinitely.
            now = time.monotonic()
            if now - last_pull_error_logged_at > PULL_ERROR_LOG_INTERVAL_SECONDS:
                _log(f"pull failed (status={status}) against subscription "
                     f"'{subscription}' in project '{project}' -- check that this "
                     f"subscription actually exists and is bound to the right topic")
                last_pull_error_logged_at = now
            time.sleep(EMPTY_PULL_SLEEP_SECONDS)
            continue

        messages = payload.get("receivedMessages") or []
        if not messages:
            time.sleep(EMPTY_PULL_SLEEP_SECONDS)
            continue

        ack_ids = []
        for received in messages:
            ack_id = received.get("ackId")
            message = received.get("message") or {}
            body = _decode_message_body(message)
            if body is not None:
                for event in _process_message(body):
                    _emit(event)
                # Best-effort and synchronous, deliberately: previewUrl is
                # short-lived (SDM docs don't state an exact TTL, but it's
                # clearly minutes, not hours -- confirmed live against a
                # ~7-hour-old one), so this has to happen now, with the
                # access token already in hand, not deferred to whenever
                # the popup next opens.
                clip_device_id, preview_url = _extract_clip_preview(body)
                if clip_device_id and preview_url:
                    _download_clip_preview(preview_url, tokens.access_token, clip_device_id)
            if ack_id:
                ack_ids.append(ack_id)

        if ack_ids:
            _http_post_json(ack_url, {"ackIds": ack_ids}, tokens.access_token)
        # Non-empty pull: loop again immediately to drain any backlog.

    return 0


def main():
    for name in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(name, _handle_stop_signal)

    credentials = _read_credentials()
    if credentials is None:
        return 1

    try:
        return run(credentials)
    except Exception as error:  # noqa: BLE001 -- last-resort: report, exit, let the supervisor restart us
        _log(f"unhandled error: {error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
