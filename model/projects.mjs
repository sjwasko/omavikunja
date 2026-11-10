import { MAX_PROJECTS, MAX_TITLE_CHARS, assertOutputWithinLimit, clamped } from "./limits.mjs"

// Projects nest at most this deep in the tree. Vikunja does not cap nesting,
// so a malformed or cyclic parent chain is cut off here.
export const MAX_PROJECT_DEPTH = 8

// The panel instantiates at most this many tree rows (project headers and
// tasks together); anything past it is counted in an "…and N more" notice.
export const MAX_TREE_ROWS = 200

function normalizeColor(value) {
  const text = clamped(value, 16).trim().replace(/^#/, "")
  return /^[0-9a-fA-F]{6}$/.test(text) ? "#" + text.toLowerCase() : ""
}

// Parse the merged /projects array into a flat, validated list. Saved filters
// come back as pseudo-projects with negative ids; they hold no tasks of their
// own and are dropped.
export function parseProjectList(json) {
  const input = json === undefined || json === null ? "" : String(json)
  assertOutputWithinLimit(input)
  const parsed = JSON.parse(input)
  if (!Array.isArray(parsed)) throw new Error("Vikunja output must be a JSON array")
  if (parsed.length > MAX_PROJECTS) {
    throw new Error("Vikunja output exceeds " + MAX_PROJECTS + " projects")
  }

  const list = []
  const seen = Object.create(null)
  for (let i = 0; i < parsed.length; i++) {
    const raw = parsed[i]
    if (!raw || typeof raw !== "object") continue
    const id = Math.floor(Number(raw.id))
    if (!isFinite(id) || id <= 0 || seen[id]) continue
    seen[id] = true
    const parentId = Math.floor(Number(raw.parent_project_id)) || 0
    const position = Number(raw.position)
    list.push({
      id,
      title: clamped(raw.title, MAX_TITLE_CHARS).trim() || "Untitled project",
      parentId: parentId > 0 && parentId !== id ? parentId : 0,
      archived: raw.is_archived === true,
      position: isFinite(position) ? position : 0,
      color: normalizeColor(raw.hex_color)
    })
  }
  return list
}

export function projectTitleMap(projects) {
  const map = Object.create(null)
  for (let i = 0; i < (projects || []).length; i++) map[String(projects[i].id)] = projects[i].title
  return map
}

function compareProjects(a, b) {
  if (a.position !== b.position) return a.position - b.position
  return a.title.localeCompare(b.title)
}

// Build the nested project tree. Children whose parent is unknown (archived,
// not shared with the user, or deleted) become roots so their tasks never
// vanish. Cycles are broken by the depth cap and a visited set.
export function buildProjectTree(projects, options) {
  const opts = options || {}
  const showArchived = opts.showArchived === true
  const visible = []
  for (let i = 0; i < (projects || []).length; i++) {
    if (!showArchived && projects[i].archived) continue
    visible.push(projects[i])
  }

  const byId = Object.create(null)
  for (let i = 0; i < visible.length; i++) byId[visible[i].id] = visible[i]

  const children = Object.create(null)
  const roots = []
  for (let i = 0; i < visible.length; i++) {
    const p = visible[i]
    if (p.parentId && byId[p.parentId]) {
      if (!children[p.parentId]) children[p.parentId] = []
      children[p.parentId].push(p)
    } else {
      roots.push(p)
    }
  }

  const visited = Object.create(null)
  function make(project, depth) {
    visited[project.id] = true
    const node = { project, depth, children: [] }
    const kids = (children[project.id] || []).slice().sort(compareProjects)
    for (let i = 0; i < kids.length; i++) {
      if (visited[kids[i].id] || depth + 1 >= MAX_PROJECT_DEPTH) continue
      node.children.push(make(kids[i], depth + 1))
    }
    return node
  }

  const tree = []
  roots.sort(compareProjects)
  for (let i = 0; i < roots.length; i++) tree.push(make(roots[i], 0))
  // Anything left unvisited sits on a parent cycle; surface it as a root.
  for (let i = 0; i < visible.length; i++) {
    if (!visited[visible[i].id]) tree.push(make(visible[i], 0))
  }
  return tree
}

// Ids of `rootId` and every project nested below it.
export function descendantIds(projects, rootId) {
  const id = Number(rootId)
  const result = Object.create(null)
  if (!isFinite(id) || id <= 0) return result
  result[id] = true
  let grew = true
  let guard = 0
  while (grew && guard++ < MAX_PROJECT_DEPTH + 1) {
    grew = false
    for (let i = 0; i < (projects || []).length; i++) {
      const p = projects[i]
      if (!result[p.id] && p.parentId && result[p.parentId]) {
        result[p.id] = true
        grew = true
      }
    }
  }
  return result
}

// Restrict tasks to one project, optionally with its sub-projects.
export function scopeTasks(tasks, projects, projectId, includeSubprojects) {
  const id = Number(projectId)
  if (!isFinite(id) || id <= 0) return tasks
  const allowed = includeSubprojects ? descendantIds(projects, id) : { [id]: true }
  const out = []
  for (let i = 0; i < tasks.length; i++) {
    if (allowed[tasks[i].projectId]) out.push(tasks[i])
  }
  return out
}

// The selected project's breadcrumb, e.g. "Work › Website", for headers.
export function projectPath(projects, projectId) {
  const byId = Object.create(null)
  for (let i = 0; i < (projects || []).length; i++) byId[projects[i].id] = projects[i]
  const parts = []
  let current = byId[Number(projectId)]
  let guard = 0
  while (current && guard++ < MAX_PROJECT_DEPTH) {
    parts.unshift(current.title)
    current = current.parentId ? byId[current.parentId] : null
  }
  return parts.join(" › ")
}

// Every project in tree order with its depth, ignoring collapse state. Used
// by the settings page's project picker.
export function flatProjects(projects, options) {
  const out = []
  function walk(nodes) {
    for (let i = 0; i < nodes.length; i++) {
      const n = nodes[i]
      out.push({ id: n.project.id, title: n.project.title, depth: n.depth,
        color: n.project.color, archived: n.project.archived })
      walk(n.children)
    }
  }
  walk(buildProjectTree(projects, options))
  return out
}

function asSet(collapsed) {
  if (!collapsed) return Object.create(null)
  if (Array.isArray(collapsed)) {
    const set = Object.create(null)
    for (let i = 0; i < collapsed.length; i++) set[Number(collapsed[i])] = true
    return set
  }
  return collapsed
}

// Flatten the tree into display rows, honouring collapse state.
//
// `tasks` must already be filtered to open tasks (pending-done clones are
// fine). Each project row carries `count`: open tasks in it plus every
// sub-project, so a collapsed header still says how much is hidden inside.
// With `hideEmpty`, projects with no open tasks anywhere in their subtree are
// left out entirely.
export function buildTreeRows(projects, tasks, options) {
  const opts = options || {}
  const collapsed = asSet(opts.collapsed)
  const hideEmpty = opts.hideEmpty !== false
  const limit = Number(opts.limit) > 0 ? Math.floor(Number(opts.limit)) : MAX_TREE_ROWS
  const tree = buildProjectTree(projects, opts)

  const byProject = Object.create(null)
  for (let i = 0; i < tasks.length; i++) {
    const key = tasks[i].projectId
    if (!byProject[key]) byProject[key] = []
    byProject[key].push(tasks[i])
  }

  function countOf(node) {
    let total = (byProject[node.project.id] || []).length
    for (let i = 0; i < node.children.length; i++) total += countOf(node.children[i])
    node.count = total
    return total
  }
  for (let i = 0; i < tree.length; i++) countOf(tree[i])

  const rows = []
  let hidden = 0
  function push(row, weight) {
    if (rows.length < limit) rows.push(row)
    else hidden += weight
  }

  function walk(nodes) {
    for (let i = 0; i < nodes.length; i++) {
      const node = nodes[i]
      if (hideEmpty && node.count === 0) continue
      const own = byProject[node.project.id] || []
      const visibleKids = hideEmpty
        ? node.children.filter(c => c.count > 0)
        : node.children
      const isCollapsed = collapsed[node.project.id] === true
      push({
        kind: "project",
        key: "p" + node.project.id,
        id: node.project.id,
        title: node.project.title,
        color: node.project.color,
        depth: node.depth,
        count: node.count,
        expandable: own.length > 0 || visibleKids.length > 0,
        collapsed: isCollapsed
      }, 0)
      if (isCollapsed) continue
      for (let t = 0; t < own.length; t++) {
        push({ kind: "task", key: "t" + own[t].id, depth: node.depth + 1, task: own[t] }, 1)
      }
      walk(node.children)
    }
  }
  walk(tree)

  // Tasks whose project is not in the list (archived parent, no access):
  // gather them under a synthetic header so nothing silently disappears.
  // Tasks in an archived project stay hidden along with the project.
  const known = Object.create(null)
  for (let i = 0; i < (projects || []).length; i++) known[projects[i].id] = true
  const orphans = tasks.filter(t => !known[t.projectId])
  if (orphans.length > 0) {
    const isCollapsed = collapsed[0] === true
    push({ kind: "project", key: "p0", id: 0, title: "Other", color: "", depth: 0,
      count: orphans.length, expandable: true, collapsed: isCollapsed }, 0)
    if (!isCollapsed) {
      for (let t = 0; t < orphans.length; t++) {
        push({ kind: "task", key: "t" + orphans[t].id, depth: 1, task: orphans[t] }, 1)
      }
    }
  }

  return { rows, hidden }
}

// Every id that can be collapsed, so "collapse all" has something to write.
export function allProjectIds(projects) {
  const ids = [0]
  for (let i = 0; i < (projects || []).length; i++) ids.push(projects[i].id)
  return ids
}

// Where the header's "+" adds a todo when no project is in scope: the
// lowest-id unarchived project called "Inbox", else the first root project.
export function defaultProjectId(projects) {
  let best = 0
  for (let i = 0; i < (projects || []).length; i++) {
    const p = projects[i]
    if (p.archived || p.title.trim().toLowerCase() !== "inbox") continue
    if (best === 0 || p.id < best) best = p.id
  }
  if (best > 0) return best
  const tree = buildProjectTree(projects)
  return tree.length > 0 ? tree[0].project.id : 0
}

// ---- Collapse-state file. Stored per instance URL so two servers' project
// ids never collide: { "<instance>": [id, id, …] }.
export const MAX_COLLAPSED_IDS = 2000

export const MAX_COLLAPSE_FILE_CHARS = 256 * 1024

export function parseCollapsedState(text) {
  let parsed = null
  const raw = String(text || "")
  if (raw.length <= MAX_COLLAPSE_FILE_CHARS) {
    try { parsed = JSON.parse(raw) } catch (e) { parsed = null }
  }
  const out = Object.create(null)
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return out
  const keys = Object.keys(parsed).slice(0, 32)
  for (let i = 0; i < keys.length; i++) {
    const value = parsed[keys[i]]
    if (!Array.isArray(value)) continue
    const ids = []
    const seen = new Set()
    for (let j = 0; j < value.length && ids.length < MAX_COLLAPSED_IDS; j++) {
      const id = Math.floor(Number(value[j]))
      if (isFinite(id) && id >= 0 && !seen.has(id)) { seen.add(id); ids.push(id) }
    }
    out[keys[i].slice(0, 2048)] = ids
  }
  return out
}

export function collapsedFor(state, instance) {
  const ids = state && state[instance]
  return Array.isArray(ids) ? ids : []
}

// Return a new state with `id` toggled (or forced, when `value` is boolean)
// for `instance`.
export function setCollapsed(state, instance, id, value) {
  const next = Object.assign(Object.create(null), state || {})
  const ids = collapsedFor(next, instance).slice()
  const at = ids.indexOf(Number(id))
  const want = typeof value === "boolean" ? value : at < 0
  if (want && at < 0) ids.push(Number(id))
  if (!want && at >= 0) ids.splice(at, 1)
  next[instance] = ids
  return next
}

export function replaceCollapsed(state, instance, ids) {
  const next = Object.assign(Object.create(null), state || {})
  next[instance] = (ids || []).map(Number).filter(n => isFinite(n) && n >= 0).slice(0, MAX_COLLAPSED_IDS)
  return next
}

export function serializeCollapsedState(state) {
  const plain = {}
  const keys = Object.keys(state || {})
  for (let i = 0; i < keys.length; i++) plain[keys[i]] = state[keys[i]]
  return JSON.stringify(plain) + "\n"
}
