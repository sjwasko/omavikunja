import { MAX_OUTPUT_CHARS } from "./limits.mjs"

export const MAX_STDOUT_BYTES = MAX_OUTPUT_CHARS
export const MAX_STDERR_BYTES = 4096

// Hard caps on untrusted response size. MAX_PAGE_BYTES bounds a single API
// response and MAX_TOTAL_BYTES bounds the sum across pages, so a hostile or
// misconfigured endpoint can never make the shell buffer an unbounded body.
export const MAX_PAGE_BYTES = 1024 * 1024
// Raw bytes read across all pages. Each page is slimmed with jq before it is
// merged, so the merged output (bounded by MAX_OUTPUT_CHARS) is far smaller.
export const MAX_TOTAL_BYTES = 64 * 1024 * 1024

// Pages fetched at most (50 items each), matching MAX_TASKS.
export const MAX_PAGES = 100

// Only the fields the widget reads are kept from each API item.
const TASK_FIELDS = "{id, title, done, due_date, priority, project_id, repeat_after, repeat_mode}"
const PROJECT_FIELDS = "{id, title, parent_project_id, is_archived, position, hex_color}"

// The Vikunja API token travels via the VIKUNJA_TOKEN environment variable
// (set on the Process), never argv. curl reads the Authorization header from
// a bash process substitution (printf is a builtin), so the token shows up in
// neither the shell's nor curl's command line in `ps`.
export const TOKEN_ENV = "VIKUNJA_TOKEN"

// The one curl argument that carries the token. `-H @file` needs curl 7.55+.
const AUTH_HEADER = '-H @<(printf "Authorization: Bearer %s\\n" "${' + TOKEN_ENV + '}")'

// The keyring service attribute the token is stored under.
export const SECRET_SERVICE = "sjwasko.omavikunja"

// Tokens stored by the original org.jsongerber.vikunja widget are still found,
// so switching widgets does not mean pasting the token again.
export const LEGACY_SECRET_SERVICE = "org.jsongerber.vikunja"

// Cap both pipes while preserving producer failures, same as the caldir widget.
export function boundedCommand(argv) {
  const script = "set -o pipefail; " +
    '{ exec "$@" 2>&1 1>&3 | head -c ' + MAX_STDERR_BYTES + " >&2; } 3>&1" +
    " | head -c " + MAX_STDOUT_BYTES
  return ["bash", "-c", script, "omavikunja"].concat(argv)
}

// Read the token from the OS keyring. The lookup keys on both the fixed
// service attribute and the instance URL, so each instance keeps its own
// token and changing the instance URL never reuses a stale one. The secret
// itself never appears on a command line.
export function secretLookupCommand(instance) {
  const script = 'secret-tool lookup service "$1" instance "$3" 2>/dev/null || secret-tool lookup service "$2" instance "$3"'
  return ["bash", "-c", script, "vikunja-lookup", SECRET_SERVICE, LEGACY_SECRET_SERVICE, instance]
}

// Store the token in the OS keyring, scoped to the instance URL it belongs
// to. The secret arrives via the VIKUNJA_TOKEN environment variable (never
// argv) and is fed to secret-tool over a here-string, so it does not show up
// in `ps`.
export function storeTokenCommand(instance) {
  const script = 'secret-tool store --label="Vikunja API token" service "$1" instance "$2" <<< "$VIKUNJA_TOKEN"'
  return ["bash", "-c", script, "vikunja-store", SECRET_SERVICE, instance]
}

