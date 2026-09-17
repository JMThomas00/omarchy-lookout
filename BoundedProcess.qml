import QtQuick
import Quickshell
import Quickshell.Io

// Vendored, unmodified except for this attribution comment, from
// scoop.uptime-kuma's BoundedProcess.qml (MIT -- see THIRD_PARTY_LICENSES.md).
// For Lookout's own two genuinely indefinite processes (go2rtc, the Pub/Sub
// listener), see SupervisedProcess.qml instead -- this component's budget/
// watchdog design assumes every helper answers once and exits, which is
// exactly right for the one-shot helpers Lookout uses this for (secret-tool,
// bin/go2rtc-verify.sh, bin/keyring-store.sh), but wrong for a server meant
// to keep running and talking indefinitely.
//
// A child process that cannot outgrow a budget, cannot outlast a deadline,
// and cannot leave anything of its own behind.
//
// StdioCollector keeps everything the child writes and only then lets you
// measure it — by the time a length check runs, the bytes are already in the
// shell's heap. This counts each chunk as it arrives, stops at the ceiling, and
// ends the child rather than truncating: an answer that outgrew its budget is a
// refusal, not a value to salvage. The budget covers stdout and stderr
// together, because a helper that says nothing useful very loudly costs the
// shell exactly as much as one that answers at length.
//
// Ending the child is the part that needs help from outside QML. Process.signal
// reaches the process Quickshell started and nothing else, and every helper here
// is a shell script that runs curl, jq and head — so a signal that stops the
// script leaves its curl holding the connection, reparented to init. Every
// command therefore goes through bin/supervise.sh, which puts the helper in a
// process group of its own and turns one signal into a TERM, then a KILL, for
// the whole group, with the exit confirmed rather than assumed. The deadline
// lives there too: a helper that produces no output at all would otherwise sit
// there forever, since a budget on what it says bounds nothing.
//
// The environment matters for the same reason the argv does. Everything this
// spawns is on the path of a password or a session token, and an inherited
// environment carries BASH_ENV, LD_PRELOAD, PYTHONPATH and the proxy variables
// into it — each of which lets another process running as this user decide what
// code runs, or where the credential goes.
Process {
    id: root

    /**
     * The helper to run, as an argv array.
     *
     * Set this rather than `command`: `command` is this plus the supervisor in
     * front of it, and a helper run without the supervisor is a helper nothing
     * can be sure of having stopped.
     */
    property var program: []

    /** Seconds the helper may run before it is torn down. */
    property int deadlineSeconds: 30

    /** Ceiling for everything the child writes, stdout and stderr together. */
    property int maxBytes: 65536

    /** Emitted once per run, after the child has exited. */
    signal finishedWith(string text, bool tooLarge)

    /** The last of the child's diagnostics, bounded like everything else. */
    property string stderrTail: ""

    // Resolved against this file rather than against the caller, and the same
    // for every user of the component: the supervisor is part of the plugin,
    // not something looked up when it is needed.
    readonly property string _supervisor: Qt.resolvedUrl("bin/supervise.sh").toString().replace("file://", "")

    readonly property int _stderrTailMax: 4096

    property string _collected: ""
    property int _used: 0
    property bool _overflowed: false

    command: program.length > 0 ? [_supervisor, String(deadlineSeconds)].concat(program) : []

    clearEnvironment: true
    environment: ({
            // Fixed, absolute, and short: nothing here is resolved through a
            // directory another process can prepend to.
            PATH: "/usr/bin:/bin",
            // secret-tool reaches the login keyring over the session bus, so
            // this one is not optional.
            DBUS_SESSION_BUS_ADDRESS: Quickshell.env("DBUS_SESSION_BUS_ADDRESS"),
            XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR"),
            HOME: Quickshell.env("HOME"),
            // Byte semantics for the helpers' own length checks.
            LC_ALL: "C",
        })

    onStarted: {
        _collected = "";
        stderrTail = "";
        _used = 0;
        _overflowed = false;
        if (deadlineSeconds > 0) {
            watchdog.restart();
        }
    }

    /**
     * Stop the whole group, and mean it.
     *
     * TERM goes to the supervisor, which passes it to the group and arms the
     * KILL that follows it. The timer here is the last resort for a supervisor
     * that is itself wedged; by then the group is already under its own
     * escalation, which was armed the moment the TERM arrived.
     */
    function _tearDown() {
        if (running) {
            signal(15);
            killTimer.restart();
        }
    }

    /** Count a chunk against the shared budget. Returns whether it fits. */
    function _charge(chunk) {
        if (_overflowed) {
            return false;
        }
        if (_used + chunk.length > maxBytes) {
            _overflowed = true;
            _collected = "";
            stderrTail = "";
            _tearDown();
            return false;
        }
        _used += chunk.length;
        return true;
    }

    stdout: SplitParser {
        // No marker: raw chunks. A line-delimited parser has to buffer until
        // the delimiter before it can hand anything over, so the ceiling would
        // arrive after the allocation it is meant to prevent.
        splitMarker: ""
        onRead: function (chunk) {
            if (root._charge(chunk)) {
                root._collected += chunk;
            }
        }
    }

    stderr: SplitParser {
        splitMarker: ""
        onRead: function (chunk) {
            if (!root._charge(chunk)) {
                return;
            }
            // Trimmed before it is joined, not after: building the whole
            // string and then slicing it is the allocation this is here to
            // prevent.
            var bounded = chunk.length > root._stderrTailMax ? chunk.slice(-root._stderrTailMax) : chunk;
            var room = root._stderrTailMax - bounded.length;
            root.stderrTail = (room > 0 ? root.stderrTail.slice(-room) : "") + bounded;
        }
    }

    // Lookout addition (upstream scoop.uptime-kuma does not have this):
    // `lastExitCode` is set here, synchronously before `finishedWith` fires,
    // specifically so a caller reading it from inside its own `onFinishedWith`
    // handler always sees the CURRENT run's exit code -- Process itself has
    // no persistent exitCode property (only a signal parameter, confirmed
    // against Quickshell's own qmltypes), and a caller instead tracking the
    // exit code via its own separate `Connections { function onExited() }`
    // races this literal handler: QML connects a type's own literal signal
    // handler (this one) before an external Connections block declared at
    // the instantiation site, so an external listener's copy of the exit
    // code is always one run stale by the time onFinishedWith reads it --
    // a real bug this exact shape caused in Lookout's CredentialStore.qml
    // (every keyring save falsely reported failure) before this property
    // was added.
    property int lastExitCode: -1

    onExited: function (exitCode, exitStatus) {
        lastExitCode = exitCode;
        killTimer.stop();
        watchdog.stop();
        root.finishedWith(root._collected, root._overflowed);
        root._collected = "";
        root._used = 0;
        root._overflowed = false;
    }

    // Nothing this shell started should outlive it.
    Component.onDestruction: root._tearDown()

    // Declared as properties rather than children: Process has no default
    // property, so it cannot hold one.

    /**
     * The deadline as this side sees it.
     *
     * supervise.sh holds the real one and enforces it on the group. This is the
     * answer to the supervisor never coming back at all — stopped, or killed
     * outright by something else — and so it waits out the supervisor's own
     * TERM-to-KILL grace before concluding anything.
     */
    property Timer watchdog: Timer {
        interval: (root.deadlineSeconds + 5) * 1000
        repeat: false
        running: false
        onTriggered: root._tearDown()
    }

    property Timer killTimer: Timer {
        interval: 6000
        repeat: false
        onTriggered: if (root.running) root.signal(9)
    }
}
