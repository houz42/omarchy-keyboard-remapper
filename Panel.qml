import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Standalone bar-widget plugin managing a small set of keyd rules, loaded
// from rules.json next to this file -- see that file to add your own
// mappings (or the README's "Add your own mappings" section). Ships with
// one rule: a standalone tap of the physical Alt key emits F12 (bound to
// herdr's prefix), while holding Alt still passes through as a normal
// modifier for every existing Hyprland/herdr Alt-chord. Hyprland's XKB
// config stays the owner of its own kb_options, but the popup reads the
// compositor's LIVE value, shows it next to the keyd rules, flags the
// double-map class (keyd sits below XKB, so a rule whose EMITTED key is
// re-mapped by an XKB option silently produces a third key at the
// compositor), and can edit options or MIGRATE them into equivalent keyd
// rules (map/swap types) -- see the XKB section below.
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

  // Real keyboards for the per-device rule picker, from bin/list-keyboards
  // (sysfs + udev, no root). Refreshed when the popup opens; a device
  // unplugged since a rule was created still gets its own scope tab by raw
  // id (see scopeTabs), so stale rules never become invisible.
  property var keyboards: []

  Process {
    id: keyboardsProcess
    running: true   // populate once at load; re-runs each popup open
    command: [root.binDir + "/list-keyboards"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text || "").trim())
          root.keyboards = Array.isArray(parsed) ? parsed : []
        } catch (e) {
          root.keyboards = []
        }
      }
    }
  }

  function deviceOptions() {
    var opts = ["global (all keyboards)"]
    for (var i = 0; i < root.keyboards.length; i++) {
      opts.push(root.keyboards[i].name + " (" + root.keyboards[i].id + ")")
    }
    return opts
  }

  // Human label for a scope key: device names when currently seen, raw ids
  // otherwise. Shared by the scope tabs and the add-form preset.
  function scopeLabel(key) {
    var ids = key.split("+")
    var names = []
    for (var i = 0; i < ids.length; i++) {
      var found = ""
      for (var j = 0; j < root.keyboards.length; j++) {
        if (root.keyboards[j].id === ids[i]) { found = root.keyboards[j].name; break }
      }
      names.push(found !== "" ? found : ids[i])
    }
    return names.join(" + ")
  }

  // The add-form device option matching a scope (single-id scopes only;
  // multi-id tabs have no single dropdown entry, so they preset global).
  function deviceOptionFor(key) {
    if (key === "*") return "global (all keyboards)"
    var ids = key.split("+")
    if (ids.length !== 1) return "global (all keyboards)"
    for (var i = 0; i < root.keyboards.length; i++) {
      if (root.keyboards[i].id === ids[0]) return root.keyboards[i].name + " (" + ids[0] + ")"
    }
    return "global (all keyboards)"
  }

  // ----- Scope tabs: Global + one per keyboard on the machine -----
  //
  // Tabs mirror the HARDWARE (every keyboard udev sees), not just scopes
  // that already have rules -- so the per-keyboard UI is visible before
  // any scoped rule exists, and adding a rule from a device tab presets
  // that device. Scopes present in the catalog but referencing unplugged
  // devices keep a raw-id tab so their rules never disappear. Selected by
  // scope KEY, not index, so selection survives the tab list rebuilding on
  // every refresh; a selected scope that vanishes falls back to Global.
  property string selectedScopeId: "*"

  function ensureSelectedScope() {
    var tabs = root.scopeTabs()
    for (var i = 0; i < tabs.length; i++) {
      if (tabs[i].key === root.selectedScopeId) return
    }
    root.selectedScopeId = "*"
  }

  onRulesChanged: root.ensureSelectedScope()
  onKeyboardsChanged: root.ensureSelectedScope()

  function scopeTabs() {
    var keys = ["*"]
    var i
    for (i = 0; i < root.keyboards.length; i++) {
      if (keys.indexOf(root.keyboards[i].id) === -1) keys.push(root.keyboards[i].id)
    }
    for (i = 0; i < root.rules.length; i++) {
      var k = root.scopeKey(root.rules[i])
      if (keys.indexOf(k) === -1) keys.push(k)
    }
    var rest = keys.slice(1)
    rest.sort(function(a, b) {
      var la = root.scopeLabel(a).toLowerCase(), lb = root.scopeLabel(b).toLowerCase()
      return la < lb ? -1 : la > lb ? 1 : 0
    })
    return ["*"].concat(rest).map(function(k) {
      return { key: k, label: k === "*" ? "Global" : root.scopeLabel(k) }
    })
  }

  function rulesInScope(scope) {
    return root.rules.filter(function(r) { return root.scopeKey(r) === scope })
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
  //
  // Backed by a plain JSON file in the plugin's state dir rather than
  // Quickshell's PersistentProperties. PersistentProperties (a Reloadable)
  // only survives an in-process QML hot-reload -- it does NOT survive a
  // full quickshell process restart (e.g. `omarchy restart shell`, which
  // kills and respawns the process). Across a real restart it silently
  // reset to {}, so isRuleEnabled() fell back to defaultEnabled (false)
  // even though /etc/keyd still had the rule applied from before the
  // restart -- surfacing as permanent "config drift", and pressing Apply
  // at that point would have silently turned the remap off instead of
  // restoring it.
  readonly property string enabledStatePath: root.stateDir + "/enabled-state.json"
  property var enabledById: ({})

  function isRuleEnabled(rule) {
    var stored = root.enabledById[rule.id]
    if (stored !== undefined) return stored === true
    return rule.defaultEnabled === true
  }

  function setRuleEnabled(id, enabled) {
    var next = Object.assign({}, root.enabledById)
    next[id] = enabled
    root.enabledById = next
    enabledStateFile.setText(JSON.stringify(next, null, 2) + "\n")
    root.recomputeRules()
  }

  FileView {
    id: enabledStateFile
    path: root.enabledStatePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        root.enabledById = (parsed && typeof parsed === "object") ? parsed : {}
      } catch (e) {
        console.warn("keyboard-remapper: enabled-state.json parse failed:", e)
        root.enabledById = {}
      }
      root.recomputeRules()
    }
    onLoadFailed: {
      // Doesn't exist yet (no rule ever toggled) -- treat as empty rather
      // than an error; the file gets created on the first setRuleEnabled().
      root.enabledById = {}
      root.recomputeRules()
    }
    onFileChanged: reload()
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
    var conflicts = root.xkbConflictCount()
    if (conflicts > 0) return conflicts + " XKB double-map conflict" + (conflicts === 1 ? "" : "s")
    var onCount = root.rules.filter(root.isRuleEnabled).length
    if (onCount === 0) return "No rules enabled"
    return onCount + " of " + root.rules.length + " rule" + (root.rules.length === 1 ? "" : "s") + " active"
  }

  // Single source of truth for "rule state -> keyd config text". Written to
  // pendingPath (below) both right before an apply AND on every status
  // refresh, so bin/check-keyd-status never needs to know the rule format
  // itself -- it just compares the live /etc/keyd conf against this file.
  //
  // Rule types: "overload" (tap/hold, the original shape: source/holdLayer/
  // tap), "map" (plain one-way source -> target), and "swap" (bidirectional
  // source <-> target, emitted as two bindings). map/swap exist so XKB
  // options like caps:escape or altwin:swap_alt_win can migrate into keyd
  // rules 1:1 -- overloads can't express them. A rule without a `type`
  // field is an overload (schema back-compat).
  // A rule's device scope: absent/empty `devices` = global. The scope key
  // is the sorted id list joined by "+", so two rules written with the
  // same device set in different orders share a chunk.
  function scopeKey(rule) {
    var d = rule.devices
    if (!d || d.length === 0) return "*"
    return d.slice().sort().join("+")
  }

  // Rendered blob = one chunk per device scope. Each chunk is a complete
  // keyd conf headed by a marker comment -- keyd ignores "#" lines, and
  // apply-keyd-config splits on the marker and installs it WITH its chunk,
  // so the blob stays byte-identical to `cat` of the sorted live file set
  // (what check-keyd-status diffs). The global chunk always exists, even
  // with zero enabled rules, so a fresh install diffs clean. Chunk order
  // matches LC_ALL=C filename order of the installed set: "*.conf" sorts
  // before any id, and a multi-id scope ("a+b.conf") sorts before its
  // prefix single-id scope ("a.conf"), exactly like the shell's glob.
  function renderConf() {
    var groups = {}
    var scopes = []
    for (var i = 0; i < root.rules.length; i++) {
      var rule = root.rules[i]
      if (!root.isRuleEnabled(rule)) continue
      var key = root.scopeKey(rule)
      if (!groups[key]) {
        groups[key] = []
        scopes.push(key)
      }
      groups[key].push(root.ruleSyntax(rule))
    }
    if (scopes.indexOf("*") === -1) scopes.push("*")
    scopes.sort(function(a, b) {
      var fa = a + ".conf", fb = b + ".conf"
      return fa < fb ? -1 : fa > fb ? 1 : 0
    })
    var blob = ""
    for (var g = 0; g < scopes.length; g++) {
      var key = scopes[g]
      var ids = key === "*" ? ["*"] : key.split("+")
      blob += "### houz42-keyboard-remapper scope: " + key + "\n"
      blob += "[ids]\n" + ids.join("\n") + "\n\n[main]\n"
      var lines = groups[key] || []
      for (var b = 0; b < lines.length; b++) blob += lines[b] + "\n"
    }
    return blob
  }

  function ruleSyntax(rule) {
    var type = rule.type || "overload"
    if (type === "map") return rule.source + " = " + rule.target
    if (type === "swap") return rule.source + " = " + rule.target + "\n" + rule.target + " = " + rule.source
    return rule.source + " = overload(" + rule.holdLayer + ", " + rule.tap + ")"
  }

  // Keys a rule BINDS (consumes). keyd does NOT reject duplicate bindings
  // in a layer -- `keyd check` passes them and one binding silently wins,
  // shadowing the other rule with no error anywhere. Overlapping sources
  // are refused up front instead of discovered as a rule that "applies"
  // but does nothing. Note a swap binds BOTH of its keys; targets may
  // repeat freely.
  function boundSources(rule) {
    return (rule.type || "overload") === "swap" ? [rule.source, rule.target] : [rule.source]
  }

  // Device scope of a rule as a set; ["*"] = global, which overlaps every
  // other scope. Two rules only collide on a source when their scopes
  // OVERLAP -- the same key bound on disjoint keyboards is a legitimate
  // per-device remap (each lands in a different conf file), not a
  // duplicate.
  function ruleScope(rule) {
    var d = rule.devices
    return (d && d.length > 0) ? d : ["*"]
  }

  function scopesOverlap(a, b) {
    if (a.indexOf("*") !== -1 || b.indexOf("*") !== -1) return true
    for (var i = 0; i < a.length; i++) {
      if (b.indexOf(a[i]) !== -1) return true
    }
    return false
  }

  // First source collision between candidate rules and the WHOLE catalog
  // (enabled or not -- a dormant duplicate is a trap armed for later), or
  // "" when clean. Used when creating rules.
  function duplicateError(candidates) {
    var taken = {}  // source -> [{label, scope}]
    for (var i = 0; i < root.rules.length; i++) {
      var r = root.rules[i]
      root.boundSources(r).forEach(function(s) {
        if (!taken[s]) taken[s] = []
        taken[s].push({ label: r.label || r.id, scope: root.ruleScope(r) })
      })
    }
    for (var c = 0; c < candidates.length; c++) {
      var candScope = root.ruleScope(candidates[c])
      var srcs = root.boundSources(candidates[c])
      for (var s = 0; s < srcs.length; s++) {
        var prior = taken[srcs[s]] || []
        for (var p = 0; p < prior.length; p++) {
          if (root.scopesOverlap(candScope, prior[p].scope))
            return "Source key " + srcs[s] + " is already bound by '" + prior[p].label + "' on an overlapping device scope — two rules can't bind the same key for the same keyboard (keyd would silently keep only one)."
        }
        prior.push({ label: candidates[c].label || candidates[c].id, scope: candScope })
        taken[srcs[s]] = prior
      }
    }
    return ""
  }

  // Collision of one rule against the ENABLED set only -- the check that
  // runs when toggling a rule on, since keyd only ever sees enabled rules.
  function enabledDuplicateError(rule) {
    var srcs = root.boundSources(rule)
    var scope = root.ruleScope(rule)
    for (var i = 0; i < root.rules.length; i++) {
      var other = root.rules[i]
      if (other.id === rule.id || !root.isRuleEnabled(other)) continue
      if (!root.scopesOverlap(scope, root.ruleScope(other))) continue
      var otherSrcs = root.boundSources(other)
      for (var a = 0; a < srcs.length; a++) {
        if (otherSrcs.indexOf(srcs[a]) !== -1)
          return "Can't enable: " + srcs[a] + " is already bound by enabled rule '" + (other.label || other.id) + "' on an overlapping device scope — keyd would silently keep only one of them."
      }
    }
    return ""
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
  // error string, or "" on success. Which key fields are required depends
  // on the type (overload: source/holdLayer/tap; map & swap: source/target).
  // label is always auto-generated from the keys (no manual field for it --
  // it's fully derivable, so asking for it is one more thing to type for no
  // benefit); description is the only free-text, optional field.
  function addRule(fields) {
    var type = String(fields.type || "overload")
    var source = String(fields.source || "").trim()
    var description = String(fields.description || "").trim()
    var rule = {
      id: "",
      description: description,
      type: type,
      source: source,
      defaultEnabled: false
    }
    if (type === "map" || type === "swap") {
      var target = String(fields.target || "").trim()
      if (source === "" || target === "") {
        return "Source and target keys are both required."
      }
      rule.target = target
      rule.label = source + (type === "swap" ? " ⇄ " : " → ") + target
      rule.id = root.uniqueRuleId(root.slugify(source + "-" + target))
    } else {
      rule.type = "overload"
      var holdLayer = String(fields.holdLayer || "").trim()
      var tap = String(fields.tap || "").trim()
      if (source === "" || holdLayer === "" || tap === "") {
        return "Source, hold layer, and tap key are all required."
      }
      rule.holdLayer = holdLayer
      rule.tap = tap
      rule.label = source + " tap → " + tap
      rule.id = root.uniqueRuleId(root.slugify(source + "-" + tap))
    }
    // Optional per-device scope: the dropdown offers "global (all
    // keyboards)" plus "Name (vid:pid)" entries; only the latter set
    // `devices`. Multi-keyboard scopes are expressible by adding the same
    // rule per device.
    var deviceMatch = String(fields.device || "").match(/\(([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\)\s*$/)
    if (deviceMatch) rule.devices = [deviceMatch[1].toLowerCase()]

    var collision = root.duplicateError([rule])
    if (collision !== "") return collision
    root.saveUserRules(root.userRules.concat([rule]))
    return ""
  }

  function removeRule(id) {
    root.saveUserRules(root.userRules.filter(function(r) { return r.id !== id }))
    if (root.enabledById[id] !== undefined) {
      var next = Object.assign({}, root.enabledById)
      delete next[id]
      root.enabledById = next
      enabledStateFile.setText(JSON.stringify(next, null, 2) + "\n")
    }
  }

  onOpenedChanged: if (opened) {
    refreshNow()
    keyboardsProcess.running = true
  }

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
    if (!statusProcess.running) statusProcess.running = true
    if (!xkbProcess.running) xkbProcess.running = true
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
        "keyd isn't installed yet. Open the bar icon and press Install & Enable to set up Alt tap → F12."])
    }
  }

  // ----- Live XKB options (read-only awareness; Hyprland owns them) -----
  //
  // Read via `hyprctl getoption` (the compositor's actual live value, which
  // works under Quattro/Lua config too) rather than by parsing the user's
  // hyprland config files -- Lua syntax, multiple config blocks, and stale
  // .conf siblings make file-parsing fragile, and the live value is the only
  // one that matters for conflict detection anyway. hyprctl inherits the
  // session env from the shell process, so no environment setup is needed.
  property bool xkbAvailable: false
  property string xkbOptionsRaw: ""

  Process {
    id: xkbProcess
    running: false
    command: ["hyprctl", "getoption", "input:kb_options"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyXkbStatus(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      // Failures (not on Hyprland, hyprctl missing) surface as "no str: line"
      // in applyXkbStatus; nothing to do with stderr itself.
      onStreamFinished: {}
    }
  }

  function applyXkbStatus(text) {
    var match = String(text || "").match(/^str:\s*(.*)$/m)
    if (!match) {
      root.xkbAvailable = false
      root.xkbOptionsRaw = ""
      return
    }
    root.xkbAvailable = true
    root.xkbOptionsRaw = match[1].trim()
  }

  // Known remapping options, decoded straight into keyd key names so the
  // conflict check below can compare against rule source/tap without any
  // keysym translation. `swaps` register both directions in the seen-as map,
  // `maps` (one-way "acts as") register one. Options not in the table
  // (compose:, grp:, lv3:, shift:...) aren't key remaps -- they're listed
  // raw in the UI and never conflict.
  readonly property var xkbOptionTable: ({
    "altwin:swap_alt_win":   { label: "Swap Alt ⇄ Super (both sides)", swaps: [["leftalt", "leftmeta"], ["rightalt", "rightmeta"]] },
    "altwin:swap_lalt_lwin": { label: "Swap Left Alt ⇄ Left Super",    swaps: [["leftalt", "leftmeta"]] },
    "altwin:meta_alt":       { label: "Alt keys act as Super",         maps:  [["leftalt", "leftmeta"], ["rightalt", "rightmeta"]] },
    "altwin:ctrl_win":       { label: "Win keys act as Ctrl",          maps:  [["leftmeta", "leftctrl"], ["rightmeta", "rightctrl"]] },
    "caps:escape":           { label: "CapsLock acts as Escape",       maps:  [["capslock", "escape"]] },
    "caps:swapescape":       { label: "Swap CapsLock ⇄ Escape",        swaps: [["capslock", "escape"]] },
    "caps:ctrl_modifier":    { label: "CapsLock is an extra Ctrl",     maps:  [["capslock", "leftctrl"]] },
    "caps:super":            { label: "CapsLock is an extra Super",    maps:  [["capslock", "leftmeta"]] },
    "ctrl:swap_lwin_lctl":   { label: "Swap Left Super ⇄ Left Ctrl",   swaps: [["leftmeta", "leftctrl"]] },
    "ctrl:swap_rwin_rctl":   { label: "Swap Right Super ⇄ Right Ctrl", swaps: [["rightmeta", "rightctrl"]] }
  })

  // Representative evdev key for each hold layer's modifier output -- what
  // the compositor actually sees pressed while the rule is held.
  readonly property var holdLayerKeys: ({ "alt": "leftalt", "control": "leftctrl", "shift": "leftshift", "meta": "leftmeta", "altgr": "rightalt" })

  // key-as-emitted -> key-as-seen-by-the-compositor, derived from the live
  // options. Rebuilt whenever xkbOptionsRaw changes.
  readonly property var xkbSeenAs: (function() {
    var seen = {}
    var tokens = root.xkbOptionsRaw === "" ? [] : root.xkbOptionsRaw.split(",")
    for (var t = 0; t < tokens.length; t++) {
      var token = tokens[t].trim()
      if (!Object.prototype.hasOwnProperty.call(root.xkbOptionTable, token)) continue
      var entry = root.xkbOptionTable[token]
      if (!entry) continue
      var i
      if (entry.swaps) for (i = 0; i < entry.swaps.length; i++) {
        seen[entry.swaps[i][0]] = entry.swaps[i][1]
        seen[entry.swaps[i][1]] = entry.swaps[i][0]
      }
      if (entry.maps) for (i = 0; i < entry.maps.length; i++) {
        seen[entry.maps[i][0]] = entry.maps[i][1]
      }
    }
    return seen
  })()

  // Rows for the XKB section: every live option token, decoded when known.
  function xkbRows() {
    if (!root.xkbAvailable || root.xkbOptionsRaw === "") return []
    var tokens = root.xkbOptionsRaw.split(",")
    var rows = []
    for (var i = 0; i < tokens.length; i++) {
      var token = tokens[i].trim()
      if (token === "") continue
      var known = Object.prototype.hasOwnProperty.call(root.xkbOptionTable, token)
      rows.push({ token: token, label: known ? root.xkbOptionTable[token].label : "", migratable: known })
    }
    return rows
  }

  // Amber warning for an ENABLED rule whose emitted key is re-mapped by a
  // live XKB option -- the double-map trap: the rule says leftalt → leftmeta,
  // but an XKB swap turns that leftmeta back into leftalt, so the compositor
  // shows the opposite of the rule's label. The rule's SOURCE key is never
  // checked: keyd consumes it at evdev level, before XKB runs, so a swap
  // can't change what reaches a rule's input side.
  function xkbConflict(rule) {
    if (!root.isRuleEnabled(rule)) return ""
    var seen = root.xkbSeenAs
    var parts = []
    var tapSeen = seen[rule.tap]
    if (tapSeen) parts.push("tap emits " + rule.tap + " → compositor sees " + tapSeen)
    var holdKey = root.holdLayerKeys[rule.holdLayer]
    var holdSeen = holdKey ? seen[holdKey] : ""
    if (holdSeen) parts.push("hold emits " + holdKey + " → compositor sees " + holdSeen)
    return parts.length === 0 ? "" : parts.join("; ") + " (XKB)"
  }

  function xkbConflictCount() {
    var n = 0
    for (var i = 0; i < root.rules.length; i++) {
      if (root.xkbConflict(root.rules[i]) !== "") n++
    }
    return n
  }

  // ----- XKB option editing (writes the user's Hyprland config) -----
  //
  // Hyprland auto-reloads on the config write, so the change goes live on
  // its own; the post-write timer just forces an early re-read instead of
  // waiting for the next poll tick.
  property bool xkbApplying: false
  property string xkbPendingOptions: ""

  Process {
    id: xkbSetProcess
    running: false
    command: [root.binDir + "/set-xkb-options", root.xkbPendingOptions]
    property string stderrText: ""

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.xkbApplying = false
        var msg
        try {
          var payload = JSON.parse(String(text || "").trim())
          if (payload.ok === true) {
            msg = "kb_options updated in " + String(payload.file || "?").split("/").pop()
            if (payload.chezmoi === "readded") msg += " (chezmoi re-added)"
            else if (payload.chezmoi === "template-skipped") msg += " — chezmoi TEMPLATE source not updated, edit it by hand"
            else if (payload.chezmoi === "readd-failed") msg += " — chezmoi re-add FAILED, run 'chezmoi re-add' yourself"
          } else {
            msg = "XKB update failed: " + (payload.error || "unknown error")
          }
        } catch (e) {
          msg = "XKB update failed (no result from writer)"
        }
        root.lastMessage = msg
        root.refreshNow()
        xkbPostWriteTimer.restart()
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { xkbSetProcess.stderrText = text }
    }
  }

  Timer {
    id: xkbPostWriteTimer
    interval: 2000
    onTriggered: root.refreshNow()
  }

  function xkbTokensNow() {
    if (root.xkbOptionsRaw === "") return []
    return root.xkbOptionsRaw.split(",").map(function(s) { return s.trim() }).filter(function(s) { return s !== "" })
  }

  function setXkbOptions(tokens) {
    if (root.xkbApplying) return
    root.xkbApplying = true
    root.xkbPendingOptions = tokens.join(",")
    xkbSetProcess.running = true
  }

  function removeXkbOptions(tokens) {
    var drop = {}
    tokens.forEach(function(t) { drop[t] = true })
    root.setXkbOptions(root.xkbTokensNow().filter(function(t) { return !drop[t] }))
  }

  function removeXkbOption(token) {
    root.removeXkbOptions([token])
  }

  function addXkbOption(token) {
    token = String(token || "").trim()
    if (token === "" || root.xkbTokensNow().indexOf(token) !== -1) return
    root.setXkbOptions(root.xkbTokensNow().concat([token]))
  }

  function xkbAddableOptions() {
    var now = {}
    root.xkbTokensNow().forEach(function(t) { now[t] = true })
    var out = []
    for (var k in root.xkbOptionTable) {
      if (Object.prototype.hasOwnProperty.call(root.xkbOptionTable, k) && !now[k]) out.push(k)
    }
    return out.sort()
  }

  function xkbMigratableTokens() {
    return root.xkbTokensNow().filter(function(t) {
      return Object.prototype.hasOwnProperty.call(root.xkbOptionTable, t)
    })
  }

  // ----- XKB option -> keyd rule migration -----
  //
  // Two phases with the pkexec apply in between, in the only safe order:
  // create+enable the keyd rules and APPLY them first, remove the XKB option
  // only after the keyd side is live. Reversing it (or removing on failure)
  // would leave the mapping dead in the gap. A failed/cancelled apply rolls
  // the created rules back out, so state returns exactly to pre-migration.
  // The brief window between apply and option-removal has the mapping in
  // BOTH layers (double-map) -- the conflict warnings flag it, and it lasts
  // about a second.
  property var pendingXkbMigration: null

  // The rules produced from one XKB option token: one rule per key pair so
  // each side stays independently removable afterwards. Swaps become the
  // bidirectional "swap" type (one row covers both directions); one-way
  // "acts as" options become "map" rules.
  function xkbRulesFor(token) {
    if (!Object.prototype.hasOwnProperty.call(root.xkbOptionTable, token)) return []
    var entry = root.xkbOptionTable[token]
    var pairs = entry.swaps ? entry.swaps : entry.maps
    var type = entry.swaps ? "swap" : "map"
    var rules = []
    for (var i = 0; i < pairs.length; i++) {
      var a = pairs[i][0], b = pairs[i][1]
      rules.push({
        id: root.uniqueRuleId(root.slugify("xkb-" + a + "-" + b)),
        label: a + (type === "swap" ? " ⇄ " : " → ") + b,
        description: "Migrated from XKB option " + token,
        type: type,
        source: a,
        target: b,
        defaultEnabled: true
      })
    }
    return rules
  }

  function migrateXkbOptions(tokens) {
    if (root.applying || root.xkbApplying || root.pendingXkbMigration) return
    tokens = tokens.filter(function(t) { return root.xkbMigratableTokens().indexOf(t) !== -1 })
    if (tokens.length === 0) return
    var newRules = []
    for (var t = 0; t < tokens.length; t++) newRules = newRules.concat(root.xkbRulesFor(tokens[t]))
    if (newRules.length === 0) return
    // Refuse the whole batch on any source collision with the catalog -- a
    // half-migrated set is worse than none.
    var collision = root.duplicateError(newRules)
    if (collision !== "") {
      root.lastMessage = "Migration refused: " + collision
      return
    }
    root.pendingXkbMigration = { tokens: tokens, ruleIds: newRules.map(function(r) { return r.id }) }
    var next = root.userRules.concat(newRules)
    root.saveUserRules(next)
    // Mirrors setRuleEnabled's pattern: update in-memory state synchronously
    // (the FileView watch re-confirms from disk) so applyRules() below
    // renders the NEW rules, not the pre-migration catalog.
    root.userRules = next
    root.recomputeRules()
    root.applyRules()
  }

  function rollbackMigration() {
    var mig = root.pendingXkbMigration
    if (!mig) return
    var drop = {}
    mig.ruleIds.forEach(function(id) { drop[id] = true })
    var next = root.userRules.filter(function(r) { return !drop[r.id] })
    root.pendingXkbMigration = null
    root.saveUserRules(next)
    root.userRules = next
    root.recomputeRules()
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
        var errDetail = ""
        try {
          var payload = JSON.parse(String(text || "").trim())
          ok = payload.ok === true
          errDetail = String(payload.error || "")
        } catch (e) {
          ok = false
        }
        if (ok) {
          root.lastMessage = "Applied."
        } else {
          var detail = errDetail !== "" ? errDetail : applyProcess.stderrText.trim()
          root.lastMessage = detail !== "" ? ("Apply failed: " + detail) : "Apply failed — see notification."
        }
        // Migration phase 2: the XKB options come out ONLY after the keyd
        // side is live. On failure the created rules roll back, restoring
        // the exact pre-migration state (XKB options untouched either way).
        var mig = root.pendingXkbMigration
        if (mig) {
          if (ok) {
            root.pendingXkbMigration = null
            root.removeXkbOptions(mig.tokens)
          } else {
            root.rollbackMigration()
            root.lastMessage = "Migration aborted, XKB options kept. " + root.lastMessage
          }
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
    if (!root.isRuleEnabled(rule)) {
      var collision = root.enabledDuplicateError(rule)
      if (collision !== "") {
        root.lastMessage = collision
        return
      }
    }
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
    text: (root.drift || root.xkbConflictCount() > 0) ? "⚠" : "⌨"
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

            // Scope tabs: Global plus every keyboard seen on the machine.
            // Flow (not Row) so the chips WRAP -- several long device names
            // would otherwise run off the popup's fixed narrow width.
            Flow {
              id: scopeChips
              visible: root.scopeTabs().length > 1
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.scopeTabs()

                delegate: Button {
                  text: modelData.label
                  selected: root.selectedScopeId === modelData.key
                  bordered: true
                  fontSize: Style.font.caption
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY
                  onClicked: root.selectedScopeId = modelData.key
                }
              }
            }

            Text {
              visible: root.rulesInScope(root.selectedScopeId).length === 0
              text: root.selectedScopeId === "*"
                ? "No global rules."
                : "No rules scoped to this device. Global rules still apply to it."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width
            }

            Repeater {
              model: root.rulesInScope(root.selectedScopeId)

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

                  // Double-map warning: this rule's emitted key is itself
                  // re-mapped by a live XKB option (see the XKB section
                  // below), so what apps receive differs from the rule.
                  Text {
                    visible: text !== ""
                    width: parent.width
                    text: root.xkbConflict(ruleRow.modelData)
                    color: root.amber
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
                  text: root.ruleSyntax(ruleRow.modelData)
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
                  onClicked: {
                    // Opened from a scope tab -> preset that device, so a
                    // rule added from the Milsky tab lands on the Milsky.
                    deviceDropdown.value = root.deviceOptionFor(root.selectedScopeId)
                    addRuleForm.visible = true
                  }
                }
              }

              Column {
                id: addRuleForm
                visible: false
                width: parent.width
                spacing: Style.space(6)

                TextField { id: descriptionField; width: parent.width; placeholderText: "Description (optional)"; foreground: root.foreground }

                SearchableDropdown {
                  id: typeDropdown
                  width: parent.width
                  label: "Rule type"
                  placeholderText: "Search types..."
                  triggerLabel: "Select type (default: tap/hold overload)"
                  options: ["overload", "map", "swap"]
                  foreground: root.foreground
                }

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
                  id: deviceDropdown
                  width: parent.width
                  label: "Device (optional)"
                  placeholderText: "Search devices..."
                  triggerLabel: "Global (all keyboards)"
                  options: root.deviceOptions()
                  foreground: root.foreground
                }

                SearchableDropdown {
                  id: holdLayerDropdown
                  visible: typeDropdown.value === "" || typeDropdown.value === "overload"
                  width: parent.width
                  label: "Hold layer"
                  placeholderText: "Search layers..."
                  triggerLabel: "Select hold layer"
                  options: root.holdLayerNames
                  foreground: root.foreground
                }

                SearchableDropdown {
                  id: tapDropdown
                  visible: typeDropdown.value === "" || typeDropdown.value === "overload"
                  width: parent.width
                  label: "Tap key"
                  placeholderText: "Search keys..."
                  triggerLabel: "Select tap key"
                  options: root.keyNames
                  foreground: root.foreground
                }

                SearchableDropdown {
                  id: targetDropdown
                  visible: typeDropdown.value === "map" || typeDropdown.value === "swap"
                  width: parent.width
                  label: "Target key"
                  placeholderText: "Search keys..."
                  triggerLabel: "Select target key"
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
                        type: typeDropdown.value,
                        source: sourceDropdown.value,
                        holdLayer: holdLayerDropdown.value,
                        tap: tapDropdown.value,
                        target: targetDropdown.value,
                        device: deviceDropdown.value
                      })
                      if (error !== "") {
                        formError.text = error
                        return
                      }
                      formError.text = ""
                      descriptionField.text = ""
                      typeDropdown.value = ""
                      sourceDropdown.value = ""
                      deviceDropdown.value = ""
                      holdLayerDropdown.value = ""
                      tapDropdown.value = ""
                      targetDropdown.value = ""
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

          // ----- System mappings outside keyd's reach -----
          //
          // The compositor's own XKB options apply AFTER keyd, so they are
          // part of the effective mapping for every key this plugin emits.
          // Options can be removed/added here (rewrites the Hyprland config;
          // chezmoi-tracked files are re-added so the change survives
          // `chezmoi apply`), or MIGRATED into equivalent keyd rules, which
          // moves ownership of that mapping into this plugin.
          PanelSeparator {
            visible: xkbSection.visible
            foreground: root.foreground
          }

          Column {
            id: xkbSection
            visible: root.xkbAvailable
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "XKB — VIA HYPRLAND"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              id: xkbRepeater
              model: root.xkbRows()

              delegate: Item {
                id: xkbRow
                required property var modelData
                width: parent.width
                height: Math.max(xkbRowLabel.implicitHeight, xkbRowActions.implicitHeight)

                Column {
                  id: xkbRowLabel
                  anchors.left: parent.left
                  anchors.right: xkbRowActions.left
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 0

                  Text {
                    width: parent.width
                    text: modelData.label !== "" ? modelData.label : modelData.token
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }

                  Text {
                    visible: modelData.label !== ""
                    width: parent.width
                    text: modelData.token
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Row {
                  id: xkbRowActions
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  // Migrate this option into keyd rule(s), then drop the
                  // option -- only shown for options with known semantics.
                  Button {
                    visible: xkbRow.modelData.migratable
                    text: "→ keyd"
                    fontSize: Style.font.caption
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    bordered: true
                    enabled: !root.applying && !root.xkbApplying && root.pendingXkbMigration === null
                    onClicked: root.migrateXkbOptions([xkbRow.modelData.token])
                  }

                  PanelActionButton {
                    iconText: "-"
                    tooltipText: "Remove " + xkbRow.modelData.token + " from kb_options"
                    foreground: root.foreground
                    hoverColor: Color.urgent
                    enabled: !root.xkbApplying && root.pendingXkbMigration === null
                    onClicked: root.removeXkbOption(xkbRow.modelData.token)
                  }
                }
              }
            }

            Row {
              spacing: Style.space(12)
              visible: !addXkbForm.visible

              Text {
                visible: root.xkbAddableOptions().length > 0
                text: "+ Add option"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: addXkbForm.visible = true
                }
              }

              Text {
                visible: root.xkbMigratableTokens().length > 1
                text: "Migrate all to keyd"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.migrateXkbOptions(root.xkbMigratableTokens())
                }
              }
            }

            Column {
              id: addXkbForm
              visible: false
              width: parent.width
              spacing: Style.space(6)

              SearchableDropdown {
                id: xkbOptionDropdown
                width: parent.width
                label: "XKB option"
                placeholderText: "Search options..."
                triggerLabel: "Select option"
                options: root.xkbAddableOptions()
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
                  enabled: !root.xkbApplying
                  onClicked: {
                    root.addXkbOption(xkbOptionDropdown.value)
                    xkbOptionDropdown.value = ""
                    addXkbForm.visible = false
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
                  onClicked: addXkbForm.visible = false
                }
              }
            }

            Text {
              width: parent.width
              text: "Live compositor kb_options, applied after keyd. − removes an option; → keyd migrates it into a rule above (option removed once the keyd side is live)."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
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
