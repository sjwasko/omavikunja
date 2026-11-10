import assert from "node:assert/strict"
import test from "node:test"

import * as Model from "../Model.mjs"

const PROJECTS = JSON.stringify([
  { id: 1, title: "Inbox", parent_project_id: 0, position: 1 },
  { id: 2, title: "Work", parent_project_id: 0, position: 2, hex_color: "1973ff" },
  { id: 3, title: "Website", parent_project_id: 2, position: 1 },
  { id: 4, title: "Copy", parent_project_id: 3, position: 1 },
  { id: 5, title: "Old", parent_project_id: 0, is_archived: true },
  { id: 6, title: "Empty", parent_project_id: 2, position: 2 },
  { id: -2, title: "Saved filter" }
])

function t(id, projectId, extra = {}) {
  return { id, title: "Task " + id, done: false, dueMs: null, priority: 0, projectId, ...extra }
}

const projects = Model.parseProjectList(PROJECTS)
const tasks = [t(10, 1), t(11, 3), t(12, 4), t(13, 4), t(14, 5), t(15, 99)]

test("parseProjectList drops saved filters and validates colors", () => {
  assert.deepEqual(projects.map(p => p.id), [1, 2, 3, 4, 5, 6])
  assert.equal(projects[1].color, "#1973ff")
  assert.equal(projects[0].color, "")
  assert.equal(projects[2].parentId, 2)
})

test("buildProjectTree nests children and hides archived projects", () => {
  const tree = Model.buildProjectTree(projects)
  assert.deepEqual(tree.map(n => n.project.title), ["Inbox", "Work"])
  assert.equal(tree[1].children[0].project.title, "Website")
  assert.equal(tree[1].children[0].children[0].depth, 2)
})

test("a parent cycle does not loop or lose projects", () => {
  const cyclic = Model.parseProjectList(JSON.stringify([
    { id: 1, title: "A", parent_project_id: 2 },
    { id: 2, title: "B", parent_project_id: 1 }
  ]))
  const flat = Model.flatProjects(cyclic)
  assert.deepEqual(flat.map(p => p.id).sort(), [1, 2])
})

test("tree rows count sub-project tasks and hide empty projects", () => {
  const { rows } = Model.buildTreeRows(projects, tasks, {})
  const titles = rows.map(r => r.kind === "project" ? "P:" + r.title : "T:" + r.task.id)
  assert.deepEqual(titles, [
    "P:Inbox", "T:10",
    "P:Work", "P:Website", "T:11", "P:Copy", "T:12", "T:13",
    "P:Other", "T:15"
  ])
  assert.equal(rows.find(r => r.title === "Work").count, 3)
  assert.ok(!titles.includes("P:Empty"))
  assert.ok(!titles.includes("T:14"), "tasks in archived projects stay hidden")
})

test("collapsed projects hide their tasks and sub-projects but keep counts", () => {
  const { rows } = Model.buildTreeRows(projects, tasks, { collapsed: [3] })
  const website = rows.find(r => r.title === "Website")
  assert.equal(website.collapsed, true)
  assert.equal(website.count, 3)
  assert.ok(!rows.some(r => r.title === "Copy"))
  assert.ok(!rows.some(r => r.kind === "task" && r.task.id === 12))
})

test("hideEmpty off shows empty projects as non-expandable", () => {
  const { rows } = Model.buildTreeRows(projects, tasks, { hideEmpty: false })
  const empty = rows.find(r => r.title === "Empty")
  assert.ok(empty)
  assert.equal(empty.expandable, false)
})

test("row limit reports hidden tasks", () => {
  const { rows, hidden } = Model.buildTreeRows(projects, tasks, { limit: 3 })
  assert.equal(rows.length, 3)
  assert.ok(hidden > 0)
})

test("scopeTasks with and without sub-projects", () => {
  assert.deepEqual(Model.scopeTasks(tasks, projects, 2, true).map(x => x.id), [11, 12, 13])
  assert.deepEqual(Model.scopeTasks(tasks, projects, 3, false).map(x => x.id), [11])
  assert.equal(Model.scopeTasks(tasks, projects, 0, true), tasks)
})

