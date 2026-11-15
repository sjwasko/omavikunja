import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import test from "node:test"

import * as Model from "../Model.mjs"

const manifestText = readFileSync(new URL("../manifest.json", import.meta.url), "utf8")
const MANIFEST = JSON.parse(manifestText)

test("the installed version is read from the plugin's own manifest", () => {
  assert.equal(Model.manifestVersion(manifestText), MANIFEST.version)
})

test("a manifest that is not JSON, has no version or an odd one yields no version", () => {
  assert.equal(Model.manifestVersion(""), "")
  assert.equal(Model.manifestVersion("<html>rate limited</html>"), "")
  assert.equal(Model.manifestVersion('{"name":"x"}'), "")
  assert.equal(Model.manifestVersion('{"version":"1.2.0-beta"}'), "")
  assert.equal(Model.manifestVersion('{"version":"<b>9.9.9</b>"}'), "")
  assert.equal(Model.manifestVersion('{"version":1.2}'), "")
  assert.equal(Model.manifestVersion(null), "")
  assert.equal(Model.manifestVersion(undefined), "")
})

test("whitespace around a version is ignored", () => {
  assert.equal(Model.manifestVersion('{"version":" 1.2.3 "}'), "1.2.3")
})

test("an oversized manifest is refused without being parsed", () => {
  const big = '{"version":"9.9.9","pad":"' + "x".repeat(70000) + '"}'
  assert.equal(Model.manifestVersion(big), "")
})

test("newer versions compare numerically, part by part", () => {
  assert.equal(Model.isNewerVersion("1.1.2", "1.1.1"), true)
  assert.equal(Model.isNewerVersion("1.10.0", "1.9.9"), true)
  assert.equal(Model.isNewerVersion("2.0", "1.9.9"), true)
  assert.equal(Model.isNewerVersion("1.1.1.1", "1.1.1"), true)
})

test("the same or an older version is not an update", () => {
  assert.equal(Model.isNewerVersion("1.1.1", "1.1.1"), false)
  assert.equal(Model.isNewerVersion("1.1.0", "1.1.1"), false)
  assert.equal(Model.isNewerVersion("1.1", "1.1.0"), false)
  assert.equal(Model.isNewerVersion("1.9.9", "1.10.0"), false)
})

test("an unknown version on either side is never reported as an update", () => {
  assert.equal(Model.isNewerVersion("", "1.1.1"), false)
  assert.equal(Model.isNewerVersion("1.1.2", ""), false)
  assert.equal(Model.isNewerVersion("garbage", "1.1.1"), false)
})

test("the update check fetches only the fixed GitHub manifest over https", () => {
  const argv = Model.updateCheckCommand()
  assert.equal(argv[0], "curl")
  assert.ok(argv.includes("-q") && argv.indexOf("-q") === 1, "ignores ~/.curlrc")
  assert.equal(argv[argv.indexOf("--proto") + 1], "=https")
  assert.equal(argv[argv.indexOf("--proto-redir") + 1], "=https")
  assert.equal(argv[argv.indexOf("--url") + 1], Model.UPDATE_MANIFEST_URL)
  assert.equal(Model.UPDATE_MANIFEST_URL, "https://raw.githubusercontent.com/sjwasko/omavikunja/main/manifest.json")
  assert.ok(!argv.some(a => /VIKUNJA|Authorization|Bearer/.test(a)), "carries no Vikunja credentials")
})

test("the update link is the plugin's marketplace page", () => {
  assert.equal(Model.UPDATE_PAGE_URL, "https://plugins.omarchy.org/plugin.html?id=" + MANIFEST.id)
})

test("the update check is on unless turned off, and has a deadline", () => {
  assert.equal(Model.normalizeCheckForUpdates(undefined), true)
  assert.equal(Model.normalizeCheckForUpdates(false), false)
  assert.equal(Model.normalizeCheckForUpdates("off"), false)
  assert.equal(Model.CHECK_FOR_UPDATES.key, "checkForUpdates")
  assert.ok(Model.DEADLINES.update > 0)
})

test("the manifest declares the update setting with its default", () => {
  assert.equal(MANIFEST.barWidget.defaults.checkForUpdates, true)
  const entry = MANIFEST.barWidget.schema.find(s => s.key === "checkForUpdates")
  assert.ok(entry, "schema entry")
  assert.equal(entry.type, "boolean")
  assert.equal(entry.defaultValue, true)
})