// Fetch items across all pages and merge every page's items into one JSON
// array. Bounded to MAX_PAGES pages so a misbehaving total can never loop forever.
// Non-200 responses (auth failures, wrong host, etc.) are reported on stderr
// and fail the fetch so the widget can surface an error instead of showing an
// empty list.
function fetchItemsCommand(instance, path, query, fields) {
  const pageCap = MAX_PAGE_BYTES
  const totalCap = MAX_TOTAL_BYTES
  // curl aborts one byte past the page cap so an over-limit response stays
  // detectable, and the read is capped one byte past that (plus the trailing
  // three-byte HTTP code). Together they bound the response regardless of the
  // curl version: curl stops the socket read, and head stops the shell from
  // buffering more than the cap if the running curl does not honour it.
  const curlCap = pageCap + 1
  const readCap = pageCap + 4
  const overflowCap = pageCap + 3
  const script = [
    'instance="$1"',
    'path="$2"',
    'query="$3"',
    'fields="$4"',
    "page=1",
    "total_pages=1",
    "total_bytes=0",
    'out="[]"',
    'while [ "$page" -le "$total_pages" ] && [ "$page" -le ' + MAX_PAGES + ' ]; do',
    '  resp="$(curl -sS --max-time 20 --max-filesize ' + curlCap + ' -w "%{http_code}" ' + AUTH_HEADER + ' "${instance}${path}?per_page=50&page=${page}${query}" | head -c ' + readCap + ')"',
    '  resp_bytes="$(printf "%s" "$resp" | wc -c)"',
    '  if [ "$resp_bytes" -gt ' + overflowCap + ' ]; then',
    '    printf "Vikunja response exceeds ' + pageCap + ' bytes for %s" "$path" >&2',
    "    exit 1",
    "  fi",
    '  code="${resp: -3}"',
    '  body="${resp%???}"',
    '  if [ "$code" != "200" ]; then',
    '    case "$code" in',
    '      401) printf "Unauthorized (HTTP 401) — check the API token" >&2 ;;',
    '      403) printf "Forbidden (HTTP 403) — the token lacks access" >&2 ;;',
    '      404)',
    '        v1="$(curl -sS --max-time 20 -o /dev/null -w "%{http_code}" "${instance}/api/v1/info")"',
    '        if [ "$v1" = "200" ]; then printf "Vikunja is running API v1 — update your instance (this widget requires API v2, Vikunja 2.4+)" >&2;',
    '        else printf "Not a Vikunja instance (HTTP 404)" >&2; fi ;;',
    '      *) printf "HTTP %s from %s" "$code" "$path" >&2 ;;',
    '    esac',
    '    exit 1',
    '  fi',
    '  total_bytes=$((total_bytes + resp_bytes - 3))',
    '  if [ "$total_bytes" -gt ' + totalCap + ' ]; then',
    '    printf "Vikunja response exceeds ' + totalCap + ' bytes across pages" >&2',
    "    exit 1",
    "  fi",
    '  total_pages="$(printf "%s" "$body" | jq -r ".total_pages // 1")"',
    '  out="$(printf "%s\\n%s" "$out" "$body" | jq -c -s ".[0] + (.[1].items // [] | map($fields))" 2>/dev/null)" || { printf "Vikunja returned invalid JSON for %s" "$path" >&2; exit 1; }',
    '  page="$((page + 1))"',
    "done",
    "printf '%s' \"$out\""
  ].join("\n")
  return ["bash", "-c", script, "vikunja-fetch", instance, path, query || "", fields || "."]
}

export function tasksCommand(instance) {
  // Only open tasks: done ones can outnumber them many times over and would
  // otherwise eat the page budget before open tasks are reached.
  return fetchItemsCommand(instance, "/api/v2/tasks", "&filter=done%20%3D%20false", TASK_FIELDS)
}

export function projectsCommand(instance) {
  return fetchItemsCommand(instance, "/api/v2/projects", "", PROJECT_FIELDS)
}

// Mark a task done. The panel only offers this on open tasks, so "done" is
// always the target state; reopening is out of scope for the widget.
export function toggleDoneCommand(instance, id) {
  const script = [
    'instance="$1"',
    'id="$2"',
    'code="$(curl -sS --max-time 20 -o /dev/null -w "%{http_code}" -X PATCH ' + AUTH_HEADER + ' -H "Content-Type: application/json" -d \'{"done":true}\' "${instance}/api/v2/tasks/${id}")" || exit 1',
    'case "$code" in',
    '  200|201|204) exit 0 ;;',
    '  401) printf "Unauthorized (HTTP 401): check the API token" >&2 ;;',
    '  403) printf "Forbidden (HTTP 403): no write access to this todo" >&2 ;;',
    '  404) printf "Todo not found (HTTP 404): it may have been deleted" >&2 ;;',
    '  *) printf "Could not mark the todo as done (HTTP %s)" "$code" >&2 ;;',
    'esac',
    'exit 1'
  ].join("\n")
  return ["bash", "-c", script, "vikunja-toggle", instance, String(Math.floor(Number(id)) || 0)]
}