test("projectPath builds a breadcrumb", () => {
  assert.equal(Model.projectPath(projects, 4), "Work › Website › Copy")
})

test("collapse state round-trips per instance and rejects junk", () => {
  let state = Model.parseCollapsedState("not json")
  assert.deepEqual(Model.collapsedFor(state, "https://a"), [])
  state = Model.setCollapsed(state, "https://a", 3)
  state = Model.setCollapsed(state, "https://b", 7)
  state = Model.setCollapsed(state, "https://a", 4)
  state = Model.setCollapsed(state, "https://a", 3)
  const reread = Model.parseCollapsedState(Model.serializeCollapsedState(state))
  assert.deepEqual(Model.collapsedFor(reread, "https://a"), [4])
  assert.deepEqual(Model.collapsedFor(reread, "https://b"), [7])
  const junk = Model.parseCollapsedState('{"x":[1,"2","<b>",-1,2], "y":"nope"}')
  assert.deepEqual(Model.collapsedFor(junk, "x"), [1, 2])
  assert.deepEqual(Model.collapsedFor(junk, "y"), [])
})

test("view settings normalize hand-edited values", () => {
  assert.equal(Model.normalizeViewMode("PROJECT"), "project")
  assert.equal(Model.normalizeViewMode("bogus"), "tree")
  assert.equal(Model.normalizeProjectId("12"), 12)
  assert.equal(Model.normalizeProjectId(-3), 0)
})

test("keyring lookup falls back to the legacy service without argv secrets", () => {
  const argv = Model.secretLookupCommand("https://v.example")
  assert.equal(argv[0], "bash")
  assert.ok(argv.includes(Model.SECRET_SERVICE))
  assert.ok(argv.includes(Model.LEGACY_SECRET_SERVICE))
})

test("the task fetch asks the server for open tasks only and slims items", () => {
  const argv = Model.tasksCommand("https://v.example")
  assert.ok(argv.includes("&filter=done%20%3D%20false"))
  assert.ok(argv.some(a => a.includes("project_id")))
  assert.match(argv[2], new RegExp('-le ' + Model.MAX_PAGES))
})

test("defaultProjectId prefers Inbox", () => {
  assert.equal(Model.defaultProjectId(projects), 1)
  assert.equal(Model.defaultProjectId(projects.filter(p => p.id !== 1)), 2)
  assert.equal(Model.defaultProjectId([]), 0)
})

test("insertTask merges a created task in sort order and ignores junk", () => {
  const list = Model.parseTasks(JSON.stringify([
    { id: 1, title: "B", due_date: "2026-08-20T09:00:00Z", project_id: 1 }
  ]))
  const added = Model.insertTask(list, JSON.stringify({ id: 2, title: "A", due_date: "2026-08-19T09:00:00Z", project_id: 1 }), { 1: "Inbox" })
  assert.deepEqual(added.map(t => t.id), [2, 1])
  assert.equal(added[0].projectTitle, "Inbox")
  assert.equal(Model.insertTask(list, "nope"), list)
  assert.deepEqual(Model.removeTask(added, 2).map(t => t.id), [1])
})

