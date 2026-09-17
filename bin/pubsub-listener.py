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
"""

from __future__ import annotations

import base64
import json
import signal
import sys
import time
import urllib.error
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
HTTP_TIMEOUT_SECONDS = 20
TOKEN_REFRESH_MARGIN_SECONDS = 300

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


def _process_message(message):
    """Yield zero or more bounded event dicts for one Pub/Sub message."""
    try:
        data_raw = base64.b64decode(message.get("data", ""))
        body = json.loads(data_raw)
    except (ValueError, TypeError, json.JSONDecodeError):
        return
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
            for event in _process_message(message):
                _emit(event)
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