// Verify the instance URL and API token by requesting one page of the tasks
// endpoint, which is the resource the widget actually loads. `/api/v2/user`
// is avoided because scoped API tokens (Vikunja 2.5+) can read tasks without
// the "user" permission, which would report a false 401. Prints a short
// human-readable result to stdout and exits non-zero unless Vikunja answers
// 200. A 404 on v2 is checked against /api/v1/info so an old instance gets a
// "please update" hint instead of a generic "not a Vikunja instance".
export function testCommand(instance) {
  const script = [
    'instance="$1"',
    'errfile="$(mktemp)"',
    'code="$(curl -sS --max-time 20 -o /dev/null -w "%{http_code}" ' + AUTH_HEADER + ' "${instance}/api/v2/tasks?per_page=1" 2>"$errfile")"',
    'err="$(cat "$errfile")"; rm -f "$errfile"',
    'if [ "$code" = "200" ]; then printf "Connection OK"; exit 0; fi',
    'if [ -n "$err" ]; then printf "%s" "$err"',
    'elif [ "$code" = "401" ]; then printf "Unauthorized: check the API token"',
    'elif [ "$code" = "403" ]; then printf "Forbidden: the token lacks access"',
    'elif [ "$code" = "404" ]; then',
    '  v1="$(curl -sS --max-time 20 -o /dev/null -w "%{http_code}" "${instance}/api/v1/info")"',
    '  if [ "$v1" = "200" ]; then printf "Vikunja is running API v1 — update your instance (this widget requires API v2, Vikunja 2.4+)"',
    '  else printf "Not a Vikunja instance (HTTP 404)"; fi',
    'else printf "HTTP %s" "$code"; fi',
    'exit 1'
  ].join("\n")
  return ["bash", "-c", script, "vikunja-test", instance]
}

// The new task's title travels via this environment variable, never argv, so
// a title added to a private project cannot be read from `ps` by another local
// account. jq reads it with env.* and builds the JSON body first; if jq fails
// the script stops before curl runs. curl then reads the body from a bash
// process substitution (printf is a builtin), so it stays out of argv too.
export const TITLE_ENV = "VIKUNJA_TASK_TITLE"

// Create a task in a project. Returns { command, env }: run `command` with
// `env` (plus TOKEN_ENV) set on the Process, so the title cannot be left out.
// Prints the created task's JSON on success.
export function createTaskRequest(instance, projectId, title) {
  const script = [
    'instance="$1"',
    'project="$2"',
    '[ -n "${' + TITLE_ENV + '}" ] || { printf "Could not add the todo (empty title)" >&2; exit 1; }',
    'body="$(jq -cn \'{title: env.' + TITLE_ENV + '}\')" && [ -n "$body" ] || { printf "Could not add the todo (jq failed)" >&2; exit 1; }',
    'resp="$(curl -sS --max-time 20 --max-filesize 1048576 -w "%{http_code}" -X POST ' + AUTH_HEADER + ' -H "Content-Type: application/json" --data-binary @<(printf "%s" "$body") "${instance}/api/v2/projects/${project}/tasks")" || exit 1',
    'code="${resp: -3}"',
    'if [ "$code" != "200" ] && [ "$code" != "201" ]; then printf "Could not add the todo (HTTP %s)" "$code" >&2; exit 1; fi',
    'printf "%s" "${resp%???}"'
  ].join("\n")
  const env = {}
  env[TITLE_ENV] = String(title)
  return {
    command: ["bash", "-c", script, "vikunja-create", instance, String(Math.floor(Number(projectId)) || 0)],
    env
  }
}
