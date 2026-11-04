#!/usr/bin/env python3
"""One-time image-only review of audited synthetic fixtures, run41785031631.

This is deliberately NOT a general artifact exporter. The exact source run/SHA
and artifact are fixed in the companion opt-in workflow. No account or personal
device was used: each script created a fresh Simulator; settings/material used
literal UIKit fixtures; history used only a loopback fake HTTP server.
Only cropped derivative JPEG pages are emitted. Index/reports/console/crashes,
raw screenshots/videos, arbitrary files and future artifact families are never
emitted. Stop on any source-name, hash, frame-coverage or image-list mismatch.
"""
import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import re

from PIL import Image

SOURCE_SHA = "3b51266f14b545649f07fbe896be34f2e5061aa3"
SOURCE_RUN = 41785031631
EVIDENCE_ARTIFACT = 13302090213
CHUNK_SIZE = 4000
PART_PAYLOAD_LIMIT = 1100000
SETTINGS_FOLDER = "CodeGram-native-UI-36"
HISTORY_FOLDER = "CodeGram-history-UI-36"
MATERIAL_FOLDER = "CodeGram-modern-material-36"
SETTINGS_PHASES = (
    "appearance", "privacy", "voice", "text-entry", "video-error",
    "media-actions", "media-actions-started", "dashboard", "scroll", "return", "search",
    "icons-original-burst", "icons-original", "icons-clip-burst", "icons-clip",
    "icons-paper-burst", "icons-paper", "icons-echo-burst", "icons-echo",
    "icons-rift-burst", "icons-rift", "icons-slice-burst", "icons-slice",
    "icons-pixel-burst", "icons-pixel", "icons-chrome-burst", "icons-chrome",
    "icons-stairs-burst", "icons-stairs", "icons-effects-stopped", "icons-applied",
)
HISTORY_PHASES = (
    "01-initial-offset-zero", "02-story-without-refresh", "03-older-history",
    "04-story-while-scrolled", "05-gap-caught-up", "06-file-ready-in-open-detail",
    "07-visible-resumed", "08-background-request", "09-foreground-live",
    "10-stale-row-rejected", "11-archive-replaced",
)
ALLOWED_SCREENSHOTS = {
    SETTINGS_FOLDER + "/" + phase + "-" + style + ".png"
    for phase in SETTINGS_PHASES for style in ("dark", "light")
} | {HISTORY_FOLDER + "/" + phase + ".png" for phase in HISTORY_PHASES} | {
    MATERIAL_FOLDER + "/01-modern-material-dark.png",
    MATERIAL_FOLDER + "/02-modern-material-light.png",
}
ALLOWED_VIDEOS = {
    SETTINGS_FOLDER + "/native-controls.mp4",
    HISTORY_FOLDER + "/profile-live.mp4",
    MATERIAL_FOLDER + "/modern-material.mp4",
}


def slug(relative):
    clean = re.sub(r"[^A-Za-z0-9_.-]+", "-", relative).strip("-")
    return clean[:110] + "-" + hashlib.sha256(relative.encode()).hexdigest()[:8]


def validate_synthetic_index(report):
    if set(report["screenshots"]) != ALLOWED_SCREENSHOTS or len(report["screenshots"]) != 75:
        raise SystemExit("Source screenshots differ from the audited 75 synthetic phases")
    if {video["source"] for video in report["videos"]} != ALLOWED_VIDEOS or len(report["videos"]) != 3:
        raise SystemExit("Source videos differ from the three audited isolated fixtures")
    video_pages = set()
    frame_count = 0
    for video in report["videos"]:
        if video["represented_frames"] != video["decoded_frames"] or len(video["frame_pts"]) != video["decoded_frames"]:
            raise SystemExit("Incomplete synthetic decoded-frame coverage")
        next_index = 0
        for group in video["groups"]:
            if group["start"] != next_index or group["end"] < group["start"] or group["repeat_count"] != group["end"] - group["start"] + 1:
                raise SystemExit("Synthetic frame ranges are not complete and contiguous")
            next_index = group["end"] + 1
        if next_index != video["decoded_frames"]:
            raise SystemExit("Synthetic last decoded frame is absent")
        frame_count += next_index
        pattern = re.compile(r"video-" + re.escape(slug(video["source"])) + r"-[0-9]{3}\.jpg")
        if any(not pattern.fullmatch(name) for name in video["sheets"]):
            raise SystemExit("Unexpected synthetic video-page name")
        video_pages.update(video["sheets"])
    images = report["images"]
    names = [item["file"] for item in images]
    if len(names) != len(set(names)):
        raise SystemExit("Duplicate synthetic page names")
    for item in images:
        name = item["file"]
        allowed = (
            item["kind"] == "phase-screenshots" and re.fullmatch(r"screenshots-[0-9]{3}\.jpg", name)
            or item["kind"] == "large-selected-phases" and re.fullmatch(r"large-ui-[0-9]{3}\.jpg", name)
            or item["kind"] == "all-video-frames" and name in video_pages
        )
        if not allowed or item["mime"] != "image/jpeg":
            raise SystemExit("Unexpected synthetic derivative image")
    if {item["file"] for item in images if item["kind"] == "all-video-frames"} != video_pages:
        raise SystemExit("A synthetic video contact page is absent")
    return frame_count


