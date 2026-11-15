// Release check for people who don't use a plugin manager.
//
// Once a day the widget fetches the plugin's manifest from GitHub (a few KB)
// and compares its version with the installed one. Only a version bump counts
// as an update, so ordinary commits never raise a notice. The link it shows
// is the marketplace page, which says whether that version is verified and
// how to install it. Nothing about the user's todos, instance or token is
// sent, and the fetched text is only ever reduced to a plain dotted version.

const PLUGIN_ID = "sjwasko.omavikunja"

export const UPDATE_MANIFEST_URL = "https://raw.githubusercontent.com/sjwasko/omavikunja/main/manifest.json"
export const UPDATE_PAGE_URL = "https://plugins.omarchy.org/plugin.html?id=" + PLUGIN_ID

// A manifest is a few KB; anything far bigger is not one.
const MAX_MANIFEST_CHARS = 65536
const VERSION_PATTERN = /^[0-9]{1,6}(\.[0-9]{1,6}){0,3}$/

// The version in a manifest's text, or "" when it can't be trusted to be one.
export function manifestVersion(text) {
  if (typeof text !== "string" || text.length === 0 || text.length > MAX_MANIFEST_CHARS) return ""
  let manifest
  try {
    manifest = JSON.parse(text)
  } catch (e) {
    return ""
  }
  if (!manifest || typeof manifest.version !== "string") return ""
  const version = manifest.version.trim()
  return VERSION_PATTERN.test(version) ? version : ""
}

// True only when both are plain dotted versions and `candidate` is higher.
// Missing parts count as 0, so 1.1 and 1.1.0 are the same release.
export function isNewerVersion(candidate, current) {
  if (!VERSION_PATTERN.test(String(candidate)) || !VERSION_PATTERN.test(String(current))) return false
  const a = String(candidate).split(".").map(Number)
  const b = String(current).split(".").map(Number)
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const x = a[i] || 0
    const y = b[i] || 0
    if (x !== y) return x > y
  }
  return false
}

// A plain argv (no shell): curl ignores ~/.curlrc (-q must come first),
// speaks https only, fails on HTTP errors and gives up after 20 seconds.
export function updateCheckCommand() {
  return ["curl", "-q", "-fsS", "--proto", "=https", "--proto-redir", "=https",
    "--max-time", "20", "--max-filesize", String(MAX_MANIFEST_CHARS), "--url", UPDATE_MANIFEST_URL]
}
