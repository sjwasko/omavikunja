import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.mjs" as Model

// Vikunja Projects popup: next-todo hero followed by either the nested
// project tree (chevrons roll each project up) or the open todos of one
// project grouped by due date. The host owns all data, actions and the saved
// collapse state, so the panel stays presentational.
Panel {
  id: root
  moduleName: "sjwasko.omavikunja"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string instance: hostWidget ? hostWidget.instance : ""
  readonly property bool syncing: hostWidget ? hostWidget.syncing : false
  readonly property string widgetState: hostWidget ? hostWidget.widgetState : "checking"
  readonly property string loadError: hostWidget ? hostWidget.loadError : ""
  readonly property bool hasConfig: hostWidget ? hostWidget.hasConfig : false
  readonly property var groups: hostWidget && hostWidget.groups ? hostWidget.groups : []
  readonly property var next: hostWidget ? hostWidget.next : null
  readonly property int hiddenCount: hostWidget ? hostWidget.hiddenCount : 0
  readonly property bool showTitle: hostWidget ? hostWidget.showTitle : true
  readonly property string testStatus: hostWidget ? hostWidget.testStatus : "idle"
  readonly property string testMessage: hostWidget ? hostWidget.testMessage : ""
  readonly property string configIssue: hostWidget ? hostWidget.configIssue : ""
  property date now: hostWidget ? hostWidget.now : new Date()
  readonly property string viewMode: hostWidget ? hostWidget.viewMode : Model.VIEW_TREE
  readonly property bool treeView: viewMode === Model.VIEW_TREE
    || (viewMode === Model.VIEW_PROJECT && !(hostWidget && hostWidget.projectScoped))
  readonly property var treeRows: hostWidget && hostWidget.treeRows ? hostWidget.treeRows : []
  readonly property int treeHidden: hostWidget ? hostWidget.treeHidden : 0
  readonly property string scopeTitle: hostWidget ? hostWidget.scopeTitle : ""
  readonly property bool anyCollapsed: hostWidget ? hostWidget.collapsedIds.length > 0 : false
  readonly property var pickerProjects: hostWidget && hostWidget.pickerProjects ? hostWidget.pickerProjects : []

  onTestStatusChanged: {
    if (root.testStatus === "ok") tokenField.text = ""
  }

  // Color.accent is undefined for a moment while the shell starts and the
  // theme loads; fall back to the foreground until it is there.
  readonly property color accentColor: Color.accent !== undefined ? Color.accent : contentForeground
  // Text-safe red: the theme's own red can be near-black on some themes,
  // which makes overdue labels unreadable. Matches the "Urgent" priority color.
  readonly property color urgentColor: "#e05c5c"
  readonly property color contentForeground: bar ? bar.barForeground : (Color.foreground !== undefined ? Color.foreground : "#cacccc")
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  function open() {
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function openTask(task) {
    if (!hostWidget || !task) return
    hostWidget.openTask(task)
    root.close()
  }

  function toggleDone(task) {
    if (!hostWidget || !task) return
    hostWidget.toggleDone(task)
  }

  function syncNow() {
    if (hostWidget) hostWidget.refresh()
  }

  function testConnection() {
    if (!hostWidget) return
    root.saveServer()
    var typed = String(tokenField.text || "").trim()
    // Pass the address in the field; the host refuses to test (and sends
    // nothing) unless it is the instance actually saved.
    hostWidget.testConnection(typed, Model.normalizeInstance(String(serverField.text || "").trim()))
  }

  // ---- Paste. The text fields never read the clipboard themselves: Qt's
  //      own paste reads the whole offer synchronously inside the shell, so a
  //      huge or never-ending clipboard could stall it. Keyboard paste is
  //      routed through `wl-paste | head -c` in a separate process with a
  //      deadline; middle-click and context-menu paste are disabled. A result
  //      is dropped if the field changed, lost focus, or the panel closed
  //      while it was being read.
  property var pasteTarget: null
  property var pasteSnapshot: null
  property int pasteGeneration: 0

  function interceptPaste(field, event) {
    var isPaste = event.matches(StandardKey.Paste)
      || (event.key === Qt.Key_Insert && (event.modifiers & Qt.ShiftModifier))
    if (!isPaste) return
    event.accepted = true
    startPaste(field)
  }

  function startPaste(field) {
    // pasteBusy holds from launch until the exit has been handled, so a late
    // exit from a cancelled read can never be taken for this one's result.
    if (pasteBusy || !field || field.readOnly || !field.enabled) return
    pasteBusy = true
    pasteGeneration += 1
    pasteTarget = field
    pasteSnapshot = {
      generation: pasteGeneration,
      text: field.text,
      cursor: field.cursorPosition,
      selStart: field.selectionStart,
      selEnd: field.selectionEnd
    }
    pasteProcess.command = Model.pasteCommand()
    pasteProcess.running = true
    pasteWatchdog.restart()
  }

  // Any change to the paste's target field while the clipboard is being read
  // (an edit, cursor or selection move, focus loss) invalidates the pending
  // result for good, even if the field is later restored to how it was. So
  // does a change of instance, so a value read for one server can never land
  // in a field after switching to another.
  function invalidatePaste(field) {
    if (pasteTarget !== null && field === pasteTarget) cancelPaste()
  }

  property bool pasteBusy: false

  // Drops any pending result. The read itself is stopped but stays "busy"
  // until its exit arrives (or the watchdog gives up on it).
  function cancelPaste() {
    pasteGeneration += 1
    pasteTarget = null
    pasteSnapshot = null
    if (pasteProcess.running) pasteProcess.running = false
  }

  function finishPaste() {
    var field = pasteTarget
    var snap = pasteSnapshot
    pasteTarget = null
    pasteSnapshot = null
    if (!field || !snap || snap.generation !== pasteGeneration || !root.opened) return
    if (!field.activeFocus || field.text !== snap.text || field.cursorPosition !== snap.cursor
        || field.selectionStart !== snap.selStart || field.selectionEnd !== snap.selEnd) return
    // Single-line fields: control characters and line breaks become spaces;
    // the interval field only takes digits.
    var clip = String(pasteStdout.text || "").replace(/[\u0000-\u001f\u007f]+/g, " ")
    if (field === intervalField) clip = clip.replace(/[^0-9]+/g, "")
    if (clip === "") return
    var start = snap.selStart
    var room = field.maximumLength - (field.text.length - (snap.selEnd - snap.selStart))
    if (room <= 0) return
    clip = clip.slice(0, room)
    if (snap.selEnd > snap.selStart) field.remove(snap.selStart, snap.selEnd)
    field.insert(start, clip)
    field.cursorPosition = start + clip.length
  }

  Process {
    id: pasteProcess
    running: false
    stdout: StdioCollector {
      id: pasteStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      pasteWatchdog.stop()
      root.pasteBusy = false
      root.finishPaste()
    }
  }

  // Backstop for the command's own `timeout`. First firing: the read is
  // overdue, so drop its result and stop it. Second firing: its exit never
  // arrived, so stop waiting for it and allow new pastes again.
  Timer {
    id: pasteWatchdog
    interval: (Model.DEADLINES.paste + 3) * 1000
    repeat: false
    onTriggered: {
      if (pasteProcess.running) {
        root.cancelPaste()
        pasteWatchdog.restart()
      } else {
        root.cancelPaste()
        root.pasteBusy = false
      }
    }
  }

  function priorityColor(priority) {
    switch (priority) {
      case 1: return "#6fc276"
      case 2: return "#d2b14f"
      case 3: return "#e08f3c"
      case 4: return "#e05c5c"
      case 5: return "#ff4d6d"
      default: return "transparent"
    }
  }

  // ---- Settings view. The gear button toggles it; everything writes back
  //      through the host widget, which persists to shell.json (or the
  //      keyring, for the token).
  property bool showSettings: false

  function openSettings() {
    root.showSettings = true
    Qt.callLater(function() {
      serverField.text = root.hostWidget ? root.hostWidget.instance : ""
      tokenField.text = ""
      if (root.hostWidget) root.hostWidget.resetTest()
      if (scroll) scroll.contentY = 0
      root.scrollPickerToSelection()
    })
  }

  function toggleSettings() {
    if (root.showSettings) root.showSettings = false
    else root.openSettings()
  }

  property string serverError: ""

  function saveServer() {
    if (!root.hostWidget) return false
    var typed = String(serverField.text || "").trim()
    var normalized = Model.normalizeInstance(typed)
    if (typed !== "" && normalized === "") {
      root.serverError = "Use a plain http:// or https:// address, without a username, password or query."
      return false
    }
    root.serverError = ""
    if (normalized === root.hostWidget.instance) return true
    root.hostWidget.persistSettings({ instance: normalized })
    serverField.text = normalized
    return true
  }

  function saveSyncInterval(value) {
    if (!root.hostWidget) return
    var normalized = Model.normalizeSyncInterval(value)
    if (normalized !== root.hostWidget.syncInterval)
      root.hostWidget.persistSettings({ syncInterval: normalized })
    // Show the clamped value that was actually saved.
    intervalField.text = String(normalized)
  }

  function stepSyncInterval(delta) {
    if (!root.hostWidget) return
    var current = parseInt(intervalField.text, 10)
    if (!isFinite(current)) current = root.hostWidget.syncInterval
    saveSyncInterval(current + delta)
  }

  function toggleShowNoDate() {
    if (!root.hostWidget) return
    root.hostWidget.persistSettings({ showNoDate: !root.hostWidget.showNoDate })
  }

  function setViewMode(value) {
    if (!root.hostWidget) return
    var mode = Model.normalizeViewMode(value)
    if (mode === root.hostWidget.viewMode) return
    var values = { viewMode: mode }
    // "One project" needs a project straight away, or nothing is highlighted
    // and the panel keeps showing the tree. Keep the last pick if it still
    // exists, otherwise start on Inbox (or the first project).
    if (mode === Model.VIEW_PROJECT && !root.projectExists(root.hostWidget.projectId)) {
      var fallback = Model.defaultProjectId(root.hostWidget.projects)
      if (fallback > 0) values.projectId = fallback
    }
    root.hostWidget.persistSettings(values)
    if (mode === Model.VIEW_PROJECT) Qt.callLater(root.scrollPickerToSelection)
  }

  function projectExists(id) {
    for (var i = 0; i < root.pickerProjects.length; i++)
      if (root.pickerProjects[i].id === Number(id)) return true
    return false
  }

  // Bring the chosen project into view inside the picker's own scroll area.
  function scrollPickerToSelection() {
    if (!root.hostWidget || !pickerScroll.visible) return
    for (var i = 0; i < pickerRepeater.count; i++) {
      var item = pickerRepeater.itemAt(i)
      if (!item || !item.selected) continue
      var top = item.y
      var bottom = item.y + item.height
      if (top < pickerScroll.contentY) pickerScroll.contentY = top
      else if (bottom > pickerScroll.contentY + pickerScroll.height)
        pickerScroll.contentY = Math.min(pickerScroll.contentHeight - pickerScroll.height,
          bottom - pickerScroll.height)
      return
    }
  }

  function pickProject(id) {
    if (!root.hostWidget) return
    var values = { projectId: Model.normalizeProjectId(id) }
    if (root.hostWidget.viewMode !== Model.VIEW_PROJECT) values.viewMode = Model.VIEW_PROJECT
    root.hostWidget.persistSettings(values)
  }

  function toggleIncludeSubprojects() {
    if (!root.hostWidget) return
    root.hostWidget.persistSettings({ includeSubprojects: !root.hostWidget.includeSubprojects })
  }

  function toggleHideEmptyProjects() {
    if (!root.hostWidget) return
    root.hostWidget.persistSettings({ hideEmptyProjects: !root.hostWidget.hideEmptyProjects })
  }

  // ---- Adding todos. `addTarget` 0 means the default project (the scoped
  //      project, else Inbox).
  property bool addOpen: false
  property int addTarget: 0

  // A project picked for adding belongs to the old server; never carry it
  // over to a new one.
  onInstanceChanged: {
    root.cancelPaste()
    root.addOpen = false
    root.addTarget = 0
    addField.text = ""
  }
  readonly property int effectiveAddTarget: addTarget > 0 ? addTarget
    : (hostWidget ? hostWidget.defaultProjectId : 0)
  readonly property string addTargetTitle: hostWidget ? hostWidget.projectTitle(effectiveAddTarget) : ""
  readonly property bool adding: hostWidget ? hostWidget.adding : false
  readonly property string addError: hostWidget ? hostWidget.addError : ""

  function openAdd(projectId) {
    root.showSettings = false
    root.addTarget = Number(projectId) || 0
    root.addOpen = true
    Qt.callLater(function() {
      if (scroll) scroll.contentY = 0
      addField.forceActiveFocus()
    })
  }

  function closeAdd() {
    root.addOpen = false
    addField.text = ""
    keyCatcher.forceActiveFocus()
  }

  function submitAdd() {
    if (!root.hostWidget || root.adding) return
    if (root.hostWidget.addTask(root.effectiveAddTarget, addField.text)) addField.text = ""
  }

  function setIconStyle(value) {
    if (!root.hostWidget) return
    var style = Model.normalizeIconStyle(value)
    if (style !== root.hostWidget.iconStyle) root.hostWidget.persistSettings({ iconStyle: style })
  }

  // ---- Keyboard cursor over the list rows (project headers and todos).
  //      Tracked by row key so it survives syncs, collapses and completions;
  //      when its row disappears it stays at the same index, so the next row
  //      takes its place.
  // ---- Vikunja-style "g then letter" navigation: g o / g u / g p / g a / g m
  //      open Overview, Upcoming, Projects, Labels and Teams in the browser.
  property bool gPending: false
  readonly property var gRoutes: ({ o: "/", u: "/tasks/by/upcoming", p: "/projects", a: "/labels", m: "/teams" })

  Timer {
    id: gTimer
    interval: 1500
    onTriggered: root.gPending = false
  }

  function openInVikunja(path) {
    if (root.instance === "") return
    Quickshell.execDetached(["xdg-open", root.instance + path])
    root.close()
  }

  function cursorProjectId() {
    var row = root.cursorRow
    if (!row) return 0
    if (row.kind === "project") return Number(row.id) || 0
    return row.task ? Number(row.task.projectId) || 0 : 0
  }

  function showShortcuts() {
    root.openSettings()
    Qt.callLater(function() {
      if (!scroll || !shortcutsSection) return
      var p = shortcutsSection.mapToItem(contentColumn, 0, 0)
      scroll.contentY = Math.max(0, Math.min(scroll.contentHeight - scroll.height, p.y - Style.space(8)))
    })
  }

  function handleTextKey(text, modifiers) {
    if (root.gPending) {
      root.gPending = false
      gTimer.stop()
      var path = root.gRoutes[String(text).toLowerCase()]
      if (path !== undefined) root.openInVikunja(path)
      return
    }
    if (text === "?") { root.showShortcuts(); return }
    if (root.showSettings || !root.hasConfig) return
    if (text === "g") { root.gPending = true; gTimer.restart(); return }
    if (text === "t" || text === "T") { root.completeCursor(); return }
    if (text === "u") {
      var pid = root.cursorProjectId()
      if (pid > 0) root.openInVikunja("/projects/" + pid)
      return
    }
    if (text === "n" || text === "N") { root.openAdd(root.cursorProjectId()); return }
    if ((text === "z" || text === "Z") && root.treeView) root.toggleAllCollapsed()
  }

  property string cursorKey: ""
  property bool enterPressed: false
  property int cursorIndex: -1

  readonly property var navRows: {
    if (root.treeView) return root.treeRows
    var out = []
    for (var g = 0; g < root.groups.length; g++) {
      var items = root.groups[g].items || []
      for (var i = 0; i < items.length; i++)
        out.push({ kind: "task", key: "t" + items[i].id, task: items[i], depth: 0 })
    }
    return out
  }

  onNavRowsChanged: {
    if (root.cursorKey === "") return
    var idx = root.navIndexOf(root.cursorKey)
    if (idx < 0) idx = Math.min(root.cursorIndex, root.navRows.length - 1)
    root.setCursor(idx)
  }

  function navIndexOf(key) {
    for (var i = 0; i < navRows.length; i++) if (navRows[i].key === key) return i
    return -1
  }

  function setCursor(idx) {
    if (idx < 0 || navRows.length === 0) {
      cursorIndex = -1
      cursorKey = ""
      return
    }
    cursorIndex = Math.max(0, Math.min(navRows.length - 1, idx))
    cursorKey = navRows[cursorIndex].key
  }

  function clearCursor() { setCursor(-1) }

  readonly property var cursorRow: cursorIndex >= 0 && cursorIndex < navRows.length ? navRows[cursorIndex] : null

  function navActive() {
    return root.opened && !root.showSettings && !root.addOpen && root.hasConfig && navRows.length > 0
  }

  function moveCursor(dx, dy) {
    if (!navActive()) return
    if (dy !== 0) {
      if (cursorIndex < 0) setCursor(dy > 0 ? 0 : navRows.length - 1)
      else setCursor(cursorIndex + dy)
      return
    }
    var row = cursorRow
    if (!row) { setCursor(0); return }
    if (dx > 0) {
      // Right / l: open a rolled-up project, else step into it.
      if (row.kind === "project" && row.expandable && row.collapsed) toggleCollapsed(row.id)
      else if (row.kind === "project" && row.expandable) setCursor(cursorIndex + 1)
    } else if (dx < 0) {
      // Left / h: roll up an open project, else jump to the parent project.
      if (row.kind === "project" && row.expandable && !row.collapsed) { toggleCollapsed(row.id); return }
      for (var i = cursorIndex - 1; i >= 0; i--) {
        if (navRows[i].kind === "project" && navRows[i].depth < row.depth) { setCursor(i); return }
      }
    }
  }

  function activateCursor() {
    if (!navActive()) return
    var row = cursorRow
    if (!row) return
    if (row.kind === "project") { if (row.expandable) toggleCollapsed(row.id) }
    else openTask(row.task)
  }

  function completeCursor() {
    if (!navActive()) return
    var row = cursorRow
    if (row && row.kind === "task") toggleDone(row.task)
  }

  // Keep the keyboard row in view inside the scrolling panel.
  function ensureVisible(item) {
    if (!item || !scroll) return
    var p = item.mapToItem(contentColumn, 0, 0)
    var margin = Style.space(8)
    if (p.y - margin < scroll.contentY) scroll.contentY = Math.max(0, p.y - margin)
    else if (p.y + item.height + margin > scroll.contentY + scroll.height)
      scroll.contentY = Math.min(Math.max(0, scroll.contentHeight - scroll.height),
        p.y + item.height + margin - scroll.height)
  }

  function toggleCollapsed(id) {
    if (root.hostWidget) root.hostWidget.toggleCollapsed(id)
  }

  function toggleAllCollapsed() {
    if (!root.hostWidget) return
    if (root.anyCollapsed) root.hostWidget.expandAll()
    else root.hostWidget.collapseAll()
  }

  function toggleShowTitle() {
    if (!root.hostWidget) return
    root.hostWidget.persistSettings({ showTitle: !root.hostWidget.showTitle })
  }

  function openTokenUrl() {
    if (!root.hostWidget || root.hostWidget.instance === "") return
    Qt.openUrlExternally(root.hostWidget.instance + "/user/settings/api-tokens")
  }

  onOpenedChanged: if (opened) {
    if (scroll) scroll.contentY = 0
  } else {
    root.showSettings = false
    root.addOpen = false
    addField.text = ""
    // An unsaved token never outlives the panel, nor does a pending paste.
    tokenField.text = ""
    root.cancelPaste()
    root.serverError = ""
    root.clearCursor()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: serverField.activeFocus || tokenField.activeFocus
        || intervalField.activeFocus
        || showNoDateToggle.activeFocus
        || showTitleToggle.activeFocus
        || viewGroup.activeFocus
        || subprojectsToggle.activeFocus
        || hideEmptyToggle.activeFocus
        || iconGroup.activeFocus
        || addField.activeFocus
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      // Keys follow Vikunja's own shortcuts (j/k/Enter in lists, t done,
      // u open project, ? shortcuts, g-then-letter navigation). Panel-only
      // actions use keys Vikunja leaves free: n new todo, z fold all, F5 sync.
      onReturnRequested: root.enterPressed = true
      onActivateRequested: {
        // Enter opens a todo; Enter or Space shows/hides a project.
        var enter = root.enterPressed
        root.enterPressed = false
        var row = root.cursorRow
        if (row && row.kind === "task" && !enter) return
        root.activateCursor()
      }
      // Delete deletes a task in Vikunja; the panel never deletes, so it is
      // deliberately inert rather than doing something else.
      onDeleteRequested: {}
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text, modifiers) { root.handleTextKey(text, modifiers) }
      Keys.onPressed: function(event) {
        if (keyCatcher.blocked || event.accepted) return
        if (event.key === Qt.Key_F5) { root.syncNow(); event.accepted = true }
        else if (event.key === Qt.Key_Home && root.navActive()) { root.setCursor(0); event.accepted = true }
        else if (event.key === Qt.Key_End && root.navActive()) { root.setCursor(root.navRows.length - 1); event.accepted = true }
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: scroll.width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: contentColumn
          width: scroll.width
          spacing: Style.space(12)

          Item {
            id: headerRow
            visible: true
            width: parent.width
            height: visible ? Math.max(headingLabel.height, stampLabel.height, settingsButton.height) : 0
            implicitHeight: height

            Text {
              id: headingLabel
              anchors.left: parent.left
              anchors.right: stampLabel.visible && stampLabel.text !== "" ? stampLabel.left : actionRow.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: root.showSettings ? "SETTINGS"
                : root.scopeTitle !== "" ? root.scopeTitle.toUpperCase()
                : root.treeView ? "PROJECTS" : "TODOS"
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: Qt.darker(root.contentForeground, 1.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.2
              font.bold: true
            }

            Text {
              id: stampLabel
              visible: !root.showSettings
              anchors.right: actionRow.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: {
                if (root.widgetState === "checking") return "Checking…"
                if (root.widgetState === "missing") return "Not configured"
                if (root.syncing) return "Syncing…"
                if (root.loadError !== "") return "Load failed"
                return ""
              }
              color: root.loadError !== "" ? root.urgentColor : Qt.darker(root.contentForeground, 1.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              id: actionRow
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              PanelActionButton {
                id: addButton
                visible: !root.showSettings && root.hasConfig
                iconText: "\uf067"
                tooltipText: "Add a todo (n)"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.addOpen ? root.closeAdd() : root.openAdd(0)
              }

              PanelActionButton {
                id: collapseAllButton
                visible: !root.showSettings && root.treeView && root.hasConfig
                iconText: root.anyCollapsed ? "\uf065" : "\uf066"
                tooltipText: root.anyCollapsed ? "Expand all projects (z)" : "Collapse all projects (z)"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.toggleAllCollapsed()
              }

              PanelActionButton {
                id: syncButton
                iconText: ""
                tooltipText: root.syncing ? "Syncing todos…" : "Sync now (F5)"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                visible: !root.showSettings
                enabled: !root.syncing
                opacity: root.syncing ? 0.6 : 1.0
                onClicked: root.syncNow()

                Text {
                  id: syncIcon
                  anchors.centerIn: parent
                  text: root.syncing ? "" : ""
                  color: syncButton.foreground
                  font.family: syncButton.fontFamily
                  font.pixelSize: syncButton.fontSize

                  RotationAnimation on rotation {
                    from: 0
                    to: 360
                    duration: 900
                    loops: Animation.Infinite
                    running: root.syncing
                  }

                  onRotationChanged: if (!root.syncing && rotation !== 0) rotation = 0
                }
              }

              PanelActionButton {
                id: settingsButton
                iconText: root.showSettings ? "" : ""
                tooltipText: root.showSettings ? "Back to todos" : "Settings"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.toggleSettings()
              }
            }
          }

          Column {
            id: addBar
            visible: root.addOpen && !root.showSettings && root.hasConfig
            width: parent.width
            height: visible ? implicitHeight : 0
            spacing: Style.space(6)

            Text {
              width: parent.width
              text: root.addTargetTitle !== ""
                ? "New todo in " + root.addTargetTitle + "  ·  Enter to add, Esc to close"
                : "No project to add to yet. Sync first."
              textFormat: Text.PlainText
              color: Qt.darker(root.contentForeground, 1.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            TextField {
              id: addField
              // Paste only through root.startPaste(); see the Paste section.
              Keys.onPressed: function(event) { root.interceptPaste(addField, event) }
              onActiveFocusChanged: root.invalidatePaste(addField)
              onTextChanged: root.invalidatePaste(addField)
              onCursorPositionChanged: root.invalidatePaste(addField)
              onSelectionStartChanged: root.invalidatePaste(addField)
              onSelectionEndChanged: root.invalidatePaste(addField)
              QQC.ContextMenu.menu: null
              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.MiddleButton
              }
              width: parent.width
              placeholderText: root.adding ? "Adding…" : "What needs doing?"
              enabled: root.effectiveAddTarget > 0
              maximumLength: Model.MAX_NEW_TITLE_CHARS
              foreground: root.contentForeground
              accent: root.accentColor
              font.family: root.contentFontFamily
              onAccepted: root.submitAdd()
              Keys.onEscapePressed: root.closeAdd()
            }

            Text {
              width: parent.width
              visible: root.addError !== ""
              text: root.addError
              textFormat: Text.PlainText
              color: root.urgentColor
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Item {
            id: settingsItem
            visible: root.showSettings
            width: parent.width
            height: visible ? settingsColumn.implicitHeight : 0
            implicitHeight: height

            Column {
              id: settingsColumn
              width: parent.width
              spacing: Style.space(12)

              Column {
                width: parent.width
                spacing: Style.space(6)

                PanelSectionHeader {
                  text: "SERVER"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                }

                TextField {
                  id: serverField
                  // Paste only through root.startPaste(); see the Paste section.
                  Keys.onPressed: function(event) { root.interceptPaste(serverField, event) }
                  onActiveFocusChanged: root.invalidatePaste(serverField)
                  onTextChanged: root.invalidatePaste(serverField)
                  onCursorPositionChanged: root.invalidatePaste(serverField)
                  onSelectionStartChanged: root.invalidatePaste(serverField)
                  onSelectionEndChanged: root.invalidatePaste(serverField)
                  QQC.ContextMenu.menu: null
                  MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.MiddleButton
                  }
                  width: parent.width
                  placeholderText: "https://vikunja.example.com"
                  foreground: root.contentForeground
                  accent: root.accentColor
                  font.family: root.contentFontFamily
                  onAccepted: root.saveServer()
                  onEditingFinished: root.saveServer()
                }

                Text {
                  width: parent.width
                  visible: text !== ""
                  text: root.serverError !== ""
                    ? root.serverError
                    : (Model.isInsecureInstance(root.instance)
                      ? "This address is not encrypted (http://): your API token crosses the network in plain text. Use https:// if you can."
                      : "")
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  color: root.urgentColor
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(6)

                PanelSectionHeader {
                  text: "API TOKEN"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                }

                TextField {
                  id: tokenField
                  // Paste only through root.startPaste(); see the Paste section.
                  Keys.onPressed: function(event) { root.interceptPaste(tokenField, event) }
                  onActiveFocusChanged: root.invalidatePaste(tokenField)
                  onTextChanged: root.invalidatePaste(tokenField)
                  onCursorPositionChanged: root.invalidatePaste(tokenField)
                  onSelectionStartChanged: root.invalidatePaste(tokenField)
                  onSelectionEndChanged: root.invalidatePaste(tokenField)
                  QQC.ContextMenu.menu: null
                  MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.MiddleButton
                  }
                  width: parent.width
                  password: true
                  placeholderText: "Paste token, then test connection"
                  foreground: root.contentForeground
                  accent: root.accentColor
                  font.family: root.contentFontFamily
                  onAccepted: root.testConnection()
                }

                Item {
                  id: tokenLinkRow
                  visible: root.instance !== ""
                    && Model.normalizeInstance(serverField.text) === root.instance
                  width: tokenLink.implicitWidth
                  height: tokenLink.implicitHeight

                  Text {
                    id: tokenLink
                    text: "Generate an API token"
                    color: tokenLinkMouse.containsMouse
                      ? Style.hoverStateColor(root.contentForeground, root.accentColor)
                      : root.accentColor
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.underline: true
                  }

                  MouseArea {
                    id: tokenLinkMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openTokenUrl()
                  }
                }

                Text {
                  visible: !tokenLinkRow.visible
                  width: parent.width
                  text: "Settings → API Tokens page to generate a token."
                  textFormat: Text.PlainText
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(6)

                PanelSectionHeader {
                  text: "TEST CONNECTION"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                }

                Button {
                  id: testButton
                  width: parent.width
                  text: root.testStatus === "running" ? "Testing…" : "Test connection"
                  selected: true
                  accent: root.accentColor
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  fontSize: Style.font.bodySmall
                  iconSize: Style.font.bodySmall
                  horizontalPadding: Style.space(12)
                  verticalPadding: Style.space(7)
                  onClicked: root.testConnection()
                }

                Text {
                  width: parent.width
                  visible: root.testStatus === "ok" || root.testStatus === "error"
                  text: root.testMessage
                  textFormat: Text.PlainText
                  color: root.testStatus === "ok" ? "#6fc276" : root.urgentColor
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(6)

                PanelSectionHeader {
                  text: "VIEW"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                }

                ButtonGroup {
                  id: viewGroup
                  options: [
                    { value: Model.VIEW_TREE, label: "All projects" },
                    { value: Model.VIEW_PROJECT, label: "One project" },
                    { value: Model.VIEW_DATES, label: "By date" }
                  ]
                  value: root.viewMode
                  foreground: root.contentForeground
                  accent: root.accentColor
                  fontFamily: root.contentFontFamily
                  fontSize: Style.font.bodySmall
                  onChanged: function(value) { root.setViewMode(value) }
                }

                Text {
                  width: parent.width
                  text: root.viewMode === Model.VIEW_TREE
                    ? "Every project, nested. Click a project's chevron to show or hide it; that choice is remembered."
                    : root.viewMode === Model.VIEW_PROJECT
                      ? "Only the project picked below, grouped by due date."
                      : "All open todos in one list, grouped by due date."
                  textFormat: Text.PlainText
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              Column {
                id: pickerSection
                visible: root.viewMode === Model.VIEW_PROJECT
                width: parent.width
                spacing: Style.space(6)

                PanelSectionHeader {
                  text: "PROJECT"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                }

                Text {
                  visible: root.pickerProjects.length === 0
                  width: parent.width
                  text: root.hasConfig ? "No projects loaded yet. Press sync, then come back." : "Connect to Vikunja first."
                  textFormat: Text.PlainText
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Flickable {
                  id: pickerScroll
                  visible: root.pickerProjects.length > 0
                  width: parent.width
                  height: Math.min(pickerColumn.implicitHeight, Style.space(240))
                  contentWidth: width
                  contentHeight: pickerColumn.implicitHeight
                  clip: true
                  boundsBehavior: Flickable.StopAtBounds
                  interactive: contentHeight > height

                  Column {
                    id: pickerColumn
                    width: pickerScroll.width

                    Repeater {
                      id: pickerRepeater
                      model: root.pickerProjects

                      CursorSurface {
                        id: pickRow
                        required property var modelData
                        readonly property bool selected: root.hostWidget
                          && root.hostWidget.projectId === modelData.id
                        width: parent.width
                        implicitHeight: Style.space(28)
                        hasCursor: pickMouse.containsMouse
                        current: selected
                        foreground: root.contentForeground
                        accent: root.accentColor

                        Rectangle {
                          id: pickDot
                          anchors.left: parent.left
                          anchors.leftMargin: Style.space(8) + pickRow.modelData.depth * Style.space(14)
                          anchors.verticalCenter: parent.verticalCenter
                          width: Style.space(6)
                          height: width
                          radius: width / 2
                          color: pickRow.modelData.color !== "" ? pickRow.modelData.color : Qt.darker(root.contentForeground, 1.8)
                        }

                        Text {
                          anchors.left: pickDot.right
                          anchors.leftMargin: Style.space(8)
                          anchors.right: pickCheck.left
                          anchors.rightMargin: Style.space(6)
                          anchors.verticalCenter: parent.verticalCenter
                          text: pickRow.modelData.title
                          textFormat: Text.PlainText
                          color: root.contentForeground
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.bodySmall
                          font.bold: pickRow.selected
                          elide: Text.ElideRight
                        }

                        Text {
                          id: pickCheck
                          anchors.right: parent.right
                          anchors.rightMargin: Style.space(10)
                          anchors.verticalCenter: parent.verticalCenter
                          text: pickRow.selected ? "\uf00c" : ""
                          textFormat: Text.PlainText
                          color: root.accentColor
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.bodySmall
                        }

                        MouseArea {
                          id: pickMouse
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: root.pickProject(pickRow.modelData.id)
                        }
                      }
                    }
                  }
                }

                Toggle {
                  id: subprojectsToggle
                  width: parent.width
                  label: "Include sub-projects"
                  description: "Also show todos from projects nested inside the chosen one."
                  checked: root.hostWidget ? root.hostWidget.includeSubprojects : true
                  foreground: root.contentForeground
                  accent: root.accentColor
                  fontFamily: root.contentFontFamily
                  onClicked: root.toggleIncludeSubprojects()
                }
              }

              Toggle {
                id: hideEmptyToggle
                visible: root.viewMode === Model.VIEW_TREE
                width: parent.width
                label: "Hide empty projects"
                description: "Leave out projects with no open todos anywhere inside them."
                checked: root.hostWidget ? root.hostWidget.hideEmptyProjects : true
                foreground: root.contentForeground
                accent: root.accentColor
                fontFamily: root.contentFontFamily
                onClicked: root.toggleHideEmptyProjects()
              }

              Column {
                width: parent.width
                spacing: Style.space(6)

                PanelSectionHeader {
                  text: "SYNC INTERVAL"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                }

                // A plain TextField rather than the kit's NumberField (an
                // editable SpinBox), so paste can be routed through
                // root.startPaste() like the other fields. Up/Down step by 15.
                TextField {
                  id: intervalField
                  width: Style.spacing.numberFieldWidth
                  text: String(root.hostWidget ? root.hostWidget.syncInterval : Model.SYNC_INTERVAL.defaultValue)
                  maximumLength: 5
                  inputMethodHints: Qt.ImhDigitsOnly
                  validator: IntValidator { bottom: 0; top: Model.SYNC_INTERVAL.max }
                  foreground: root.contentForeground
                  accent: root.accentColor
                  font.family: root.contentFontFamily
                  // Paste only through root.startPaste(); see the Paste section.
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
                      event.accepted = true
                      root.stepSyncInterval(event.key === Qt.Key_Up ? 15 : -15)
                      return
                    }
                    root.interceptPaste(intervalField, event)
                  }
                  onActiveFocusChanged: root.invalidatePaste(intervalField)
                  onTextChanged: root.invalidatePaste(intervalField)
                  onCursorPositionChanged: root.invalidatePaste(intervalField)
                  onSelectionStartChanged: root.invalidatePaste(intervalField)
                  onSelectionEndChanged: root.invalidatePaste(intervalField)
                  QQC.ContextMenu.menu: null
                  MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.MiddleButton
                  }
                  onEditingFinished: root.saveSyncInterval(text)
                }

                Text {
                  width: parent.width
                  text: "Seconds between automatic refreshes."
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Toggle {
                id: showNoDateToggle
                width: parent.width
                label: "Show todos without a due date"
                description: "Include tasks that have no due date."
                checked: root.hostWidget ? root.hostWidget.showNoDate : true
                foreground: root.contentForeground
                accent: root.accentColor
                fontFamily: root.contentFontFamily
                onClicked: root.toggleShowNoDate()
              }

              Toggle {
                id: showTitleToggle
                width: parent.width
                label: "Show next task title in the bar"
                description: "When off, the bar shows only a compact icon."
                checked: root.showTitle
                foreground: root.contentForeground
                accent: root.accentColor
                fontFamily: root.contentFontFamily
                onClicked: root.toggleShowTitle()
              }

              Column {
                width: parent.width
                spacing: Style.space(6)

                PanelSectionHeader {
                  text: "BAR ICON"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                }

                ButtonGroup {
                  id: iconGroup
                  options: [
                    { value: "mono", label: "Theme color" },
                    { value: "color", label: "Vikunja blue" }
                  ]
                  value: root.hostWidget ? root.hostWidget.iconStyle : "mono"
                  foreground: root.contentForeground
                  accent: root.accentColor
                  fontFamily: root.contentFontFamily
                  fontSize: Style.font.bodySmall
                  onChanged: function(value) { root.setIconStyle(value) }
                }
              }

              Column {
                id: shortcutsSection
                width: parent.width
                spacing: Style.space(6)

                PanelSectionHeader {
                  text: "KEYBOARD SHORTCUTS"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                }

                Repeater {
                  model: [
                    { keys: "j  /  ↓", what: "Next row" },
                    { keys: "k  /  ↑", what: "Previous row" },
                    { keys: "Home  /  End", what: "First / last row" },
                    { keys: "→  /  ←", what: "Open / roll up a project; ← on a todo jumps to its project" },
                    { keys: "Enter", what: "Open the todo in Vikunja; on a project, show or hide it" },
                    { keys: "t", what: "Mark the todo done" },
                    { keys: "u", what: "Open the todo's project in Vikunja" },
                    { keys: "n", what: "New todo (in the highlighted project, else the default)" },
                    { keys: "Enter  /  Esc", what: "In the new-todo box: add it / close the box" },
                    { keys: "z", what: "Expand or collapse all projects (project tree)" },
                    { keys: "g  then  o", what: "Open Overview in Vikunja" },
                    { keys: "g  then  u", what: "Open Upcoming in Vikunja" },
                    { keys: "g  then  p", what: "Open Projects in Vikunja" },
                    { keys: "g  then  a", what: "Open Labels in Vikunja" },
                    { keys: "g  then  m", what: "Open Teams in Vikunja" },
                    { keys: "F5", what: "Sync now" },
                    { keys: "?", what: "Show these shortcuts" },
                    { keys: "Tab  /  Shift+Tab", what: "Move to the next or previous bar panel" },
                    { keys: "Esc", what: "Close the panel" }
                  ]

                  Item {
                    required property var modelData
                    width: shortcutsSection.width
                    height: Math.max(keyChip.height, keyWhat.implicitHeight) + Style.space(2)

                    Rectangle {
                      id: keyChip
                      anchors.left: parent.left
                      anchors.top: parent.top
                      width: Math.max(Style.space(110), keyText.implicitWidth + Style.space(12))
                      height: keyText.implicitHeight + Style.space(6)
                      radius: Style.cornerRadius > 0 ? Style.space(4) : 0
                      color: "transparent"
                      border.width: 1
                      border.color: Qt.darker(root.contentForeground, 2.2)

                      Text {
                        id: keyText
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.keys
                        textFormat: Text.PlainText
                        color: root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }

                    Text {
                      id: keyWhat
                      anchors.left: keyChip.right
                      anchors.leftMargin: Style.space(10)
                      anchors.right: parent.right
                      anchors.verticalCenter: keyChip.verticalCenter
                      text: modelData.what
                      textFormat: Text.PlainText
                      color: Qt.darker(root.contentForeground, 1.3)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }
                  }
                }

                Text {
                  width: parent.width
                  topPadding: Style.space(2)
                  text: "Keys match Vikunja's own shortcuts where Vikunja has one. Mouse: click a todo to open it, click its box or right-click it to mark it done. Right-click the bar icon to complete the next todo."
                  textFormat: Text.PlainText
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }
            }
          }

          BorderSurface {
            id: errorItem
            visible: !root.showSettings && root.loadError !== "" && root.hasConfig
            width: parent.width
            height: visible ? errorColumn.implicitHeight + Style.space(20) : 0
            implicitHeight: height
            radius: Style.cornerRadius
            color: Style.normalFillFor(root.contentForeground, Color.urgent)
            borderSpec: Border.controlSpec("normal", root.contentForeground, Color.urgent)

            Column {
              id: errorColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              spacing: Style.space(8)

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: ""
                color: root.urgentColor
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.display
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "Couldn't reach Vikunja"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                wrapMode: Text.WordWrap
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.loadError
                textFormat: Text.PlainText
                color: Qt.darker(root.contentForeground, 1.35)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              RowLayout {
                width: parent.width
                spacing: Style.space(8)

                Button {
                  Layout.fillWidth: true
                  text: "Retry"
                  iconText: ""
                  selected: true
                  accent: root.accentColor
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  fontSize: Style.font.bodySmall
                  iconSize: Style.font.bodySmall
                  horizontalPadding: Style.space(12)
                  verticalPadding: Style.space(7)
                  onClicked: root.syncNow()
                }

                Button {
                  Layout.fillWidth: true
                  text: "Settings"
                  iconText: ""
                  bordered: true
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  fontSize: Style.font.bodySmall
                  iconSize: Style.font.bodySmall
                  horizontalPadding: Style.space(12)
                  verticalPadding: Style.space(7)
                  onClicked: root.openSettings()
                }
              }
            }
          }

          Item {
            id: setupItem
            visible: !root.showSettings && !!root.hostWidget && !root.hasConfig
              && root.widgetState === "missing"
            width: parent.width
            height: visible ? setupColumn.implicitHeight + Style.space(16) : 0
            implicitHeight: height

            Column {
              id: setupColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              spacing: Style.space(8)

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: ""
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.display
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.configIssue === "no-instance" ? "No instance set" : "No API token"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                wrapMode: Text.WordWrap
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.configIssue === "no-instance"
                  ? "Set your Vikunja instance URL to load your todos."
                  : "Store your Vikunja API token to load your todos."
                textFormat: Text.PlainText
                color: Qt.darker(root.contentForeground, 1.35)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              RowLayout {
                width: parent.width
                spacing: Style.space(8)

                Button {
                  Layout.fillWidth: true
                  text: "Open settings"
                  iconText: ""
                  selected: true
                  accent: root.accentColor
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  fontSize: Style.font.bodySmall
                  iconSize: Style.font.bodySmall
                  horizontalPadding: Style.space(12)
                  verticalPadding: Style.space(7)
                  onClicked: root.openSettings()
                }
              }
            }
          }

          Item {
            id: heroItem
            visible: !root.showSettings && root.hasConfig && !!root.next
            width: parent.width
            height: visible ? heroBlock.implicitHeight : 0
            implicitHeight: height

            BorderSurface {
              id: heroBlock
              width: parent.width
              radius: Style.cornerRadius
              color: Style.normalFillFor(root.contentForeground, root.accentColor)
              borderSpec: Border.none()
              implicitHeight: heroColumn.implicitHeight + Style.space(20)

              Column {
                id: heroColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(5)

                RowLayout {
                  width: parent.width

                  Text {
                    text: "NEXT"
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1.2
                    font.bold: true
                  }

                  Item { Layout.fillWidth: true }

                  Text {
                    text: root.next
                      ? Model.dueDateLabel(root.next, root.now) + (root.next.isRepeating ? " \uf01e" : "")
                      : ""
                    textFormat: Text.PlainText
                    color: Qt.darker(root.contentForeground, 1.4)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                Text {
                  width: parent.width
                  text: root.next ? String(root.next.title) : ""
                  textFormat: Text.PlainText
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  wrapMode: Text.WordWrap
                }

                Text {
                  width: parent.width
                  visible: root.next ? root.next.projectTitle !== "" : false
                  text: root.next ? root.next.projectTitle : ""
                  textFormat: Text.PlainText
                  color: Qt.darker(root.contentForeground, 1.4)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                Text {
                  width: parent.width
                  visible: root.next ? root.next.priority > 0 : false
                  text: root.next ? Model.priorityName(root.next.priority) + " priority" : ""
                  textFormat: Text.PlainText
                  color: priorityColor(root.next ? root.next.priority : 0)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                RowLayout {
                  width: parent.width
                  spacing: Style.space(8)

                  Button {
                    id: openButton
                    Layout.fillWidth: true
                    text: "Open"
                    iconText: ""
                    selected: true
                    accent: root.accentColor
                    fontFamily: root.contentFontFamily
                    fontSize: Style.font.bodySmall
                    iconSize: Style.font.bodySmall
                    horizontalPadding: Style.space(12)
                    verticalPadding: Style.space(7)
                    onClicked: root.openTask(root.next)
                  }

                  Button {
                    id: doneButton
                    Layout.fillWidth: true
                    text: "Mark Done"
                    iconText: ""
                    bordered: true
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    fontSize: Style.font.bodySmall
                    iconSize: Style.font.bodySmall
                    horizontalPadding: Style.space(12)
                    verticalPadding: Style.space(7)
                    onClicked: root.toggleDone(root.next)
                  }
                }
              }
            }
          }

          Item {
            id: emptyItem
            visible: !root.showSettings
              && root.hasConfig
              && root.loadError === ""
              && root.groups.length === 0
              && root.treeRows.length === 0
            width: parent.width
            height: visible ? emptyColumn.implicitHeight + Style.space(16) : 0
            implicitHeight: height

            Column {
              id: emptyColumn
              anchors.centerIn: parent
              spacing: Style.space(4)

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: ""
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.display
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "No open todos"
                color: Qt.darker(root.contentForeground, 1.3)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "You are all caught up."
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Item {
            id: groupsItem
            visible: !root.showSettings && root.hasConfig && !root.treeView && root.groups.length > 0
            width: parent.width
            height: visible ? groupsColumn.implicitHeight : 0
            implicitHeight: height

            Column {
              id: groupsColumn
              width: parent.width
              spacing: Style.space(10)

              Repeater {
                model: root.groups

                Item {
                  id: groupItem
                  required property var modelData
                  required property int index
                  readonly property var group: modelData
                  width: parent.width
                  height: groupColumn.implicitHeight
                  implicitHeight: height

                  Column {
                    id: groupColumn
                    width: parent.width
                    spacing: Style.space(4)

                    PanelSeparator {
                      visible: groupItem.index > 0 || heroItem.visible
                      foreground: root.contentForeground
                      strength: 0.1
                    }

                    RowLayout {
                      spacing: Style.space(6)

                      PanelSectionHeader {
                        text: groupItem.group.title
                        foreground: root.contentForeground
                        fontFamily: root.contentFontFamily
                        leftPadding: Style.space(4)
                      }

                      PanelSectionHeader {
                        text: groupItem.group.items.length + ""
                        foreground: root.contentForeground
                        fontFamily: root.contentFontFamily
                        opacity: 0.55
                      }
                    }

                    Repeater {
                      model: groupItem.group.items

                      CursorSurface {
                        id: taskRow
                        required property var modelData
                        required property int index
                        readonly property var todo: modelData
                        readonly property bool done: modelData.done === true
                        width: parent.width
                        readonly property bool keyed: root.cursorKey === "t" + modelData.id
                        onKeyedChanged: if (keyed) root.ensureVisible(taskRow)
                        hasCursor: rowMouse.containsMouse || keyed
                        foreground: root.contentForeground
                        accent: root.accentColor
                        opacity: done ? 0.45 : 1.0
                        implicitHeight: Math.max(Style.space(32), taskLayout.implicitHeight + Style.space(8))

                        Item {
                          id: priorityMarker
                          anchors.left: parent.left
                          anchors.leftMargin: Style.space(6)
                          anchors.verticalCenter: parent.verticalCenter
                          width: Style.space(6)
                          height: parent.height - Style.space(8)

                          Rectangle {
                            anchors.centerIn: parent
                            width: taskRow.todo.priority > 0 ? Style.space(2) : 0
                            height: taskRow.todo.priority > 0 ? priorityMarker.height : 0
                            radius: width / 2
                            color: priorityColor(taskRow.todo.priority)
                          }
                        }

                        MouseArea {
                          id: rowMouse
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          acceptedButtons: Qt.LeftButton | Qt.RightButton
                          onClicked: function(mouse) {
                            if (mouse.button === Qt.RightButton) root.toggleDone(taskRow.todo)
                            else root.openTask(taskRow.todo)
                          }
                        }

                        DoneBox {
                          anchors.left: parent.left
                          anchors.leftMargin: Style.space(16)
                          anchors.verticalCenter: parent.verticalCenter
                          todo: taskRow.todo
                          rowHot: rowMouse.containsMouse
                        }

                        RowLayout {
                          id: taskLayout
                          anchors.left: parent.left
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                          anchors.leftMargin: Style.space(40)
                          anchors.rightMargin: Style.space(10)
                          spacing: Style.space(8)

                          Column {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            spacing: Style.space(1)

                            Text {
                              width: parent.width
                              text: taskRow.todo.title
                              textFormat: Text.PlainText
                              color: root.contentForeground
                              font.family: root.contentFontFamily
                              font.pixelSize: Style.font.body
                              font.strikeout: taskRow.done
                              elide: Text.ElideRight
                              maximumLineCount: 1
                            }

                            Text {
                              width: parent.width
                              visible: taskRow.todo.projectTitle !== ""
                                && !(root.hostWidget && root.hostWidget.projectScoped
                                  && taskRow.todo.projectId === root.hostWidget.projectId)
                              text: taskRow.todo.projectTitle
                              textFormat: Text.PlainText
                              color: Qt.darker(root.contentForeground, 1.45)
                              font.family: root.contentFontFamily
                              font.pixelSize: Style.font.caption
                              elide: Text.ElideRight
                              maximumLineCount: 1
                            }
                          }

                          Text {
                            Layout.alignment: Qt.AlignVCenter
                            visible: groupItem.group.key === Model.GROUP_LATER
                              || groupItem.group.key === Model.GROUP_OVERDUE
                            text: (groupItem.group.key === Model.GROUP_OVERDUE
                              ? Model.relativeDue(taskRow.todo, root.now)
                              : Model.dueDateLabel(taskRow.todo, root.now))
                              + (taskRow.todo.isRepeating ? " \uf01e" : "")
                            textFormat: Text.PlainText
                            color: groupItem.group.key === Model.GROUP_OVERDUE
                              ? root.urgentColor
                              : Qt.darker(root.contentForeground, 1.35)
                            font.family: root.contentFontFamily
                            font.pixelSize: Style.font.caption
                          }

                          Text {
                            Layout.alignment: Qt.AlignVCenter
                            visible: taskRow.todo.isRepeating
                              && groupItem.group.key !== Model.GROUP_LATER
                              && groupItem.group.key !== Model.GROUP_OVERDUE
                            text: "\uf01e"
                            textFormat: Text.PlainText
                            color: Qt.darker(root.contentForeground, 1.35)
                            font.family: root.contentFontFamily
                            font.pixelSize: Style.font.caption
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          Item {
            id: treeItem
            visible: !root.showSettings && root.hasConfig && root.treeView && root.treeRows.length > 0
            width: parent.width
            height: visible ? treeColumn.implicitHeight : 0
            implicitHeight: height

            Column {
              id: treeColumn
              width: parent.width
              spacing: Style.space(2)

              PanelSeparator {
                visible: heroItem.visible
                foreground: root.contentForeground
                strength: 0.1
              }

              Repeater {
                model: root.treeRows

                Loader {
                  id: rowLoader
                  required property var modelData
                  width: treeColumn.width
                  sourceComponent: modelData.kind === "project" ? projectRowComponent : treeTaskComponent
                  onLoaded: item.row = Qt.binding(function() { return rowLoader.modelData })
                }
              }
            }
          }

          Item {
            id: treeHiddenNotice
            visible: !root.showSettings && root.treeView && root.treeHidden > 0
            width: parent.width
            height: visible ? treeHiddenText.implicitHeight + Style.space(4) : 0
            implicitHeight: height

            Text {
              id: treeHiddenText
              anchors.horizontalCenter: parent.horizontalCenter
              text: "…and " + root.treeHidden + " more. Collapse some projects to see them."
              textFormat: Text.PlainText
              color: Qt.darker(root.contentForeground, 1.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Component {
            id: projectRowComponent

            CursorSurface {
              id: projectRow
              property var row: ({})
              readonly property real indent: Style.space(4) + (row.depth || 0) * Style.space(16)
              width: parent ? parent.width : 0
              implicitHeight: Style.space(30)
              readonly property bool keyed: root.cursorKey !== "" && root.cursorKey === row.key
              onKeyedChanged: if (keyed) root.ensureVisible(projectRow)
              Component.onCompleted: if (keyed) Qt.callLater(root.ensureVisible, projectRow)
              hasCursor: projectMouse.containsMouse || keyed
              foreground: root.contentForeground
              accent: root.accentColor

              Text {
                id: chevron
                anchors.left: parent.left
                anchors.leftMargin: projectRow.indent
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(16)
                horizontalAlignment: Text.AlignHCenter
                visible: projectRow.row.expandable === true
                text: I18n.rightToLeft ? "\uf053" : "\uf054"
                textFormat: Text.PlainText
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                rotation: projectRow.row.collapsed ? 0 : (I18n.rightToLeft ? -90 : 90)
                Behavior on rotation {
                  NumberAnimation {
                    duration: Style.duration(150)
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Style.easeOut
                  }
                }
              }

              Rectangle {
                id: projectDot
                anchors.left: chevron.right
                anchors.leftMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(7)
                height: width
                radius: width / 2
                color: projectRow.row.color ? projectRow.row.color : Qt.darker(root.contentForeground, 1.8)
              }

              Text {
                anchors.left: projectDot.right
                anchors.leftMargin: Style.space(8)
                anchors.right: projectCount.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: projectRow.row.title || ""
                textFormat: Text.PlainText
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: (projectRow.row.depth || 0) === 0 ? Style.font.body : Style.font.bodySmall
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                id: projectAdd
                anchors.right: projectCount.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                visible: projectRow.row.id > 0 && (projectMouse.containsMouse || projectAddMouse.containsMouse)
                text: "\uf067"
                textFormat: Text.PlainText
                color: projectAddMouse.containsMouse ? root.accentColor : Qt.darker(root.contentForeground, 1.3)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                z: 2

                MouseArea {
                  id: projectAddMouse
                  anchors.fill: parent
                  anchors.margins: -Style.space(6)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openAdd(projectRow.row.id)
                }
              }

              Text {
                id: projectCount
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: projectRow.row.count > 0 ? String(projectRow.row.count) : ""
                textFormat: Text.PlainText
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                id: projectMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: projectRow.row.expandable ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: if (projectRow.row.expandable) root.toggleCollapsed(projectRow.row.id)
              }
            }
          }

          Component {
            id: treeTaskComponent

            CursorSurface {
              id: treeTask
              property var row: ({})
              readonly property var todo: row.task || ({})
              readonly property bool done: todo.done === true
              readonly property bool overdue: todo.dueMs !== null && todo.dueMs !== undefined
                && Model.dayDistance(todo.dueMs, root.now) < 0
              width: parent ? parent.width : 0
              implicitHeight: Style.space(28)
              readonly property bool keyed: root.cursorKey !== "" && root.cursorKey === row.key
              onKeyedChanged: if (keyed) root.ensureVisible(treeTask)
              hasCursor: treeTaskMouse.containsMouse || keyed
              foreground: root.contentForeground
              accent: root.accentColor
              opacity: done ? 0.45 : 1.0

              Rectangle {
                id: treePriority
                anchors.left: parent.left
                anchors.leftMargin: Style.space(4) + (treeTask.row.depth || 0) * Style.space(16) + Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(2)
                height: parent.height - Style.space(10)
                radius: width / 2
                color: root.priorityColor(treeTask.todo.priority)
              }

              DoneBox {
                id: treeDoneBox
                anchors.left: treePriority.right
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                todo: treeTask.todo
                rowHot: treeTaskMouse.containsMouse
                z: 2
              }

              Text {
                anchors.left: treeDoneBox.right
                anchors.leftMargin: Style.space(8)
                anchors.right: treeDue.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: treeTask.todo.title || ""
                textFormat: Text.PlainText
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.strikeout: treeTask.done
                elide: Text.ElideRight
                maximumLineCount: 1
              }

              Text {
                id: treeDue
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: Model.relativeDue(treeTask.todo, root.now) + (treeTask.todo.isRepeating ? " \uf01e" : "")
                textFormat: Text.PlainText
                color: treeTask.overdue ? root.urgentColor : Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                id: treeTaskMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: function(mouse) {
                  if (mouse.button === Qt.RightButton) root.toggleDone(treeTask.todo)
                  else root.openTask(treeTask.todo)
                }
              }
            }
          }

          Item {
            id: hiddenNotice
            visible: !root.showSettings && !root.treeView && root.hiddenCount > 0
            width: parent.width
            height: visible ? hiddenNoticeText.implicitHeight + Style.space(4) : 0
            implicitHeight: height

            Text {
              id: hiddenNoticeText
              anchors.horizontalCenter: parent.horizontalCenter
              text: "…and " + root.hiddenCount + " more"
              textFormat: Text.PlainText
              color: Qt.darker(root.contentForeground, 1.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }

  // Square checkbox in front of every todo: click to mark it done.
  component DoneBox: Item {
    id: box
    property var todo: ({})
    property bool rowHot: false
    readonly property bool done: todo && todo.done === true
    width: Style.space(16)
    height: Style.space(16)
    z: 2

    Text {
      anchors.centerIn: parent
      text: box.done || boxMouse.containsMouse ? "\uf14a" : "\uf096"
      textFormat: Text.PlainText
      color: box.done || boxMouse.containsMouse
        ? root.accentColor
        : Qt.darker(root.contentForeground, box.rowHot ? 1.15 : 1.6)
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.body
    }

    MouseArea {
      id: boxMouse
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (!box.done) root.toggleDone(box.todo)
    }
  }
}
