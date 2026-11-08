import { addLocalDays, startOfLocalDay } from "./dates.mjs"
import { normalizeShowNoDate } from "./settings.mjs"

export const GROUP_OVERDUE = "overdue"
export const GROUP_TODAY = "today"
export const GROUP_TOMORROW = "tomorrow"
export const GROUP_LATER = "later"
export const GROUP_NO_DATE = "no-date"

// The next todo is the most urgent open task. parseTasks already sorts
// overdue first, then soonest due, then highest priority, then title.
// `pendingDone` is an optional id -> true map of tasks optimistically marked
// done; they are skipped so the hero advances without waiting for a sync.
export function nextTodo(tasks, pendingDone) {
  for (let i = 0; i < tasks.length; i++) {
    if (tasks[i].done === true) continue
    if (pendingDone && pendingDone[tasks[i].id] === true) continue
    return tasks[i]
  }
  return null
}

export function openTasks(tasks, pendingDone) {
  const open = []
  for (let i = 0; i < tasks.length; i++) {
    const task = tasks[i]
    const pending = pendingDone && pendingDone[task.id] === true
    if (task.done === true && !pending) continue
    // A pending task is still open on the server, so clone it with the done
    // flag set so the panel can render it crossed while the PATCH is in flight.
    open.push(pending && task.done !== true ? Object.assign({}, task, { done: true }) : task)
  }
  return open
}

export function buildGroups(tasks, now, options) {
  const settings = options || {}
  const showNoDate = normalizeShowNoDate(settings.showNoDate)
  const pendingDone = settings.pendingDone || null

  const list = openTasks(tasks, pendingDone)
  const todayStart = startOfLocalDay(now)
  const tomorrowStart = addLocalDays(todayStart, 1)

  const buckets = {}
  for (let i = 0; i < list.length; i++) {
    const task = list[i]
    let key
    if (task.dueMs === null) {
      key = GROUP_NO_DATE
    } else {
      const dueDay = startOfLocalDay(new Date(task.dueMs))
      if (dueDay < todayStart) key = GROUP_OVERDUE
      else if (dueDay.getTime() === todayStart.getTime()) key = GROUP_TODAY
      else if (dueDay.getTime() === tomorrowStart.getTime()) key = GROUP_TOMORROW
      else key = GROUP_LATER
    }
    if (!buckets[key]) buckets[key] = []
    buckets[key].push(task)
  }

  const titles = {
    [GROUP_OVERDUE]: "OVERDUE",
    [GROUP_TODAY]: "TODAY",
    [GROUP_TOMORROW]: "TOMORROW",
    [GROUP_LATER]: "LATER",
    [GROUP_NO_DATE]: "NO DUE DATE"
  }
  const order = [GROUP_OVERDUE, GROUP_TODAY, GROUP_TOMORROW, GROUP_LATER, GROUP_NO_DATE]

  const groups = []
  for (let i = 0; i < order.length; i++) {
    const key = order[i]
    if (!buckets[key] || buckets[key].length === 0) continue
    if (key === GROUP_NO_DATE && !showNoDate) continue
    groups.push({ key: key, title: titles[key], items: buckets[key] })
  }
  return groups
}

// A list rather than a set of flags, so the panel's selected action is an
// index and an unavailable action is absent rather than present-but-invalid.
export function heroActions(task) {
  if (!task) return []
  return task.done ? ["open"] : ["open", "done"]
}

// Counts for the bar tooltip. Overdue and no-date counts only consider open
// tasks, so the summary reflects what still needs attention.
export function summaryCounts(tasks, now) {
  const todayStart = startOfLocalDay(now)
  let open = 0
  let overdue = 0
  let noDate = 0
  for (let i = 0; i < tasks.length; i++) {
    const task = tasks[i]
    if (task.done === true) continue
    open++
    if (task.dueMs === null) noDate++
    else if (startOfLocalDay(new Date(task.dueMs)) < todayStart) overdue++
  }
  return { open, overdue, noDate }
}

// Truncate the grouped list to `limit` items total so a huge server never
// instantiates thousands of rows. Returns the reduced groups plus the count
// of items that were hidden; the full task list is left untouched so the
// "next" hero and tooltip counts stay accurate.
export function truncateGroups(groups, limit) {
  const max = Number(limit)
  if (!isFinite(max) || max <= 0) return { groups, hidden: 0 }
  let remaining = Math.floor(max)
  let hidden = 0
  const out = []
  for (let i = 0; i < groups.length; i++) {
    const group = groups[i]
    const items = group.items || []
    if (remaining <= 0) {
      hidden += items.length
      continue
    }
    if (items.length <= remaining) {
      out.push(group)
      remaining -= items.length
    } else {
      out.push({ key: group.key, title: group.title, items: items.slice(0, remaining) })
      hidden += items.length - remaining
      remaining = 0
    }
  }
  return { groups: out, hidden }
}
