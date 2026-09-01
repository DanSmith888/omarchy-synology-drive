import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Synology Drive: the pill in the bar, and the host for the panel.
//
// This is the manifest entry point. It owns nothing but the pill and the IPC
// target; all state lives in Panel.qml, loaded here and read through
// panelLoader.item. The shell routes on this shape — Bar.findPanelWidget
// looks for open/close/opened on the widget mounted in the bar slot — so the
// pill must be the thing the bar sees.
BarWidget {
  id: root
  moduleName: "dansmith888.synology-drive"

  readonly property var panel: panelLoader.item

  // Mirrors of the panel's state, so the pill has nothing to compute.
  readonly property bool devicePresent: panel ? panel.devicePresent === true : false
  readonly property string syncState: panel ? panel.syncState : ""
  readonly property int pending: panel ? panel.pending : 0
  readonly property var current: panel ? panel.current : null
  readonly property bool paused: panel ? panel.paused === true : false

  // While a transfer runs the glyph alternates between "cloud-sync" and the
  // direction of the current file, so the pill visibly moves without a
  // spinner — and the count says how much is left.
  property bool phase: false
  Timer {
    interval: 700
    running: root.visible && root.syncState === "syncing"
    repeat: true
    onTriggered: root.phase = !root.phase
    onRunningChanged: if (!running) root.phase = false
  }

  // Setting: a pill that only appears when something is happening.
  readonly property bool hideWhenIdle: root.settings && root.settings.hideWhenIdle === true

  // ---- Panel lifecycle contract (shell.summon/hide/toggle routing).
  readonly property bool opened: panel ? panel.opened === true : false
  readonly property bool popoutSwitchClosing: panel ? panel.popoutSwitchClosing === true : false

  function open() { if (panel) panel.open() }
  function close() { if (panel) panel.close() }
  function togglePanel() { if (panel) panel.toggle() }
  function closeForPopoutSwitch() { if (panel) panel.closeForPopoutSwitch() }
  function refresh() { if (panel) panel.refresh() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // Hidden, not removed, when the client is not installed (or, by setting,
  // while idle): the slot stays in shell.json and the pill reappears on its
  // own.
  visible: root.devicePresent && !(root.hideWhenIdle && root.syncState === "uptodate" && !root.opened)
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // Single IPC target for the plugin; Panel.qml sets manageIpc: false.
  //   omarchy-shell shell toggle dansmith888.synology-drive
  IpcHandler {
    target: "dansmith888.synology-drive"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.broadcast("refresh") }
    function state(): string { return root.syncState }
    function pause(): void { if (root.panel && !root.paused) root.panel.togglePauseAll() }
    function resume(): void { if (root.panel && root.paused) root.panel.togglePauseAll() }
  }

  // Glyph alone when everything is fine; a word or a count only when there
  // is something to know. That is the whole point versus the old tray icon.
  readonly property string pillText: {
    if (!root.panel) return ""
    var g = root.panel.stateGlyph(root.syncState)
    switch (root.syncState) {
    case "syncing":
      if (root.phase && root.current) g = root.panel.directionGlyph(root.current.direction)
      return g + "  " + root.pending
    case "paused":   return g + "  Paused"
    case "offline":  return g + "  Offline"
    case "error":    return g + "  Error"
    default:         return g
    }
  }

  // Reserve the width the pill has actually needed in its current state, so
  // a count going 9 -> 12 -> 3 never shoves the neighbours; reset when the
  // state changes, because a "Paused" reserve would otherwise leave a hole
  // beside the bare glyph for the rest of the session.
  property real reservedWidth: 0
  onSyncStateChanged: reservedWidth = 0

  TextMetrics {
    id: pillMetrics
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
    text: root.pillText
    onWidthChanged: if (width > root.reservedWidth) root.reservedWidth = width
  }

  // WidgetButton, not BarIconButton: the latter is glyph-only and clips text.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.pillText
    hasVisualContent: text !== ""
    // WidgetButton centres its label, so slack sits either side and the
    // neighbours never move. pillMetrics stays in the max so a reading can
    // never be clipped by a stale reserve.
    fixedWidth: pillMetrics.width > 0
      ? Math.max(root.reservedWidth, pillMetrics.width, labelWidth) + scaledHorizontalMargin * 2
      : -1
    horizontalMargin: 5
    verticalPadding: 8.75
    active: root.syncState === "error"
    tooltipText: {
      if (!root.panel) return "Synology Drive"
      var t = "Synology Drive — " + root.panel.stateText(root.syncState)
      if (root.current) t += "\n" + (root.current.direction === "download" ? "↓ " : "↑ ") + root.current.name
      if (root.panel.stale) t += " (last known)"
      return t
    }

    // Hovering the pill is how people "check" it, so make that a real refresh.
    onTooltipHoveredChanged: if (tooltipHovered) root.refresh()

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else if (b === Qt.RightButton) { if (root.panel) root.panel.togglePauseAll() }
      else root.togglePanel()
    }
  }
}
