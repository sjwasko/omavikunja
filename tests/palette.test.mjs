import assert from "node:assert/strict"
import test from "node:test"

import * as Model from "../Model.mjs"

// Independent WCAG 2.x contrast so the tests do not trust the module's math.
function channel(v) {
  const c = v / 255
  return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
}
function luminance(hex) {
  const n = parseInt(hex.slice(1, 7), 16)
  return 0.2126 * channel((n >> 16) & 255) + 0.7152 * channel((n >> 8) & 255) + 0.0722 * channel(n & 255)
}
function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x)
  return (hi + 0.05) / (lo + 0.05)
}
function hue(hex) {
  const n = parseInt(hex.slice(1, 7), 16)
  const [r, g, b] = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map(v => v / 255)
  const max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min
  if (d === 0) return 0
  let h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4
  return ((h * 60) + 360) % 360
}

const URGENT = "#e05c5c"
const OK = "#6fc276"

// Popup surface/text pairs from installed themes, light and dark.
const THEMES = {
  "terminal-outpost-labs": { surface: "#101719", text: "#d6dedb", foreground: "#d6dedb", accent: "#5fc9c7" },
  everforest: { surface: "#2d353b", text: "#d3c6aa", foreground: "#d3c6aa", accent: "#a7c080" },
  "rose-pine": { surface: "#faf4ed", text: "#575279", foreground: "#575279", accent: "#56949f" },
  "catppuccin-latte": { surface: "#eff1f5", text: "#4c4f69", foreground: "#4c4f69", accent: "#1e66f5" },
  white: { surface: "#ffffff", text: "#000000", foreground: "#000000", accent: "#6e6e6e" }
}

function palette(theme) {
  return Model.contentPalette({ ...theme, urgent: URGENT, ok: OK })
}

test("text the same color as the popup surface is made readable (sw-x1 clear-bar bug)", () => {
  const p = Model.contentPalette({ surface: "#101719", text: "#101719", foreground: "#101719", accent: "#5fc9c7", urgent: URGENT, ok: OK })
  assert.ok(contrast(p.text, "#101719") >= 4.5, `text ${p.text} on #101719`)
})

test("an unreadable popup text falls back to a readable global foreground", () => {
  const p = Model.contentPalette({ surface: "#101719", text: "#101719", foreground: "#d6dedb", accent: "#5fc9c7", urgent: URGENT, ok: OK })
  assert.equal(p.text, "#d6dedb")
})

test("a theme's readable text and accent are returned unchanged", () => {
  for (const [name, theme] of Object.entries(THEMES)) {
    const p = palette(theme)
    assert.equal(p.text, theme.text, name)
    assert.equal(p.surface, theme.surface, name)
    if (contrast(theme.accent, theme.surface) >= 3) assert.equal(p.accent, theme.accent, name)
  }
})

test("muted text tiers meet their contrast floors on light and dark themes", () => {
  for (const [name, theme] of Object.entries(THEMES)) {
    const p = palette(theme)
    assert.ok(contrast(p.secondary, p.surface) >= 4.5, `${name} secondary ${p.secondary}`)
    assert.ok(contrast(p.tertiary, p.surface) >= 3.0, `${name} tertiary ${p.tertiary}`)
    assert.ok(contrast(p.decor, p.surface) >= 1.8, `${name} decor ${p.decor}`)
  }
})

test("muted tiers are quieter than the main text, not louder", () => {
  for (const [name, theme] of Object.entries(THEMES)) {
    const p = palette(theme)
    const main = contrast(p.text, p.surface)
    assert.ok(contrast(p.secondary, p.surface) < main, `${name} secondary`)
    assert.ok(contrast(p.tertiary, p.surface) <= contrast(p.secondary, p.surface), `${name} tertiary`)
    assert.ok(contrast(p.decor, p.surface) <= contrast(p.tertiary, p.surface), `${name} decor`)
  }
})

test("status colors are nudged to stay legible on a white popup", () => {
  const p = palette(THEMES.white)
  assert.ok(contrast(p.urgent, "#ffffff") >= 3, `urgent ${p.urgent}`)
  assert.ok(contrast(p.ok, "#ffffff") >= 3, `ok ${p.ok}`)
  assert.ok(contrast(p.accent, "#ffffff") >= 3, `accent ${p.accent}`)
})

test("status colors already legible on a dark popup are unchanged", () => {
  const p = palette(THEMES["terminal-outpost-labs"])
  assert.equal(p.urgent, URGENT)
  assert.equal(p.ok, OK)
})

test("priority colors keep their hue and stay legible; no priority is transparent", () => {
  for (const [name, theme] of Object.entries(THEMES)) {
    const p = palette(theme)
    assert.equal(p.priority(0), "transparent", name)
    assert.equal(p.priority(undefined), "transparent", name)
    for (let level = 1; level <= 5; level++) {
      const c = p.priority(level)
      assert.match(c, /^#[0-9a-f]{6}$/, `${name} p${level}`)
      assert.ok(contrast(c, p.surface) >= 3, `${name} p${level} ${c}`)
    }
  }
  const dark = palette(THEMES.white)
  assert.ok(Math.abs(hue(dark.priority(1)) - hue(OK)) < 12, "priority 1 stays green")
  assert.ok(Math.abs(hue(dark.priority(4)) - hue(URGENT)) < 12, "priority 4 stays red")
})

test("missing or malformed theme colors fall back to defaults without throwing", () => {
  const p = Model.contentPalette({ surface: undefined, text: "nope", foreground: null, accent: undefined })
  assert.equal(p.surface, "#101315")
  assert.equal(p.text, "#cacccc")
  assert.ok(contrast(p.secondary, p.surface) >= 4.5)
  assert.match(p.urgent, /^#[0-9a-f]{6}$/)
  assert.doesNotThrow(() => Model.contentPalette())
})

test("QML color objects and #aarrggbb strings are accepted", () => {
  // QML hands JS a color whose toString() is "#rrggbb" or "#aarrggbb".
  const qmlColor = { toString: () => "#ff101719" }
  const p = Model.contentPalette({ surface: qmlColor, text: { toString: () => "#d6dedb" }, urgent: URGENT, ok: OK })
  assert.equal(p.surface, "#101719")
  assert.equal(p.text, "#d6dedb")
})
