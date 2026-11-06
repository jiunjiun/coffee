#!/usr/bin/env python3
"""Local status page for the shop skill. No model calls: it reads session lists, git, gh, and the event log.
Usage: watch.py <project root> [port] | watch.py <project root> --once (print the state as JSON)
"""
import datetime, http.server, json, os, re, subprocess, sys, threading, time

ROOT = sys.argv[1]
ARG = sys.argv[2] if len(sys.argv) > 2 else "8766"
HERE = os.path.dirname(os.path.abspath(__file__))
EVENTS = f"{ROOT}/.scratch/shop/events.jsonl"
SOURCE = os.path.getmtime(__file__)
THREADS = """query($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) {
  pullRequests(states: OPEN, first: 30) { nodes { number reviewThreads(first: 100) { nodes { isResolved } } } } } }"""


def run(*args):
    try:
        return subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def cached(ttl):
    """Keeps the last result for ttl seconds: `gh` has a rate limit, and each browser tab polls."""
    def wrap(f):
        memo = {"at": 0, "value": None}
        lock = threading.Lock()
        def call():
            with lock:
                if time.time() - memo["at"] >= ttl:
                    memo.update(at=time.time(), value=f())
                return memo["value"]
        return call
    return wrap


def parse(text, empty):
    try:
        return json.loads(text)
    except ValueError:
        return empty


@cached(2)
def agents():
    text = run("claude", "agents", "--json")
    return {"rows": parse(text, []), "ok": bool(text.strip())}


@cached(30)
def pull_requests():
    text = run("gh", "pr", "list", "--state", "all", "--limit", "30", "--json",
               "number,title,state,headRefName,url,createdAt,mergedAt,statusCheckRollup")
    prs = parse(text, [])
    threads = parse(run("gh", "api", "graphql", "-F", "owner={owner}", "-F", "repo={repo}", "-f", f"query={THREADS}"), {})
    nodes = ((threads.get("data") or {}).get("repository") or {}).get("pullRequests", {}).get("nodes", [])
    unresolved = {n["number"]: sum(not t["isResolved"] for t in n["reviewThreads"]["nodes"]) for n in nodes}
    for pr in prs:
        pr["openThreads"] = unresolved.get(pr["number"], 0)
    return {"rows": prs, "ok": bool(text.strip())}


def config():
    return parse(open(f"{ROOT}/.claude/shop.json", encoding="utf-8").read(), {})


def events():
    if not os.path.exists(EVENTS):
        return []
    return [parse(line, {}) for line in open(EVENTS, encoding="utf-8") if line.strip()]


def seconds(iso):
    return datetime.datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp() if iso else None


def checks(pr):
    count = {"pass": 0, "fail": 0, "wait": 0}
    for c in pr.get("statusCheckRollup") or []:
        result = (c.get("conclusion") if c.get("status") == "COMPLETED" else c.get("status")) or c.get("state") or ""
        key = "pass" if result in ("SUCCESS", "SKIPPED", "NEUTRAL") else "fail" if result in ("FAILURE", "ERROR", "TIMED_OUT", "CANCELLED") else "wait"
        count[key] += 1
    return count


def session(row):
    if not row:
        return {"state": "gone", "startedAt": None}
    started = row.get("startedAt")
    return {"state": row.get("state") or row.get("status") or "unknown", "waitingFor": row.get("waitingFor") or "", "id": row.get("id") or "",
            "startedAt": started / 1000 if started and started > 1e11 else started}


def worktrees():
    paths = re.findall(r"^worktree (.+)$", run("git", "worktree", "list", "--porcelain"), re.M)
    return [p for p in paths if p.startswith(f"{ROOT}/.scratch/")]


STUCK = ("blocked", "waiting")