test("createTaskRequest keeps the title out of argv and sends it as JSON", async (t) => {
  const { spawnSync } = await import("node:child_process")
  const { mkdtempSync, writeFileSync, chmodSync, rmSync } = await import("node:fs")
  const { tmpdir } = await import("node:os")
  const { join } = await import("node:path")
  const title = '"; rm -rf ~; echo "$(id) %s \\n é'
  const req = Model.createTaskRequest("https://v.example", 7, title)
  assert.deepEqual(req.command.slice(3), ["vikunja-create", "https://v.example", "7"])
  assert.ok(!req.command.some(a => a.includes(title)))
  // A stub curl that echoes the --data-binary body back as the created task.
  const dir = mkdtempSync(join(tmpdir(), "vikunja-create-"))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  writeFileSync(join(dir, "curl"),
    '#!/bin/bash\nwhile [ $# -gt 0 ]; do [ "$1" = --data-binary ] && cat "${2#@}"; shift; done; printf 201\n')
  chmodSync(join(dir, "curl"), 0o755)
  const run = env => spawnSync(req.command[0], req.command.slice(1), {
    env: { ...process.env, PATH: dir + ":" + process.env.PATH, VIKUNJA_TOKEN: "t", ...env }, encoding: "utf8"
  })
  const ok = run(req.env)
  assert.equal(ok.status, 0, ok.stderr)
  assert.equal(JSON.parse(ok.stdout).title, title)
  const missing = run({})
  assert.notEqual(missing.status, 0)
  assert.match(missing.stderr, /empty title/)
  assert.equal(Model.normalizeNewTitle("  a\nb  "), "a b")
})

test("toggleDoneCommand fails on a non-2xx status", async (t) => {
  const { spawnSync } = await import("node:child_process")
  const { mkdtempSync, writeFileSync, chmodSync, rmSync } = await import("node:fs")
  const { tmpdir } = await import("node:os")
  const { join } = await import("node:path")
  for (const [code, ok] of [["200", true], ["401", false], ["404", false]]) {
    const dir = mkdtempSync(join(tmpdir(), "vikunja-toggle-"))
    t.after(() => rmSync(dir, { recursive: true, force: true }))
    writeFileSync(join(dir, "curl"), `#!/bin/sh\nprintf '${code}'\n`)
    chmodSync(join(dir, "curl"), 0o755)
    const argv = Model.toggleDoneCommand("https://v.example", 5)
    const r = spawnSync(argv[0], argv.slice(1), {
      env: { ...process.env, PATH: dir + ":" + process.env.PATH, VIKUNJA_TOKEN: "t" }, encoding: "utf8"
    })
    assert.equal(r.status === 0, ok, `HTTP ${code}`)
    if (!ok) assert.match(r.stderr, new RegExp(code))
  }
})

test("instance URLs: only plain http(s), no credentials or curl options", () => {
  for (const ok of ["https://v.example", "https://v.example:8443", "http://todo.localhost:8456", "https://host.ts.net:8443/vikunja"])
    assert.equal(Model.normalizeInstance(ok + "/"), ok, ok)
  for (const bad of ["https://user:pass@v.example", "https://user@v.example", "-K/tmp/x", "file:///etc/passwd",
                     "dict://v.example", "https://v.example/?q=1", "https://v.example/#x", "https://v.ex ample",
                     "javascript:alert(1)", "https://v.example\n-K/tmp/x"])
    assert.equal(Model.normalizeInstance(bad), "", JSON.stringify(bad))
  assert.equal(Model.isInsecureInstance("http://vikunja.lan"), true)
  assert.equal(Model.isInsecureInstance("http://todo.localhost:8456"), false)
  assert.equal(Model.isInsecureInstance("http://127.0.0.1:3456"), false)
  assert.equal(Model.isInsecureInstance("http://127.attacker.example"), true)
  assert.equal(Model.isInsecureInstance("https://vikunja.lan"), false)
})

test("tokens with whitespace or control characters are refused", () => {
  assert.equal(Model.isValidToken("tk_abc123.-_XYZ"), true)
  for (const bad of ["", "a b", "a\nX-Evil: 1", "a\r", "a\t"]) assert.equal(Model.isValidToken(bad), false, JSON.stringify(bad))
})

test("notification text is markup-escaped", () => {
  assert.equal(Model.escapeMarkup("<b>a & b</b>"), "&lt;b&gt;a &amp; b&lt;/b&gt;")
})

test("task ids must be safe positive integers", () => {
  const parse = id => Model.normalizedTask({ id, title: "x" }, {})
  assert.equal(parse(5).id, 5)
  for (const bad of [5.5, 0, -3, 2 ** 60, "abc", null]) assert.equal(parse(bad), null, String(bad))
})

