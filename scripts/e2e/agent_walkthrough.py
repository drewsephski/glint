#!/usr/bin/env python3
"""End-to-end: an "agent" records a real walkthrough of a running app through Glint's MCP server and turns it
into verified deliverables.

  1. builds and launches AcmeNotes (real AppKit window) and `glint mcp`
  2. finds the window via glint_list_sources and records ONLY that window (glint_record_start)
  3. relays the app's actions (click/type) with glint_record_action and markers with glint_record_mark
  4. glint_record_stop → glint_autopilot (cuts, zooms) → renders landscape / portrait / gif
  5. glint_quality_report, glint_contact_sheet, and prints every measured check

Usage: scripts/e2e/agent_walkthrough.py <path-to-glint> <workdir>
The workdir gets an isolated GLINT_HOME whose policy allows capture (the user asked for real recording tests);
without it, glint_record_start returns approval_required — that path is covered by the MCP unit tests.
"""
import json, os, subprocess, sys, time, threading, queue

glint, work = sys.argv[1], os.path.abspath(sys.argv[2])
here = os.path.dirname(os.path.abspath(__file__))
home, projects = os.path.join(work, "home"), os.path.join(work, "projects")
os.makedirs(home, exist_ok=True); os.makedirs(projects, exist_ok=True)
with open(os.path.join(home, "policy.json"), "w") as f:
    json.dump({"capture": "allow", "destructive": "ask", "external": "ask", "captureAllowedApps": [], "approvalTTL": 900}, f)

exe = os.path.join(work, "AcmeNotes")
subprocess.run(["swiftc", "-O", os.path.join(here, "AcmeNotes.swift"), "-o", exe], check=True)
demo = subprocess.Popen([exe], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
import atexit; atexit.register(lambda: demo.poll() is None and demo.kill())
events = queue.Queue()
threading.Thread(target=lambda: [events.put(json.loads(l)) for l in demo.stdout if l.strip().startswith("{")], daemon=True).start()
assert events.get(timeout=20)["kind"] == "ready"
time.sleep(1.0)

env = dict(os.environ, GLINT_HOME=home, GLINT_PROJECTS=projects)
mcp = subprocess.Popen([glint, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1, env=env)
next_id = [0]
def rpc(method, params=None):
    next_id[0] += 1
    mcp.stdin.write(json.dumps({"jsonrpc": "2.0", "id": next_id[0], "method": method, "params": params or {}}) + "\n"); mcp.stdin.flush()
    while True:
        msg = json.loads(mcp.stdout.readline())
        if msg.get("id") == next_id[0]: return msg
def tool(tool_name, **args):
    r = rpc("tools/call", {"name": tool_name, "arguments": args})["result"]
    if r.get("isError"): raise SystemExit(f"{tool_name} failed: {r['content'][0]['text']}")
    return r.get("structuredContent") or json.loads(r["content"][0]["text"])

rpc("initialize", {"protocolVersion": "2025-06-18", "clientInfo": {"name": "e2e-agent", "version": "1"}, "capabilities": {}})
srcs = tool("glint_list_sources")
win = next(s for s in (srcs if isinstance(srcs, list) else srcs.get("items", [])) if s["kind"] == "window" and s.get("app") == "AcmeNotes")
print(f"recording window {win['id']} {win['pixelWidth']}x{win['pixelHeight']} '{win['name']}'")
rec = tool("glint_record_start", window_id=win["id"], system_audio=False, name="Acme Notes walkthrough")
session = rec["session_id"]
time.sleep(0.8)
demo.stdin.write("go\n"); demo.stdin.flush()
while True:
    e = events.get(timeout=60)
    if e["kind"] == "done": break
    if e["kind"] == "mark": tool("glint_record_mark", session_id=session, note=e["note"])
    elif e["kind"] == "click": tool("glint_record_action", session_id=session, kind="click", global_x=e["global_x"], global_y=e["global_y"], label=e["label"])
    elif e["kind"] == "type": tool("glint_record_action", session_id=session, kind="type", count=e["count"], duration=e["duration"])
summary = tool("glint_record_stop", session_id=session)
demo.terminate()
project = summary["path"]
print(f"recorded {summary['sourceDuration']:.1f}s → {project}")
print("  counts:", summary["counts"])

events_summary = tool("glint_get_events", project=project)
print("  clicks:", [(round(c["t"], 2), c.get("target")) for c in events_summary["clicks"]], "typing bursts:", len(events_summary["typing"]))

auto = tool("glint_autopilot", project=project, variants=["landscape", "portrait", "gif"])
for s in auto["steps"]:
    r = s["result"]
    print("  step", s["step"], r if isinstance(r, str) else (r.get("label") or f"score {r.get('score')}"))
q = tool("glint_quality_report", project=project)
print(f"edit quality {q['score']}/100")
for c in q["checks"]: print(f"   {c['verdict']:5} {c['id']:24} {c['message']}")
for o in auto["render"]["outputs"]:
    rep = o["report"]
    print(f"render {o['variant']:10} {o['width']}x{o['height']} {rep['duration']:.2f}s {rep['codec']} {o['seconds']:.1f}s to render · quality {rep['quality']['score']}/100")
    for c in rep["quality"]["checks"]: print(f"   {c['verdict']:5} {c['id']:22} {c['message']}")
sheet = tool("glint_contact_sheet", project=project, count=12)
print("contact sheet:", sheet["path"])
with open(os.path.join(work, "e2e-result.json"), "w") as f:
    json.dump({"summary": summary, "events": events_summary, "autopilot": auto, "quality": q, "contact_sheet": sheet["path"]}, f, indent=2)
mcp.stdin.close(); mcp.wait(timeout=10)
print("OK")
