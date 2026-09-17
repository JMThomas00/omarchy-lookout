import QtQuick
import Quickshell
import Quickshell.Io

// Companion to BoundedProcess.qml for processes that need real-time,
// line-by-line access to their own stdout while still running -- something
// BoundedProcess can't offer, since it only ever delivers accumulated
// output once, after the whole process has exited. Two shapes use this:
//
// - deadlineSeconds: 0 (the default) for a genuinely indefinite process
//   (go2rtc, bin/pubsub-listener.py) -- bin/supervise.sh itself documents
//   0 as exactly this: "no deadline... bounded by its caller noticing it
//   has gone quiet." Stopped explicitly via _tearDown(), never a timer.
// - deadlineSeconds > 0 for a process that both has a real deadline AND
//   needs an interactive read-then-write-back exchange while it's still
//   running -- the OAuth callback listener (bin/oauth-callback.py) is the
//   one example: it prints the accepted request line, then waits for this
//   side to write back an HTTP response, all before it exits. A QML-side
//   watchdog timer backs up supervise.sh's own deadline enforcement, the
//   same reasoning as BoundedProcess.qml's own watchdog.
//
// Either way, the caller owns `stdout`/`stderr` directly, as it would on a
// plain Process -- there's no generic budget/accumulator logic here to
// route through, unlike BoundedProcess.
Process {
    id: root

    /** The helper to run, as an argv array. Set this, not `command` -- see BoundedProcess.qml. */
    property var program: []

    /** Seconds before a QML-side watchdog backs up supervise.sh's own deadline. 0 = no deadline. */
    property int deadlineSeconds: 0

    readonly property string _supervisor: Qt.resolvedUrl("bin/supervise.sh").toString().replace("file://", "")

    command: program.length > 0 ? [_supervisor, String(deadlineSeconds)].concat(program) : []

    clearEnvironment: true
    environment: ({
            PATH: "/usr/bin:/bin",
            DBUS_SESSION_BUS_ADDRESS: Quickshell.env("DBUS_SESSION_BUS_ADDRESS"),
            XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR"),
            HOME: Quickshell.env("HOME"),
            LC_ALL: "C",
        })

    onStarted: if (deadlineSeconds > 0) watchdog.restart()

    /** Stop the whole process group -- see BoundedProcess.qml's _tearDown for the reasoning. */
    function _tearDown() {
        if (running) {
            signal(15);
            killTimer.restart();
        }
    }

    onExited: {
        killTimer.stop();
        watchdog.stop();
    }

    Component.onDestruction: root._tearDown()

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
