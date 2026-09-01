pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Synology Drive: the panel, and the owner of all state.
//
// Loaded by BarWidget.qml (the manifest entry point), which injects bar,
// anchorItem and hostWidget and forwards open/close/toggle to us. IPC is
// left to the bar widget so the target is registered once.
//
// Everything here is read from what the Synology Drive Client already keeps
// on disk (its SQLite databases and daemon log) via bin/syndstatus. Pause and
// resume go to the sync daemon over its local socket with the same request
// the client's own button sends (PROTOCOL.md); nothing under the sync folders
// is touched, and no client setting is written.
Panel {
  id: root
  moduleName: "dansmith888.synology-drive"
  manageIpc: false

  // Injected by BarWidget.qml. The bar tracks the widget mounted in its slot,
  // not this nested panel, so everything the bar identifies a panel by has to
  // be that widget.
  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // ---- State. Mirrors the JSON from bin/syndstatus; see bin/syndctl get.
  property bool devicePresent: false   // client installed
  property string syncState: ""        // uptodate|syncing|paused|offline|error|stopped|unlinked
  property bool paused: false
  property var pausedSessions: []      // ids currently paused
  property bool offline: false
  property bool daemonRunning: false
  property bool uiRunning: false
  property string version: ""
  property var connection: null        // {server, host, user, port, ssl, ...}
  property var sessions: []            // sync folders
  property int pending: 0
  property var current: null           // the file a worker is on right now
  property var queue: []
  property var recent: []              // history, newest first
  property string recentSig: ""        // cheap change detector for `recent`
  property var unsynced: []
  property int unsyncedCount: 0
  property var clientSettings: null    // read-only view of the client's options
  property var lastActivity: null      // unix seconds
  property bool busy: false
  property bool stale: false           // last poll failed; readings are old
  property var polledAt: null

  // ---- UI state.
  property string logFilter: "all"     // all | downloaded | uploaded
  property bool settingsOpen: false

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(root.barForeground, 1.4)
  readonly property color urgent: root.bar ? root.bar.urgent : Color.urgent
  readonly property int logCount: {
    var n = root.settings && typeof root.settings.logCount === "number" ? root.settings.logCount : 40
    return Math.max(5, Math.min(100, Math.round(n)))
  }
  readonly property var logRows: root.logFilter === "all" ? root.recent
      : root.recent.filter(function(r) { return r.action === root.logFilter })

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

  // ---- Presentation helpers shared with the pill.

  function stateText(s) {
    switch (s) {
    case "uptodate": return "Up to date"
    case "syncing":  return root.pending === 1 ? "Syncing 1 file" : "Syncing " + root.pending + " files"
    case "paused":   return "Paused"
    case "offline":  return "Offline"
    case "error":    return "Error"
    case "stopped":  return "Client not running"
    case "unlinked": return "Not linked to a NAS"
    default:         return ""
    }
  }

  // Material Design cloud glyphs from the Nerd Font: the one family that has
  // a cloud for every state we can be in.
  function stateGlyph(s) {
    switch (s) {
    case "uptodate": return "󰅠"     // cloud-check
    case "syncing":  return "󰘿"     // cloud-sync
    case "paused":   return "󰅟"     // cloud
    case "error":    return "󰧠"     // cloud-alert
    default:         return "󰅤"     // cloud-off-outline: offline / stopped / unlinked
    }
  }

  function directionGlyph(d) {
    return d === "download" || d === "downloaded" ? "󰅢" : "󰅧"   // cloud-download / cloud-upload
  }

  function actionGlyph(a) {
    if (a === "download" || a === "downloaded") return "󰇚"
    if (a === "upload" || a === "uploaded") return "󰕒"
    if (a === "deleted") return "󰆴"
    return "󰓦"
  }

  function tilde(path) {
    if (!path) return ""
    return root.home !== "" && path.indexOf(root.home) === 0 ? "~" + path.slice(root.home.length) : path
  }

  function fmtSize(n) {
    if (typeof n !== "number" || n <= 0) return ""
    var units = ["B", "kB", "MB", "GB", "TB"]
    var i = 0
    while (n >= 1000 && i < units.length - 1) { n /= 1000; i++ }
    return (i === 0 ? n : n.toFixed(1)) + " " + units[i]
  }

  function relTime(ts) {
    if (typeof ts !== "number" || ts <= 0) return ""
    var d = Math.round(Date.now() / 1000 - ts)
    if (d < 45) return "just now"
    if (d < 3600) return Math.round(d / 60) + "m ago"
    if (d < 86400) return Math.round(d / 3600) + "h ago"
    if (d < 172800) return "yesterday"
    return Qt.formatDate(new Date(ts * 1000), "d MMM")
  }

  function sessionStateText(s) {
    switch (s.state) {
    case "syncing":  return s.pending === 1 ? "1 pending" : s.pending + " pending"
    case "paused":   return "Paused"
    case "offline":  return "Offline"
    case "error":    return "Error " + s.error
    case "stopped":  return ""
    default:         return "Up to date"
    }
  }

  function onOff(v) { return v === null || v === undefined ? "—" : (v ? "On" : "Off") }

  // ---- Backend.

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function apply(args) {
    if (root.busy) return
    root.busy = true
    actionProc.command = [root.pluginDir + "bin/syndctl"].concat(args)
    actionProc.running = true
  }

  function openFolder(sessionId) { apply(["open", String(sessionId)]) }
  function reveal(path) { if (path) apply(["reveal", path]) }
  function showClient() { apply(["show"]) }

  readonly property bool canControl: root.daemonRunning && root.syncState !== "stopped" && root.syncState !== "unlinked"

  // Optimistic: flip the local state before the daemon confirms so the button
  // and pill react at once; the next poll (triggered by onExited) is truth.
  function togglePauseAll() {
    if (!root.canControl || root.busy) return
    var next = !root.paused
    root.paused = next
    root.syncState = next ? "paused" : (root.pending > 0 ? "syncing" : "uptodate")
    apply([next ? "pause" : "resume"])
  }

  function togglePauseSession(id) {
    if (!root.canControl || root.busy) return
    var isPaused = root.pausedSessions.indexOf(id) !== -1
    apply([isPaused ? "resume" : "pause", String(id)])
  }

  Process {
    id: statusProc
    command: [root.pluginDir + "bin/syndstatus"]
    stdout: StdioCollector {
      onStreamFinished: {
        var out = String(this.text).trim()
        if (out === "") { root.devicePresent = false; return }
        try {
          var d = JSON.parse(out)
          root.devicePresent = d.present === true
          if (!root.devicePresent) return
          // Installed but unreadable this time (lock held, database busy):
          // keep the last reading rather than blanking the pill.
          if (d.state === null || d.state === undefined) {
            if (root.syncState !== "") { root.stale = true; return }
            root.syncState = "stopped"
            return
          }
          root.stale = false
          root.syncState = String(d.state)
          root.paused = d.paused === true
          root.pausedSessions = Array.isArray(d.paused_sessions) ? d.paused_sessions : []
          root.offline = d.offline === true
          root.daemonRunning = d.daemon_running === true
          root.uiRunning = d.ui_running === true
          root.version = d.version || ""
          root.connection = d.connection || null
          root.sessions = Array.isArray(d.sessions) ? d.sessions : []
          root.pending = (typeof d.pending === "number") ? d.pending : 0
          root.current = d.current || null
          root.queue = Array.isArray(d.queue) ? d.queue : []
          // Only swap the log model when the history actually changed: a
          // fresh array every poll would rebuild the Repeater and yank the
          // user's scroll position every three seconds.
          var rec = Array.isArray(d.recent) ? d.recent.slice(0, root.logCount) : []
          var sig = rec.length + ":" + (rec.length ? rec[0].id + ":" + rec[rec.length - 1].id : "")
          if (sig !== root.recentSig) {
            root.recentSig = sig
            root.recent = rec
            Qt.callLater(function() { if (logFlick) logFlick.contentY = 0 })
          }
          root.unsynced = Array.isArray(d.unsynced) ? d.unsynced : []
          root.unsyncedCount = (typeof d.unsynced_count === "number") ? d.unsynced_count : 0
          root.clientSettings = d.settings || null
          root.lastActivity = (typeof d.last_activity === "number") ? d.last_activity : null
          root.polledAt = Date.now()
        } catch (e) {
          root.devicePresent = false
        }
      }
    }
  }

  Process {
    id: actionProc
    onExited: { root.busy = false; root.refresh() }
  }

  // Steady state: quick while a transfer is running so the pill count tracks
  // it, relaxed when idle. The probe is a log-tail parse, ~130 ms end to end.
  Timer {
    interval: !root.devicePresent ? 5000 : root.syncState === "syncing" ? 4000 : 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Faster while the popup is open so the readout tracks reality.
  Timer {
    interval: 3000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!root.busy) root.refresh()
  }

  // Re-render relative times ("3m ago") while open without re-polling.
  property int tick: 0
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.tick++
  }

  onOpenedChanged: if (opened) { if (logFlick) logFlick.contentY = 0; if (outerFlick) outerFlick.contentY = 0 }

  // One row of the activity lists: glyph, name, trailing caption; tooltip
  // carries the full path. Clickable when the caller wires onActivated.
  component ActivityRow: Item {
    id: row
    property string glyph: ""
    property string title: ""
    property string subtitle: ""
    property string trailing: ""
    property string tooltip: ""
    property bool clickable: false
    property bool urgent: false
    property real glyphOpacity: 1.0
    property string actionGlyph: ""      // optional small button on the right
    property string actionTooltip: ""
    signal activated()
    signal actionTriggered()

    width: parent ? parent.width : implicitWidth
    implicitHeight: Math.max(Style.spacing.popupRowHeight, rowLabels.implicitHeight + Style.space(6))

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.barForeground
      opacity: rowMouse.containsMouse && row.clickable ? 0.08 : 0
    }

    Text {
      id: rowGlyph
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: row.glyph
      color: row.urgent ? root.urgent : root.dim
      opacity: row.glyphOpacity
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }

    Column {
      id: rowLabels
      anchors.left: rowGlyph.right
      anchors.leftMargin: Style.space(10)
      anchors.right: rowTrailing.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        width: parent.width
        text: row.title
        color: root.barForeground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideMiddle
      }
      Text {
        width: parent.width
        visible: row.subtitle !== ""
        text: row.subtitle
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }
    }

    PanelActionButton {
      id: rowAction
      visible: row.actionGlyph !== ""
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      iconText: row.actionGlyph
      tooltipText: row.actionTooltip
      foreground: root.barForeground
      fontFamily: root.fontFamily
      fontSize: Style.font.iconSmall
      enabled: !root.busy
      onClicked: row.actionTriggered()
    }

    Text {
      id: rowTrailing
      anchors.right: rowAction.visible ? rowAction.left : parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: row.trailing
      color: row.urgent ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: rowMouse
      // Leave the action button its own hit area.
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.right: rowAction.visible ? rowAction.left : parent.right
      hoverEnabled: true
      cursorShape: row.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (row.clickable) row.activated()
      onEntered: if (row.tooltip !== "" && root.bar && typeof root.bar.showTooltip === "function") root.bar.showTooltip(row, row.tooltip)
      onExited: if (root.bar && typeof root.bar.hideTooltip === "function") root.bar.hideTooltip(row)
    }
  }

  // Label / value line for the read-only settings view.
  component InfoPair: Item {
    property string label: ""
    property string value: ""
    width: parent ? parent.width : implicitWidth
    implicitHeight: Math.max(pairLabel.implicitHeight, pairValue.implicitHeight)
    Text {
      id: pairLabel
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      text: parent.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    Text {
      id: pairValue
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.left: pairLabel.right
      anchors.leftMargin: Style.space(8)
      horizontalAlignment: Text.AlignRight
      text: parent.value
      color: root.barForeground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideLeft
    }
  }

  // A section header that can fold its content away.
  component FoldHeader: Item {
    id: fold
    property string text: ""
    property bool open: false
    property string hint: ""
    signal toggled()
    width: parent ? parent.width : implicitWidth
    implicitHeight: foldHeader.implicitHeight + Style.space(4)
    PanelSectionHeader {
      id: foldHeader
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: fold.text
      foreground: root.barForeground
      fontFamily: root.fontFamily
    }
    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: (fold.hint !== "" ? fold.hint + "  " : "") + (fold.open ? "󰅃" : "󰅀")
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: fold.toggled()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(900))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0 && logFlick.interactive)
          logFlick.contentY = Math.max(0, Math.min(logFlick.contentHeight - logFlick.height,
                                                    logFlick.contentY + dy * Style.spacing.popupRowHeight))
      }
      onTextKey: function(t) {
        if (t === "p" || t === "P") root.togglePauseAll()
        else if (t === "r" || t === "R") root.refresh()
        else if (t === "o" || t === "O") root.showClient()
        else if (t === "s" || t === "S") root.settingsOpen = !root.settingsOpen
      }

      // The whole panel scrolls once it outgrows the height cap (settings
      // unfolded on a small screen); the log inside has its own scroller so
      // the header and folders stay put in the common case.
      Flickable {
        id: outerFlick
        // anchors.fill, no margins of our own: KeyboardPanel already pads the
        // surface.
        anchors.fill: parent
        contentWidth: width
        contentHeight: panelColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: panelColumn
        width: outerFlick.width
        spacing: Style.spacing.sm
        enabled: !root.stale
        opacity: root.stale ? 0.55 : 1.0

        // The shell's standard panel header: glyph left, title, status badge
        // right.
        PanelHero {
          width: parent.width
          title: "Synology Drive"
          meta: {
            var c = root.connection
            var who = c && c.user && c.host ? c.user + "@" + c.host : ""
            var s = root.stateText(root.syncState)
            return who !== "" && s !== "" ? who + " · " + s : (who || s)
          }
          // Quiet when everything is fine; the badge is for states that need
          // a glance, plus BUSY when the readings are last-known.
          detail: root.stale ? "BUSY"
              : root.syncState === "uptodate" || root.syncState === "" ? ""
              : root.syncState === "syncing" ? "SYNCING"
              : root.stateText(root.syncState).toUpperCase()
          foreground: root.barForeground
          fontFamily: root.fontFamily
          iconOpacity: root.stale ? 0.5 : 1
          iconComponent: Component {
            Text {
              text: root.stateGlyph(root.syncState)
              color: root.syncState === "error" ? root.urgent : root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            PanelActionButton {
              visible: root.canControl
              iconText: root.paused ? "󰐊" : "󰏤"
              tooltipText: root.paused ? "Resume syncing (all tasks)" : "Pause syncing (all tasks)"
              foreground: root.barForeground
              fontFamily: root.fontFamily
              bordered: true
              enabled: !root.busy
              onClicked: root.togglePauseAll()
            }
          }
        }

        PanelSeparator {
          anchors.left: parent.left
          anchors.right: parent.right
          foreground: root.barForeground
        }

        // ---- Something needs saying: paused / offline / stopped.
        Text {
          width: parent.width
          visible: text !== ""
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          text: {
            root.tick
            if (root.syncState === "stopped") return "The Synology Drive Client is not running. Start it to resume syncing."
            if (root.syncState === "unlinked") return "The client is not linked to a NAS yet. Open it to set up a connection."
            if (root.paused) return root.pausedSessions.length === root.sessions.length
                ? "Syncing is paused." : "Some tasks are paused."
            if (root.offline && root.connection) return "Can't reach " + root.connection.server + " — the client keeps retrying."
            return ""
          }
        }

        // ---- What is moving right now.
        PanelSectionHeader {
          text: "NOW"
          foreground: root.barForeground
          fontFamily: root.fontFamily
          visible: root.current !== null || root.pending > 0
        }

        ActivityRow {
          visible: root.current !== null
          glyph: root.current ? root.directionGlyph(root.current.direction) : ""
          title: root.current ? root.current.name : ""
          subtitle: root.current
            ? (root.current.direction === "download" ? "Downloading" : "Uploading")
              + (root.current.size > 0 ? " · " + root.fmtSize(root.current.size) : "")
            : ""
          trailing: {
            root.tick
            return root.current && root.current.started_at ? root.relTime(root.current.started_at) : ""
          }
          tooltip: root.current ? root.current.path : ""
        }

        Repeater {
          // Queued behind the current one, capped so a big drop does not
          // turn the panel into a scrollbar.
          model: root.queue.filter(function(q) { return !root.current || q.path !== root.current.path || q.session !== root.current.session }).slice(0, 4)
          ActivityRow {
            required property var modelData
            glyph: root.actionGlyph(modelData.direction)
            glyphOpacity: 0.55
            title: modelData.name
            subtitle: "Queued" + (modelData.size > 0 ? " · " + root.fmtSize(modelData.size) : "")
            tooltip: modelData.path
          }
        }

        Text {
          visible: root.pending > 5
          width: parent.width
          text: "+" + (root.pending - 5) + " more queued"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          leftPadding: Style.space(6)
        }

        // ---- Sync folders: click to open in the file manager.
        PanelSectionHeader {
          text: "SYNC FOLDERS"
          foreground: root.barForeground
          fontFamily: root.fontFamily
          visible: root.sessions.length > 0
        }

        Repeater {
          model: root.sessions
          ActivityRow {
            required property var modelData
            glyph: "󰝰"
            title: modelData.name
            subtitle: root.tilde(modelData.folder)
                + (modelData.direction === 1 ? " · download only"
                 : modelData.direction === 2 ? " · upload only" : "")
            trailing: root.sessionStateText(modelData)
            urgent: modelData.state === "error"
            clickable: true
            tooltip: "Open " + root.tilde(modelData.folder)
            onActivated: root.openFolder(modelData.id)
            actionGlyph: root.canControl ? (root.pausedSessions.indexOf(modelData.id) !== -1 ? "󰐊" : "󰏤") : ""
            actionTooltip: (root.pausedSessions.indexOf(modelData.id) !== -1 ? "Resume " : "Pause ") + modelData.name
            onActionTriggered: root.togglePauseSession(modelData.id)
          }
        }

        // ---- Files the client refused: the thing the old tray nagged about.
        PanelSectionHeader {
          text: "PROBLEMS"
          foreground: root.barForeground
          fontFamily: root.fontFamily
          visible: root.unsynced.length > 0
        }

        Repeater {
          model: root.unsynced
          ActivityRow {
            required property var modelData
            glyph: "󰀨"
            title: modelData.name
            subtitle: modelData.reason
            trailing: { root.tick; return root.relTime(modelData.time) }
            urgent: true
            clickable: modelData.exists === true
            tooltip: modelData.path
            onActivated: root.reveal(modelData.path)
          }
        }

        // ---- The log: the client's own history, scrolling, click to reveal.
        Item {
          width: parent.width
          implicitHeight: logHeader.implicitHeight
          visible: root.recent.length > 0

          PanelSectionHeader {
            id: logHeader
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "LOG"
            foreground: root.barForeground
            fontFamily: root.fontFamily
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Repeater {
              model: [
                { id: "all", label: "All" },
                { id: "downloaded", label: "󰇚" },
                { id: "uploaded", label: "󰕒" }
              ]
              Button {
                required property var modelData
                text: modelData.label
                bordered: true
                selected: root.logFilter === modelData.id
                foreground: root.barForeground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(7)
                verticalPadding: Style.space(2)
                tooltipText: modelData.id === "all" ? "Everything" : modelData.id === "downloaded" ? "Downloads only" : "Uploads only"
                onClicked: { root.logFilter = modelData.id; logFlick.contentY = 0 }
              }
            }
          }
        }

        Flickable {
          id: logFlick
          width: parent.width
          visible: root.recent.length > 0
          // Tall enough for ~7 rows; the rest scrolls. The panel itself stays
          // put so the header and folders never move.
          height: Math.min(logColumn.implicitHeight, Style.space(300))
          contentWidth: width
          contentHeight: logColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: logColumn
            width: logFlick.width
            spacing: 0

            Repeater {
              model: root.logRows
              ActivityRow {
                required property var modelData
                glyph: root.actionGlyph(modelData.action)
                // A deleted entry's file is meant to be gone; only dim the
                // ones that vanished behind the client's back.
                glyphOpacity: modelData.exists === false && modelData.action !== "deleted" ? 0.4 : 1.0
                title: modelData.name
                subtitle: (modelData.action === "downloaded" ? "Downloaded to "
                         : modelData.action === "uploaded" ? "Uploaded from "
                         : modelData.action === "deleted" ? "Deleted from " : "Changed in ")
                        + root.tilde(modelData.folder)
                        + (modelData.exists === false && modelData.action !== "deleted" ? " · gone" : "")
                trailing: { root.tick; return root.relTime(modelData.time) }
                clickable: modelData.exists === true
                tooltip: modelData.exists === true ? "Show " + modelData.path + " in Files" : modelData.path
                onActivated: root.reveal(modelData.path)
              }
            }

            Text {
              visible: root.logRows.length === 0
              width: parent.width
              text: root.logFilter === "downloaded" ? "No downloads in the last " + root.recent.length + " entries."
                  : "No uploads in the last " + root.recent.length + " entries."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              topPadding: Style.space(8)
              bottomPadding: Style.space(8)
            }
          }
        }

        Text {
          visible: root.recent.length === 0 && root.devicePresent && root.syncState !== "stopped"
          width: parent.width
          text: "No transfers yet."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
        }

        // ---- The client's options, read-only. Writable ones live in its own
        //      window; there is no safe way to change them from outside yet.
        FoldHeader {
          text: "SETTINGS"
          open: root.settingsOpen
          hint: root.settingsOpen ? "" : "read-only"
          visible: root.clientSettings !== null
          onToggled: root.settingsOpen = !root.settingsOpen
        }

        Column {
          width: parent.width
          spacing: Style.space(3)
          visible: root.settingsOpen && root.clientSettings !== null

          InfoPair { label: "Start at login";          value: root.onOff(root.clientSettings ? root.clientSettings.global.start_at_login : null) }
          InfoPair { label: "Desktop notifications";   value: root.onOff(root.clientSettings ? root.clientSettings.global.desktop_notifications : null) }
          InfoPair { label: "Unsynced-file alerts";    value: root.onOff(root.clientSettings ? root.clientSettings.global.unsynced_notifications : null) }
          InfoPair { label: "Icon overlay";            value: root.onOff(root.clientSettings ? root.clientSettings.global.icon_overlay : null) }
          InfoPair { label: "File-manager context menu"; value: root.onOff(root.clientSettings ? root.clientSettings.global.context_menu : null) }
          InfoPair { label: "Sync temporary files";    value: root.onOff(root.clientSettings ? root.clientSettings.global.sync_temp_files : null) }
          InfoPair { label: "Proxy";                   value: root.onOff(root.clientSettings ? root.clientSettings.global.proxy : null) }
          InfoPair { label: "Client";                  value: "v" + root.version + (root.connection && root.connection.server_version ? " · server " + root.connection.server_version : "") }
          InfoPair { label: "Connection";              value: root.connection ? root.connection.server + ":" + root.connection.port + (root.connection.ssl ? " (SSL)" : "") : "—" }

          Repeater {
            model: root.clientSettings ? root.clientSettings.tasks : []
            Column {
              id: taskRow
              required property var modelData
              readonly property var f: modelData.filters
              width: parent.width
              spacing: Style.space(3)
              topPadding: Style.space(6)
              Text {
                text: taskRow.modelData.name + " · " + taskRow.modelData.direction + (taskRow.modelData.read_only ? " · read-only" : "")
                color: root.barForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                leftPadding: Style.space(6)
              }
              InfoPair { label: "Excluded extensions";    value: taskRow.f.excluded_extensions.length ? taskRow.f.excluded_extensions.join(", ") : "none" }
              InfoPair { label: "Excluded name prefixes"; value: taskRow.f.excluded_name_prefixes.length ? taskRow.f.excluded_name_prefixes.join(", ") : "none" }
              InfoPair { label: "Excluded folders";       value: taskRow.f.excluded_folders.length ? taskRow.f.excluded_folders.join(", ") : "none" }
              InfoPair { visible: taskRow.f.max_file_size !== null; label: "Max file size"; value: root.fmtSize(taskRow.f.max_file_size) }
            }
          }

          Text {
            width: parent.width
            text: "To change any of these, open the Synology Drive window."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            leftPadding: Style.space(6)
            topPadding: Style.space(4)
          }
        }

        PanelSeparator {
          anchors.left: parent.left
          anchors.right: parent.right
          foreground: root.barForeground
        }

        // ---- Footer: the client's own window for anything we don't cover.
        Item {
          width: parent.width
          implicitHeight: footerButton.implicitHeight

          Button {
            id: footerButton
            anchors.left: parent.left
            text: root.syncState === "stopped" ? "Start Synology Drive" : "Open Synology Drive"
            bordered: true
            foreground: root.barForeground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            enabled: !root.busy
            tooltipText: "The client's own window: link a NAS, add sync tasks, filters"
            onClicked: root.showClient()
          }

          Text {
            anchors.left: footerButton.right
            anchors.leftMargin: Style.space(10)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideLeft
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            text: {
              root.tick
              return root.lastActivity ? "last sync " + root.relTime(root.lastActivity) : ""
            }
          }
        }
      }
      }
    }
  }
}
