// Runtime check that secrets never reach a process command line.
//
// Starts tools/fake-vikunja.py, then runs every request the widget makes,
// built exactly as the widget builds it, under `strace -f -e trace=execve`
// with a dummy token and a dummy new-todo title in the environment. Every
// argv of every process (bash, timeout, curl, jq, head, ...) is logged; the
// check fails if the token or the title appears in any of them. argv is
// readable by every local user via ps/proc, the environment is not.
//
//   node tools/argv-audit.mjs        (needs python3 and strace)
import { spawn, spawnSync } from "node:child_process"
import { mkdtempSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join, dirname } from "node:path"
import { fileURLToPath } from "node:url"
import * as M from "../Model.mjs"

const here = dirname(fileURLToPath(import.meta.url))
const port = 18000 + Math.floor(Math.random() * 2000)
const instance = "http://127.0.0.1:" + port
const TOKEN = "tk_ARGVAUDIT_" + Math.random().toString(36).slice(2)
const TITLE = "Private title ARGVAUDIT " + Math.random().toString(36).slice(2)

const server = spawn("python3", ["-I", join(here, "fake-vikunja.py"), String(port)], { stdio: "ignore" })
const dir = mkdtempSync(join(tmpdir(), "vikunja-argv-"))
let failed = 0
try {
  // Wait for the server.
  for (let i = 0; i < 50; i++) {
    const r = spawnSync("curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", instance + "/api/v1/info"], { encoding: "utf8" })
    if (r.stdout === "200") break
    spawnSync("sleep", ["0.1"])
  }
  const create = M.createTaskRequest(instance, 1, TITLE)
  const runs = {
    projects: [M.boundedCommand(M.withDeadline(M.projectsCommand(instance), M.DEADLINES.fetch)), {}],
    tasks: [M.boundedCommand(M.withDeadline(M.tasksCommand(instance), M.DEADLINES.fetch)), {}],
    test: [M.boundedCommand(M.withDeadline(M.testCommand(instance), M.DEADLINES.test)), {}],
    toggleDone: [M.boundedCommand(M.withDeadline(M.toggleDoneCommand(instance, 2), M.DEADLINES.toggle)), {}],
    createTask: [M.boundedCommand(M.withDeadline(create.command, M.DEADLINES.create)), create.env],
    // Control: the old, leaky way of passing the token. Must be detected.
    controlLeak: [["bash", "-c", 'curl -sS -o /dev/null -H "Authorization: Bearer $' + M.TOKEN_ENV + '" "$1/api/v2/tasks"',
      "control", instance], {}]
  }
  for (const [name, [argv, extraEnv]] of Object.entries(runs)) {
    const log = join(dir, name + ".log")
    const r = spawnSync("strace", ["-f", "-qq", "-e", "trace=execve", "-s", "65536", "-o", log].concat(argv), {
      env: { ...process.env, [M.TOKEN_ENV]: TOKEN, ...extraEnv }, encoding: "utf8"
    })
    const trace = readFileSync(log, "utf8")
    const execs = (trace.match(/execve\(/g) || []).length
    const leaks = [TOKEN, TITLE].filter(s => trace.includes(s))
    const curlRan = /execve\("[^"]*\/curl"/.test(trace)
    if (name === "controlLeak") {
      if (leaks.length === 0) { failed++; console.log("FAIL control: the audit did not detect a token in argv") }
      else console.log("ok   control (a token in argv is detected)")
      continue
    }
    if (r.status !== 0 || leaks.length > 0 || !curlRan) {
      failed++
      console.log("FAIL " + name + ": exit " + r.status + ", curl ran: " + curlRan +
        (leaks.length ? ", LEAKED: " + leaks.map(s => s === TOKEN ? "token" : "title").join(", ") : "") +
        (r.stderr ? "\n     " + r.stderr.trim().slice(0, 200) : ""))
    } else {
      console.log("ok   " + name + " (" + execs + " processes, no token/title in any argv)")
    }
  }
} finally {
  server.kill()
  rmSync(dir, { recursive: true, force: true })
}
process.exit(failed ? 1 : 0)
