"""Drive the shipped screens on a simulator and save the visual checks alongside the log."""

import json
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
            raise RuntimeError(f"Timed out waiting for {identifier or label}")
        time.sleep(0.6)


def tap(identifier):
    axe("tap", "--id", identifier, "--wait-timeout", "12")


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
            wait_for("demo.tournament")
            wait_for(accepts=lambda s: "Бот Слоу" in s)
            time.sleep(0.5)
            shot("room")
        finally:
            recording.send_signal(signal.SIGINT)
            recording.wait(timeout=30)
    remember("offline_entry", "Демо-комната")

    tap("demo.tournament")
    remember("tournament", wait_for("arena.progress", accepts=lambda s: "Бокс, игра 1 из 10" in s))
    tap("arena.back")

    games = [("box", "Бокс"), ("race", "Гонка"), ("mines", "Минёр"), ("duel", "Дуэль"),
             ("slice", "Самурай"), ("goal", "Пенальти"), ("range", "Тир"), ("arm", "Армрестлинг"),
             ("hoop", "Баскет"), ("beat", "Ритм")]
    for key, title in games:
        wait_for("demo.close")
        tile = "demo.game." + key
        axe("swipe", "--start-x", "180", "--start-y", "620", "--end-x", "180", "--end-y", "270",
            "--until-id", tile, "--max-swipes", "10")
        tap(tile)
        progress = wait_for("arena.progress", accepts=lambda s: f"{title}, игра 1 из 1" in s)
        score = wait_for("arena.opponent.score", accepts=lambda s: s.isdecimal() and int(s) > 0, timeout=45)
        remember(key, {"round": progress, "bot_points": int(score)})
        if key == "box":
            axe("tap", "-x", "170", "-y", "445")
            shot("match")
            remember("bot_live_score", int(score))
            wait_for(label="В демо-комнату", timeout=110)
            shot("result")
            axe("tap", "--label", "В демо-комнату")
            wait_for("demo.close")
            remember("complete_match", "three rounds and back to the room")
        else:
            tap("arena.back")
    wait_for("demo.close")
    tap("demo.close")
    wait_for("demo.enter")
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
