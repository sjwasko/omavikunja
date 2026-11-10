// Limits for untrusted Vikunja data; string sizes use UTF-16 code units.
export const MAX_OUTPUT_CHARS = 4 * 1024 * 1024
export const MAX_TASKS = 5000
// Same as the fetch can return (MAX_PAGES x 50 per page).
export const MAX_PROJECTS = 5000
// The panel only renders the first N open tasks; the rest stay counted in the
// tooltip summary but are not instantiated as rows.
export const MAX_DISPLAY_TASKS = 20
export const MAX_TITLE_CHARS = 500
export const MAX_DESCRIPTION_CHARS = 8192
export const MAX_DATE_CHARS = 64
export const MAX_URL_CHARS = 2048
export const MAX_ENUM_CHARS = 32

function scalarText(value) {
  if (value === undefined || value === null) return ""
  if (typeof value === "string") return value
  if (typeof value === "number" || typeof value === "boolean") return String(value)
  return ""
}

export function clamped(value, limit) {
  const string = scalarText(value)
  return string.length > limit ? string.slice(0, limit) : string
}

// Reject overlong structured fields instead of truncating them.
export function limited(value, limit) {
  const string = scalarText(value)
  return string.length > limit ? "" : string
}

export function assertOutputWithinLimit(output) {
  if (output.length > MAX_OUTPUT_CHARS) {
    throw new Error("Vikunja output exceeds " + MAX_OUTPUT_CHARS + " characters")
  }
}
