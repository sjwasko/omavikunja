import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import * as Model from "../Model.mjs"

const NOW = new Date("2026-08-19T10:00:00+01:00")

function task(title, extra = {}) {
  return {
    id: 1,
    title: title,
    done: false,
    due_date: null,
    priority: 0,
    project_id: 1,
    ...extra
  }
}

test("parseTasks parses a merged array of task items", () => {
  const parsed = Model.parseTasks(JSON.stringify([
    task("Later", { id: 2, due_date: "2026-08-21T09:00:00Z" }),
    task("Soon", { id: 3, due_date: "2026-08-19T12:00:00Z" })
  ]))

  assert.deepEqual(parsed.map(t => t.title), ["Soon", "Later"])
  assert.equal(parsed[0].id, 3)
  assert.equal(parsed[0].dueMs, Date.parse("2026-08-19T12:00:00Z"))
})

test("parseTasks rejects non-array output", () => {
  assert.throws(() => Model.parseTasks('{"items":[]}'), /JSON array/)
  assert.throws(() => Model.parseTasks("{"), SyntaxError)
})

test("Go zero time is treated as no due date", () => {
  const parsed = Model.parseTasks(JSON.stringify([
    task("No date", { due_date: "0001-01-01T00:00:00Z" })
  ]))
  assert.equal(parsed[0].dueMs, null)
})

test("missing and invalid due dates fall back to null", () => {
  const parsed = Model.parseTasks(JSON.stringify([
    task("No due"),
    task("Bad due", { due_date: "not-a-date" })
  ]))
  assert.equal(parsed[0].dueMs, null)
  assert.equal(parsed[1].dueMs, null)
})

test("priority is normalized and clamped", () => {
  const parsed = Model.parseTasks(JSON.stringify([
    task("Urgent", { priority: 4 }),
    task("High", { priority: 3 }),
    task("Medium", { priority: "2" }),
    task("Low", { priority: 1 }),
    task("Unset", { priority: 0 }),
    task("Junk", { priority: 99 }),
    task("Negative", { priority: -5 })
  ]))

  assert.deepEqual(parsed.map(t => t.priority), [4, 3, 2, 1, 0, 0, 0])
})

test("tasks sort by due date, then priority, then title", () => {
  const parsed = Model.parseTasks(JSON.stringify([
    task("No date", { id: 7 }),
    task("Later", { id: 2, due_date: "2026-08-25T09:00:00Z" }),
    task("High later", { id: 3, due_date: "2026-08-25T09:00:00Z", priority: 3 }),
    task("Overdue", { id: 4, due_date: "2026-08-10T09:00:00Z" }),
    task("Today", { id: 5, due_date: "2026-08-19T11:00:00Z" })
  ]))

  assert.deepEqual(parsed.map(t => t.title), ["Overdue", "Today", "High later", "Later", "No date"])
})

test("titles fall back to Untitled task", () => {
  const parsed = Model.parseTasks(JSON.stringify([task("   ")]))
  assert.equal(parsed[0].title, "Untitled task")
})

test("isRepeating is set from repeat_after or monthly repeat_mode", () => {
  const repeatAfter = Model.parseTasks(JSON.stringify([task("a", { repeat_after: 86400 })]))[0]
  const monthly = Model.parseTasks(JSON.stringify([task("b", { repeat_mode: 1 })]))[0]
  const none = Model.parseTasks(JSON.stringify([task("c", { repeat_after: null, repeat_mode: 0 })]))[0]
  const junk = Model.parseTasks(JSON.stringify([task("d", { repeat_after: "nope" })]))[0]

  assert.equal(repeatAfter.isRepeating, true)
  assert.equal(monthly.isRepeating, true)
  assert.equal(none.isRepeating, false)
  assert.equal(junk.isRepeating, false)
})

test("nextTodo returns the most urgent open task and skips done ones", () => {
  const parsed = Model.parseTasks(JSON.stringify([
    task("Overdue", { id: 4, due_date: "2026-08-10T09:00:00Z" }),
    task("Done overdue", { id: 6, due_date: "2026-08-05T09:00:00Z", done: true }),
    task("No date", { id: 7 })
  ]))

  assert.equal(Model.nextTodo(parsed).title, "Overdue")
  assert.equal(Model.nextTodo(Model.parseTasks(JSON.stringify([task("Done", { done: true })]))), null)
})

