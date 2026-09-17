import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "OAuth.js" as OAuth
import "Sdm.js" as Sdm

// First-run onboarding: paste the user's own Device Access/OAuth
// credentials, authorize once via a loopback redirect, discover cameras,
// and (best-effort) create the Pub/Sub pull subscription. See README.md's
// Security > Credential boundary section for what gets stored where.
Item {
  id: root

  required property string pluginDir
  required property CredentialStore credentialStoreRef
  required property CameraListStore cameraListStoreRef
  required property SetupStore setupStoreRef
  property bool reauthorizing: false

  signal setupCompleted()

  // "prereqs" | "credentials" | "authorizing" | "exchanging" | "discovering"
  // | "pubsub" | "error"
  property string step: "prereqs"
  property string errorMessage: ""

  property string clientId: ""
  property string clientSecret: ""
  property string deviceAccessProjectId: root.setupStoreRef.deviceAccessProjectId
  property string gcpProjectId: root.setupStoreRef.gcpProjectId
  property string pubsubTopicId: root.setupStoreRef.pubsubTopicId
  property string oauthPortText: String(root.setupStoreRef.oauthPort || 8912)

  property string _pkceVerifier: ""
  property string _pkceChallenge: ""
  property string _oauthState: ""
  property string _accessToken: ""
  property string _gcloudFallbackCommand: ""
  // Editable on the fallback screen -- the user may have created the
  // subscription under a different name than what was guessed (by hand,
  // via `gcloud`, or the Cloud Console UI), and Skip needs to check
  // whatever name is ACTUALLY correct, not just the original guess.
  property string _subscriptionNameOverride: ""
  // True once a Skip has already been through one failed verification --
  // a second Skip click proceeds unconditionally rather than blocking
  // forever, matching the original "don't force the user to solve a
  // possibly permissions-related issue right now" intent, just no longer
  // silent about it.
  property bool _skipVerifyFailedOnce: false

  readonly property string redirectUri: "http://127.0.0.1:"
    + OAuth.normalizedPort(root.oauthPortText) + "/oauth/callback"

  function beginAuthorize() {
    if (!root.clientId || !root.clientSecret || !root.deviceAccessProjectId
        || !root.gcpProjectId || !root.pubsubTopicId) {
      root.errorMessage = "All fields are required."
      return
    }
    root.errorMessage = ""
    root._callbackHandled = false
    root._subscriptionNameOverride = ""
    root._skipVerifyFailedOnce = false
    root.step = "authorizing"
    pkceProc.program = [root.pluginDir + "/bin/pkce.sh"]
    pkceProc.running = true
  }

  // Lets the user back out of any of the wait screens (authorizing/
  // exchanging/discovering/pubsub) without restarting the whole plugin --
  // real gap the first live run of this wizard surfaced. Tears down the
  // one process that could otherwise keep running (the loopback listener)
  // and clears in-flight secrets from memory; every async completion below
  // additionally checks `root.step` still matches what it expects before
  // applying its result, so a callback that arrives after Cancel (a late
  // HTTP response, a slow process exit) is discarded rather than acted on.
  function cancelAuthorization() {
    root._callbackHandled = true
    if (callbackListener.running) callbackListener._tearDown()
    root._pkceVerifier = ""
    root._pkceChallenge = ""
    root._oauthState = ""
    root._accessToken = ""
    root._gcloudFallbackCommand = ""
    root._subscriptionNameOverride = ""
    root._skipVerifyFailedOnce = false
    root.errorMessage = ""
    root.step = "credentials"
  }

  BoundedProcess {
    id: pkceProc
    deadlineSeconds: 8
    maxBytes: 4096
    onFinishedWith: function (text, tooLarge) {
      if (root.step !== "authorizing") return
      if (tooLarge) { root._fail("Could not start sign-in (PKCE helper produced too much output)"); return }
      var result = OAuth.parsePkceOutput(text)
      if (!result.ok) { root._fail(result.error); return }
      root._pkceVerifier = result.verifier
      root._pkceChallenge = result.challenge
      root._oauthState = result.state
      root._startCallbackListener()
    }
  }

  function _startCallbackListener() {
    var port = OAuth.normalizedPort(root.oauthPortText)
    callbackListener.program = [root.pluginDir + "/bin/oauth-callback.py",
      "--port", String(port), "--path", "/oauth/callback", "--timeout", "300"]
    callbackListener.deadlineSeconds = 310
    callbackListener.running = true
  }

  SupervisedProcess {
    id: callbackListener
    stdinEnabled: true

    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (line) { root._handleCallbackLine(line) }
    }
  }

  Connections {
    target: callbackListener
    function onStarted() { authOpenDelay.restart() }
    function onExited(exitCode) {
      if (root.step === "authorizing" && !root._callbackHandled) {
        root._fail(exitCode === 0 ? "The sign-in window closed before it finished" : "Sign-in timed out. Please try again")
      }
    }
  }

  property bool _callbackHandled: false

  Timer {
    id: authOpenDelay
    interval: 120
    onTriggered: {
      var url = OAuth.authUrl(root.deviceAccessProjectId, {
        client_id: root.clientId,
        redirect_uri: root.redirectUri,
        scope: OAuth.SCOPES.join(" "),
        access_type: "offline",
        prompt: "consent",
        response_type: "code",
        code_challenge: root._pkceChallenge,
        code_challenge_method: "S256",
        state: root._oauthState
      })
      Quickshell.execDetached(["xdg-open", url])
    }
  }

  function _handleCallbackLine(line) {
    if (root._callbackHandled) return
    var result = OAuth.parseCallbackRequestLine(line, "/oauth/callback")
    if (!result.ok || result.state !== root._oauthState) {
      root._callbackHandled = true
      callbackListener.write(Qt.btoa(OAuth.failureResponse()) + "\n")
      callbackStopTimer.restart()
      root._fail(result.ok ? "Sign-in could not be verified. Please try again" : result.error)
      return
    }
    root._callbackHandled = true
    callbackListener.write(Qt.btoa(OAuth.successResponse()) + "\n")
    callbackStopTimer.restart()
    root._exchangeCode(result.code)
  }

  Timer {
    id: callbackStopTimer
    interval: 250
    onTriggered: if (callbackListener.running) callbackListener._tearDown()
  }

  function _exchangeCode(code) {
    root.step = "exchanging"
    var verifier = root._pkceVerifier
    root._pkceVerifier = ""
    root._pkceChallenge = ""
    root._oauthState = ""
    var body = OAuth.formBody({
      client_id: root.clientId,
      client_secret: root.clientSecret,
      code: code,
      code_verifier: verifier,
      grant_type: "authorization_code",
      redirect_uri: root.redirectUri
    })
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      if (root.step !== "exchanging") return
      var result = OAuth.parseTokenResponse(xhr.status, xhr.responseText, "")
      if (!result.ok) { root._fail(result.error); return }
      root._accessToken = result.accessToken
      root._storeCredentials(result.refreshToken)
    }
    xhr.open("POST", OAuth.TOKEN_URL)
    xhr.setRequestHeader("Content-Type", "application/x-www-form-urlencoded")
    xhr.send(body)
  }

  function _storeCredentials(refreshToken) {
    root.credentialStoreRef.storeFinished.connect(root._onCredentialsStored)
    root.credentialStoreRef.store({
      clientId: root.clientId,
      clientSecret: root.clientSecret,
      refreshToken: refreshToken
    })
  }

  function _onCredentialsStored(ok) {
    root.credentialStoreRef.storeFinished.disconnect(root._onCredentialsStored)
    if (root.step !== "exchanging") return
    if (!ok) { root._fail("Could not save your credentials securely. Is a Secret Service (gnome-keyring) running?"); return }
    root._discoverCameras()
  }

  function _discoverCameras() {
    root.step = "discovering"
    Sdm.listCameras(root._accessToken, root.deviceAccessProjectId, function (ok, status, cameras, payload) {
      if (root.step !== "discovering") return
      if (!ok) {
        root._fail("Could not list your cameras (status " + status + "): "
          + OAuth.responseError(status, payload, "no further detail from Google"))
        return
      }
      if (cameras.length === 0) { root._fail("No cameras or doorbells were found on this Device Access project"); return }
      root.cameraListStoreRef.replaceFromDiscovery(cameras)
      root._createSubscription()
    })
  }

  function _createSubscription() {
    root.step = "pubsub"
    // Prefers whatever's in the (editable) override field over the stored/
    // guessed name -- retrySubscription() re-runs this after the user may
    // have corrected the name on the fallback screen, and this is what
    // makes that edit actually take effect.
    if (!root._subscriptionNameOverride) {
      root._subscriptionNameOverride = root.setupStoreRef.pubsubSubscriptionName || "lookout-events"
    }
    var subscriptionName = root._subscriptionNameOverride
    // The Pub/Sub topic lives in the USER's own GCP project, not Google's --
    // Device Access's own "Enable events" step requires you to create it
    // yourself and grant sdm-publisher@googlegroups.com Publisher on it,
    // confirmed directly against the real Device Access Console UI (its
    // topic field literally requires this exact "projects/{project}/
    // topics/{topic}" format against your own project). An earlier version
    // of this code wrongly assumed Google auto-provisions the topic under
    // its own "sdm-prod" project.
    //
    // normalizeTopicPath handles either a bare id or that same full-path
    // format -- a user who pastes exactly what the Device Access Console
    // asked for here would otherwise get it doubled into a malformed
    // resource name (found live: a real 400 from Pub/Sub).
    var topicPath = Sdm.normalizeTopicPath(root.gcpProjectId, root.pubsubTopicId)
    Sdm.createPullSubscription(root._accessToken, root.gcpProjectId, subscriptionName, topicPath,
      function (ok, status, payload) {
        if (root.step !== "pubsub") return
        // 409 = already exists from a previous setup run -- treat as success.
        if (ok || status === 409) { root._finish(subscriptionName); return }
        root._gcloudFallbackCommand = Sdm.gcloudCreateCommand(root.gcpProjectId, subscriptionName, topicPath)
        root.errorMessage = "Could not create the Pub/Sub subscription automatically (status " + status + "): "
          + OAuth.responseError(status, payload, "no further detail from Google")
      })
  }

  function retrySubscription() {
    root._skipVerifyFailedOnce = false
    root._createSubscription()
  }

  // Verifies the subscription actually exists before trusting it --
  // previously this just recorded whatever name had been guessed/attempted
  // with no check at all. Found live: a real setup where the user's own
  // manual subscription creation ended up under a different name than the
  // guess, so the recorded name pointed at nothing and the listener pulled
  // a 404 forever, completely silently -- weeks of real camera events with
  // zero notifications, only caught by manually curling the Pub/Sub API.
  //
  // Still never blocks forever, per this button's own "for now" framing:
  // a second Skip (after one failed verification) proceeds unconditionally.
  function skipSubscription() {
    var subscriptionName = root._subscriptionNameOverride
      || root.setupStoreRef.pubsubSubscriptionName || "lookout-events"
    if (root._skipVerifyFailedOnce) { root._finish(subscriptionName); return }
    Sdm.getSubscription(root._accessToken, root.gcpProjectId, subscriptionName,
      function (ok, status, payload) {
        if (root.step !== "pubsub") return
        if (ok) { root._finish(subscriptionName); return }
        root._skipVerifyFailedOnce = true
        root._gcloudFallbackCommand = Sdm.gcloudCreateCommand(root.gcpProjectId, subscriptionName,
          Sdm.normalizeTopicPath(root.gcpProjectId, root.pubsubTopicId))
        root.errorMessage = "No subscription named \"" + subscriptionName + "\" exists yet in "
          + root.gcpProjectId + " -- if you created one under a different name, fix it above and "
          + "try again. Notifications won't work until this points at a real subscription. "
          + "Click Skip again to continue anyway."
      })
  }

  function _finish(subscriptionName) {
    root._accessToken = ""
    root.setupStoreRef.markComplete({
      deviceAccessProjectId: root.deviceAccessProjectId,
      gcpProjectId: root.gcpProjectId,
      pubsubTopicId: root.pubsubTopicId,
      pubsubSubscriptionName: subscriptionName,
      oauthPort: OAuth.normalizedPort(root.oauthPortText)
    })
    root.setupCompleted()
  }

  function _fail(message) {
    root.errorMessage = message
    root.step = "credentials"
    if (callbackListener.running) callbackListener._tearDown()
  }

  Component.onDestruction: {
    if (callbackListener.running) callbackListener._tearDown()
  }

  // -------------------------------------------------------------------- UI

  // Fixed, not content-derived like CameraGridPanel's -- this view is
  // mostly prose/buttons that just wants generous, stable width across its
  // several steps, unlike the camera grid where the whole point is to
  // shrink/grow with the user's own camera count and thumbnail size.
  implicitWidth: Style.space(560)
  implicitHeight: column.implicitHeight

  Column {
    id: column
    width: parent.width
    spacing: Style.spacing.md

    Text {
      width: parent.width
      text: root.reauthorizing ? "Lookout: sign in again" : "Lookout setup"
      font.family: Style.font.family
      font.pixelSize: Style.font.title
      font.bold: true
      color: Color.foreground
    }

    Text {
      visible: root.errorMessage.length > 0
      width: parent.width
      text: root.errorMessage
      color: Color.urgent
      wrapMode: Text.WordWrap
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    // ---- prereqs ----
    Column {
      visible: root.step === "prereqs"
      width: parent.width
      spacing: Style.spacing.sm

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        text: "Lookout needs your own Google Device Access project (Google's one-time "
          + "$5 fee applies) and a Cloud Console OAuth client of type "
          + "\"Web application\" (Device Access does not support \"Desktop\"). "
          + "Register this exact redirect URI on that client:"
      }
      TextField {
        width: parent.width
        readOnly: true
        text: root.redirectUri
        selectByMouse: true
      }
      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        text: "Before creating your Device Access project, also create a Pub/Sub "
          + "topic in that same GCP project (Cloud Console -> Pub/Sub -> Topics -> "
          + "Create Topic -- the plain Pub/Sub API, not \"Pub/Sub Lite\", a different, "
          + "unrelated product), then on that topic's Permissions tab grant "
          + "sdm-publisher@googlegroups.com the Pub/Sub Publisher role. Device "
          + "Access's own \"Enable events\" step needs this topic to already exist "
          + "in your project -- it does not create one for you."
      }
      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        text: "Also install go2rtc from the AUR first: go2rtc-bin (not go2rtc -- "
          + "see README.md's Security section for why)."
      }
      Button {
        text: "I've done this -- continue"
        onClicked: root.step = "credentials"
      }
    }

    // ---- credentials ----
    Column {
      visible: root.step === "credentials"
      width: parent.width
      spacing: Style.spacing.sm

      TextField { width: parent.width; placeholderText: "OAuth Client ID"; text: root.clientId; onTextEdited: root.clientId = text }
      TextField { width: parent.width; placeholderText: "OAuth Client Secret"; echoMode: TextInput.Password; text: root.clientSecret; onTextEdited: root.clientSecret = text }
      TextField { width: parent.width; placeholderText: "Device Access Project ID"; text: root.deviceAccessProjectId; onTextEdited: root.deviceAccessProjectId = text }
      TextField { width: parent.width; placeholderText: "GCP Project ID"; text: root.gcpProjectId; onTextEdited: root.gcpProjectId = text }
      TextField { width: parent.width; placeholderText: "Pub/Sub Topic ID -- either \"nest-events\" or the full \"projects/.../topics/...\" path, both work"; text: root.pubsubTopicId; onTextEdited: root.pubsubTopicId = text }
      TextField { width: parent.width; placeholderText: "Loopback port (default 8912)"; text: root.oauthPortText; onTextEdited: root.oauthPortText = text }

      Row {
        spacing: Style.spacing.sm
        Button { text: "Back"; onClicked: root.step = "prereqs" }
        Button { text: "Authorize with Google"; onClicked: root.beginAuthorize() }
      }
    }

    // ---- authorizing / exchanging / discovering ----
    Column {
      visible: root.step === "authorizing" || root.step === "exchanging" || root.step === "discovering"
      width: parent.width
      spacing: Style.spacing.sm

      Text {
        width: parent.width
        color: Color.muted
        wrapMode: Text.WordWrap
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        text: {
          if (root.step === "authorizing") return "Waiting for you to finish signing in with Google in your browser…"
          if (root.step === "exchanging") return "Finishing sign-in…"
          return "Discovering your cameras…"
        }
      }

      Button {
        text: "Cancel -- go back and re-enter information"
        onClicked: root.cancelAuthorization()
      }
    }

    // ---- pubsub fallback ----
    Column {
      visible: root.step === "pubsub" && root._gcloudFallbackCommand.length > 0
      width: parent.width
      spacing: Style.spacing.sm

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        text: "Run this once, then Retry -- or if you already created a subscription " +
          "yourself under a different name, fix the name below first:"
      }
      TextField {
        width: parent.width
        readOnly: true
        text: Sdm.gcloudCreateCommand(root.gcpProjectId, root._subscriptionNameOverride,
          Sdm.normalizeTopicPath(root.gcpProjectId, root.pubsubTopicId))
        selectByMouse: true
      }
      Row {
        width: parent.width
        spacing: Style.spacing.sm
        Text {
          text: "Subscription name:"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          anchors.verticalCenter: parent.verticalCenter
        }
        TextField {
          width: 220
          text: root._subscriptionNameOverride
          onTextChanged: root._subscriptionNameOverride = text
        }
      }
      Row {
        spacing: Style.spacing.sm
        Button { text: "Retry"; onClicked: root.retrySubscription() }
        Button {
          text: root._skipVerifyFailedOnce ? "Skip anyway" : "Skip for now (verifies first)"
          onClicked: root.skipSubscription()
        }
        Button { text: "Cancel -- go back and re-enter information"; onClicked: root.cancelAuthorization() }
      }
    }
  }
}
