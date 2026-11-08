export const MINUTE_MS = 60 * 1000
export const DAY_MS = 24 * 60 * 60 * 1000

// Vikunja stores "no due date" as the Go zero time 0001-01-01T00:00:00Z.
export const ZERO_DATE = "0001-01-01T00:00:00Z"

function pad2(value) {
  const number = Number(value)
  return (number < 10 ? "0" : "") + number
}

export function localDateKey(date) {
  return date.getFullYear() + "-" + pad2(date.getMonth() + 1) + "-" + pad2(date.getDate())
}

export function startOfLocalDay(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate())
}

export function addLocalDays(date, count) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate() + Number(count || 0))
}

// Parse a Vikunja RFC3339 date string to milliseconds since epoch, or null
// when the task has no due date. Go's zero time and anything else in year 1
// are treated as absent.
export function parseDueDate(value) {
  const text = value === undefined || value === null ? "" : String(value).trim()
  if (text === "" || text === ZERO_DATE) return null
  const ms = Date.parse(text)
  if (isNaN(ms)) return null
  if (new Date(ms).getUTCFullYear() < 100) return null
  return ms
}

// Signed whole-day distance from `now` to `dueMs`; negative means overdue.
// Rounding absorbs the 23/25-hour days that DST transitions introduce.
export function dayDistance(dueMs, now) {
  const due = startOfLocalDay(new Date(dueMs))
  const current = startOfLocalDay(now)
  return Math.round((due - current) / DAY_MS)
}
