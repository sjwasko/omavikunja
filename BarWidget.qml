import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.mjs" as Model

// Vikunja Projects — a keyring-authenticated Vikunja todo list for the bar.
// Based on org.jsongerber.vikunja (MIT). Adds a nested, collapsible project
// tree and a single-project view; which projects are rolled up is remembered
// across launches in $XDG_STATE_HOME/omarchy/sjwasko.omavikunja/collapsed.json.
//
// The API token is read once from the OS keyring and passed to curl via the
// environment, never argv. Left click opens the panel, right click marks the
// next todo done, and the list refreshes on the sync interval.
BarWidget {
  id: root
  moduleName: "sjwasko.omavikunja"

  readonly property string instance: Model.normalizeInstance(setting("instance", null))
  readonly property bool showNoDate: Model.normalizeShowNoDate(setting("showNoDate", null))
  readonly property bool showTitle: Model.normalizeShowTitle(setting("showTitle", null))
  readonly property int syncInterval: Model.normalizeSyncInterval(setting("syncInterval", null))
  readonly property string viewMode: Model.normalizeViewMode(setting("viewMode", null))
  readonly property int projectId: Model.normalizeProjectId(setting("projectId", null))
  readonly property bool includeSubprojects: Model.normalizeIncludeSubprojects(setting("includeSubprojects", null))
  readonly property bool hideEmptyProjects: Model.normalizeHideEmptyProjects(setting("hideEmptyProjects", null))
  // Single-project view with no project picked yet falls back to the tree.
  // A saved project that has since been deleted or archived counts as unset.
  readonly property bool projectScoped: viewMode === Model.VIEW_PROJECT && projectId > 0
    && (projects.length === 0 || projects.some(function(p) { return p.id === projectId && !p.archived }))
  readonly property string scopeTitle: projectScoped ? Model.projectPath(projects, projectId) : ""

  property var allTasks: []
  property var tasks: []
  property var groups: []
  property var projects: []
  property var pickerProjects: []
  property var treeRows: []
  property int treeHidden: 0
  property var collapseState: ({})
  readonly property var collapsedIds: Model.collapsedFor(collapseState, instance)
  property var next: null
  property var pendingDone: ({})
  property var projectTitles: ({})
  property string token: ""
  property string loadError: ""
  property string widgetState: "checking"
  property int hiddenCount: 0
  property date now: new Date()
  property string testStatus: "idle"
  property string testMessage: ""
  property string testToken: ""

  readonly property bool syncing: tasksProcess.running || projectsProcess.running
  readonly property bool hasConfig: instance !== "" && token !== ""
  readonly property string configIssue: instance === ""
    ? "no-instance"
    : token === "" ? "no-token" : ""
  // The bar sizes itself from `label`; the leading glyph and spaces reserve
  // the room the llama icon takes in front of the title.
  readonly property string titleText: next ? Model.formatLabel(next, now) : ""
  readonly property string label: next ? "\uf058  " + titleText : ""
  readonly property string iconStyle: Model.normalizeIconStyle(setting("iconStyle", null))
  readonly property bool showingFallbackIcon: !showTitle || label === ""

  // The token is scoped to the instance URL in the keyring, so a cached token
  // from the previous instance is invalid once the URL changes. Drop it so the
  // next refresh re-reads the keyring (or shows the "no token" setup screen)
  // instead of firing the old token at the new instance.
  //
  // Requests already running for the old instance are left to finish, but each
  // Process remembers the instance it started for (forInstance) and its result
  // is thrown away if that no longer matches, so a late keyring lookup or
  // connection test can never send the old token to the new instance. Queued
  // "mark done" clicks are dropped too: their task ids belong to the old server.
  onInstanceChanged: {
    if (token !== "") token = ""
    doneQueue = []
    pendingDone = ({})
    rebuild()
  }

  // True (after cleaning up) when a finished Process was started for a
  // different instance than the current one.
  function staleResult(process) {
    if (process.forInstance === instance) return false
    if (process === toggleProcess) {
      togglingId = 0
      Qt.callLater(startNextToggle)
    } else if (process === testProcess || process === secretTestProcess) {
      testToken = ""
      resetTest()
    } else if (process !== createProcess) {
      Qt.callLater(refresh)
    }
    return true
  }

  function refresh() {
    if (secretProcess.running || tasksProcess.running || projectsProcess.running) return
    if (instance === "") {
      widgetState = "missing"
      token = ""
      loadError = "Set the instance URL in the widget settings."
      setTasks([])
      return
    }
    if (token === "") {
      secretProcess.command = Model.secretLookupCommand(instance)
      secretProcess.forInstance = instance
    secretProcess.running = true
      return
    }
    startFetch()
  }

  function finishSecretLookup(exitCode) {
    var value = String(secretStdout.text || "").trim()
    if (exitCode !== 0 || !Model.isValidToken(value)) {
      widgetState = "missing"
      token = ""
      loadError = "Vikunja token not found in the keyring.\nOpen the settings (gear icon) to store your API token."
      setTasks([])
      return
    }
    token = value
    widgetState = "ready"
    loadError = ""
    startFetch()
  }

  function startFetch() {
    fetchStartedAt = Date.now()
    projectsProcess.command = Model.boundedCommand(Model.projectsCommand(instance))
    projectsProcess.environment = rootTokenEnv()
    projectsProcess.forInstance = instance
    projectsProcess.running = true
  }

  function finishProjects(exitCode) {
    if (exitCode === 0) {
      try {
        projects = Model.parseProjectList(projectsStdout.text || "")
        projectTitles = Model.projectTitleMap(projects)
        pickerProjects = Model.flatProjects(projects)
      } catch (error) {
        // Keep the last good project list; task loading should still proceed.
      }
    }
    tasksProcess.command = Model.boundedCommand(Model.tasksCommand(instance))
    tasksProcess.environment = rootTokenEnv()
    tasksProcess.forInstance = instance
    tasksProcess.running = true
  }

  // Processes that carried the token (or a new todo's title) in their
  // environment drop it as soon as they exit, so it is not kept around.
  function dropSecrets(process) {
    process.environment = ({})
  }

  function rootTokenEnv() {
    var env = {}
    env[Model.TOKEN_ENV] = token
    return env
  }

  // ---- Sync on demand. A request made while a sync is running is held and
  //      run as soon as that one finishes, so nothing waits a full interval.
  property bool resyncPending: false
  property real fetchStartedAt: 0
  // id -> { at: ms added, json: the created task as Vikunja returned it }. Keeps a just-added todo visible if a sync that started
  // before the add (and so cannot know about it) finishes first.
  property var recentlyAdded: ({})

  function createdId(json) {
    try { return Number(JSON.parse(String(json || "")).id) || 0 } catch (e) { return 0 }
  }

  function syncBusy() {
    return secretProcess.running || tasksProcess.running || projectsProcess.running
  }

  function requestSync() {
    if (syncBusy()) { resyncPending = true; return }
    syncTimer.restart()
    refresh()
  }

  function finishSyncCycle() {
    if (!resyncPending) return
    resyncPending = false
    Qt.callLater(requestSync)
  }

  function keepRecentlyAdded(parsed) {
    var keep = {}
    var out = parsed
    for (var key in recentlyAdded) {
      var entry = recentlyAdded[key]
      if (entry.at <= fetchStartedAt) continue    // this fetch already saw it
      keep[key] = entry
      var id = Number(key)
      if (out.some(function(t) { return t.id === id })) continue
      if (recentlyDone[id] !== undefined) continue
      out = Model.insertTask(out, entry.json, projectTitles)
    }
    recentlyAdded = keep
    return out
  }

  function finishFetch(exitCode) {
    finishSyncCycle()
    if (exitCode !== 0) {
      var stderr = String(tasksStderr.text || "").trim()
      var detail = Model.truncate(stderr, 320)
      loadError = detail !== ""
        ? "Vikunja failed: " + detail
        : "Could not load todos from Vikunja."
      setTasks([])
      return
    }
    try {
      var parsed = Model.parseTasks(tasksStdout.text || "", projectTitles)
      loadError = ""
      allTasks = keepRecentlyAdded(dropRecentlyDone(parsed))
      rebuild()
    } catch (error) {
      loadError = "Vikunja returned unusable output: " + error
      setTasks([])
    }
  }

  function setTasks(list) {
    allTasks = list
    rebuild()
  }

  // Derive everything the bar and panel show from allTasks: scope to the
  // chosen project, pick the next todo, and build either the date groups or
  // the project tree rows.
  function rebuild() {
    tasks = projectScoped
      ? Model.scopeTasks(allTasks, projects, projectId, includeSubprojects)
      : allTasks
    next = Model.nextTodo(tasks, pendingDone)

    if (viewMode === Model.VIEW_TREE || (viewMode === Model.VIEW_PROJECT && !projectScoped)) {
      var open = Model.openTasks(tasks, pendingDone).filter(function(t) {
        return showNoDate || t.dueMs !== null
      })
      var built = Model.buildTreeRows(projects, open, {
        collapsed: collapsedIds,
        hideEmpty: hideEmptyProjects
      })
      treeRows = built.rows
      treeHidden = built.hidden
      groups = []
      hiddenCount = 0
    } else {
      var grouped = Model.buildGroups(tasks, now, { showNoDate: showNoDate, pendingDone: pendingDone })
      var limited = Model.truncateGroups(grouped, Model.MAX_DISPLAY_TASKS * 3)
      groups = limited.groups
      hiddenCount = limited.hidden
      treeRows = []
      treeHidden = 0
    }
  }

  // ---- Collapse state. One JSON file holds the collapsed project ids per
  //      instance URL; every chevron click rewrites it atomically.
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/sjwasko.omavikunja"
  property bool stateDirReady: false

  function isCollapsed(id) {
    return collapsedIds.indexOf(Number(id)) >= 0
  }

  function toggleCollapsed(id) {
    saveCollapseState(Model.setCollapsed(collapseState, instance, id))
  }

  function expandAll() {
    saveCollapseState(Model.replaceCollapsed(collapseState, instance, []))
  }

  function collapseAll() {
    saveCollapseState(Model.replaceCollapsed(collapseState, instance, Model.allProjectIds(projects)))
  }

  function saveCollapseState(state) {
    collapseState = state
    rebuild()
    if (stateDirReady) collapseFile.setText(Model.serializeCollapsedState(state))
  }

  onCollapsedIdsChanged: rebuild()
  onViewModeChanged: rebuild()
  onProjectIdChanged: rebuild()
  onProjectScopedChanged: rebuild()
  onIncludeSubprojectsChanged: rebuild()
  onHideEmptyProjectsChanged: rebuild()
  onShowNoDateChanged: rebuild()

  Process {
    id: stateDirProcess
    command: ["mkdir", "-p", root.stateDir]
    running: true
    onExited: function(exitCode) {
      root.stateDirReady = exitCode === 0
      collapseFile.reload()
    }
  }

  FileView {
    id: collapseFile
    path: root.stateDirReady ? root.stateDir + "/collapsed.json" : ""
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.collapseState = Model.parseCollapsedState(text())
    onFileChanged: reload()
  }

  function openTask(task) {
    if (!task) return
    Quickshell.execDetached(["xdg-open", instance + "/tasks/" + task.id])
  }

  // ---- Marking done. Clicks queue up: each task is crossed out at once and
  //      PATCHed one after another, so rapid clicks are never dropped.
  property var doneQueue: []
  property int togglingId: 0
  // id -> ms completed. Filters those tasks out of a sync that was already in
  // flight (and so still lists them as open) for a few minutes.
  property var recentlyDone: ({})
  readonly property int doneQueueLength: doneQueue.length + (toggleProcess.running ? 1 : 0)

  function toggleDone(task) {
    if (!task || token === "") return
    var id = Number(task.id)
    if (pendingDone[id] === true) return
    // Optimistically mark the task done so it renders crossed immediately;
    // finishToggle reverts it if the PATCH fails.
    pendingDone[id] = true
    doneQueue = doneQueue.concat([id])
    rebuild()
    startNextToggle()
  }

  function startNextToggle() {
    if (toggleProcess.running || doneQueue.length === 0) return
    var id = doneQueue[0]
    doneQueue = doneQueue.slice(1)
    togglingId = id
    toggleProcess.command = Model.boundedCommand(Model.toggleDoneCommand(instance, id))
    toggleProcess.environment = rootTokenEnv()
    toggleProcess.forInstance = instance
    toggleProcess.running = true
  }

  function finishToggle(exitCode) {
    var id = togglingId
    delete pendingDone[id]
    if (exitCode !== 0) {
      var detail = Model.truncate(String(toggleStderr.text || "").trim(), 200)
      Quickshell.execDetached([
        "notify-send", "-u", "low", "Vikunja",
        Model.escapeMarkup(detail !== "" ? detail : "Could not mark the todo as done.")
      ])
    } else {
      // Only open tasks are fetched, so a done task simply leaves the list;
      // no need to wait on a full re-sync.
      recentlyDone[id] = Date.now()
      allTasks = Model.removeTask(allTasks, id)
    }
    rebuild()
    // Start the next one on the next tick: the Process is still finishing
    // its exit handler here.
    Qt.callLater(startNextToggle)
  }

  function dropRecentlyDone(list) {
    var cutoff = Date.now() - 10 * 60 * 1000
    var keep = {}
    var any = false
    for (var key in recentlyDone) {
      if (recentlyDone[key] >= cutoff) { keep[key] = recentlyDone[key]; any = true }
    }
    recentlyDone = keep
    if (!any) return list
    return list.filter(function(t) { return keep[t.id] === undefined })
  }

  // ---- Adding todos. The created task comes back from the API and is merged
  //      into the list straight away.
  property string addError: ""
  readonly property bool adding: createProcess.running
  readonly property int defaultProjectId: projectScoped ? projectId : Model.defaultProjectId(projects)
  signal taskAdded(int projectId)

  function projectTitle(id) {
    return projectTitles[String(id)] || ""
  }

  function addTask(projectId, title) {
    var text = Model.normalizeNewTitle(title)
    var target = Number(projectId) || defaultProjectId
    if (text === "" || target <= 0 || token === "" || createProcess.running) return false
    addError = ""
    createProcess.addedProject = target
    // The title rides in the environment, like the token, so it stays out of ps.
    var request = Model.createTaskRequest(instance, target, text)
    var env = rootTokenEnv()
    for (var key in request.env) env[key] = request.env[key]
    createProcess.command = Model.boundedCommand(request.command)
    createProcess.environment = env
    createProcess.forInstance = instance
    createProcess.running = true
    return true
  }

  function finishCreate(exitCode) {
    if (exitCode !== 0) {
      var detail = Model.truncate(String(createStderr.text || "").trim(), 200)
      addError = detail !== "" ? detail : "Could not add the todo."
      return
    }
    allTasks = Model.insertTask(allTasks, createStdout.text || "", projectTitles)
    // Make sure the new todo is visible: open its project in the tree.
    if (isCollapsed(createProcess.addedProject))
      saveCollapseState(Model.setCollapsed(collapseState, instance, createProcess.addedProject, false))
    rebuild()
    var newId = createdId(createStdout.text)
    if (newId > 0) recentlyAdded[newId] = { at: Date.now(), json: String(createStdout.text || "") }
    taskAdded(createProcess.addedProject)
    // Pull the server's view of the new todo right away instead of waiting
    // for the next interval.
    requestSync()
  }

  Process {
    id: createProcess
    property string forInstance: ""
    property int addedProject: 0
    running: false
    clearEnvironment: false
    stdout: StdioCollector {
      id: createStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: createStderr
      waitForEnd: true
    }
    onExited: function(exitCode) { root.dropSecrets(createProcess); if (!root.staleResult(createProcess)) root.finishCreate(exitCode) }
  }

  function eventValue(value) {
    return value === undefined || value === null ? "" : String(value)
  }

  // Reset the settings-page connection test back to a neutral state.
  function resetTest() {
    testStatus = "idle"
    testMessage = ""
  }

  // Test the configured instance + token with a lightweight authenticated
  // request. `tokenOverride` is the unsaved token still sitting in the
  // settings field; when present it is tested directly instead of the keyring.
  // Otherwise the cached token is used, or looked up from the keyring first.
  function testConnection(tokenOverride) {
    if (testProcess.running || secretTestProcess.running) return
    if (instance === "") {
      testStatus = "error"
      testMessage = "Set an instance URL first."
      return
    }
    var candidate = tokenOverride === undefined || tokenOverride === null
      ? "" : String(tokenOverride).trim()
    if (candidate !== "") {
      if (!Model.isValidToken(candidate)) {
        testStatus = "error"
        testMessage = "That doesn't look like an API token (it contains spaces or control characters)."
        return
      }
      testToken = candidate
      runTest()
      return
    }
    if (token === "") {
      testStatus = "running"
      testMessage = "Reading API token from the keyring…"
      secretTestProcess.command = Model.secretLookupCommand(instance)
      secretTestProcess.forInstance = instance
    secretTestProcess.running = true
      return
    }
    runTest()
  }

  function runTest() {
    testStatus = "running"
    testMessage = "Testing connection…"
    testProcess.command = Model.boundedCommand(Model.testCommand(instance))
    testProcess.environment = testTokenEnv()
    testProcess.forInstance = instance
    testProcess.running = true
  }

  function testTokenEnv() {
    var env = {}
    env[Model.TOKEN_ENV] = testToken !== "" ? testToken : token
    return env
  }

  function finishSecretTest(exitCode) {
    var value = String(secretTestStdout.text || "").trim()
    if (exitCode !== 0 || !Model.isValidToken(value)) {
      testStatus = "error"
      testMessage = "API token not found in the keyring. Paste it above and try again."
      return
    }
    token = value
    runTest()
  }

  function finishTest(exitCode) {
    var out = String(testStdout.text || "").trim()
    var override = testToken
    testToken = ""
    if (exitCode === 0) {
      testStatus = "ok"
      testMessage = "Connection OK"
      loadError = ""
      widgetState = "ready"
      if (override !== "") {
        // The user tested a token still in the field — persist it so the list
        // actually loads, then refresh.
        storeToken(instance, override)
      } else {
        refresh()
      }
    } else {
      testStatus = "error"
      testMessage = out !== "" ? Model.truncate(out, 240) : "Connection failed."
    }
  }

  // Persist one or more settings to this widget's shell.json entry. Applied
  // locally first so the bar reacts on the click itself; the shell.json write
  // comes back through the bar as the same values. The token is intentionally
  // excluded — it lives in the keyring, never in shell.json.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    for (var k in values) entry[k] = values[k]

    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // Store a freshly entered token in the keyring, scoped to the instance it
  // belongs to, then re-read it so the widget re-authenticates. The token
  // travels via the VIKUNJA_TOKEN environment variable, never argv.
  function storeToken(instanceUrl, value) {
    var text = String(value || "").trim()
    if (!Model.isValidToken(text) || tokenStoreProcess.running) return
    var env = {}
    env[Model.TOKEN_ENV] = text
    tokenStoreProcess.environment = env
    tokenStoreProcess.command = Model.storeTokenCommand(instanceUrl)
    tokenStoreProcess.running = true
  }

  function finishStoreToken(exitCode) {
    if (exitCode !== 0) {
      var detail = Model.truncate(String(tokenStoreStderr.text || "").trim(), 200)
      Quickshell.execDetached([
        "notify-send", "-u", "critical", "Vikunja",
        Model.escapeMarkup(detail !== ""
          ? "Could not store the API token in the keyring: " + detail
          : "Could not store the API token in the keyring.")
      ])
      return
    }
    token = ""
    widgetState = "checking"
    loadError = ""
    refresh()
  }

  // Shape used by shell panel routing and the popout coordinator.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() {
    refresh()
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (opened) close()
    else open()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  readonly property real openPanelIndicatorWidth: showingFallbackIcon
    ? Math.max(
        fallbackIcon.width,
        Style.space(10),
        Math.round(Style.bar.iconSlot * 0.55))
    : plainLabel.implicitWidth

  onSettingsChanged: {
    root.resetTest()
    Qt.callLater(root.refresh)
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: {
      Date.timeZoneUpdated()
      root.now = date
      root.rebuild()
    }
  }

  Timer {
    id: syncTimer
    interval: root.syncInterval * 1000
    repeat: true
    running: root.hasConfig
    onTriggered: root.refresh()
  }

  Process {
    id: secretProcess
    property string forInstance: ""
    running: false
    stdout: StdioCollector {
      id: secretStdout
      waitForEnd: true
    }
    onExited: function(exitCode) { if (!root.staleResult(secretProcess)) root.finishSecretLookup(exitCode) }
  }

  Process {
    id: projectsProcess
    property string forInstance: ""
    running: false
    clearEnvironment: false
    stdout: StdioCollector {
      id: projectsStdout
      waitForEnd: true
    }
    onExited: function(exitCode) { root.dropSecrets(projectsProcess); if (!root.staleResult(projectsProcess)) root.finishProjects(exitCode) }
  }

  Process {
    id: tasksProcess
    property string forInstance: ""
    running: false
    clearEnvironment: false
    stdout: StdioCollector {
      id: tasksStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: tasksStderr
      waitForEnd: true
    }
    onExited: function(exitCode) { root.dropSecrets(tasksProcess); if (!root.staleResult(tasksProcess)) root.finishFetch(exitCode) }
  }

  Process {
    id: toggleProcess
    property string forInstance: ""
    running: false
    clearEnvironment: false
    stderr: StdioCollector {
      id: toggleStderr
      waitForEnd: true
    }
    onExited: function(exitCode) { root.dropSecrets(toggleProcess); if (!root.staleResult(toggleProcess)) root.finishToggle(exitCode) }
  }

  Process {
    id: tokenStoreProcess
    running: false
    clearEnvironment: false
    stderr: StdioCollector {
      id: tokenStoreStderr
      waitForEnd: true
    }
    onExited: function(exitCode) { root.dropSecrets(tokenStoreProcess); root.finishStoreToken(exitCode) }
  }

  Process {
    id: secretTestProcess
    property string forInstance: ""
    running: false
    stdout: StdioCollector {
      id: secretTestStdout
      waitForEnd: true
    }
    onExited: function(exitCode) { if (!root.staleResult(secretTestProcess)) root.finishSecretTest(exitCode) }
  }

  Process {
    id: testProcess
    property string forInstance: ""
    running: false
    clearEnvironment: false
    stdout: StdioCollector {
      id: testStdout
      waitForEnd: true
    }
    onExited: function(exitCode) { root.dropSecrets(testProcess); if (!root.staleResult(testProcess)) root.finishTest(exitCode) }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      item.bar = Qt.binding(function() { return root.bar })
      item.settings = Qt.binding(function() { return root.settings })
      item.anchorItem = button
      item.hostWidget = root
    }
  }

  IpcHandler {
    target: "sjwasko.omavikunja"

    function refresh(): void { root.refresh() }
    function toggle(): void { root.togglePanel() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function settings(): void {
      root.open()
      if (panelLoader.item) panelLoader.item.openSettings()
    }
    function view(mode: string): void {
      if (panelLoader.item) panelLoader.item.setViewMode(mode)
    }
    function expandAll(): void { root.expandAll() }
    function collapseAll(): void { root.collapseAll() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.label
    labelVisible: false
    hasVisualContent: true
    dimmed: root.label === ""
    active: root.next !== null
    useActiveColor: false
    fixedWidth: root.showingFallbackIcon && !vertical ? Style.bar.iconSlot : -1
    fixedHeight: root.showingFallbackIcon && vertical ? Style.bar.iconSlot : -1
    horizontalMargin: 8.75
    verticalPadding: 8.75
    tooltipText: root.tooltipLine

    Row {
      id: plainLabel
      visible: !root.showingFallbackIcon
      anchors.centerIn: parent
      spacing: Style.space(6)

      VikunjaIcon {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        color: button.foreground
        colored: root.iconStyle === "color"
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.titleText
        textFormat: Text.PlainText
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
        verticalAlignment: Text.AlignVCenter

        Behavior on color {
          enabled: !button.bar || button.bar.foregroundAnimationEnabled
          ColorAnimation { duration: Style.duration(160) }
        }
      }
    }

    VikunjaIcon {
      id: fallbackIcon
      anchors.centerIn: parent
      width: Style.bar.iconCanvas
      height: Style.bar.iconCanvas
      visible: root.showingFallbackIcon
      color: button.foreground
      colored: root.iconStyle === "color"
    }

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) {
        if (root.next) root.toggleDone(root.next)
        else root.togglePanel()
      } else if (mouseButton === Qt.LeftButton) {
        root.togglePanel()
      }
    }
  }

  // Sanitize external text passed to the host's AutoText tooltip. Shows a
  // summary of the open list rather than repeating the bar label.
  readonly property string tooltipLine: {
    if (widgetState === "checking") return "Checking for Vikunja…"
    if (loadError !== "") return Model.plainLine(loadError)
    var counts = Model.summaryCounts(tasks, now)
    var scope = root.scopeTitle !== "" ? Model.plainLine(root.scopeTitle) + ": " : ""
    if (counts.open === 0) return scope + "No open todos"
    var parts = [scope + counts.open + " open"]
    if (counts.overdue > 0) parts.push(counts.overdue + " overdue")
    if (counts.noDate > 0) parts.push(counts.noDate + " no date")
    var summary = parts.join(" · ")
    if (next && (!showTitle || Model.labelIsTruncated(next, now)))
      return Model.plainLine(next.title) + "\n────────\n" + summary
    return summary
  }

  Component.onCompleted: {
    now = new Date()
    Qt.callLater(root.refresh)
  }
}