def emit_image(unit):
    page = unit["page"]
    encoded = base64.b64encode(page["data"]).decode("ascii")
    count = (len(encoded) + CHUNK_SIZE - 1) // CHUNK_SIZE
    metadata = "%s|mime=image/jpeg|bytes=%d|chars=%d|chunks=%d|sha256=%s|part_start=%d|part_stop=%d" % (
        page["name"], len(page["data"]), len(encoded), count,
        hashlib.sha256(page["data"]).hexdigest(), unit["start"], unit["stop"])
    print("CGEVIDENCE_BEGIN|" + metadata, flush=True)
    for index in range(unit["start"], unit["stop"]):
        print("CGEVIDENCE|%s|%06d|%s" % (
            page["name"], index, encoded[index * CHUNK_SIZE:(index + 1) * CHUNK_SIZE]), flush=True)
    print("CGEVIDENCE_END|" + metadata, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--shard-index", type=int, required=True)
    args = parser.parse_args()
    if not 0 <= args.shard_index < 32:
        parser.error("--shard-index must be 0..31")
    root = args.input.resolve()
    # This index is read ONLY for allowlist/hash/coverage validation. It and all
    # nested reports/logs are never printed, copied or otherwise exported.
    report = json.loads((root / "evidence.json").read_text())
    frame_count = validate_synthetic_index(report)
    pages = []
    for item in report["images"]:
        path = (root / item["file"]).resolve()
        if path.parent != root or not path.is_file():
            raise SystemExit("Synthetic pages must be direct files in the exact artifact")
        data = path.read_bytes()
        if len(data) != item["bytes"] or hashlib.sha256(data).hexdigest() != item["sha256"]:
            raise SystemExit("Synthetic derivative page integrity mismatch")
        # Remove the generated metadata heading; retain UI pixels and the
        # per-frame presentation-time labels necessary to inspect motion.
        with Image.open(io.BytesIO(data)) as source:
            if source.format != "JPEG" or source.width > 1800 or source.height > 5000 or source.height <= 26:
                raise SystemExit("Unexpected synthetic contact-page geometry")
            cropped = source.crop((0, 26, source.width, source.height)).convert("RGB")
            target = io.BytesIO()
            cropped.save(target, format="JPEG", quality=88, optimize=True, subsampling=0)
        pages.append({"name": "synthetic-" + item["file"], "data": target.getvalue()})
    units = []
    chunks_per_part = PART_PAYLOAD_LIMIT // CHUNK_SIZE
    for position, page in enumerate(pages):
        chars = ((len(page["data"]) + 2) // 3) * 4
        count = (chars + CHUNK_SIZE - 1) // CHUNK_SIZE
        for start in range(0, count, chunks_per_part):
            stop = min(count, start + chunks_per_part)
            weight = min(chars, stop * CHUNK_SIZE) - start * CHUNK_SIZE + (stop - start) * (len(page["name"]) + 80) + 600
            units.append({"page": page, "start": start, "stop": stop, "weight": weight, "position": position})
    buckets, loads = [[] for _ in range(32)], [0] * 32
    for unit in sorted(units, key=lambda row: (-row["weight"], row["position"], row["start"])):
        shard = min(range(32), key=lambda index: (loads[index], index))
        buckets[shard].append(unit)
        loads[shard] += unit["weight"]
    selected = sorted(buckets[args.shard_index], key=lambda row: (row["position"], row["start"]))
    print("CGSYNTH_SHARD|" + json.dumps({
        "source_sha": SOURCE_SHA, "source_run": SOURCE_RUN, "artifact": EVIDENCE_ARTIFACT,
        "index": args.shard_index, "count": 32, "synthetic_phases": 75,
        "verified_decoded_frames": frame_count, "page_count": len(pages),
        "parts": [{"file": unit["page"]["name"], "first_chunk": unit["start"], "stop_chunk": unit["stop"]} for unit in selected],
        "estimated_log_chars": loads[args.shard_index], "largest_shard_chars": max(loads),
    }, ensure_ascii=True), flush=True)
    for unit in selected:
        emit_image(unit)


if __name__ == "__main__":
    main()
