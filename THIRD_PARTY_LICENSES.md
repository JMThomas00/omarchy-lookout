# Third-party code adapted into Lookout

Lookout is MIT-licensed (see `LICENSE`). A handful of files started from other
MIT-licensed Omarchy plugins, adapted rather than written from scratch, since
they already solve problems this plugin also has and have already been
through this marketplace's own security review. Their original copyright
notices are preserved here as MIT requires.

## `bin/supervise.sh`

Vendored essentially verbatim from **scoop.uptime-kuma**
(`~/.config/omarchy/plugins/scoop.uptime-kuma/bin/supervise.sh`):

```
MIT License
Copyright (c) 2026 Patrick Lenz
```

Puts a spawned helper in its own process group and turns one signal into a
bounded TERM-then-KILL for the whole group, confirming the group is actually
gone rather than assuming a signal worked. Used here, unmodified, to
supervise `go2rtc`, `bin/pubsub-listener.py`, and every short-lived helper
(`secret-tool`, `bin/go2rtc-verify.sh`).

## `BoundedProcess.qml`

Adapted from **scoop.uptime-kuma**'s `BoundedProcess.qml` (same copyright as
above), used here only for bounded, one-shot helpers -- the two genuinely
indefinite processes (`go2rtc`, the Pub/Sub listener) use a separate sibling
component, `SupervisedProcess.qml`, written for Lookout rather than adapted.

One addition beyond the original: a `lastExitCode` property, set inside the
component's own `onExited` handler immediately before it fires
`finishedWith`. `Quickshell.Io.Process` has no persistent `exitCode`
property (confirmed against its own qmltypes) -- only a signal parameter --
so a caller that instead tracked the exit code via its own separate
`Connections { function onExited() }` block was racing this literal
handler: QML connects a type's own literal signal handler before an
external `Connections` block declared at the instantiation site, so the
external listener's copy of the exit code was always one run stale by the
time `onFinishedWith` read it. This caused a real bug in Lookout's own
`CredentialStore.qml` (every keyring save falsely reported failure) --
fixed by exposing the exit code as a property set synchronously in the same
handler that fires `finishedWith`, removing the ordering dependency
entirely rather than trying to get the race "right."

## `bin/oauth-callback.py`, `bin/keyring-store.sh`, and `bin/pkce.sh`

Adapted from **io.github.jeremylanger.omaspotify**
(`~/.config/omarchy/plugins/io.github.jeremylanger.omaspotify/scripts/`):

```
MIT License
Copyright (c) 2026 Omarchy Spotify contributors
Copyright (c) 2026 OmaSpotify contributors
```

`oauth-callback.py`: the original only inspected the request path, since
Spotify's redirect carries everything needed there. Google's Device Access
redirect carries `code`/`state`/`error` as query parameters on the same
path, so Lookout's copy hands the whole accepted request line back to its
caller unmodified and lets QML (not this bounded, otherwise-dumb listener)
parse and validate the query string — same division of labor as the
original, just handling one more field. Byte budgets, per-connection
timeout, and signal handling are unchanged.

`keyring-store.sh`: unchanged in shape (stdin → `secret-tool store`, secret
never touches argv); Lookout stores one JSON blob under its own
`service lookout` attributes instead of OmaSpotify's per-`client-id`
refresh-token attributes, since Lookout's `client_id` is user-provided and
variable rather than a fixed public value.

`pkce.sh`: unchanged logic (verifier/challenge/state generation via
`openssl`). Google's Device Access OAuth client is a confidential "Web
application" type, so PKCE isn't strictly required the way it is for a
public client like Spotify's -- generated anyway as defense in depth.

## Everything else in this repository

Written for Lookout specifically, following (not copying) the architectural
conventions of `linecast`, `uplink`, and `waveform` (also this author's own
plugins): manifest schema, `Store` component shape, `Process` argv-array
discipline, and the hot-reload-safe state-directory convention.
