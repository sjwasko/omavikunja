// Lint the bash scripts the widget runs. They live as strings in
// model/command.mjs, so ShellCheck can't see them on disk: build every
// command exactly as the widget does, pull out each `bash -c <script>`, and
// pipe it to `shellcheck -s bash -`. Exits non-zero if any script has a finding.
//
//   node tools/shellcheck-scripts.mjs
import { spawnSync } from "node:child_process"
import * as M from "../Model.mjs"

const I = "https://v.example"
const commands = {
  secretLookup: M.secretLookupCommand(I),
  storeToken: M.storeTokenCommand(I),
  tasks: M.tasksCommand(I),
  projects: M.projectsCommand(I),
  toggleDone: M.toggleDoneCommand(I, 1),
  test: M.testCommand(I),
  createTask: M.createTaskRequest(I, 1, "x").command,
  paste: M.pasteCommand(),
  bounded: M.boundedCommand(["true"])
}

let failed = 0
for (const [name, argv] of Object.entries(commands)) {
  for (let i = 0; i < argv.length - 1; i++) {
    if (argv[i] !== "bash" || argv[i + 1] !== "-c") continue
    const r = spawnSync("shellcheck", ["-s", "bash", "-f", "gcc", "-"], { input: argv[i + 2], encoding: "utf8" })
    const out = (r.stdout || "").replace(/^-:/gm, name + ":")
    if (r.status !== 0) { failed++; process.stdout.write(out || r.stderr) }
    else console.log("ok   " + name)
  }
}
process.exit(failed ? 1 : 0)
