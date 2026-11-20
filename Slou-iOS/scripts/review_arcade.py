"""Record short native simulator sequences and verify both the pilot and explicit physical inputs."""
import json
import signal
import subprocess
import sys
import time
from pathlib import Path

sim, out, tmp = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
app = "app.slou.watch"
control = ["xcrun", "simctl"]
data = Path(subprocess.check_output([*control, "get_app_container", sim, app, "data"], text=True).strip())
files = data / "Documents" / "arcade-review"


def wait_until(test, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if test():
            return
        time.sleep(0.15)
    raise RuntimeError("Simulator did not reach the requested capture state")


for i, game in enumerate(("race", "box", "mines", "duel", "slice", "goal", "range", "arm", "hoop", "beat")):
    args = ["-arcade-review", game]
    if i == 0:
        args.append("-review-checks")
    subprocess.run([*control, "launch", sim, app, *args], check=True)
    wait_until((files / (game + ".ready")).is_file, 120)
    with (tmp / (game + ".log")).open("w+") as log:
        process = subprocess.Popen([*control, "io", sim, "recordVideo", "--codec=h264", "--force",
                                    str(out / (game + ".mp4"))], stdout=log, stderr=subprocess.STDOUT)
        try:
            wait_until(lambda: "Recording started" in Path(log.name).read_text(), 25)
            time.sleep(4.5 if game == "race" else 3.1)
        finally:
            process.send_signal(signal.SIGINT)
            process.wait(timeout=45)
    subprocess.run([*control, "terminate", sim, app], check=True)
    print("Recorded", game, (out / (game + ".mp4")).stat().st_size, flush=True)

raw = (files / "checks.json").read_bytes()
(out / "checks.json").write_bytes(raw)
checks = json.loads(raw)
failures = [key for key, passed in checks.items() if not passed]
print("Verified", len(checks) - len(failures), "out of", len(checks), "checks", flush=True)
if failures:
    raise RuntimeError("Failed physical checks: " + ", ".join(failures))
