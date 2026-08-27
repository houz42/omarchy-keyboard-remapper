import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Standalone bar-widget plugin managing a small set of keyd rules, loaded
// from rules.json next to this file -- see that file to add your own
// mappings (or the README's "Add your own mappings" section). Ships with
// one rule: a standalone tap of the physical Alt key emits F13 (bound to
// herdr's prefix), while holding Alt still passes through as a normal
// modifier for every existing Hyprland/herdr Alt-chord. CapsLock<->Ctrl and
// Win<->Alt stay owned by Hyprland's own XKB config -- this plugin never
// touches them.
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
  readonly property string rulesPath: Qt.resolvedUrl("rules.json").toString().replace("file://", "")
  // Gitignored, unlike rules.json -- this plugin's own repo gets `git add -A`
  // + pushed during development, so anything the popup writes into a
  // tracked file risks getting swept into a public commit. Rules you add
  // from the popup live here instead, never in the shipped/tracked file.
  readonly property string userRulesPath: Qt.resolvedUrl("user-rules.json").toString().replace("file://", "")
  readonly property string keyNamesPath: Qt.resolvedUrl("keyd-keys.json").toString().replace("file://", "")
  readonly property int refreshIntervalSec: Math.max(5, Number(setting("refreshIntervalSec", 10)))

  // Valid keyd key names, from `keyd list-keys`, for the source/tap pickers
  // in the Add-rule form (see keyNamesFile below). Standard modifier layer
  // names for the hold-layer picker aren't in `keyd list-keys` (they're
  // implicit, not physical keys) so this list is hand-maintained; it covers
  // every case Panel.qml's simple one-line-per-rule renderer can produce
  // (custom `[layername]` sections aren't generated here).
  property var keyNames: []
  readonly property var holdLayerNames: ["alt", "control", "shift", "meta", "altgr"]

  FileView {
    id: keyNamesFile
    path: root.keyNamesPath
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        root.keyNames = Array.isArray(parsed.keys) ? parsed.keys : []
      } catch (e) {
        console.warn("keyboard-remapper: keyd-keys.json parse failed:", e)
      }
    }
  }

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/houz42.keyboard-remapper"
  readonly property string pendingPath: root.stateDir + "/pending.conf"

  // Rule catalog: shipped/tracked rules.json (read-only from this plugin's
  // own perspective -- never written by the popup) merged with gitignored
  // user-rules.json (the popup's own scratch space). Each entry: {id, label,
  // description?, source, holdLayer, tap, defaultEnabled?}, plus a
  // runtime-only _removable flag added at merge time (not persisted) so the
  // UI only offers to remove rules the popup itself can safely delete.
  property var shippedRules: []
  property var userRules: []
  property var rules: []

  function recomputeRules() {
    var shippedIds = {}
    var merged = root.shippedRules.map(function(r) {
      shippedIds[r.id] = true
      return Object.assign({}, r, { _removable: false })
    })
    root.userRules.forEach(function(r) {
      // A shipped rule re-adding the same id (e.g. after a plugin update)
      // wins over a same-id user rule, so an upstream default can't be
      // silently shadowed by stale local state.
      if (shippedIds[r.id]) return
      merged.push(Object.assign({}, r, { _removable: true }))
    })
    root.rules = merged
    root.syncPendingFile()
    root.refreshNow()
  }

  // Per-rule on/off state, keyed by rule id -- kept separate from rules.json
  // itself so editing rules.json (adding your own mappings, pulling plugin
  // updates) never clobbers what you've toggled on/off, and vice versa.
  PersistentProperties {
    id: persisted
    reloadableId: "houz42.keyboard-remapper.rules"
    property var enabledById: ({})
    // Restoring enabledById from disk is async and races rulesFile/
    // userRulesFile loading -- if recomputeRules() already ran (and
    // rendered pendingPath) before this restore lands, pendingPath is
    // stuck reflecting the default-disabled state while the real /etc/keyd
    // conf still has the previously-applied rules, which check-keyd-status
    // then reports as permanent drift. Re-syncing here whenever the
    // restored (or toggled) state actually changes keeps pendingPath
    // truthful regardless of load order.
    onEnabledByIdChanged: root.recomputeRules()
  }

  function isRuleEnabled(rule) {
    var stored = persisted.enabledById[rule.id]
    if (stored !== undefined) return stored === true
    return rule.defaultEnabled === true
  }

  function setRuleEnabled(id, enabled) {
    var next = Object.assign({}, persisted.enabledById)
    next[id] = enabled
    persisted.enabledById = next
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
    var onCount = root.rules.filter(root.isRuleEnabled).length
    if (onCount === 0) return "No rules enabled"
    return onCount + " of " + root.rules.length + " rule" + (root.rules.length === 1 ? "" : "s") + " active"
  }

  // Single source of truth for "rule state -> keyd config text". Written to
  // pendingPath (below) both right before an apply AND on every status
  // refresh, so bin/check-keyd-status never needs to know the rule format
  // itself -- it just compares the live /etc/keyd conf against this file.
  function renderConf() {
    var lines = "[ids]\n*\n\n[main]\n"
    for (var i = 0; i < root.rules.length; i++) {
      var rule = root.rules[i]
      if (!root.isRuleEnabled(rule)) continue
      lines += rule.source + " = overload(" + rule.holdLayer + ", " + rule.tap + ")\n"
    }
    return lines
  }

  function syncPendingFile() {
    pendingFile.setText(root.renderConf())
  }

  FileView {
    id: rulesFile
    path: root.rulesPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.shippedRules = root.parseRulesJson(text(), "rules.json")
      root.recomputeRules()
    }
    onFileChanged: reload()
  }

  FileView {
    id: userRulesFile
    path: root.userRulesPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.userRules = root.parseRulesJson(text(), "user-rules.json")
      root.recomputeRules()
    }
    onLoadFailed: {
      // Doesn't exist yet (nothing added from the popup so far) -- treat
      // as an empty list rather than an error; the file gets created on
      // the first actual addRule() write.
      root.userRules = []
      root.recomputeRules()
    }
    onFileChanged: reload()
  }

  function parseRulesJson(text, sourceLabel) {
    var trimmed = String(text || "").trim()
    if (trimmed === "") return []
    try {
      var parsed = JSON.parse(trimmed)
      return Array.isArray(parsed.rules) ? parsed.rules : []
    } catch (e) {
      console.warn("keyboard-remapper: " + sourceLabel + " parse failed:", e)
      return []
    }
  }

  // Writes the popup-added rule catalog back to user-rules.json -- never to
  // the shipped/tracked rules.json. userRulesFile's watchChanges then
  // reloads and re-derives everything else (merged rule list, pending
  // conf, status) from the new content, so this is the only place that
  // needs to know the file format.
  function saveUserRules(newUserRules) {
    userRulesFile.setText(JSON.stringify({ rules: newUserRules }, null, 2) + "\n")
  }

  function slugify(text) {
    return String(text || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
  }

  function uniqueRuleId(base) {
    var candidate = base !== "" ? base : "rule"
    var existing = {}
    root.rules.forEach(function(r) { existing[r.id] = true })
    var id = candidate
    var n = 2
    while (existing[id]) {
      id = candidate + "-" + n
      n++
    }
    return id
  }

  // Validates and appends one rule from the "Add rule" form. Returns an
  // error string, or "" on success. source/holdLayer/tap are required --
  // they're what actually drives the keyd config. label is always
  // auto-generated from source+tap (no manual field for it -- it's fully
  // derivable, so asking for it is one more thing to type for no benefit);
  // description is the only free-text, optional field.
  function addRule(fields) {
    var source = String(fields.source || "").trim()
    var holdLayer = String(fields.holdLayer || "").trim()
    var tap = String(fields.tap || "").trim()
    if (source === "" || holdLayer === "" || tap === "") {
      return "Source, hold layer, and tap key are all required."
    }
    var description = String(fields.description || "").trim()
    var rule = {
      id: root.uniqueRuleId(root.slugify(source + "-" + tap)),
      label: source + " tap → " + tap,
      description: description,
      source: source,
      holdLayer: holdLayer,
      tap: tap,
      defaultEnabled: false
    }
    root.saveUserRules(root.userRules.concat([rule]))
    return ""
  }

  function removeRule(id) {
    root.saveUserRules(root.userRules.filter(function(r) { return r.id !== id }))
    if (persisted.enabledById[id] !== undefined) {
      var next = Object.assign({}, persisted.enabledById)
      delete next[id]
      persisted.enabledById = next
    }
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
    command: [root.binDir + "/check-keyd-status", root.pendingPath]

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
          root.lastMessage = "Applied."
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

  function toggleRule(rule) {
    if (root.applying) return
    root.setRuleEnabled(rule.id, !root.isRuleEnabled(rule))
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
    contentWidth: panel.fittedContentWidth(Style.space(320))
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

            Repeater {
              model: root.rules

              Item {
                id: ruleRow
                required property var modelData

                width: parent.width
                height: Math.max(ruleLabel.implicitHeight, ruleToggle.height, removeButton.size)

                Column {
                  id: ruleLabel
                  anchors.left: parent.left
                  anchors.right: removeButton.left
                  anchors.rightMargin: ruleRow.modelData._removable === true ? Style.space(6) : 0
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    text: ruleRow.modelData.label || ruleRow.modelData.id
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  // Optional human-readable description, in place of the raw
                  // keyd syntax -- the syntax itself is still available on
                  // hover, for anyone who wants it.
                  Text {
                    visible: (ruleRow.modelData.description || "") !== ""
                    width: parent.width
                    text: ruleRow.modelData.description || ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }

                MouseArea {
                  id: ruleHover
                  anchors.fill: ruleLabel
                  hoverEnabled: true
                  acceptedButtons: Qt.NoButton
                }

                PanelToolTip {
                  visible: ruleHover.containsMouse
                  text: ruleRow.modelData.source + " = overload(" + ruleRow.modelData.holdLayer + ", " + ruleRow.modelData.tap + ")"
                  fontFamily: root.fontFamily
                }

                PanelActionButton {
                  id: removeButton
                  anchors.right: ruleToggle.visible ? ruleToggle.left : parent.right
                  anchors.rightMargin: (visible && ruleToggle.visible) ? Style.space(6) : 0
                  anchors.verticalCenter: parent.verticalCenter
                  // Only rules added from this popup (user-rules.json) can
                  // be removed here -- shipped/example rules from the
                  // tracked rules.json can be toggled off but not deleted
                  // (deleting one would just come back on the next `git
                  // pull`/plugin update anyway).
                  visible: ruleRow.modelData._removable === true
                  width: visible ? size : 0
                  iconText: "-"
                  tooltipText: "Remove " + (ruleRow.modelData.label || ruleRow.modelData.id)
                  foreground: root.foreground
                  hoverColor: Color.urgent
                  enabled: !root.applying
                  onClicked: root.removeRule(ruleRow.modelData.id)
                }

                ToggleSwitch {
                  id: ruleToggle
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  visible: root.keydPresent
                  checked: root.isRuleEnabled(ruleRow.modelData)
                  busy: root.applying
                  foreground: root.foreground
                  onToggled: root.toggleRule(ruleRow.modelData)
                }
              }
            }

            // ---------- Add rule ----------
            Column {
              width: parent.width
              spacing: Style.space(8)

              Text {
                visible: !addRuleForm.visible
                text: "+ Add rule"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: addRuleForm.visible = true
                }
              }

              Column {
                id: addRuleForm
                visible: false
                width: parent.width
                spacing: Style.space(6)

                TextField { id: descriptionField; width: parent.width; placeholderText: "Description (optional)"; foreground: root.foreground }

                SearchableDropdown {
                  id: sourceDropdown
                  width: parent.width
                  label: "Source key"
                  placeholderText: "Search keys..."
                  triggerLabel: "Select source key"
                  options: root.keyNames
                  foreground: root.foreground
                }

                SearchableDropdown {
                  id: holdLayerDropdown
                  width: parent.width
                  label: "Hold layer"
                  placeholderText: "Search layers..."
                  triggerLabel: "Select hold layer"
                  options: root.holdLayerNames
                  foreground: root.foreground
                }

                SearchableDropdown {
                  id: tapDropdown
                  width: parent.width
                  label: "Tap key"
                  placeholderText: "Search keys..."
                  triggerLabel: "Select tap key"
                  options: root.keyNames
                  foreground: root.foreground
                }

                Row {
                  spacing: Style.space(8)

                  Button {
                    text: "Add"
                    fontSize: Style.font.bodySmall
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    bordered: true
                    onClicked: {
                      var error = root.addRule({
                        description: descriptionField.text,
                        source: sourceDropdown.value,
                        holdLayer: holdLayerDropdown.value,
                        tap: tapDropdown.value
                      })
                      if (error !== "") {
                        formError.text = error
                        return
                      }
                      formError.text = ""
                      descriptionField.text = ""
                      sourceDropdown.value = ""
                      holdLayerDropdown.value = ""
                      tapDropdown.value = ""
                      addRuleForm.visible = false
                    }
                  }

                  Button {
                    text: "Cancel"
                    fontSize: Style.font.bodySmall
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    bordered: true
                    onClicked: {
                      formError.text = ""
                      addRuleForm.visible = false
                    }
                  }
                }

                Text {
                  id: formError
                  visible: text !== ""
                  width: parent.width
                  text: ""
                  color: root.amber
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }
            }

            Button {
              id: installButton
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
