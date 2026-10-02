#!/usr/bin/env python3
"""End-to-end check of graphcoded's Nod wiring against scripts/fake-graphcode-nod.

Runs an isolated daemon (its own support directory and ZMX_DIR, never the installed one)
and drives it through the CLI the way a human or another loop would:

  launch argv · control.sock delivery · reported presence · Needs you from an open ask
  · usage · goal verdict resolving the loop · daemon heartbeat into the same conversation
  · restart resuming the banked conversation

Usage: scripts/nod-daemon-e2e.py <dir with graphcoded and graphcode> [zmx binary]
Exit 0 when every check passes.
"""

import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

bin_dir = sys.argv[1]
zmx = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/.graphcode/bin/zmx")
root = tempfile.mkdtemp(prefix="gn", dir="/tmp")  # short: sun_path is 104 bytes
support, project, zmx_dir = f"{root}/s", f"{root}/proj", f"{root}/zmx"
for directory in (f"{support}/bin", project, zmx_dir):
    os.makedirs(directory)
shutil.copy(zmx, f"{support}/bin/zmx")
fake = f"{root}/graphcode-nod"
shutil.copy(os.path.join(os.path.dirname(__file__), "fake-graphcode-nod"), fake)
os.chmod(fake, 0o755)
env = dict(os.environ, GRAPHCODE_SUPPORT_DIR=support, ZMX_DIR=zmx_dir, GRAPHCODE_NOD_PATH=fake)
daemon = subprocess.Popen([f"{bin_dir}/graphcoded"], env=env, cwd=root,
                          stdout=open(f"{root}/daemon.log", "w"), stderr=subprocess.STDOUT)
failures = []


def cli(*args):
    result = subprocess.run([f"{bin_dir}/graphcode", *args], env=env, capture_output=True, text=True)
    return result.stdout + result.stderr


def check(name, condition, detail=""):
    print(("PASS " if condition else "FAIL ") + name + (f" — {detail}" if detail and not condition else ""),
          flush=True)
    if not condition:
        failures.append(name)


nodes = {}
lock = threading.Lock()


def watch():
    # Presence is polled only while a client is attached, so this stays connected.
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    for _ in range(50):
        try:
            sock.connect(f"{support}/graphcoded.sock")
            break
        except OSError:
            time.sleep(0.2)
    frame = json.dumps({"openProject": {"path": project}}).encode()
    sock.sendall(struct.pack(">I", len(frame)) + frame)

    def read(count):
        data = b""
        while len(data) < count:
            chunk = sock.recv(count - len(data))
            if not chunk:
                raise EOFError
            data += chunk
        return data

    def tick():
        # What the app does on its timer: the one command that refreshes presence, usage,
        # activity and the summary together.
        while True:
            time.sleep(3)
            command = json.dumps(
                {"graphCommand": {"projectPath": project, "command": {"refreshUsage": {}}}}).encode()
            try:
                sock.sendall(struct.pack(">I", len(command)) + command)
            except OSError:
                return

    threading.Thread(target=tick, daemon=True).start()
    try:
        while True:
            event = json.loads(read(struct.unpack(">I", read(4))[0]))
            if "graphChanged" in event:
                with lock:
                    for node in event["graphChanged"]["_0"]["nodes"]:
                        nodes[node["title"]] = node
    except (EOFError, OSError):
        return


def wait_for(title, predicate, seconds=60):
    deadline = time.time() + seconds
    while time.time() < deadline:
        with lock:
            node = nodes.get(title)
        if node and predicate(node):
            return node
        time.sleep(0.5)
    with lock:
        return nodes.get(title)


def state_dir(node_id):
    return f"{support}/nod/{node_id}"


def events(node_id):
    try:
        with open(f"{state_dir(node_id)}/events.jsonl") as log:
            return [json.loads(line) for line in log if line.strip()]
    except OSError:
        return []


def presence(node):
    return (node or {}).get("presence") or {}


def node_id_of(title):
    for line in cli("status", project).splitlines():
        if line.strip().endswith(title):
            return line.split()[0]
    return None


