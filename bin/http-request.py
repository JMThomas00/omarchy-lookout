#!/usr/bin/env python3
"""One bounded HTTP request on behalf of Lookout's QML side.

Every credential-bearing request the QML code makes (OAuth token exchange and
refresh, camera discovery, Pub/Sub subscription create/verify) runs through
this helper instead of QML's own XMLHttpRequest, for one reason: an
XMLHttpRequest buffers the ENTIRE response body inside the shared Quickshell
process before any callback (and so any size check) can run, so a compromised
endpoint or an oversized/chunked response could exhaust the shell's memory
first. Here the ceiling is enforced by the producer, before Quickshell ever
sees a byte -- and again by HttpRequester.qml's BoundedProcess budget on this
process's own output.

Protocol: exactly one JSON line on stdin --
  {"method": "GET"|"POST"|"PUT", "url": "...", "headers": {...},
   "body": "...", "timeout": seconds, "max_bytes": n, "discard_body": bool}
-- and exactly one JSON line on stdout --
  {"status": <http status>, "body": "<text>"}            on any HTTP response
  {"status": 0, "error": "timeout|too_large|network|rejected"}  otherwise.
The request line carries the bearer token / client secret / refresh token, so
it only ever crosses the process boundary over stdin, never argv or the
environment, and this script never logs it.

Fail-closed on everything the caller can influence:
  * the origin must be exactly one of a short allowlist (three Google API
    hosts over https, plus go2rtc's own loopback readiness endpoint, which is
    GET-only and never has its body read);
  * only Authorization and Content-Type headers, no CR/LF in any value;
  * redirects are only followed within the ORIGINAL origin. Stock urllib
    forwards the Authorization header to whatever host a redirect names --
    confirmed, not assumed -- which would hand the live token to any host a
    compromised endpoint pointed at;
  * nothing outlives its caller: the caller must keep stdin OPEN until it has
    its answer, and this exits the moment stdin reaches EOF. When the owning
    QML object is destroyed mid-request (or Quickshell itself dies), the
    kernel closes that pipe -- this is the only reliable signal available,
    because Quickshell's Process destructor kills its direct child
    (supervise.sh) outright, before that child can run its own group
    cleanup, and would otherwise orphan this process until its deadline
    (found by sampling `ps` after destroying an owner mid-request);
  * the response is read in chunks, never more than max_bytes + 1, under an
    overall wall-clock deadline (a per-socket-operation timeout alone doesn't
    stop a slow-drip response), for BOTH success and error bodies. Reaching
    max_bytes + 1 is a refusal (status 0, "too_large") -- an oversized answer
    is never truncated and handed to a JSON parser.
"""

from __future__ import annotations

import http.client
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

MAX_REQUEST_LINE_BYTES = 64 * 1024
MAX_REQUEST_BODY_BYTES = 32 * 1024
MAX_HEADER_VALUE_BYTES = 4096
HARD_MAX_RESPONSE_BYTES = 1024 * 1024
DEFAULT_MAX_RESPONSE_BYTES = 256 * 1024
DEFAULT_TIMEOUT_SECONDS = 20.0
MAX_TIMEOUT_SECONDS = 30.0
READ_CHUNK_BYTES = 8192

# (scheme, hostname, port) -- exact match, no suffix/wildcard matching.
ALLOWED_ORIGINS = {
    ("https", "oauth2.googleapis.com", 443),
    ("https", "smartdevicemanagement.googleapis.com", 443),
    ("https", "pubsub.googleapis.com", 443),
}
# go2rtc's own readiness endpoint. Status only -- its body lists every stream
# source URL, credentials included, and must never enter this process's output.
LOOPBACK_READINESS_ORIGIN = ("http", "127.0.0.1", 1984)

ALLOWED_METHODS = {"GET", "POST", "PUT"}
ALLOWED_HEADERS = {"authorization": "Authorization", "content-type": "Content-Type"}


class Rejected(Exception):
    """The request itself is not something this helper will send."""


def _origin(url):
    parts = urllib.parse.urlsplit(url)
    if parts.username is not None or parts.password is not None:
        raise Rejected("credentials in url")
    try:
        port = parts.port
    except ValueError as error:
        raise Rejected("bad port") from error
    if port is None:
        port = 443 if parts.scheme == "https" else 80
    return (parts.scheme, (parts.hostname or "").lower(), port)


class _SameOriginRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        try:
            same = _origin(newurl) == _origin(req.full_url)
        except Rejected:
            same = False
        if not same:
            return None  # urllib then raises HTTPError for the 3xx itself
        return super().redirect_request(req, fp, code, msg, headers, newurl)


# ProxyHandler({}) explicitly: no proxy environment variable may reroute a
# credential-bearing request (the caller clears the environment as well;
# this doesn't rely on that).
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}), _SameOriginRedirect)


