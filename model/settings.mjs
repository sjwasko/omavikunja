// shell.json is hand-editable, so the manifest's types and bounds constrain
// the settings UI but not the file. Everything is re-checked here.

export const INSTANCE = {
  key: "instance",
  defaultValue: ""
}

export const SHOW_NO_DATE = {
  key: "showNoDate",
  defaultValue: true
}

export const SHOW_TITLE = {
  key: "showTitle",
  defaultValue: true
}

export const SYNC_INTERVAL = {
  key: "syncInterval",
  defaultValue: 300,
  min: 30,
  max: 86400
}

// The instance URL is kept as a trimmed base URL without a trailing slash,
// so callers can append "/api/v2/..." directly. An empty string means the
// widget has not been configured yet.
//
// Only plain http(s) URLs are accepted: no username or password (they would
// show up in `ps` and in the state file), no query or fragment, nothing that
// could be read as a curl option. Anything else normalizes to "" so the
// widget treats it as unconfigured and never runs curl or xdg-open with it.
const INSTANCE_PATTERN = /^https?:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?(\/[A-Za-z0-9._~%!$&'()*+,;=:@-]*)*$/

export function isValidInstance(value) {
  return INSTANCE_PATTERN.test(String(value)) && String(value).length <= 2048
}

export function normalizeInstance(value) {
  if (value === undefined || value === null) return INSTANCE.defaultValue
  const text = String(value).trim().replace(/\/+$/, "")
  return isValidInstance(text) ? text : ""
}

// True for http:// on anything but this machine: the token would cross the
// network unencrypted.
export function isInsecureInstance(value) {
  const match = /^http:\/\/([^/:]+)/.exec(String(value))
  if (!match) return false
  const host = match[1].toLowerCase()
  return !(host === "localhost" || host.endsWith(".localhost") || /^127\.\d+\.\d+\.\d+$/.test(host))
}

// API tokens are single printable ASCII words. Anything with whitespace or
// control characters is refused, so it can never add an HTTP header line.
export function isValidToken(value) {
  return /^[\x21-\x7e]{1,4096}$/.test(String(value))
}

// notify-send bodies are rendered as markup by mako and most daemons.
export function escapeMarkup(text) {
  return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

function normalizeBoolean(value, spec) {
  if (value === undefined || value === null) return spec.defaultValue
  if (typeof value === "boolean") return value
  if (typeof value === "string") {
    const text = value.trim().toLowerCase()
    if (text === "true" || text === "1" || text === "yes" || text === "on") return true
    if (text === "false" || text === "0" || text === "no" || text === "off") return false
  }
  return spec.defaultValue
}

export function normalizeShowNoDate(value) {
  return normalizeBoolean(value, SHOW_NO_DATE)
}

export function normalizeShowTitle(value) {
  return normalizeBoolean(value, SHOW_TITLE)
}

// Seconds between automatic refreshes. shell.json is hand-editable so the
// value can arrive as a string or anything else; clamp to the declared bounds
// and fall back to the default on anything unparseable.
export function normalizeSyncInterval(value) {
  if (value === undefined || value === null) return SYNC_INTERVAL.defaultValue
  const n = parseInt(String(value).trim(), 10)
  if (!isFinite(n)) return SYNC_INTERVAL.defaultValue
  if (n < SYNC_INTERVAL.min) return SYNC_INTERVAL.min
  if (n > SYNC_INTERVAL.max) return SYNC_INTERVAL.max
  return n
}

export const VIEW_TREE = "tree"
export const VIEW_PROJECT = "project"
export const VIEW_DATES = "dates"

export const VIEW_MODE = {
  key: "viewMode",
  defaultValue: VIEW_TREE,
  values: [VIEW_TREE, VIEW_PROJECT, VIEW_DATES]
}

export const PROJECT_ID = { key: "projectId", defaultValue: 0 }
export const INCLUDE_SUBPROJECTS = { key: "includeSubprojects", defaultValue: true }
export const HIDE_EMPTY_PROJECTS = { key: "hideEmptyProjects", defaultValue: true }

export function normalizeViewMode(value) {
  const text = value === undefined || value === null ? "" : String(value).trim().toLowerCase()
  return VIEW_MODE.values.indexOf(text) >= 0 ? text : VIEW_MODE.defaultValue
}

export function normalizeProjectId(value) {
  if (value === undefined || value === null) return PROJECT_ID.defaultValue
  const n = parseInt(String(value).trim(), 10)
  return isFinite(n) && n > 0 ? n : PROJECT_ID.defaultValue
}

export function normalizeIncludeSubprojects(value) {
  return normalizeBoolean(value, INCLUDE_SUBPROJECTS)
}

export function normalizeHideEmptyProjects(value) {
  return normalizeBoolean(value, HIDE_EMPTY_PROJECTS)
}

export const ICON_STYLE = { key: "iconStyle", defaultValue: "mono", values: ["mono", "color"] }

export function normalizeIconStyle(value) {
  const text = value === undefined || value === null ? "" : String(value).trim().toLowerCase()
  return ICON_STYLE.values.indexOf(text) >= 0 ? text : ICON_STYLE.defaultValue
}