test("buildGroups groups by Overdue/Today/Tomorrow/Later/No date", () => {
  const parsed = Model.parseTasks(JSON.stringify([
    task("Overdue", { due_date: "2026-08-10T09:00:00Z" }),
    task("Today", { due_date: "2026-08-19T11:00:00Z" }),
    task("Tomorrow", { due_date: "2026-08-20T11:00:00Z" }),
    task("Later", { due_date: "2026-08-25T09:00:00Z" }),
    task("No date")
  ]))

  const groups = Model.buildGroups(parsed, NOW)
  assert.deepEqual(groups.map(g => g.key), ["overdue", "today", "tomorrow", "later", "no-date"])
  assert.deepEqual(groups.map(g => g.items.map(t => t.title)), [
    ["Overdue"], ["Today"], ["Tomorrow"], ["Later"], ["No date"]
  ])
})

test("buildGroups hides no-date tasks when showNoDate is false", () => {
  const parsed = Model.parseTasks(JSON.stringify([
    task("No date"),
    task("Today", { due_date: "2026-08-19T11:00:00Z" })
  ]))

  assert.deepEqual(Model.buildGroups(parsed, NOW, { showNoDate: false }).map(g => g.key), ["today"])
})

test("buildGroups hides done tasks", () => {
  const parsed = Model.parseTasks(JSON.stringify([
    task("Open", { due_date: "2026-08-19T11:00:00Z" }),
    task("Done", { due_date: "2026-08-19T12:00:00Z", done: true })
  ]))

  assert.deepEqual(Model.buildGroups(parsed, NOW).map(g => g.items.length), [1])
})

test("buildGroups keeps optimistically-done tasks as crossed entries", () => {
  const parsed = Model.parseTasks(JSON.stringify([
    task("Overdue", { id: 1, due_date: "2026-08-10T09:00:00Z" }),
    task("Today", { id: 2, due_date: "2026-08-19T11:00:00Z" })
  ]))

  const groups = Model.buildGroups(parsed, NOW, { pendingDone: { 1: true } })
  assert.deepEqual(groups.map(g => g.key), ["overdue", "today"])
  assert.equal(groups[0].items.length, 1)
  assert.equal(groups[0].items[0].title, "Overdue")
  assert.equal(groups[0].items[0].done, true)
})

test("nextTodo skips optimistically-done tasks", () => {
  const parsed = Model.parseTasks(JSON.stringify([
    task("Overdue", { id: 1, due_date: "2026-08-10T09:00:00Z" }),
    task("Today", { id: 2, due_date: "2026-08-19T11:00:00Z" })
  ]))

  assert.equal(Model.nextTodo(parsed, { 1: true }).title, "Today")
  assert.equal(Model.nextTodo(parsed, { 1: true, 2: true }), null)
})

test("relativeDue labels overdue, today, tomorrow, and future days", () => {
  const overdue = Model.parseTasks(JSON.stringify([task("a", { due_date: "2026-08-16T09:00:00Z" })]))[0]
  const today = Model.parseTasks(JSON.stringify([task("b", { due_date: "2026-08-19T23:00:00+01:00" })]))[0]
  const tomorrow = Model.parseTasks(JSON.stringify([task("c", { due_date: "2026-08-20T09:00:00Z" })]))[0]
  const future = Model.parseTasks(JSON.stringify([task("d", { due_date: "2026-08-25T09:00:00Z" })]))[0]

  assert.equal(Model.relativeDue(overdue, NOW), "3d ago")
  assert.equal(Model.relativeDue(today, NOW), "today")
  assert.equal(Model.relativeDue(tomorrow, NOW), "tmrw")
  assert.equal(Model.relativeDue(future, NOW), "in 6d")
  assert.equal(Model.relativeDue(task("e"), NOW), "")
})

test("formatLabel appends the relative due time and caps long titles", () => {
  const parsed = Model.parseTasks(JSON.stringify([task("Standup", { due_date: "2026-08-19T11:00:00Z" })]))[0]
  assert.equal(Model.formatLabel(parsed, NOW), "Standup · today")

  const long = Model.parseTasks(JSON.stringify([task("A very long todo title indeed", { due_date: "2026-08-19T11:00:00Z" })]))[0]
  assert.ok(Model.formatLabel(long, NOW).endsWith("· today"))
})

test("labelIsTruncated matches whether formatLabel ellipsizes the title", () => {
  const short = Model.parseTasks(JSON.stringify([task("Standup", { due_date: "2026-08-19T11:00:00Z" })]))[0]
  const long = Model.parseTasks(JSON.stringify([task("A very long todo title indeed", { due_date: "2026-08-19T11:00:00Z" })]))[0]

  assert.equal(Model.labelIsTruncated(short, NOW), false)
  assert.equal(Model.labelIsTruncated(long, NOW), true)
  assert.equal(Model.formatLabel(long, NOW).includes("…"), true)
  assert.equal(Model.labelIsTruncated(null, NOW), false)
})