def _validate(spec):
    if not isinstance(spec, dict):
        raise Rejected("request is not an object")
    method = spec.get("method")
    if method not in ALLOWED_METHODS:
        raise Rejected("method")
    url = spec.get("url")
    if not isinstance(url, str) or len(url) > 2048:
        raise Rejected("url")
    discard_body = spec.get("discard_body") is True
    origin = _origin(url)
    if origin not in ALLOWED_ORIGINS:
        if not (origin == LOOPBACK_READINESS_ORIGIN and method == "GET" and discard_body):
            raise Rejected("origin not allowed")

    headers = {}
    raw_headers = spec.get("headers") or {}
    if not isinstance(raw_headers, dict):
        raise Rejected("headers")
    for name, value in raw_headers.items():
        canonical = ALLOWED_HEADERS.get(str(name).lower())
        if canonical is None:
            raise Rejected("header not allowed")
        if not isinstance(value, str) or len(value) > MAX_HEADER_VALUE_BYTES \
                or "\r" in value or "\n" in value:
            raise Rejected("header value")
        headers[canonical] = value

    body = spec.get("body")
    if body is None:
        body_bytes = None
    elif isinstance(body, str) and len(body.encode("utf-8")) <= MAX_REQUEST_BODY_BYTES:
        body_bytes = body.encode("utf-8")
    else:
        raise Rejected("body")

    try:
        timeout = float(spec.get("timeout", DEFAULT_TIMEOUT_SECONDS))
    except (TypeError, ValueError) as error:
        raise Rejected("timeout") from error
    timeout = min(max(timeout, 1.0), MAX_TIMEOUT_SECONDS)
    try:
        max_bytes = int(spec.get("max_bytes", DEFAULT_MAX_RESPONSE_BYTES))
    except (TypeError, ValueError) as error:
        raise Rejected("max_bytes") from error
    max_bytes = min(max(max_bytes, 1), HARD_MAX_RESPONSE_BYTES)

    return method, url, headers, body_bytes, timeout, max_bytes, discard_body


def _read_bounded(stream, max_bytes, deadline):
    """(bytes, "ok"|"too_large"|"timeout"). Reads at most max_bytes + 1."""
    chunks = []
    total = 0
    # read1, not read: read(n) blocks until all n bytes arrive, so a
    # slow-drip response (a byte at a time, each inside the per-socket
    # timeout) would never let the wall-clock check below run. read1 returns
    # whatever one recv produced.
    read = getattr(stream, "read1", stream.read)
    while True:
        if time.monotonic() >= deadline:
            return b"", "timeout"
        want = min(READ_CHUNK_BYTES, max_bytes + 1 - total)
        chunk = read(want)
        if not chunk:
            return b"".join(chunks), "ok"
        total += len(chunk)
        if total > max_bytes:
            return b"", "too_large"
        chunks.append(chunk)


def perform(spec):
    """Run one request; always returns the result dict, never raises."""
    try:
        method, url, headers, body, timeout, max_bytes, discard_body = _validate(spec)
    except Rejected:
        return {"status": 0, "error": "rejected"}

    deadline = time.monotonic() + timeout
    request = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        try:
            with _OPENER.open(request, timeout=timeout) as response:
                status = response.status
                if discard_body:
                    return {"status": status, "body": ""}
                raw, outcome = _read_bounded(response, max_bytes, deadline)
        except urllib.error.HTTPError as error:
            # Error bodies get exactly the same ceiling as success bodies.
            status = error.code
            if discard_body:
                return {"status": status, "body": ""}
            raw, outcome = _read_bounded(error, max_bytes, deadline)
    except (urllib.error.URLError, TimeoutError, OSError, ValueError, http.client.HTTPException) as error:
        reason = getattr(error, "reason", error)
        timed_out = isinstance(error, TimeoutError) or isinstance(reason, TimeoutError) \
            or "timed out" in str(reason).lower()
        return {"status": 0, "error": "timeout" if timed_out else "network"}

    if outcome != "ok":
        return {"status": 0, "error": outcome}
    return {"status": status, "body": raw.decode("utf-8", errors="replace")}


# Set BEFORE the answer is written: an EOF that arrives after this point is
# ignored (the caller is already gone or about to be, and this process is
# about to exit 0 on its own), so the exit status is deterministic instead of
# depending on who wins a race around the final write.
_answering = threading.Event()


def _exit_when_caller_goes_away():
    try:
        while sys.stdin.buffer.read(4096):
            pass
    except (OSError, ValueError):
        pass
    if not _answering.is_set():
        os._exit(3)


def main():
    line = sys.stdin.buffer.readline(MAX_REQUEST_LINE_BYTES + 1)
    threading.Thread(target=_exit_when_caller_goes_away, daemon=True).start()
    if not line or len(line) > MAX_REQUEST_LINE_BYTES:
        result = {"status": 0, "error": "rejected"}
    else:
        try:
            result = perform(json.loads(line.decode("utf-8")))
        except (UnicodeDecodeError, json.JSONDecodeError):
            result = {"status": 0, "error": "rejected"}
    _answering.set()
    sys.stdout.write(json.dumps(result, separators=(",", ":")) + "\n")
    sys.stdout.flush()
    # Exit right here rather than returning, so the watcher thread can never
    # race interpreter shutdown either.
    os._exit(0)


if __name__ == "__main__":
    main()
