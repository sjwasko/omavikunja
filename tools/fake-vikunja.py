#!/usr/bin/env python3
"""A tiny stand-in for the Vikunja API v2, with made-up demo data.

Serves just what the widget uses: paginated /projects and /tasks (with the
`done = false` filter), PATCH /tasks/{id}, POST /projects/{id}/tasks and
/api/v1/info. Data lives in memory and resets on restart.

    python3 tools/fake-vikunja.py [port]      # default 8456

Then set the widget's instance to http://todo.localhost:8456 and store any
token for it, e.g.
    printf demo | secret-tool store --label=demo service sjwasko.omavikunja \\
        instance http://todo.localhost:8456

Used for development and for the screenshots in screenshots/.
"""
import json
import sys
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8456
ZERO = "0001-01-01T00:00:00Z"

PROJECTS = [
    # id, title, parent, position, color
    (1, "Inbox", 0, 1, ""),
    (2, "Work", 0, 2, "1973ff"),
    (3, "Website Redesign", 2, 1, "8e44ad"),
    (4, "Copywriting", 3, 1, ""),
    (5, "Q3 Planning", 2, 2, "e67e22"),
    (6, "Home", 0, 3, "27ae60"),
    (7, "Garden", 6, 1, "2ecc71"),
    (8, "Kitchen Renovation", 6, 2, ""),
    (9, "Personal", 0, 4, "e84393"),
    (10, "Reading List", 9, 1, ""),
    (11, "Fitness", 9, 2, "00b894"),
    (12, "Groceries", 0, 5, "fdcb6e"),
    (13, "Someday", 0, 6, ""),
]


def due(days, hour=17):
    if days is None:
        return ZERO
    now = datetime.now().astimezone()
    d = (now + timedelta(days=days)).replace(hour=hour, minute=0, second=0, microsecond=0)
    return d.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


TASKS = [
    # title, project, due-in-days (None = no date), priority, repeat-every-days
    ("Reply to Dana about the venue", 1, -2, 3, 0),
    ("Renew passport", 1, 6, 2, 0),
    ("Book dentist appointment", 1, None, 0, 0),
    ("Back up the photo library", 1, None, 0, 0),
    ("Send weekly status update", 2, 0, 2, 7),
    ("Expense report for October", 2, -1, 4, 0),
    ("Review pull requests", 2, 0, 0, 1),
    ("Pick a typeface for headings", 3, 1, 2, 0),
    ("Build the new pricing page", 3, 4, 3, 0),
    ("Fix mobile nav overflow", 3, -3, 4, 0),
    ("Write homepage hero copy", 4, 1, 2, 0),
    ("Proofread About page", 4, 8, 0, 0),
    ("Draft Q3 OKRs", 5, 3, 3, 0),
    ("Collect team capacity", 5, 2, 0, 0),
    ("Plant garlic before first frost", 7, 5, 2, 0),
    ("Order raised-bed soil", 7, None, 0, 0),
    ("Get three contractor quotes", 8, 9, 2, 0),
    ("Choose cabinet hardware", 8, None, 1, 0),
    ("Finish 'The Overstory'", 10, None, 0, 0),
    ("Return library books", 10, 0, 1, 0),
    ("5k run", 11, 0, 0, 2),
    ("Stretch routine", 11, 1, 0, 1),
    ("Oat milk", 12, None, 0, 0),
    ("Coffee beans", 12, None, 1, 0),
    ("Lemons", 12, None, 0, 0),
    ("Learn to bake sourdough", 13, None, 0, 0),
]

state = {"projects": [], "tasks": [], "next_id": 100}


def reset():
    state["projects"] = [
        {"id": i, "title": t, "parent_project_id": p, "position": pos, "hex_color": c,
         "is_archived": False}
        for i, t, p, pos, c in PROJECTS
    ]
    state["tasks"] = [
        {"id": n + 1, "title": t, "project_id": pid, "due_date": due(d), "priority": pr,
         "done": False, "repeat_after": rep * 86400, "repeat_mode": 0, "is_favorite": False}
        for n, (t, pid, d, pr, rep) in enumerate(TASKS)
    ]
    # A few done tasks, so the done-filter matters.
    for k in range(5):
        state["tasks"].append({"id": 50 + k, "title": "Old done task %d" % k, "project_id": 1,
                               "due_date": ZERO, "priority": 0, "done": True,
                               "repeat_after": 0, "repeat_mode": 0, "is_favorite": False})


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("fake-vikunja: " + fmt % args + "\n")

    def send_json(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        if self.headers.get("Authorization", "").startswith("Bearer ") and len(self.headers["Authorization"]) > 7:
            return True
        self.send_json(401, {"message": "missing token"})
        return False

    def page(self, items, query):
        per = max(1, min(50, int(query.get("per_page", ["50"])[0])))
        page = max(1, int(query.get("page", ["1"])[0]))
        total_pages = max(1, -(-len(items) // per))
        return {"items": items[(page - 1) * per: page * per], "page": page, "per_page": per,
                "total": len(items), "total_pages": total_pages}

    def read_body(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        try:
            return json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return {}

    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        if url.path == "/api/v1/info":
            return self.send_json(200, {"version": "fake"})
        if not self.authorized():
            return
        if url.path == "/api/v2/projects":
            return self.send_json(200, self.page(state["projects"], query))
        if url.path == "/api/v2/tasks":
            tasks = state["tasks"]
            flt = " ".join(query.get("filter", [])).replace(" ", "")
            if flt == "done=false":
                tasks = [t for t in tasks if not t["done"]]
            return self.send_json(200, self.page(tasks, query))
        self.send_json(404, {"message": "not found"})

    def do_PATCH(self):
        if not self.authorized():
            return
        parts = urlparse(self.path).path.strip("/").split("/")
        if len(parts) == 4 and parts[:3] == ["api", "v2", "tasks"]:
            for t in state["tasks"]:
                if str(t["id"]) == parts[3]:
                    body = self.read_body()
                    for key in ("done", "title", "is_favorite"):
                        if key in body:
                            t[key] = body[key]
                    return self.send_json(200, t)
        self.send_json(404, {"message": "not found"})

    def do_POST(self):
        if not self.authorized():
            return
        parts = urlparse(self.path).path.strip("/").split("/")
        if len(parts) == 5 and parts[:3] == ["api", "v2", "projects"] and parts[4] == "tasks":
            pid = int(parts[3])
            if not any(p["id"] == pid for p in state["projects"]):
                return self.send_json(404, {"message": "no such project"})
            body = self.read_body()
            state["next_id"] += 1
            task = {"id": state["next_id"], "title": str(body.get("title", "")).strip() or "Untitled",
                    "project_id": pid, "due_date": ZERO, "priority": 0, "done": False,
                    "repeat_after": 0, "repeat_mode": 0, "is_favorite": False}
            state["tasks"].append(task)
            return self.send_json(201, task)
        self.send_json(404, {"message": "not found"})


if __name__ == "__main__":
    reset()
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("fake-vikunja on http://todo.localhost:%d" % PORT, flush=True)
    server.serve_forever()
