# Lookout for Omarchy

A live thumbnail grid for your Google Home/Nest cameras, right from the
Omarchy bar. Click the icon for a grid of live snapshots, click a tile for a
floating full-size live view, and get a bar badge plus a desktop
notification whenever a camera sees motion or a person -- which clears the
moment you open the grid.

## Features

- **One-time sign-in.** Associate your Google account once during setup;
  Lookout keeps a refresh token in your OS keyring after that.
- **Live thumbnail grid**, one tile per camera/doorbell, refreshed only
  while the popup is open -- see [Requirements](#requirements) and
  [How it works](#how-it-works) for why.
- **Floating live view.** Click a tile for a full-size, real-time feed in
  its own floating window. Click the same tile again to focus that window
  instead of opening a second one.
- **Bar badge + notifications.** A per-camera, per-event-type (motion,
  person, sound, doorbell chime) unseen counter drives both a bar badge and
  a native desktop notification, independent of whether the grid has ever
  been opened. Opening the grid clears the badge and dismisses any of this
  plugin's own outstanding notifications. Each notification can optionally
  attach a fresh snapshot of that camera, fetched at the moment of the
  event (Settings -- on by default).
- **Auto-open on doorbell.** A doorbell chime is different from the other
  event types -- someone is standing there right now -- so by default it
  jumps straight to that camera's floating live view instead of waiting for
  a bar-badge click (Settings -- per-camera and globally toggleable).
- **Test connection.** A button in Settings that verifies Google sign-in
  and your Pub/Sub subscription right now, without waiting for a real
  camera event, so a broken setup shows up immediately instead of as
  "notifications just never happen."

## Requirements

### Dependencies

- [Omarchy](https://omarchy.org/) (Quickshell-based bar/shell).
- **go2rtc**: `yay -S go2rtc-bin` (the **-bin** package specifically -- see
  [Security → Backend binding](#backend-binding) for why the source-built
  `go2rtc` AUR package won't pass verification). Lookout uses it as a
  verified WebRTC bridge: Google's own API has no simple "give me an RTSP
  URL" option for cameras migrated to the Google Home app (see
  [How it works](#how-it-works)), and go2rtc is a well-established,
  actively maintained open-source project already widely used for exactly
  this by the Home Assistant/Frigate community.
- **mpv**, for the floating full-size view: `sudo pacman -S mpv`.
- A running [freedesktop Secret
  Service](https://specifications.freedesktop.org/secret-service-spec/latest/)
  (`gnome-keyring` -- Omarchy already pins Electron apps to
  `gnome-libsecret` by default, so this is normally already present; if not:
  `sudo pacman -S gnome-keyring`).

### Setting up Google Device Access + Google Cloud

This is the part that has nothing to do with Lookout itself -- it's Google's
own process for letting any third-party app (this plugin, Home Assistant,
anything) talk to Nest/Google Home cameras at all, and it's genuinely
fiddly the first time. The order below matters: Device Access's own
"Enable events" step expects a Pub/Sub topic and an OAuth client to already
exist in your Google Cloud project, and won't create them for you.

1. **Create (or pick) a Google Cloud project.** Go to the
   [Cloud Console](https://console.cloud.google.com/) and create a new
   project (or reuse an existing personal one). Note its **Project ID**
   (not its display name) -- Lookout's setup wizard asks for this as the
   "GCP Project ID".
2. **Enable the Smart Device Management API** for that project: Cloud
   Console → **APIs & Services → Library**, search "Smart Device
   Management API", click **Enable**.
3. **Configure the Google Auth Platform** (Cloud Console's current name for
   what used to be called the "OAuth consent screen" -- **APIs & Services →
   Google Auth Platform**):
   - If this is the project's first OAuth client, it'll ask for basic app
     info (name, support email) -- anything reasonable works, this is
     never shown to anyone but you.
   - Under its **Audience** tab, add scopes for
     `https://www.googleapis.com/auth/sdm.service` and
     `https://www.googleapis.com/auth/pubsub`, and, importantly, **add your
     own Google account as a Test user**. Unless you go through Google's
     full verification process (not necessary for personal use), the app
     stays in **Testing** publishing status, which means Google will
     silently refuse to let you sign in through it unless your account is
     explicitly listed here first -- a very easy step to miss, since
     nothing about the sign-in flow itself tells you that's why it failed.
4. **Create an OAuth client**: **APIs & Services → Credentials → Create
   Credentials → OAuth client ID**, application type **"Web application"**
   (Device Access does not support "Desktop" or "Installed" client types --
   picking the wrong one here is the single most common way to get stuck).
   Under **Authorized redirect URIs**, add exactly the URI Lookout's own
   setup wizard shows you on its first screen
   (`http://127.0.0.1:<port>/oauth/callback` -- the port is configurable,
   8912 by default). Save the **Client ID** and **Client secret** it gives
   you; the wizard asks for both.
5. **Create a Pub/Sub topic** in the same project: Cloud Console →
   **Pub/Sub → Topics → Create Topic** (the plain Pub/Sub API -- **not**
   "Pub/Sub Lite", a different, unrelated product with its own separate
   page in the console). Note the topic name.
6. **Grant Google's own publisher account access to that topic**: open the
   topic you just created → its **Permissions** tab (not the project's
   general IAM page, which is a different list) → **Add Principal** →
   `sdm-publisher@googlegroups.com` → role **Pub/Sub Publisher**. This is
   what lets Google's backend actually deliver camera events into your
   topic; skipping it results in a topic that silently never receives
   anything.
7. **Enroll in Device Access** at the [Device Access
   Console](https://console.nest.google.com/device-access) with the same
   Google account -- this is where Google's one-time **US$5 fee** applies
   (paid to Google, not this plugin). Create a new Device Access project:
   - Paste in the **OAuth client ID** from step 4 when asked for it.
   - Under its **Enable events** step, select the Pub/Sub topic from step 5
     -- this step is what fails with a confusing error if steps 5-6 weren't
     done first.
   - Note the Device Access project's own **Project ID** (a UUID, different
     from both the GCP project ID and the OAuth client ID) -- the wizard
     asks for this as the "Device Access Project ID".
8. **Link your actual Nest/Google Home account** to that Device Access
   project if prompted (this is a separate authorization step Google's own
   Device Access Console walks you through, tied to whichever Google
   account your cameras are actually registered under).

With all of that in place, open Lookout from the bar for the first time and
its setup wizard takes over: paste in the Client ID/Secret, GCP Project ID,
Device Access Project ID, and Pub/Sub topic from above, then click through
to authorize -- it opens your browser to Google's own consent screen, and
everything after that (token exchange, subscription creation, camera
discovery) happens automatically.

## Installation

```bash
omarchy plugin add https://github.com/JMThomas00/omarchy-lookout.git --enable
```

Or manually:

```bash
git clone https://github.com/JMThomas00/omarchy-lookout.git \
  ~/.config/omarchy/plugins/lookout
omarchy plugin enable jmthomas00.lookout center
```

Click the icon and follow the setup wizard -- it lists the exact
prerequisite steps (Device Access project, OAuth client, go2rtc) before
asking for anything.

## Removal

```bash
omarchy plugin remove jmthomas00.lookout
```

Or manually:

```bash
omarchy plugin disable jmthomas00.lookout
rm -rf ~/.config/omarchy/plugins/lookout
rm -rf ~/.config/lookout ~/.local/state/lookout
secret-tool clear service lookout kind google-credentials account default
```

The `secret-tool clear` step is manual and deliberate -- removing the
plugin directory doesn't touch your OS keyring, so this is the one thing
worth doing by hand if you're done with Lookout for good. `go2rtc`/`mpv`
themselves are untouched either way (installed separately, see
Requirements above) -- remove them the same way you installed them if you
no longer want them.

## Usage

- **Click** the bar icon for the thumbnail grid.
- **Click a tile** for a floating, full-size live view of that camera.
  Click the same tile again to bring that window to the front instead of
  opening a duplicate.
- The **gear icon** in the grid opens Settings: show/hide cameras, per-camera
  per-event-type notification toggles, global notification preferences, and
  re-authorize/sign-out.
- A **bar badge** appears the moment any camera reports motion, a person, a
  sound, or a doorbell chime (each independently toggleable per camera in
  Settings) -- opening the grid clears it.

## How it works

Your specific cameras (visible at `home.google.com/home/.../cameras/grid`)
are on the **Google Home app**, which means they're **WebRTC-only** --
Google's `CameraLiveStream.GenerateRtspStream` command only works for
cameras still on the legacy Nest app. Building a WebRTC/SDP/ICE client from
scratch in Quickshell/QML isn't practical, so Lookout treats
[go2rtc](https://github.com/AlexxIT/go2rtc) as a verified external backend
(see [Security → Backend binding](#backend-binding)): its `nest:` source
does the WebRTC negotiation directly against Google's API using your own
OAuth credentials, and re-exposes each camera locally, on loopback only, as
a plain JPEG snapshot endpoint and an RTSP restream (for `mpv`'s floating
view).

Each tile fetches that JPEG snapshot endpoint exactly once per popup-open,
not continuously -- go2rtc's snapshot handler blocks until the next
keyframe arrives from Google's relay before it can answer, which measured
anywhere from under a second to 20+ seconds per request against real
cameras, entirely outside this plugin's control. Rather than mask that with
a background process continuously re-decoding each camera's video stream
(tried, and reverted after real-usage feedback -- it worked, but needed two
background processes per visible camera and still weren't genuinely live,
just a fast-looking illusion of it, at real complexity cost), Lookout fetches
one snapshot per camera when you open the grid, caches it to a small local
file that's never deleted, only overwritten by the next successful fetch,
and shows that cached frame instantly on your next open while the fresh
fetch runs in the background. If you want to see what's actually happening
right now, click the tile for the real, actually-live floating view.

Google's own API design matters here too: the Smart Device Management API
deliberately enforces a very low quota -- a few queries per minute per
device -- specifically to protect camera battery life. Lookout never keeps a
stream open in the background: go2rtc itself only runs while at least one
thumbnail grid or floating view actually needs it (a short idle-teardown
timer stops it a few seconds after the last consumer goes away), and each
snapshot fetch is a single bounded request, not a poll.

Motion/person/sound/chime events reach Lookout through a completely separate,
much cheaper path: a Google Cloud **Pub/Sub pull subscription**, polled
continuously by a small Python helper
(`bin/pubsub-listener.py`). Pub/Sub pull isn't subject to the same
per-device command quota, so this can run indefinitely without touching
your cameras' battery life at all -- it's what drives the bar badge and
notifications independently of whether the grid has ever been opened.
When an event carries a short clip preview (not every camera/event has
one), that helper downloads it immediately -- the URL Google hands back
is short-lived, so this can't wait for the popup to next open -- and a
tile shows that clip, looping, in place of a blank placeholder while it's
waiting on its own first live snapshot of the session.

## Limitations

A few things below look like bugs the first time you hit them but are
actually Google/Nest's own backend behaving the way it does for every app
that uses the SDM API, not just Lookout -- worth knowing up front:

- **The first live view or thumbnail of a "cold" camera can take a while.**
  If go2rtc hasn't talked to a given camera recently, connecting to it for
  the first time means go2rtc negotiating a fresh WebRTC session with
  Google's own relay from scratch. That's measured anywhere from under a
  second to 20-30 seconds against real cameras, occasionally longer, and
  it's outside this plugin's control -- see [How it works](#how-it-works)
  for why. A doorbell chime auto-opening the live view is the case where
  this is most noticeable, since there's usually no already-warm session to
  reuse. The desktop notification itself still fires immediately either
  way; only the live window's own appearance can lag behind it.
- **Thumbnails are a snapshot, not a live feed.** Each tile shows one frame,
  fetched when you open the grid, not a continuously updating picture.
  Google's own API caps how often any app can request a stream per device
  (a few times a minute, meant to protect camera battery life), so a truly
  live thumbnail grid isn't something this plugin can build within that
  quota. Click a tile for the real, actually-live view.
- **Events can arrive a few seconds to a couple of minutes after they
  actually happened.** Pub/Sub delivery timing is Google's, not Lookout's --
  the pull loop itself polls every 10-15 seconds, and Google's own backend
  adds its own delay on top of that before an event is even published.
- **Not every event includes a clip preview**, and the ones that do expire
  quickly (the URL Google provides is short-lived, which is why Lookout
  downloads it immediately rather than waiting). When there isn't one, a
  tile falls back to the last snapshot instead.
- **"Test connection" in Settings checks sign-in and Pub/Sub reachability,
  not individual cameras.** If it passes but one specific camera never
  notifies, the more likely cause is that camera's own notify toggle, or
  that it stopped reporting events to Google's backend at all (check the
  Google Home app itself).
- **A revoked or expired Google sign-in isn't always obvious immediately.**
  Lookout surfaces re-authorization once a refresh attempt actually fails
  (a 401 on Pub/Sub pull, or an `invalid_grant` from Google's token
  endpoint) -- there's no way to proactively know a token has been revoked
  before that happens.

None of this is a reason to assume something's misconfigured -- it's the
real shape of building on top of a battery-protecting, relay-mediated
camera API rather than a direct video feed.

## Security

Lookout stores your Google OAuth credentials, spawns several external
processes, and depends on a third-party backend (go2rtc) -- this section
covers the process, credential, network, and file boundaries this plugin's
own code crosses.

### Backend binding

go2rtc is installed by you, separately, from the AUR (see Requirements) --
the reviewed commit of this repository controls none of those bytes unless
something actively verifies them at run time. It does:

- **A committed trust root, not the installed environment's own word about
  itself.** `Go2rtcTrustRoot.json` in this repository is generated once,
  directly from the official upstream release binaries at
  [github.com/AlexxIT/go2rtc/releases](https://github.com/AlexxIT/go2rtc/releases)
  (downloaded and hashed immediately, never taken from an installed copy's
  own `--version` output or from a package manager's own checksum file).
- **Fail-closed runtime verification, every single spawn**:
  `BackendManager.qml` resolves the real on-disk `go2rtc` binary
  (`bin/go2rtc-verify.sh`: `readlink -f` to the real file, refuses anything
  that isn't a plain regular file), hashes it, and compares that hash
  against `Go2rtcTrustRoot.json` for the running architecture. Any
  mismatch -- missing binary, wrong hash, a symlink pointing somewhere
  unexpected -- is a hard refusal with **no spawn at all**. This runs fresh
  on every single start, never cached from an earlier session.
- **Explicit, deliberate limitation**: only the AUR **`go2rtc-bin`**
  package (the prebuilt upstream binary, byte-identical to the release
  asset) will pass this check. AUR **`go2rtc`** (built from source with
  your local toolchain) produces different bytes and is refused by design
  -- shown as a clear error banner, not silently accepted, the same
  posture this author's other plugin (`linecast`) takes on an unpinned
  install of its own upstream dependency.

### Process boundary

Every process this plugin spawns, and its exact lifecycle:

- **`go2rtc`** -- spawned via `bin/supervise.sh` (a whole-process-group
  supervisor: one signal becomes a TERM, then a KILL, for the entire
  group, confirmed rather than assumed), refcounted against every open
  grid/floating view, idle-torn-down a few seconds after the last consumer
  releases it. Its generated config file is deleted on every stop.
- **`mpv`** -- one process per camera, a fixed and deterministic
  `--title=` per camera (so a second click focuses the existing window
  instead of spawning a duplicate), torn down whenever the user closes
  that window.
- **`curl`** (thumbnail snapshot) -- one bounded, one-shot fetch per camera
  per popup-open (28s deadline), run through `bin/supervise.sh` like every
  other helper. Downloads to a temp file and only renames it over the real
  cache file on success, so a failed or slow fetch can never corrupt the
  last good cached frame. The device ID is filtered to `[A-Za-z0-9_-]`
  before it's used to build that file's path.
- **`bin/pubsub-listener.py`** -- the one process meant to run
  indefinitely, independent of the popup's open/closed state. Restarts
  itself with capped exponential backoff on an unexpected exit; a fatal
  auth error (refresh token revoked) stops it instead of looping forever
  and prompts re-authorization in the UI instead. Also downloads an
  event's clip preview when one exists, size-capped (8MB) and written the
  same temp-file-then-rename way as the snapshot fetch above -- a failed
  or oversized download is logged and discarded, never allowed to block
  or drop the notification event it arrived alongside. `previewUrl` comes
  from the Pub/Sub message body itself (externally-influenced, even though
  reaching this code already requires access to this user's own GCP
  subscription) -- its scheme and host are checked against the one host
  Google's docs specify (`nest-camera-frontend.googleapis.com`, see
  [Network boundary](#network-boundary)) before the live Bearer token is
  ever attached to a request built from it.
- **`bin/oauth-callback.py`** -- a single-use, hard-timeout (300s) loopback
  HTTP listener used only during setup/re-authorization, torn down the
  instant it's answered a request or the wizard component is destroyed.
- **`secret-tool`**, **`bin/keyring-store.sh`**, **`bin/pkce.sh`**,
  **`bin/go2rtc-verify.sh`** -- one-shot helpers, each with its own short
  deadline.
- **`omarchy-shell`** -- fire-and-forget (`-q`, best-effort) IPC calls to
  the already-running Omarchy shell itself, used only to dismiss this
  plugin's own outstanding desktop notifications when the popup opens.
  Never spawns or manages anything; the shell process already exists
  independently of this plugin.

Every `Process.command` in this plugin is a literal argv array -- there is
no shell-string interpolation anywhere. The handful of `bash -c` calls in
this codebase (go2rtc's config writer, the snapshot fetcher) pass every
value as a positional parameter (`"$1"`, `"$2"`, ...), never spliced into
the script text itself.

### Credential boundary

Exactly one keyring entry
(`service lookout, kind google-credentials, account default`) holds
`client_id` + `client_secret` + `refresh_token` as one JSON blob, stored
via `secret-tool store`/looked up via `secret-tool lookup` -- the secret
crosses the process boundary over stdin only, never as an argument (which
would be readable by any other process you run, via `/proc/<pid>/cmdline`),
and never appears in a log line (`OAuth.js`'s `redact()` scrubs it from any
error text before it's shown or logged).

Scopes requested: `sdm.service` (device access -- reading your camera list
and generating streams) and `pubsub` (pulling motion/person/sound/chime
events). Nothing broader is requested.

**Acknowledged limitation, not fully solved**: go2rtc has no keyring
integration of its own -- it reads its `nest:` source credentials from a
plain YAML config file. Lookout minimizes the exposure rather than
eliminating it: the file is regenerated fresh from the keyring on every
single start (never treated as a long-term source of truth), written with
mode `0600` in a `0700` directory from the moment it's created (no window
where it's briefly world/group-readable), and deleted immediately on stop
or idle-teardown.

### Network boundary

go2rtc's `api`/`rtsp`/`webrtc` listeners are all bound to `127.0.0.1`
only, in every generated config, on every start -- never `0.0.0.0`, never
reachable from your LAN. The complete, closed list of external hosts this
plugin's own code (QML/JS/Python) ever contacts:
`accounts.google.com`/`nestservices.google.com` (browser-driven consent
only), `oauth2.googleapis.com` (token exchange/refresh),
`smartdevicemanagement.googleapis.com` (device discovery),
`pubsub.googleapis.com` (event pull/ack), and
`nest-camera-frontend.googleapis.com` (fetching an event's own short clip
preview, when one exists -- same bearer access token as every other
Google API call here, never a separate credential). No telemetry, no
analytics, no other third-party endpoint of any kind.

### File boundary

Reads/writes only under `~/.config/lookout/`, `~/.local/state/lookout/`, and a
`$XDG_RUNTIME_DIR/lookout/` scratch area -- never inside
`~/.config/omarchy/plugins/lookout/` itself (that directory is
hot-reload-watched; a state write landing there has previously torn down
in-flight async work in this author's other plugins) and never inside
`~/.config/hypr/*` (the floating-window rule for `mpv` is applied only via
a session-only `hyprctl keyword windowrule` call at runtime, never a file
edit). Two things are intentionally kept across sessions, both non-secret
and both overwritten by the next successful fetch/event rather than
accumulated:
`~/.local/state/lookout/go2rtc/live/<deviceId>.jpg` per camera -- a JPEG
snapshot, purely so reopening the popup shows a frame instantly (see
[How it works](#how-it-works)) -- and
`~/.local/state/lookout/last-event/<deviceId>.mp4` per camera, the short
clip from that camera's most recent event (when one exists), shown while
waiting on the first live snapshot of the popup session. Removed with
everything else in
[Removal](#removal). See [Removal](#removal) for the one manual step
(clearing the keyring entry) that removing the plugin directory doesn't
cover.

## License

MIT -- see [LICENSE](LICENSE). A handful of files were adapted from other
MIT-licensed Omarchy plugins already installed on this author's system
(`scoop.uptime-kuma`'s subprocess-supervision pattern,
`io.github.jeremylanger.omaspotify`'s OAuth/keyring flow) -- see
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for exactly what was
adapted from where and their original copyright notices.

go2rtc is a separate project by [AlexxIT](https://github.com/AlexxIT),
also MIT-licensed -- installed by you, separately (see Requirements); this
plugin is not affiliated with or endorsed by it, nor by Google.
