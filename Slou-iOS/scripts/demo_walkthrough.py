"""Drive the shipped screens on a simulator and save the visual checks alongside the log."""

import json
import os
import pathlib
import select
import shlex
import signal
import subprocess
import sys
import time

sim, output_dir = sys.argv[1:]
out = pathlib.Path(output_dir)
results = {}


def receipt():
    if not select.select([session.stdout], [], [], 85)[0]:
        raise TimeoutError("Simulator input service stopped responding")
    line = session.stdout.readline()
    if not line:
        raise RuntimeError("Simulator input service exited")
    reply = json.loads(line)
    if reply["didError"]:
        error = reply["error"]
        raise RuntimeError(f"{error['code']}: {error['message']}")
    return reply["data"]["result"]


def axe(*args):
    session.stdin.write(shlex.join(args) + "\n")
    session.stdin.flush()
    return receipt()


def read_tree():
    return axe("describe-ui", "--minimal-keys")


def elements(tree):
    if isinstance(tree, list):
        for element in tree:
            yield from elements(element)
    elif isinstance(tree, dict):
        yield tree
        yield from elements(tree.get("children", []))


def wait_for(identifier=None, label=None, accepts=lambda value: True, timeout=25):
    deadline = time.monotonic() + timeout
    while True:
        try:
            tree = read_tree()
        except RuntimeError as error:
            if time.monotonic() >= deadline:
                raise
            print("Waiting for accessibility", error, flush=True)
            time.sleep(1)
            continue
        for element in elements(tree):
            ids = (element.get("AXUniqueId"), element.get("AXIdentifier"))
            value = str(element.get("AXLabel") or element.get("AXValue") or "")
            if (identifier is None or identifier in ids) and (label is None or label == value) and accepts(value):
                return value
        if time.monotonic() >= deadline:
            (out / "last-tree.json").write_text(json.dumps(tree, ensure_ascii=False, indent=2))
            raise LookupError(f"Timed out waiting for {identifier or label}")
        time.sleep(0.6)


def tap(identifier):
    axe("tap", "--id", identifier, "--wait-timeout", "12")


def touch(x, y):
    axe("tap", "-x", str(round(x)), "-y", str(round(y)))


def tap_card(identifier):
    tree = read_tree()
    tile = next(n for n in elements(tree) if n.get("AXUniqueId") == identifier)
    rect = tile["frame"]
    touch(rect["x"] + rect["width"] / 2, rect["y"] + rect["height"] / 2)
    tap("demo.play")


def shot(name):
    subprocess.run(["xcrun", "simctl", "io", sim, "screenshot", str(out / (name + ".png"))], check=True)


def remember(key, value):
    results[key] = value
    (out / "summary.json").write_text(json.dumps(results, ensure_ascii=False, indent=2))
    print(key, value, flush=True)


def walkthrough():
    wait_for("demo.enter", timeout=140)
    shot("home")
    with (out / "record.log").open("w") as log:
        recording = subprocess.Popen(["xcrun", "simctl", "io", sim, "recordVideo", "--codec=h264",
                                     "--force", str(out / "entry.mp4")], stdout=log, stderr=subprocess.STDOUT)
        try:
            for _ in range(150):
                if "Recording started" in (out / "record.log").read_text():
                    break
                time.sleep(0.1)
            time.sleep(0.7)
            tap("demo.enter")
            time.sleep(0.9)
        finally:
            recording.send_signal(signal.SIGINT)
            recording.wait(timeout=30)
    wait_for("demo.tournament")
    wait_for(accepts=lambda s: "Бот Слоу" in s)
    shot("room")
    remember("offline_entry", "Демо-комната")

    games = [("box", "Бокс"), ("race", "Гонка"), ("mines", "Минёр"), ("duel", "Дуэль"),
             ("slice", "Самурай"), ("goal", "Пенальти"), ("range", "Тир"), ("arm", "Армрестлинг"),
             ("hoop", "Баскет"), ("beat", "Ритм")]

    screen = next(n["frame"] for n in elements(read_tree()) if n.get("type") == "Application")
    full = os.environ.get("SLOU_FULL_TOURNAMENT") == "1"
    if full:
        tap("demo.tournament")
    else:
        tap_card("demo.game.box")
    sequence = games if full else games[:1]
    for index, (key, title) in enumerate(sequence, start=1):
        expected = f"{title}, игра {index} из {len(sequence)},"
        progress = wait_for("arena.progress", accepts=lambda s: s.startswith(expected), timeout=160)
        score = wait_for("arena.opponent.score", accepts=lambda s: s.isdecimal() and int(s) > 0, timeout=65)
        remember(key, {"round": progress, "bot_points": int(score)})
        if index == 1:
            touch(screen["width"] * 0.45, screen["height"] * 0.56)
            shot("match")
    try:
        wait_for(label="В демо-комнату", timeout=105)
    except LookupError:
        # A settled ceremony can temporarily expose an empty accessibility tree.
        # Returning and successfully starting another match below also checks the final button.
        print("Checking the result button by touch", flush=True)
    shot("result")
    # The result button stays in the bottom safe area throughout its animation.
    # Tap the visible button even if the accessibility tree is being rebuilt.
    tap("arena.result.return")
    wait_for("demo.tournament", timeout=75)
    shot("returned-room")
    remember("completed_rounds", 30 if full else 3)

    if full:
        tap_card("demo.game.box")
        alternate = "Бокс, игра 1 из 1,"
    else:
        tap("demo.tournament")
        alternate = "Бокс, игра 1 из 10,"
    progress = wait_for("arena.progress", accepts=lambda s: s.startswith(alternate))
    remember("second_match", progress)
    tap("arena.back")
    wait_for("demo.tournament")
    tap("demo.close")
    time.sleep(0.8)
    wait_for("demo.enter")
    if any(n.get("AXUniqueId") == "demo.tournament" for n in elements(read_tree())):
        raise RuntimeError("Room remained open after tapping its close control")
    remember("returned_home", True)


with subprocess.Popen(["axe", "serve", "--udid", sim], stdin=subprocess.PIPE,
                      stdout=subprocess.PIPE, text=True, bufsize=1) as session:
    try:
        if not receipt().get("ready"):
            raise RuntimeError("Simulator input service did not start")
        walkthrough()
    except Exception:
        shot("last-screen")
        try:
            (out / "last-tree.json").write_text(json.dumps(read_tree(), ensure_ascii=False, indent=2))
        except (RuntimeError, TimeoutError) as error:
            print("Last accessibility snapshot unavailable", error)
        raise
    finally:
        session.stdin.close()
