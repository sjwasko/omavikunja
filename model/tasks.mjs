import { parseDueDate } from "./dates.mjs"
import {
  MAX_DESCRIPTION_CHARS,
  MAX_PROJECTS,
  MAX_TASKS,
  MAX_TITLE_CHARS,
  assertOutputWithinLimit,
  clamped
} from "./limits.mjs"

function text(value) {
  return value === undefined || value === null ? "" : String(value)
}

function normalizePriority(value) {
  const number = Math.floor(Number(value))
  // Vikunja: 0 unset, 1 low, 2 medium, 3 high, 4 urgent, 5 do now.
  if (!isFinite(number) || number < 0 || number > 5) return 0
  return number
}

export function normalizedTask(raw, projectTitles) {
  if (!raw || typeof raw !== "object") return null

  const id = Number(raw.id)
  if (!Number.isSafeInteger(id) || id <= 0) return null

  const title = clamped(raw.title, MAX_TITLE_CHARS).trim() || "Untitled task"

  const projectId = Number(raw.project_id) || 0
  const projectTitle = projectTitles && projectTitles[String(projectId)]
    ? projectTitles[String(projectId)]
    : ""

  return {
    id,
    title,
    done: raw.done === true,
    dueMs: parseDueDate(raw.due_date),
    priority: normalizePriority(raw.priority),
    projectId,
    projectTitle,
    description: clamped(raw.description, MAX_DESCRIPTION_CHARS),
    isFavorite: raw.is_favorite === true,
    isRepeating: Number(raw.repeat_after) > 0 || Number(raw.repeat_mode) === 1
  }
}

// Due date ascending (undated last), then priority descending, then title.
// This is the only sort in the model; the selectors assume this order.
function compareTasks(a, b) {
  const aDue = a.dueMs === null ? Infinity : a.dueMs
  const bDue = b.dueMs === null ? Infinity : b.dueMs
  if (aDue !== bDue) return aDue - bDue
  if (a.priority !== b.priority) return b.priority - a.priority
  return a.title.localeCompare(b.title)
}

// The paginated fetch merges every page's items into one JSON array, so the
// model only ever sees a bare list. Invalid JSON is exceptional so the QML
// caller can retain last-good data.
export function parseTasks(json, projectTitles) {
  const input = text(json)
  assertOutputWithinLimit(input)
  const parsed = JSON.parse(input)
  if (!Array.isArray(parsed)) throw new Error("Vikunja output must be a JSON array")
  if (parsed.length > MAX_TASKS) {
    throw new Error("Vikunja output exceeds " + MAX_TASKS + " tasks")
  }

  const tasks = []
  for (let i = 0; i < parsed.length; i++) {
    const task = normalizedTask(parsed[i], projectTitles)
    if (task) tasks.push(task)
  }
  tasks.sort(compareTasks)
  return tasks
}

// Merge one task returned by the create endpoint into an already-sorted list.
// Returns a new sorted list; an unusable response leaves the list untouched.
export function insertTask(tasks, json, projectTitles) {
  let raw = null
  try { raw = JSON.parse(text(json)) } catch (e) { return tasks }
  const task = normalizedTask(raw, projectTitles)
  if (!task) return tasks
  const out = tasks.filter(t => t.id !== task.id)
  out.push(task)
  out.sort(compareTasks)
  return out
}

export function removeTask(tasks, id) {
  return tasks.filter(t => t.id !== Number(id))
}

export const MAX_NEW_TITLE_CHARS = 250

export function normalizeNewTitle(value) {
  return text(value).replace(/[\u0000-\u001F\u007F]+/g, " ").trim().slice(0, MAX_NEW_TITLE_CHARS)
}