test("oversized collapse-state files are ignored", () => {
  const big = JSON.stringify({ a: Array.from({ length: 60000 }, (_, i) => i) })
  assert.ok(big.length > Model.MAX_COLLAPSE_FILE_CHARS)
  assert.deepEqual(Object.keys(Model.parseCollapsedState(big)), [])
  assert.deepEqual(Model.parseCollapsedState('{"u":[3,3,2]}').u, [3, 2])
})

test("every curl call ignores ~/.curlrc, is limited to http(s) and passes the URL with --url", () => {
  const scripts = [Model.tasksCommand("https://v.example"), Model.toggleDoneCommand("https://v.example", 1),
                   Model.testCommand("https://v.example"), Model.createTaskRequest("https://v.example", 1, "x").command]
  for (const argv of scripts) {
    const calls = argv[2].match(/curl [^\n]*/g)
    assert.ok(calls.length > 0)
    for (const call of calls) {
      assert.match(call, /^curl -q -sS --proto =http,https --proto-redir =http,https /)
      assert.match(call, /--url "\$\{instance\}/)
    }
  }
})

test("fetch fails on a curl error or a bad page count instead of returning an empty list", async (t) => {
  const { spawnSync } = await import("node:child_process")
  const { mkdtempSync, writeFileSync, chmodSync, rmSync } = await import("node:fs")
  const { tmpdir } = await import("node:os")
  const { join } = await import("node:path")
  const cases = [
    ["exit 63", "printf 200; exit 63", /exceeds/],
    ["exit 7", "echo 'curl: (7) refused' >&2; printf 000; exit 7", /refused/],
    ["bad total_pages", `printf '{"items":[],"total_pages":"a[$(touch /tmp/x)]"}200'`, /invalid page count/],
    ["zero total_pages", `printf '{"items":[],"total_pages":0}200'`, /invalid page count/]
  ]
  for (const [name, body, err] of cases) {
    const dir = mkdtempSync(join(tmpdir(), "vikunja-fetch-"))
    t.after(() => rmSync(dir, { recursive: true, force: true }))
    writeFileSync(join(dir, "curl"), "#!/bin/bash\n" + body + "\n")
    chmodSync(join(dir, "curl"), 0o755)
    const argv = Model.boundedCommand(Model.tasksCommand("https://v.example"))
    const r = spawnSync(argv[0], argv.slice(1), {
      env: { ...process.env, PATH: dir + ":" + process.env.PATH, VIKUNJA_TOKEN: "t" }, encoding: "utf8"
    })
    assert.notEqual(r.status, 0, name)
    assert.match(r.stderr, err, name)
  }
})

test("helpers run under an overall deadline that kills the whole process group", () => {
  const argv = Model.withDeadline(["bash", "-c", "true"], Model.DEADLINES.fetch)
  assert.deepEqual(argv.slice(0, 4), ["timeout", "-k", "5", String(Model.DEADLINES.fetch)])
  assert.deepEqual(argv.slice(4), ["bash", "-c", "true"])
  assert.equal(Model.withDeadline(["x"], 0)[3], "1")
  for (const key of ["lookup", "store", "fetch", "toggle", "create", "test", "paste"])
    assert.ok(Model.DEADLINES[key] > 0, key)
})

test("a stuck helper is killed at its deadline", async () => {
  const { spawnSync } = await import("node:child_process")
  const t0 = Date.now()
  const argv = Model.withDeadline(["bash", "-c", "sleep 30 & wait"], 1)
  const r = spawnSync(argv[0], argv.slice(1))
  assert.notEqual(r.status, 0)
  assert.ok(Date.now() - t0 < 8000)
})

test("paste reads the clipboard with a byte cap and a deadline", () => {
  const argv = Model.pasteCommand()
  assert.equal(argv[0], "timeout")
  assert.equal(argv[3], String(Model.DEADLINES.paste))
  assert.ok(argv.join(" ").includes("head -c " + Model.MAX_PASTE_BYTES))
  assert.ok(argv.join(" ").includes("wl-paste --no-newline --type text"))
})
