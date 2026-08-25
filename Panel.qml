import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Standalone bar-widget plugin managing one keyd rule: a standalone tap of
// the physical Alt key emits F13 (bound to herdr's prefix), while holding
// Alt still passes through as a normal modifier for every existing
// Hyprland/herdr Alt-chord. CapsLock<->Ctrl and Win<->Alt stay owned by
// Hyprland's own XKB config -- this plugin never touches them.
//
// All root-owned mutation (installing keyd, writing /etc/keyd/*.conf,
// (re)starting the service) happens through exactly one fixed-argv pkexec
// call into bin/apply-keyd-config, only from an explicit popup button press.
Panel {
  id: root
  moduleName: "houz42.keyboard-remapper"
  ipcTarget: "houz42.keyboard-remapper"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  // No amber/warning token exists in the theme palette (Color.qml only
  // defines foreground/background/accent/urgent/muted) -- a fixed amber
  // keeps the drift warning visually distinct from Color.urgent's red
  // (used for destructive actions) across every theme.
  readonly property color amber: "#e0a030"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string binDir: Qt.resolvedUrl("bin").toString().replace("file://", "")
  readonly property int refreshIntervalSec: Math.max(5, Number(setting("refreshIntervalSec", 10)))

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/houz42.keyboard-remapper"
  readonly property string pendingPath: root.stateDir + "/pending.conf"

  // The rule: physical Alt, tap -> F13, hold -> passes through as Alt.
  readonly property string ruleSource: "leftalt"
  readonly property string ruleHoldLayer: "alt"
  readonly property string ruleTap: "f13"

  PersistentProperties {
    id: persisted
    reloadableId: "houz42.keyboard-remapper.rules"
    property bool altTapF13Enabled: true
  }

  // Fires a single notify-send the first time this plugin ever observes
  // keyd missing, so the user has a nudge to open the popup -- never used
  // to trigger the pkexec install itself, only ever an explicit button
  // press does that. Survives reloads/restarts (see SKILL.md's
  // one-time-ever-trigger pattern), so it fires at most once ever.
  PersistentProperties {
    id: installPrompted
    reloadableId: "houz42.keyboard-remapper.install-prompt"
    property bool shown: false
  }

  property bool ready: false
  property bool keydPresent: false
  property bool keydActive: false
  property bool drift: false
  property bool applying: false
  property string lastMessage: ""

  visible: root.ready
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function heroMeta() {
    if (root.applying) return "Applying..."
    if (!root.keydPresent) return "keyd not installed"
    if (!root.keydActive) return "keyd installed, service inactive"
    if (root.drift) return "Config drifted from expected"
    return persisted.altTapF13Enabled ? "Alt tap → F13 active" : "Alt tap → F13 disabled"
  }

  // Single source of truth for "rule state -> keyd config text", mirrored
  // line-for-line in bin/keyd-remapper-lib.sh's keyd_remapper_render() so
  // the non-privileged pending write and the privileged apply step (plus
  // the read-only drift check) always agree on what "expected" means.
  function renderConf() {
    var lines = "[ids]\n*\n\n[main]\n"
    if (persisted.altTapF13Enabled) {
      lines += root.ruleSource + " = overload(" + root.ruleHoldLayer + ", " + root.ruleTap + ")\n"
    }
    return lines
  }

  onOpenedChanged: if (opened) refreshNow()

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshNow()
  }

  Process {
    id: ensureStateDirProcess
    running: true
    command: ["mkdir", "-p", root.stateDir]
    onExited: root.refreshNow()
  }

  Process {
    id: statusProcess
    running: false
    command: [root.binDir + "/check-keyd-status", persisted.altTapF13Enabled ? "true" : "false"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("keyboard-remapper:", text.trim())
    }
  }

  function refreshNow() {
    if (statusProcess.running) return
    statusProcess.running = true
  }

  function applyStatus(text) {
    var trimmed = String(text || "").trim()
    if (trimmed === "") return
    var payload
    try {
      payload = JSON.parse(trimmed)
    } catch (e) {
      console.warn("keyboard-remapper: status collector printed invalid JSON")
      return
    }
    root.ready = true
    root.keydPresent = payload.keydPresent === true
    root.keydActive = payload.keydActive === true
    root.drift = payload.drift === true

    if (!root.keydPresent && !installPrompted.shown) {
      installPrompted.shown = true
      Quickshell.execDetached(["notify-send", "-a", "Keyboard Remapper", "Keyboard Remapper",
        "keyd isn't installed yet. Open the bar icon and press Install & Enable to set up Alt tap → F13."])
    }
  }

  FileView {
    id: pendingFile
    path: root.pendingPath
    atomicWrites: true
    printErrors: false
  }

  Process {
    id: applyProcess
    running: false
    command: ["pkexec", root.binDir + "/apply-keyd-config", root.pendingPath]

    // apply-keyd-config runs under `set -euo pipefail` and its only stdout
    // write is the final `jq -nc {...}` on full success -- that JSON (or its
    // absence) is the single source of truth for success/failure. stderr is
    // NOT a failure signal by itself: `systemctl enable` writes its "Created
    // symlink ..." confirmation to stderr even when it succeeds, so treating
    // any non-empty stderr as a failure (the previous bug) reported false
    // failures on every successful apply. stderr is logged for diagnostics
    // only, and only surfaced to the user when the apply actually failed.
    property string stderrText: ""

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.applying = false
        var ok = false
        try {
          ok = JSON.parse(String(text || "").trim()).ok === true
        } catch (e) {
          ok = false
        }
        if (ok) {
          root.lastMessage = persisted.altTapF13Enabled ? "Alt tap → F13 enabled." : "Alt tap → F13 disabled."
        } else {
          var detail = applyProcess.stderrText.trim()
          root.lastMessage = detail !== "" ? ("Apply failed: " + detail) : "Apply failed — see notification."
        }
        Quickshell.execDetached(["notify-send", "-a", "Keyboard Remapper", "Keyboard Remapper", root.lastMessage])
        root.refreshNow()
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        applyProcess.stderrText = text
        if (text.trim() !== "") console.warn("keyboard-remapper:", text.trim())
      }
    }
  }

  function applyRules() {
    if (root.applying) return
    root.applying = true
    pendingFile.setText(root.renderConf())
    applyProcess.running = true
  }

  function toggleAltTapF13() {
    if (root.applying) return
    persisted.altTapF13Enabled = !persisted.altTapF13Enabled
    root.applyRules()
  }

  // First-run path: keyd isn't installed yet, so this is a distinct action
  // from the on/off toggle above -- it applies the rule at its current
  // (default: enabled) state without flipping it, so the very first click
  // installs+enables rather than accidentally turning the rule off.
  function installAndEnable() {
    root.applyRules()
  }

  function reapply() {
    root.applyRules()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.drift ? "⚠" : "⌨"
    tooltipText: "Keyboard Remapper: " + root.heroMeta()
    onPressed: function(buttonCode) {
      root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(420))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Keyboard Remapper"
            meta: root.heroMeta()
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                anchors.centerIn: parent
                text: "⌨"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "RULES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              height: Math.max(ruleLabel.implicitHeight, ruleToggle.height)

              Column {
                id: ruleLabel
                anchors.left: parent.left
                anchors.right: ruleToggle.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  text: "Alt tap → F13"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  width: parent.width
                  text: "leftalt = overload(alt, f13)"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              Button {
                id: ruleToggle
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.keydPresent
                text: persisted.altTapF13Enabled ? "On" : "Off"
                fontSize: Style.font.bodySmall
                foreground: root.foreground
                fontFamily: root.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                active: persisted.altTapF13Enabled
                enabled: !root.applying
                onClicked: root.toggleAltTapF13()
              }

              Button {
                id: installButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: !root.keydPresent
                text: root.applying ? "Installing..." : "Install & Enable"
                fontSize: Style.font.bodySmall
                foreground: root.foreground
                fontFamily: root.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                enabled: !root.applying
                onClicked: root.installAndEnable()
              }
            }
          }

          PanelSeparator {
            visible: !root.keydPresent || root.drift
            foreground: root.foreground
          }

          Text {
            visible: !root.keydPresent
            width: parent.width
            text: "keyd is not installed yet. Press Install & Enable above to set it up via pacman (pkexec prompt)."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Column {
            visible: root.keydPresent && root.drift
            width: parent.width
            spacing: Style.space(6)

            Text {
              width: parent.width
              text: "Live config doesn't match the current rule state."
              color: root.amber
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Button {
              text: "Re-apply"
              fontSize: Style.font.bodySmall
              foreground: root.foreground
              fontFamily: root.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              enabled: !root.applying
              onClicked: root.reapply()
            }
          }

          Text {
            visible: root.lastMessage !== ""
            width: parent.width
            topPadding: Style.space(4)
            text: root.lastMessage
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