def attention(main, leads, orphans, sessions_ok, github_ok):
    """What the owner must look at, worst first. level act: only the owner can fix it. level watch: a session or a retry may."""
    act, watch = [], []
    if not sessions_ok:
        watch.append({"title": "Cannot read the session list", "hint": "make sure that claude agents --json runs"})
    elif main["state"] == "gone":
        act.append({"title": "No main session", "hint": "type /shop main in a session of this project"})
    for l in leads:
        for s, label in [(l, f"{l['slug']} lead")] + [(h, f"{l['slug']} helper {h['job']}") for h in l["helpers"]]:
            if s["state"] in STUCK:
                reason = s["waitingFor"] or "an answer"
                act.append({"title": f"{label} is stuck: it waits for {reason}", "hint": f"claude attach {s['id']}"})
        pr = l["pr"]
        if sessions_ok and l["state"] == "gone" and not (pr and pr["state"] == "MERGED"):
            act.append({"title": f"{l['slug']} lead is gone", "hint": "ask main to start it again, or run shop.sh close"})
        if pr and pr["state"] == "OPEN" and pr["fail"]:
            watch.append({"title": f"PR #{pr['number']} has failed checks: {pr['fail']}", "hint": "the lead fixes them, and tells main after 3 rounds"})
    for o in orphans:
        watch.append({"title": f"Worktree with no session: {o}", "hint": "make sure that it has no unsaved work, then remove it"})
    if not github_ok:
        watch.append({"title": "Cannot read GitHub: PR and CI data can be old", "hint": "gh auth status"})
    return [{"level": "act", **a} for a in act] + [{"level": "watch", **w} for w in watch]


def build_records(log, prefix):
    """One record per feature, in the order of the log. A lead started again adds to its record."""
    # A go names its order. An older log has go with no slug: it counts for a lead that starts within 10 minutes.
    goes = [e["t"] for e in log if e.get("kind") == "go" and not e.get("slug")]
    orders, records, go_at = {}, {}, {}
    for e in log:
        kind, slug, t = e.get("kind"), e.get("slug", ""), e.get("t")
        if kind == "order":
            orders[slug] = e
        if kind == "go" and slug:
            go_at[slug] = t
        if kind == "lead":
            r = records.get(slug)
            if r is None:
                r = records[slug] = {"slug": slug, "goal": "", "startedAt": t, "latest": t, "closedAt": None, "runs": 0, "helpers": [], "events": [], "order": None, "go": None, "ready": None}
            r.update(runs=r["runs"] + 1, latest=t, closedAt=None, goal=e.get("text") or r["goal"])
            if r["order"] is None and slug in orders:
                r["order"] = orders[slug]["t"]
                r["events"].append(orders[slug])
            said = [go_at[slug]] if slug in go_at else [g for g in goes if t - 600 <= g <= t]
            if r["go"] is None and said:
                r["go"] = said[-1]
                r["events"].append({"t": said[-1], "kind": "go", "who": "", "slug": slug, "text": ""})
        r = records.get(slug)
        if r is None or kind == "go":
            continue
        if not (kind == "order" and r["order"] == t):
            r["events"].append(e)
        if kind == "helper":
            job, _, goal = e.get("text", "").partition(":")
            r["helpers"].append({"name": f"{prefix}-{slug}-{job}", "job": job, "goal": goal.strip(), "startedAt": t})
        elif kind == "ready":
            r["ready"] = t
        elif kind == "close" and e.get("text") == f"{prefix}-{slug}-lead":
            r["closedAt"] = t
    for r in records.values():
        r["events"].sort(key=lambda e: e.get("t") or 0)
    return records


def step_list(r, pr, stuck):
    """The feature's real progress through the flow. state: done, now, bad, todo, or none (done, but no record of it)."""
    merged = bool(pr and pr["state"] == "MERGED")
    ci_done = merged or bool(pr and pr["state"] == "OPEN" and pr["pass"] and not pr["wait"] and not pr["fail"] and not pr["openThreads"])
    steps = [
        ("Order", r["order"], False), ("You said go", r["go"], False), ("Lead started", r["startedAt"], True),
        ("PR opened", seconds(pr["createdAt"]) if pr else None, bool(pr)), ("CI and review", None, ci_done),
        ("Reported", r["ready"], merged), ("Merged", seconds(pr["mergedAt"]) if merged else None, merged), ("Closed", r["closedAt"], bool(r["closedAt"])),
    ]
    reached = max((i for i, (_, t, passed) in enumerate(steps) if t or passed), default=-1)
    out = []
    for i, (label, t, passed) in enumerate(steps):
        if t or passed:
            state = "done"
        elif i < reached:
            state = "none"
        elif i == reached + 1 and not r["closedAt"]:
            state = "bad" if stuck or (label == "CI and review" and pr and pr["fail"]) else "now"
        else:
            state = "todo"
        out.append({"label": label, "t": t, "state": state})
    return out