try:
    time.sleep(1)
    threading.Thread(target=watch, daemon=True).start()

    # Goal loop: launch, delivery, presence, Needs you, usage, verdict.
    print(cli("node", "create", project, "--title", "NodGoal", "--type", "goal",
              "--goal", "Reply DONE when told to", "--backend", "nod").strip())
    goal_id = node_id_of("NodGoal")
    check("goal loop created", goal_id is not None)
    node = wait_for("NodGoal", lambda n: presence(n).get("presence") == "idle")
    with open(f"{state_dir(goal_id)}/argv.json") as out:
        argv = json.loads(out.readline())
    check("launch argv names node, cwd, engine, loop type, goal file",
          argv[:8] == ["--node", goal_id, "--cwd", project, "--engine", "claude", "--loop-type", "goal"]
          and argv[8:10] == ["--goal-file", f"{state_dir(goal_id)}/goal.md"], json.dumps(argv))
    check("prompt rides behind --prompt", argv[-2] == "--prompt", json.dumps(argv))
    with open(f"{state_dir(goal_id)}/goal.md") as goal:
        check("goal file holds the condition", goal.read() == "Reply DONE when told to")
    check("presence is reported idle after the first turn",
          presence(node) == {"presence": "idle", "confidence": "reported"}, json.dumps(presence(node)))

    print(cli("node", "send", project, goal_id, "please ASK first").strip())
    with open(f"{state_dir(goal_id)}/commands.jsonl") as log:
        command = json.loads(log.readline())
    check("node send arrives on control.sock as a queued send",
          command["type"] == "send" and command["delivery"] == "queue" and "ASK" in command["text"],
          json.dumps(command))
    node = wait_for("NodGoal", lambda n: presence(n).get("presence") == "awaitingInput")
    check("an open permissionAsked is Needs you", presence(node).get("presence") == "awaitingInput",
          json.dumps(presence(node)))
    node = wait_for("NodGoal", lambda n: (n.get("activity") or "").startswith("asks to run"))
    check("the live line says what it asks", (node or {}).get("activity") == "asks to run swift package resolve",
          str((node or {}).get("activity")))

    cli("node", "send", project, goal_id, "ALLOW it")
    node = wait_for("NodGoal", lambda n: presence(n).get("presence") == "idle" and n.get("usage"))
    check("answering the ask leaves Needs you", presence(node).get("presence") == "idle",
          json.dumps(presence(node)))
    usage = (node or {}).get("usage") or {}
    check("usage is the runtime's running total", usage.get("inputTokens") == 300, json.dumps(usage))

    cli("node", "send", project, goal_id, "say DONE")
    node = wait_for("NodGoal", lambda n: "succeeded" in (n.get("state") or {}), 150)
    check("a met goalCheck resolves the loop", "succeeded" in ((node or {}).get("state") or {}),
          json.dumps((node or {}).get("state")))

    # Timed loop: the daemon's heartbeat re-enters the same conversation.
    print(cli("node", "create", project, "--title", "NodTimed", "--type", "time",
              "--prompt", "/loop 10s check the inbox", "--backend", "nod").strip())
    timed_id = node_id_of("NodTimed")
    deadline = time.time() + 60
    while time.time() < deadline and not any(
            e["type"] == "userMessage" and "Heartbeat" in e["text"] for e in events(timed_id)):
        time.sleep(1)
    timed = events(timed_id)
    starts = [e for e in timed if e["type"] == "sessionStarted"]
    check("a heartbeat reaches the timed loop", any(
        e["type"] == "userMessage" and "Heartbeat" in e["text"] for e in timed))
    check("…in the same conversation", len(starts) == 1, f"{len(starts)} sessionStarted")
    conversation = starts[0]["conversationID"] if starts else None

    # Restart: the banked conversation is resumed, not replaced.
    deadline = time.time() + 30
    banked = f"{support}/sessions/{timed_id}.id"
    while time.time() < deadline and not os.path.exists(banked):
        time.sleep(1)
    with open(banked) if os.path.exists(banked) else open(os.devnull) as out:
        check("the conversation id is banked for resume", out.read().strip() == conversation)
    print(cli("node", "restart", project, timed_id).strip())
    deadline = time.time() + 30
    while time.time() < deadline and len([e for e in events(timed_id) if e["type"] == "sessionStarted"]) < 2:
        time.sleep(1)
    restarted = [e for e in events(timed_id) if e["type"] == "sessionStarted"]
    check("restart resumes the same conversation",
          len(restarted) == 2 and restarted[1]["resumed"] and restarted[1]["conversationID"] == conversation,
          json.dumps(restarted[1:] if restarted else []))
    with open(f"{state_dir(timed_id)}/argv.json") as out:
        launches = [json.loads(line) for line in out if line.strip()]
    check("the relaunch carries --resume and no prompt",
          len(launches) == 2 and launches[1][-2:] == ["--resume", conversation] and "--prompt" not in launches[1],
          json.dumps(launches[1:]))
finally:
    for title, node_id in (("NodGoal", node_id_of("NodGoal")), ("NodTimed", node_id_of("NodTimed"))):
        if node_id:
            cli("node", "delete", project, node_id)
    daemon.terminate()
    daemon.wait(timeout=10)
    subprocess.run([f"{support}/bin/zmx", "kill", "--all"], env=env, capture_output=True)

print(f"{'FAILED' if failures else 'OK'}: {len(failures)} failed")
if not failures:
    shutil.rmtree(root, ignore_errors=True)
else:
    print(f"kept {root} for inspection")
sys.exit(1 if failures else 0)