test("heroActions offer done only for open tasks", () => {
  const open = Model.parseTasks(JSON.stringify([task("open")]))[0]
  const done = Model.parseTasks(JSON.stringify([task("done", { done: true })]))[0]

  assert.deepEqual(Model.heroActions(open), ["open", "done"])
  assert.deepEqual(Model.heroActions(done), ["open"])
  assert.deepEqual(Model.heroActions(null), [])
})

test("instance normalization strips trailing slashes", () => {
  assert.equal(Model.normalizeInstance("https://vikunja.example.com///"), "https://vikunja.example.com")
  assert.equal(Model.normalizeInstance("  https://vikunja.example.com  "), "https://vikunja.example.com")
  assert.equal(Model.normalizeInstance(null), "")
})

test("boolean settings normalize strings and fall back to defaults", () => {
  assert.equal(Model.normalizeShowNoDate(undefined), true)
  assert.equal(Model.normalizeShowNoDate("off"), false)

  assert.equal(Model.normalizeShowTitle(undefined), true)
  assert.equal(Model.normalizeShowTitle(false), false)
  assert.equal(Model.normalizeShowTitle("true"), true)
  assert.equal(Model.normalizeShowTitle("nonsense"), true)
})

test("sync interval clamps to bounds and falls back to the default", () => {
  assert.equal(Model.normalizeSyncInterval(undefined), 300)
  assert.equal(Model.normalizeSyncInterval(null), 300)
  assert.equal(Model.normalizeSyncInterval(300), 300)
  assert.equal(Model.normalizeSyncInterval("600"), 600)
  assert.equal(Model.normalizeSyncInterval("15"), 30)
  assert.equal(Model.normalizeSyncInterval("999999"), 86400)
  assert.equal(Model.normalizeSyncInterval("nonsense"), 300)
})

test("projectTitleMap maps project ids to titles", () => {
  const map = Model.projectTitleMap(Model.parseProjectList(JSON.stringify([
    { id: 1, title: "Inbox" },
    { id: 2, title: "  Work  " },
    { id: -3, title: "Saved filter" },
    null
  ])))

  assert.equal(map["1"], "Inbox")
  assert.equal(map["2"], "Work")
  assert.equal(map["-3"], undefined)
})

test("saved filters do not count toward the project cap", () => {
  const filters = Array.from({ length: Model.MAX_PROJECTS }, (_, i) => ({ id: -(i + 1), title: "f" }))
  const list = Model.parseProjectList(JSON.stringify(filters.concat([{ id: 1, title: "Inbox" }])))
  assert.equal(list.length, 1)
})

test("priority 5 (do now) is kept and named", () => {
  assert.equal(Model.normalizedTask({ id: 1, title: "x", priority: 5 }, {}).priority, 5)
  assert.equal(Model.priorityName(5), "Do now")
  assert.notEqual(Model.priorityGlyph(5), "")
  assert.equal(Model.normalizedTask({ id: 1, title: "x", priority: 6 }, {}).priority, 0)
})

test("parseTasks attaches the project title as a subtitle", () => {
  const projectTitles = Model.projectTitleMap(Model.parseProjectList(JSON.stringify([{ id: 1, title: "Inbox" }])))
  const parsed = Model.parseTasks(JSON.stringify([
    task("In Inbox", { id: 5, project_id: 1 }),
    task("Orphan", { id: 6, project_id: 999 })
  ]), projectTitles)

  assert.equal(parsed[0].projectTitle, "Inbox")
  assert.equal(parsed[1].projectTitle, "")
})

test("the settings declarations stay in step with the manifest schema", () => {
  const manifest = JSON.parse(readFileSync(new URL("../manifest.json", import.meta.url), "utf8"))
  const schema = manifest.barWidget.schema
  const defaults = manifest.barWidget.defaults

  for (const spec of [Model.INSTANCE, Model.SHOW_NO_DATE, Model.SHOW_TITLE, Model.SYNC_INTERVAL,
    Model.VIEW_MODE, Model.PROJECT_ID, Model.INCLUDE_SUBPROJECTS, Model.HIDE_EMPTY_PROJECTS, Model.ICON_STYLE]) {
    const entry = schema.find(item => item.key === spec.key)
    assert.ok(entry, `manifest.json is missing a schema entry for ${spec.key}`)
    assert.equal(entry.defaultValue, spec.defaultValue)
    assert.equal(defaults[spec.key], spec.defaultValue)
  }
})

