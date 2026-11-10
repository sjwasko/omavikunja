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
  //
  // Everything loaded from the old server is dropped as well, so no row from
  // it stays on screen where a click could pair its task id with the new
  // server. Task actions are refused until a fetch for the new instance
  // succeeds (tasksInstance).
  onInstanceChanged: {
    if (token !== "") token = ""
    doneQueue = []
    pendingDone = ({})
    tasksInstance = ""
    allTasks = []
    projects = []
    projectTitles = ({})
    pickerProjects = []
    recentlyDone = ({})
    recentlyAdded = ({})
    rebuild()
  }

  // The instance the current allTasks/projects were fetched from; "" until a
  // fetch for the current instance succeeds.
  property string tasksInstance: ""
  readonly property bool tasksCurrent: tasksInstance !== "" && tasksInstance === instance

  // ---- Every helper process gets an overall deadline. The command itself is
  //      wrapped in `timeout` (which kills its whole process group), and this
  //      watchdog backs that up: a process that never started, or never
  //      reported its exit, is finished with an error after the deadline so
  //      the widget cannot get stuck "running".
  // A process counts as busy from launch until its exit has been handled,
  // not just while it is running: if the watchdog stops one and its exit
  // arrives late, nothing may relaunch it (and overwrite its forInstance) in
  // between, or the late exit would be taken for the new run's result.
  function busy(process) {
    return process.running || process.deadlineAt > 0
  }

  function launch(process, seconds) {
    var now = Date.now()
    process.launchedAt = now
    process.deadlineAt = now + (seconds + 10) * 1000
    process.running = true
  }

  readonly property var watchedProcesses: [stateDirProcess, collapseReadProcess,
    secretProcess, projectsProcess, tasksProcess, toggleProcess,
    secretTestProcess, testProcess, createProcess, tokenStoreProcess]

  Timer {
    interval: 2000
    repeat: true
    running: true
    onTriggered: {
      var now = Date.now()
      for (var i = 0; i < root.watchedProcesses.length; i++) {
        var p = root.watchedProcesses[i]
        if (p.deadlineAt === 0) continue
        if (!p.running && now - p.launchedAt > 5000) p.handleExit(-1)
        else if (p.running && now > p.deadlineAt) p.running = false
      }
    }
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
    if (busy(secretProcess) || busy(tasksProcess) || busy(projectsProcess)) return
    if (instance === "") {
      widgetState = "missing"
      token = ""
      loadError = "Set the instance URL in the widget settings."
      setTasks([])
      return
    }
    if (token === "") {
      secretProcess.command = Model.boundedCommand(Model.withDeadline(Model.secretLookupCommand(instance), Model.DEADLINES.lookup))
      secretProcess.forInstance = instance
    root.launch(secretProcess, Model.DEADLINES.lookup)
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
    projectsProcess.command = Model.boundedCommand(Model.withDeadline(Model.projectsCommand(instance), Model.DEADLINES.fetch))
    projectsProcess.environment = rootTokenEnv()
    projectsProcess.forInstance = instance
    root.launch(projectsProcess, Model.DEADLINES.fetch)
  }

  // Set when the project list could not be loaded; shown with the tasks.
  property string projectsError: ""

  function finishProjects(exitCode) {
    if (exitCode === 0) {
      try {
        projects = Model.parseProjectList(projectsStdout.text || "")
        projectTitles = Model.projectTitleMap(projects)
        pickerProjects = Model.flatProjects(projects)
        projectsError = ""
      } catch (error) {
        // Keep the last good project list; task loading still proceeds.
        projectsError = "Could not read the project list: " + error
      }
    } else {
      projectsError = "Could not load the project list from Vikunja."
    }
    tasksProcess.command = Model.boundedCommand(Model.withDeadline(Model.tasksCommand(instance), Model.DEADLINES.fetch))
    tasksProcess.environment = rootTokenEnv()
    tasksProcess.forInstance = instance
    root.launch(tasksProcess, Model.DEADLINES.fetch)
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
    return busy(secretProcess) || busy(tasksProcess) || busy(projectsProcess)
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
      // Keep showing the last good list; a failed sync only reports.
      return
    }
    try {
      var parsed = Model.parseTasks(tasksStdout.text || "", projectTitles)
      loadError = projectsError
      allTasks = keepRecentlyAdded(dropRecentlyDone(parsed))
      tasksInstance = tasksProcess.forInstance
      rebuild()
    } catch (error) {
      loadError = "Vikunja returned unusable output: " + error
    }
  }

  // The tasks the user has chosen to see: undated ones drop out when "Show
  // todos without a due date" is off, for the bar, its tooltip and the views.
  function visibleTasks() {
    return showNoDate ? tasks : tasks.filter(function(t) { return t.dueMs !== null })
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
    next = Model.nextTodo(visibleTasks(), pendingDone)

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

  // The state directory is created once at startup, under the same deadline
  // and watchdog as the other helpers. If it cannot be created, roll-up state
  // still works for this session but is not saved (reported once).
  function prepareStateDir() {
    stateDirProcess.command = Model.withDeadline(["mkdir", "-p", root.stateDir], Model.DEADLINES.state)
    root.launch(stateDirProcess, Model.DEADLINES.state)
  }

  function warnCollapseNotSaved() {
    if (collapseSaveWarned) return
    collapseSaveWarned = true
    Quickshell.execDetached(["notify-send", "-u", "low", "Vikunja",
      "Could not save which projects are rolled up; they will reset on the next restart."])
  }

  Process {
    id: stateDirProcess
    running: false
    property real launchedAt: 0
    property real deadlineAt: 0
    function handleExit(code) {
      if (deadlineAt === 0) return
      deadlineAt = 0
      root.stateDirReady = code === 0
      if (code === 0) root.readCollapseFile()
      else root.warnCollapseNotSaved()
    }
    onExited: function(exitCode) { handleExit(exitCode) }
  }

  // The FileView only writes (atomically) and watches the state file; it
  // never reads it. Reads go through `head -c`, so an oversized file is never
  // loaded whole: anything over the cap is ignored.
  FileView {
    id: collapseFile
    path: root.stateDirReady ? root.stateDir + "/collapsed.json" : ""
    preload: false
    blockAllReads: true
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: root.readCollapseFile()
    onSaveFailed: root.warnCollapseNotSaved()
  }

  property bool collapseSaveWarned: false

  function readCollapseFile() {
    if (!stateDirReady) return
    // deadlineAt is set from launch until the exit is handled, so it also
    // covers a process that was asked to start but has not started yet.
    if (collapseReadProcess.deadlineAt > 0) { collapseReadPending = true; return }
    collapseReadProcess.command = Model.withDeadline(
      ["head", "-c", String(Model.MAX_COLLAPSE_FILE_CHARS + 1), stateDir + "/collapsed.json"],
      Model.DEADLINES.state)
    root.launch(collapseReadProcess, Model.DEADLINES.state)
  }

  property bool collapseReadPending: false

  Process {
    id: collapseReadProcess
    running: false
    stdout: StdioCollector {
      id: collapseReadStdout
      waitForEnd: true
    }
    property real launchedAt: 0
    property real deadlineAt: 0
    function handleExit(code) {
      if (deadlineAt === 0) return
      deadlineAt = 0
      // 0: parse what was read. >0: no readable file (first run, or it was
      // removed), so no saved state. -1 (never started or timed out): keep
      // the state already in memory rather than guessing.
      if (code === 0) root.collapseState = Model.parseCollapsedState(collapseReadStdout.text)
      else if (code > 0) root.collapseState = Model.parseCollapsedState("")
      if (root.collapseReadPending) {
        root.collapseReadPending = false
        Qt.callLater(root.readCollapseFile)
      }
    }
    onExited: function(exitCode) { handleExit(exitCode) }
  }

  function openTask(task) {
    if (!task || !tasksCurrent) return
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
    if (!task || token === "" || !tasksCurrent) return
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
    if (busy(toggleProcess) || doneQueue.length === 0) return
    var id = doneQueue[0]
    doneQueue = doneQueue.slice(1)
    togglingId = id
    toggleProcess.command = Model.boundedCommand(Model.withDeadline(Model.toggleDoneCommand(instance, id), Model.DEADLINES.toggle))
    toggleProcess.environment = rootTokenEnv()
    toggleProcess.forInstance = instance
    root.launch(toggleProcess, Model.DEADLINES.toggle)
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

  // Only a fetch that started before the task was marked done can still list
  // it as open; later fetches are the server's word (a repeating task comes
  // back open with its next due date and must show again).
  function dropRecentlyDone(list) {
    var cutoff = Date.now() - 10 * 60 * 1000
    var keep = {}
    var stale = {}
    var any = false
    for (var key in recentlyDone) {
      if (recentlyDone[key] < cutoff) continue
      keep[key] = recentlyDone[key]
      if (recentlyDone[key] > fetchStartedAt) { stale[key] = true; any = true }
    }
    recentlyDone = keep
    if (!any) return list
    return list.filter(function(t) { return stale[t.id] === undefined })
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
    if (text === "" || target <= 0 || token === "" || !tasksCurrent || busy(createProcess)) return false
    // Only projects loaded from the current instance can be targeted.
    if (projectTitles[String(target)] === undefined) return false
    addError = ""
    createProcess.addedProject = target
    // The title rides in the environment, like the token, so it stays out of ps.
    var request = Model.createTaskRequest(instance, target, text)
    var env = rootTokenEnv()
    for (var key in request.env) env[key] = request.env[key]
    createProcess.command = Model.boundedCommand(Model.withDeadline(request.command, Model.DEADLINES.create))
    createProcess.environment = env
    createProcess.forInstance = instance
    root.launch(createProcess, Model.DEADLINES.create)
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
    property real launchedAt: 0
    property real deadlineAt: 0
    // Runs once per launch: on exit, or from the watchdog if the process
    // never started or never reported its exit.
    function handleExit(code) {
      if (deadlineAt === 0) return
      deadlineAt = 0
      root.dropSecrets(createProcess); if (!root.staleResult(createProcess)) root.finishCreate(code)
    }
    onExited: function(exitCode) { handleExit(exitCode) }
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
  // `expectedInstance` is the address in the settings field. If it does not
  // match the saved instance (it was rejected or not saved yet), nothing is
  // sent: a token typed for the new server must never go to the old one.
  function testConnection(tokenOverride, expectedInstance) {
    if (busy(testProcess) || busy(secretTestProcess)) return
    if (expectedInstance !== undefined && expectedInstance !== instance) {
      testStatus = "error"
      testMessage = "Fix the server address above first. Nothing was sent."
      return
    }
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
      secretTestProcess.command = Model.boundedCommand(Model.withDeadline(Model.secretLookupCommand(instance), Model.DEADLINES.lookup))
      secretTestProcess.forInstance = instance
    root.launch(secretTestProcess, Model.DEADLINES.lookup)
      return
    }
    runTest()
  }

  function runTest() {
    testStatus = "running"
    testMessage = "Testing connection…"
    testProcess.command = Model.boundedCommand(Model.withDeadline(Model.testCommand(instance), Model.DEADLINES.test))
    testProcess.environment = testTokenEnv()
    testProcess.forInstance = instance
    root.launch(testProcess, Model.DEADLINES.test)
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
    if (!Model.isValidToken(text) || busy(tokenStoreProcess)) return
    var env = {}
    env[Model.TOKEN_ENV] = text
    tokenStoreProcess.environment = env
    tokenStoreProcess.command = Model.boundedCommand(Model.withDeadline(Model.storeTokenCommand(instanceUrl), Model.DEADLINES.store))
    root.launch(tokenStoreProcess, Model.DEADLINES.store)
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
    // Queues behind a sync already in flight instead of being dropped.
    requestSync()
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
    // Runs whenever an instance is set, so a keyring lookup that failed
    // (locked keyring, Secret Service not up yet) is retried on its own.
    running: root.instance !== ""
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
    property real launchedAt: 0
    property real deadlineAt: 0
    // Runs once per launch: on exit, or from the watchdog if the process
    // never started or never reported its exit.
    function handleExit(code) {
      if (deadlineAt === 0) return
      deadlineAt = 0
      if (!root.staleResult(secretProcess)) root.finishSecretLookup(code)
    }
    onExited: function(exitCode) { handleExit(exitCode) }
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
    property real launchedAt: 0
    property real deadlineAt: 0
    // Runs once per launch: on exit, or from the watchdog if the process
    // never started or never reported its exit.
    function handleExit(code) {
      if (deadlineAt === 0) return
      deadlineAt = 0
      root.dropSecrets(projectsProcess); if (!root.staleResult(projectsProcess)) root.finishProjects(code)
    }
    onExited: function(exitCode) { handleExit(exitCode) }
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
    property real launchedAt: 0
    property real deadlineAt: 0
    // Runs once per launch: on exit, or from the watchdog if the process
    // never started or never reported its exit.
    function handleExit(code) {
      if (deadlineAt === 0) return
      deadlineAt = 0
      root.dropSecrets(tasksProcess); if (!root.staleResult(tasksProcess)) root.finishFetch(code)
    }
    onExited: function(exitCode) { handleExit(exitCode) }
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
    property real launchedAt: 0
    property real deadlineAt: 0
    // Runs once per launch: on exit, or from the watchdog if the process
    // never started or never reported its exit.
    function handleExit(code) {
      if (deadlineAt === 0) return
      deadlineAt = 0
      root.dropSecrets(toggleProcess); if (!root.staleResult(toggleProcess)) root.finishToggle(code)
    }
    onExited: function(exitCode) { handleExit(exitCode) }
  }

  Process {
    id: tokenStoreProcess
    running: false
    clearEnvironment: false
    stderr: StdioCollector {
      id: tokenStoreStderr
      waitForEnd: true
    }
    property real launchedAt: 0
    property real deadlineAt: 0
    // Runs once per launch: on exit, or from the watchdog if the process
    // never started or never reported its exit.
    function handleExit(code) {
      if (deadlineAt === 0) return
      deadlineAt = 0
      root.dropSecrets(tokenStoreProcess); root.finishStoreToken(code)
    }
    onExited: function(exitCode) { handleExit(exitCode) }
  }

  Process {
    id: secretTestProcess
    property string forInstance: ""
    running: false
    stdout: StdioCollector {
      id: secretTestStdout
      waitForEnd: true
    }
    property real launchedAt: 0
    property real deadlineAt: 0
    // Runs once per launch: on exit, or from the watchdog if the process
    // never started or never reported its exit.
    function handleExit(code) {
      if (deadlineAt === 0) return
      deadlineAt = 0
      if (!root.staleResult(secretTestProcess)) root.finishSecretTest(code)
    }
    onExited: function(exitCode) { handleExit(exitCode) }
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
    property real launchedAt: 0
    property real deadlineAt: 0
    // Runs once per launch: on exit, or from the watchdog if the process
    // never started or never reported its exit.
    function handleExit(code) {
      if (deadlineAt === 0) return
      deadlineAt = 0
      root.dropSecrets(testProcess); if (!root.staleResult(testProcess)) root.finishTest(code)
    }
    onExited: function(exitCode) { handleExit(exitCode) }
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
    var counts = Model.summaryCounts(visibleTasks(), now)
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
    root.prepareStateDir()
    Qt.callLater(root.refresh)
  }
}