def status_of(r, pr, lead):
    if not r["exists"]:
        if not r["closedAt"]:
            return "Session gone", "bad"
        if pr and pr["state"] == "MERGED":
            return "Done", "good"
        return "Closed", "mute"
    if lead and lead["state"] in STUCK:
        return "Stuck", "bad"
    if not pr:
        return "Building", "run"
    if pr["state"] == "MERGED":
        return "To close", "good"
    if pr["state"] != "OPEN":
        return "PR closed", "mute"
    if pr["fail"]:
        return "CI failed", "bad"
    if pr["wait"]:
        return "CI running", "run"
    if pr["openThreads"]:
        return "Review comments", "warn"
    return "To merge", "run"


def state():
    conf, sessions, log = config(), agents(), events()
    rows = sessions["rows"]
    prefix = conf.get("prefix", "")
    live = {r["name"]: r for r in rows if r.get("name", "") and r["name"].startswith(prefix + "-")}
    github = pull_requests()
    prs = github["rows"]
    note = {}
    for e in log:
        if e.get("kind") == "note":
            note[e["who"]] = e
    built = build_records(log, prefix)

    def pr_for(slug):
        r = built.get(slug)
        for p in prs:
            if p["headRefName"].split("/", 1)[-1] != slug:
                continue
            created = seconds(p["createdAt"])
            # An open PR on the branch is this feature's. A closed one may be from an older feature with the same slug.
            if r and p["state"] != "OPEN" and (created < r["startedAt"] - 60 or (r["closedAt"] and created > r["closedAt"])):
                continue
            return {"number": p["number"], "title": p["title"], "url": p["url"], "state": p["state"], "branch": p["headRefName"],
                    "createdAt": p["createdAt"], "mergedAt": p.get("mergedAt"), "openThreads": p["openThreads"], **checks(p)}
        return None

    open_slugs = {s for s, r in built.items() if not r["closedAt"]}
    slugs = sorted(open_slugs | {n[len(prefix) + 1:-5] for n in live if n.endswith("-lead")})
    leads = []
    for slug in slugs:
        name, base = f"{prefix}-{slug}-lead", f"{prefix}-{slug}-"
        helpers = sorted(n for n in live if re.fullmatch(re.escape(base) + r"[a-z0-9]+", n) and n != name)
        r = built.get(slug, {})
        leads.append({
            "name": name, "slug": slug, **session(live.get(name)), "goal": r.get("goal", ""), "note": note.get(name, {}).get("text", ""), "pr": pr_for(slug),
            "helpers": [{"name": n, "job": n[len(base):], **session(live[n]), "note": note.get(n, {}).get("text", "")} for n in helpers],
        })
    by_slug = {l["slug"]: l for l in leads}
    for l in leads:
        built.setdefault(l["slug"], {"slug": l["slug"], "goal": "", "startedAt": l["startedAt"], "latest": l["startedAt"], "closedAt": None, "runs": 1, "helpers": [], "events": [], "order": None, "go": None, "ready": None})
    records = sorted(built.values(), key=lambda r: r["latest"] or 0, reverse=True)
    for r in records:
        lead = by_slug.get(r["slug"])
        pr = pr_for(r["slug"])
        r.update(name=f"{prefix}-{r['slug']}-lead", exists=f"{prefix}-{r['slug']}-lead" in live, pr=pr, note=(lead or {}).get("note", ""),
                 state=(lead or {}).get("state", ""), waitingFor=(lead or {}).get("waitingFor", ""), id=(lead or {}).get("id", ""),
                 branch=pr["branch"] if pr else "", updatedAt=max([e.get("t") or 0 for e in r["events"]] + [r["latest"] or 0]))
        r["status"], r["tone"] = status_of(r, pr, lead)
        r["steps"] = step_list(r, pr, bool(lead and lead["state"] in STUCK))
        known = {h["name"] for h in r["helpers"]}
        for h in (lead or {}).get("helpers", []):
            if h["name"] not in known:
                r["helpers"].append({"name": h["name"], "job": h["job"], "goal": "", "startedAt": h["startedAt"]})
        for h in r["helpers"]:
            h.update(exists=h["name"] in live, **{k: v for k, v in session(live.get(h["name"])).items() if k == "state"}, note=note.get(h["name"], {}).get("text", ""))
    queue, holds = {}, {}
    for e in log:
        kind, slug = e.get("kind"), e.get("slug")
        if kind == "queue":
            queue[slug] = e.get("text", "")
        elif kind == "lead":
            queue.pop(slug, None)
        elif kind == "hold":
            holds[e.get("text", "")] = "" if slug == "free" else slug
    timeline = [{k: e.get(k, "") for k in ("t", "kind", "who", "slug", "text")} for e in log]
    for r in records:
        if r["pr"]:
            timeline.append({"t": seconds(r["pr"]["createdAt"]), "kind": "pr", "who": "", "slug": r["slug"], "text": f"#{r['pr']['number']}"})
            if r["pr"]["mergedAt"]:
                timeline.append({"t": seconds(r["pr"]["mergedAt"]), "kind": "merged", "who": "", "slug": r["slug"], "text": f"#{r['pr']['number']}"})
    timeline.sort(key=lambda e: e["t"] or 0, reverse=True)
    trees = worktrees()
    owned = {f"{ROOT}/.scratch/{r['slug']}/{w}" for r in records if r["exists"] for w in ["wt"] + [h["job"] for h in r["helpers"]]}
    orphans = [t[len(ROOT) + 1:] for t in trees if t not in owned]
    main_state = session(live.get(f"{prefix}-main"))
    merged_prs = {r["pr"]["number"] for r in records if r["pr"] and r["pr"]["state"] == "MERGED"}
    alerts = attention(main_state, leads, orphans, sessions["ok"], github["ok"])
    totals = {
        "leads": len(records), "live": sum(r["exists"] for r in records), "deleted": sum(not r["exists"] for r in records),
        "helpers": sum(len(r["helpers"]) for r in records), "merged": len(merged_prs),
    }
    return {
        "now": time.time(), "prefix": prefix, "root": ROOT, "attention": alerts, "records": records[:100], "totals": totals,
        "limits": {"leads": conf.get("max_leads", 3), "helpers": conf.get("max_helpers", 2)},
        "main": main_state, "mainName": f"{prefix}-main", "mainNote": note.get(f"{prefix}-main", {}).get("text", ""),
        "leads": leads, "queue": [{"slug": s, "goal": g} for s, g in queue.items()], "holds": holds,
        "others": sorted(r["name"] for r in rows if r.get("name") and r["name"] not in live and (r.get("cwd") or "").startswith(ROOT)),
        "orphans": orphans, "timeline": timeline[:200],
    }


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # The server stays up after the skill is updated, but each request reads the new watch.html. Start the new
        # code in place, so the page gets the state that it expects. This request fails, and the page polls again.
        if os.path.getmtime(__file__) != SOURCE:
            os.execv(sys.executable, [sys.executable, "-I", *sys.argv])
        # A web page must not reach this server through a rebound DNS name.
        if self.headers.get("Host") not in (f"127.0.0.1:{ARG}", f"localhost:{ARG}"):
            self.send_error(403)
            return
        if self.path == "/state":
            body, kind = json.dumps(state(), ensure_ascii=False).encode(), "application/json"
        elif self.path == "/":
            body, kind = open(f"{HERE}/watch.html", "rb").read(), "text/html; charset=utf-8"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if ARG == "--once":
    print(json.dumps(state(), ensure_ascii=False))
else:
    print(f"http://localhost:{ARG}", flush=True)
    http.server.ThreadingHTTPServer(("127.0.0.1", int(ARG)), Page).serve_forever()
