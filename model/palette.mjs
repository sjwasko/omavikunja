// Readable dropdown colors for whatever theme and bar style is active.
//
// The dropdown is drawn on the theme's popup surface, so every color it uses
// is checked against that surface (WCAG 2.x contrast). A color that already
// reads well is returned unchanged; one that doesn't is moved toward black or
// white, which keeps its hue, until it meets its floor.

const DEFAULT_SURFACE = "#101315"
const DEFAULT_TEXT = "#cacccc"
const DEFAULT_URGENT = "#e05c5c"
const DEFAULT_OK = "#6fc276"

const TEXT_MIN = 4.5
const SECONDARY_MIN = 4.5
const TERTIARY_MIN = 3.0
const DECOR_MIN = 1.8
const STATUS_MIN = 3.0

// How far each muted tier blends from the text toward the surface.
const SECONDARY_BLEND = 0.3
const TERTIARY_BLEND = 0.45
const DECOR_BLEND = 0.65

const PRIORITY_COLORS = ["", DEFAULT_OK, "#d2b14f", "#e08f3c", DEFAULT_URGENT, "#ff4d6d"]

// Accepts "#rrggbb", "#aarrggbb" (QML's color string) or a QML color object.
function parseHex(value) {
  if (value === undefined || value === null) return null
  const match = /^#([0-9a-f]{6}|[0-9a-f]{8})$/i.exec(String(value).trim())
  if (!match) return null
  return "#" + match[1].slice(-6).toLowerCase()
}

function channels(hex) {
  const n = parseInt(hex.slice(1), 16)
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255]
}

function toHex(rgb) {
  return "#" + rgb.map(v => Math.round(Math.min(255, Math.max(0, v))).toString(16).padStart(2, "0")).join("")
}

function luminance(hex) {
  const [r, g, b] = channels(hex).map(v => {
    const c = v / 255
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
  })
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

function contrast(a, b) {
  const la = luminance(a)
  const lb = luminance(b)
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}

function mix(from, to, t) {
  const a = channels(from)
  const b = channels(to)
  return toHex(a.map((v, i) => v + (b[i] - v) * t))
}

// Smallest move toward black or white that reaches `min` against `surface`.
function ensureContrast(color, surface, min) {
  if (contrast(color, surface) >= min) return color
  const extreme = contrast("#000000", surface) > contrast("#ffffff", surface) ? "#000000" : "#ffffff"
  let lo = 0
  let hi = 1
  for (let i = 0; i < 24; i++) {
    const mid = (lo + hi) / 2
    if (contrast(mix(color, extreme, mid), surface) >= min) hi = mid
    else lo = mid
  }
  return mix(color, extreme, hi)
}

function muted(text, surface, blend, min) {
  return ensureContrast(mix(text, surface, blend), surface, min)
}

export function contentPalette(theme = {}) {
  const surface = parseHex(theme.surface) || DEFAULT_SURFACE
  const preferred = parseHex(theme.text) || DEFAULT_TEXT
  const fallback = parseHex(theme.foreground)

  let text = preferred
  if (contrast(preferred, surface) < TEXT_MIN) {
    text = fallback && contrast(fallback, surface) >= TEXT_MIN
      ? fallback
      : ensureContrast(preferred, surface, TEXT_MIN)
  }

  const status = (value, fallbackColor) => ensureContrast(parseHex(value) || fallbackColor, surface, STATUS_MIN)
  const priorities = PRIORITY_COLORS.map(c => c ? ensureContrast(c, surface, STATUS_MIN) : "transparent")

  return {
    surface,
    text,
    secondary: muted(text, surface, SECONDARY_BLEND, SECONDARY_MIN),
    tertiary: muted(text, surface, TERTIARY_BLEND, TERTIARY_MIN),
    decor: muted(text, surface, DECOR_BLEND, DECOR_MIN),
    accent: status(theme.accent, text),
    urgent: status(theme.urgent, DEFAULT_URGENT),
    ok: status(theme.ok, DEFAULT_OK),
    priority(level) {
      return priorities[level] || "transparent"
    }
  }
}
