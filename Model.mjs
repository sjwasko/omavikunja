// Stable public API shared by QML and the dependency-free Node test suite.
export {
  MINUTE_MS,
  DAY_MS,
  ZERO_DATE,
  localDateKey,
  addLocalDays,
  parseDueDate,
  dayDistance
} from "./model/dates.mjs"

export {
  normalizedTask,
  parseTasks,
  parseProjects,
  insertTask,
  removeTask,
  normalizeNewTitle,
  MAX_NEW_TITLE_CHARS
} from "./model/tasks.mjs"

export {
  nextTodo,
  buildGroups,
  openTasks,
  heroActions,
  summaryCounts,
  truncateGroups,
  GROUP_OVERDUE,
  GROUP_TODAY,
  GROUP_TOMORROW,
  GROUP_LATER,
  GROUP_NO_DATE
} from "./model/select.mjs"

export {
  INSTANCE,
  SHOW_NO_DATE,
  SHOW_TITLE,
  SYNC_INTERVAL,
  normalizeInstance,
  normalizeShowNoDate,
  normalizeShowTitle,
  normalizeSyncInterval,
  VIEW_TREE,
  VIEW_PROJECT,
  VIEW_DATES,
  VIEW_MODE,
  PROJECT_ID,
  INCLUDE_SUBPROJECTS,
  HIDE_EMPTY_PROJECTS,
  normalizeViewMode,
  normalizeProjectId,
  normalizeIncludeSubprojects,
  normalizeHideEmptyProjects,
  ICON_STYLE,
  normalizeIconStyle
} from "./model/settings.mjs"

export {
  formatLabel,
  labelIsTruncated,
  relativeDue,
  dueDateLabel,
  priorityGlyph,
  priorityName,
  truncate,
  plainLine
} from "./model/format.mjs"

export {
  MAX_STDOUT_BYTES,
  MAX_STDERR_BYTES,
  MAX_PAGE_BYTES,
  MAX_TOTAL_BYTES,
  MAX_PAGES,
  TOKEN_ENV,
  TITLE_ENV,
  SECRET_SERVICE,
  LEGACY_SECRET_SERVICE,
  boundedCommand,
  secretLookupCommand,
  storeTokenCommand,
  tasksCommand,
  projectsCommand,
  toggleDoneCommand,
  testCommand,
  createTaskRequest
} from "./model/command.mjs"

export {
  MAX_OUTPUT_CHARS,
  MAX_TASKS,
  MAX_PROJECTS,
  MAX_DISPLAY_TASKS,
  MAX_TITLE_CHARS,
  MAX_DESCRIPTION_CHARS,
  MAX_DATE_CHARS,
  MAX_URL_CHARS,
  MAX_ENUM_CHARS
} from "./model/limits.mjs"

export {
  MAX_PROJECT_DEPTH,
  MAX_TREE_ROWS,
  MAX_COLLAPSED_IDS,
  parseProjectList,
  projectTitleMap,
  buildProjectTree,
  descendantIds,
  scopeTasks,
  projectPath,
  flatProjects,
  buildTreeRows,
  allProjectIds,
  defaultProjectId,
  parseCollapsedState,
  collapsedFor,
  setCollapsed,
  replaceCollapsed,
  serializeCollapsedState
} from "./model/projects.mjs"