test("oversized Vikunja output is rejected before parsing", () => {
  const oversized = "x".repeat(Model.MAX_OUTPUT_CHARS + 1)
  assert.throws(() => Model.parseTasks(oversized), /exceeds/)
})

test("fetch commands hard-cap each response and the aggregate before merging", () => {
  const script = Model.tasksCommand("https://example.test")[2]
  assert.match(script, new RegExp("--max-filesize " + (Model.MAX_PAGE_BYTES + 1)))
  assert.match(script, new RegExp("head -c " + (Model.MAX_PAGE_BYTES + 4)))
  assert.match(script, new RegExp("-gt " + (Model.MAX_PAGE_BYTES + 3)))
  assert.match(script, /total_bytes/)
  assert.match(script, new RegExp("-gt " + Model.MAX_TOTAL_BYTES))
})

test("an oversized response is rejected without buffering it in the shell", () => {
  const dir = mkdtempSync(join(tmpdir(), "vikunja-curl-"))
  const stub = join(dir, "curl")
  // A curl that ignores every flag and streams a body far past the page cap.
  // The in-shell read cap must still bound what the command substitution can
  // hold and turn the overrun into a clear failure.
  writeFileSync(stub, "#!/bin/sh\nhead -c 5000000 /dev/zero | tr '\\0' x\nprintf '200'\n")
  chmodSync(stub, 0o755)

  const argv = Model.tasksCommand("https://example.test")
  const result = spawnSync(argv[0], argv.slice(1), {
    env: { ...process.env, PATH: dir + ":" + process.env.PATH, VIKUNJA_TOKEN: "test-token" },
    encoding: "utf8",
    timeout: 20000,
    maxBuffer: 16 * 1024 * 1024
  })

  rmSync(dir, { recursive: true, force: true })

  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /exceeds/)
  assert.ok(result.stdout.length <= Model.MAX_STDOUT_BYTES)
})

test("tasks past the cardinality cap are rejected", () => {
  const raw = []
  for (let i = 0; i < Model.MAX_TASKS + 1; i++) raw.push(task(`Task ${i}`, { id: i + 1 }))
  assert.throws(() => Model.parseTasks(JSON.stringify(raw)), new RegExp("exceeds " + Model.MAX_TASKS + " tasks"))
})

test("plainLine neutralizes rich-text triggers", () => {
  assert.equal(Model.plainLine("<b>Hi</b>\nline2"), "‹b>Hi‹/b> line2")
  assert.equal(Model.plainLine(null), "")
})

test("summaryCounts counts open, overdue, and no-date tasks", () => {
  const parsed = Model.parseTasks(JSON.stringify([
    task("Overdue", { id: 1, due_date: "2026-08-10T09:00:00Z" }),
    task("Today", { id: 2, due_date: "2026-08-19T11:00:00Z" }),
    task("No date", { id: 3 }),
    task("Done overdue", { id: 4, due_date: "2026-08-05T09:00:00Z", done: true }),
    task("Done no date", { id: 5, done: true })
  ]))

  assert.deepEqual(Model.summaryCounts(parsed, NOW), { open: 3, overdue: 1, noDate: 1 })
  assert.deepEqual(Model.summaryCounts([], NOW), { open: 0, overdue: 0, noDate: 0 })
})

test("truncateGroups caps the total across groups and reports hidden", () => {
  const parsed = Model.parseTasks(JSON.stringify([
    task("A", { id: 1, due_date: "2026-08-10T09:00:00Z" }),
    task("B", { id: 2, due_date: "2026-08-11T09:00:00Z" }),
    task("C", { id: 3, due_date: "2026-08-19T11:00:00Z" }),
    task("D", { id: 4 }),
    task("E", { id: 5 })
  ]))
  const groups = Model.buildGroups(parsed, NOW)
  const limited = Model.truncateGroups(groups, 3)

  assert.equal(limited.hidden, 2)
  assert.equal(limited.groups.reduce((n, g) => n + g.items.length, 0), 3)
  assert.deepEqual(limited.groups.map(g => g.items.map(t => t.title)).flat(),
    ["A", "B", "C"])
})

test("truncateGroups without a limit keeps everything", () => {
  const parsed = Model.parseTasks(JSON.stringify([
    task("A", { id: 1, due_date: "2026-08-10T09:00:00Z" }),
    task("B", { id: 2 })
  ]))
  const groups = Model.buildGroups(parsed, NOW)
  const limited = Model.truncateGroups(groups, Model.MAX_DISPLAY_TASKS)

  assert.equal(limited.hidden, 0)
  assert.deepEqual(limited.groups, groups)
})
