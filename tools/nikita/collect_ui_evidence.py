#!/usr/bin/env python3
"""Turn native UI artifacts into complete, log-readable visual evidence.

Video frames are never sampled. Exact consecutive decoded-frame duplicates may
share one tile; each tile records its full original index/PTS range. ffprobe
supplies presentation timestamps. ffmpeg's timestamps are not used for labels.
"""
import argparse
import base64
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import textwrap

from PIL import Image, ImageDraw, ImageFont, ImageOps

IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg"}
VIDEO_EXTENSIONS = {".mp4", ".mov", ".m4v", ".mkv", ".webm"}
LARGE_PHASES = re.compile(r"icon|appearance|privacy|voice|search|dashboard|material|modern|status|video|input|text-entry|media-actions|navigation|dialog|surface|group", re.I)
REPORT_NAMES = {"result.json", "report.json", "runtime-progress.json", "timeline.json"}
BUNDLE_SUFFIXES = (".app", ".appex", ".framework", ".bundle", ".dsym")
CHUNK_SIZE = 4000


def run(command, timeout=1200):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, timeout=timeout, check=False)
    if result.returncode:
        raise RuntimeError("Command failed: " + command[0] + "\n" + result.stderr[-4000:])
    return result.stdout


def is_bundle_member(relative):
    return any(part.lower().endswith(BUNDLE_SUFFIXES) for part in relative.parts)


def slug(relative):
    clean = re.sub(r"[^A-Za-z0-9_.-]+", "-", relative.as_posix()).strip("-")
    return clean[:110] + "-" + hashlib.sha256(relative.as_posix().encode()).hexdigest()[:8]


def font(size=11):
    for path in ("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
        if Path(path).is_file():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def image_record(path, output, kind, **details):
    data = path.read_bytes()
    return {"file": path.relative_to(output).as_posix(), "mime": "image/jpeg",
            "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "kind": kind, **details}


def sheets(entries, output, prefix, tile_width, columns, page_size, kind):
    """Entries contain image path and label, and optional original-frame range."""
    generated = []
    for page_start in range(0, len(entries), page_size):
        page = entries[page_start:page_start + page_size]
        thumbnails = []
        for entry in page:
            with Image.open(entry["path"]) as source:
                image = ImageOps.exif_transpose(source).convert("RGB")
                height = max(1, round(image.height * tile_width / image.width))
                thumbnails.append(image.resize((tile_width, height), Image.Resampling.LANCZOS))
        if not thumbnails:
            continue
        gap, label_height, heading_height = 6, 48, 26
        tile_height = max(image.height for image in thumbnails)
        row_count = math.ceil(len(page) / columns)
        canvas = Image.new("RGB", (gap + columns * (tile_width + gap),
                           heading_height + gap + row_count * (label_height + tile_height + gap)),
                           (20, 21, 24))
        draw = ImageDraw.Draw(canvas)
        draw.text((gap, 5), prefix + " / page " + str(page_start // page_size + 1),
                  font=font(12), fill=(244, 244, 247))
        for index, (entry, image) in enumerate(zip(page, thumbnails)):
            x = gap + (index % columns) * (tile_width + gap)
            y = heading_height + gap + (index // columns) * (label_height + tile_height + gap)
            lines = []
            for line in entry["label"].splitlines():
                lines.extend(textwrap.wrap(line, width=max(18, tile_width // 7), break_long_words=True) or [""])
            draw.multiline_text((x + 2, y + 2), "\n".join(lines[:3]),
                                font=font(), fill=(239, 239, 244), spacing=1)
            canvas.paste(image, (x, y + label_height))
        target = output / (prefix + "-%03d.jpg" % (page_start // page_size + 1))
        target.parent.mkdir(parents=True, exist_ok=True)
        canvas.save(target, quality=88, optimize=True, subsampling=0)
        generated.append(image_record(target, output, kind, entries=len(page),
                         entry_start=page_start, tile_width=tile_width,
                         labels=[entry["label"] for entry in page]))
    return generated


def frame_metadata(video):
    raw = json.loads(run(["ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_frames", "-show_entries",
        "frame=best_effort_timestamp_time,pts_time,width,height", "-of", "json", str(video)]))
    frames = raw.get("frames", [])
    if not frames:
        raise ValueError("No video frames found")
    times = [row.get("best_effort_timestamp_time", row.get("pts_time")) for row in frames]
    if any(value is None or value == "N/A" for value in times):
        raise ValueError("A decoded frame has no ffprobe presentation timestamp")
    for value in times:
        float(value)
    return frames, times


def video_evidence(video, relative, output, tile_width):
    identifier = slug(relative)
    probe, times = frame_metadata(video)
    with tempfile.TemporaryDirectory(prefix="codegram-ui-frames-") as scratch:
        scratch = Path(scratch)
        decoded = scratch / "frames"
        decoded.mkdir()
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
             "-i", str(video), "-map", "0:v:0", "-an", "-vf",
             "scale=%d:-2:flags=area" % tile_width, "-fps_mode", "passthrough",
             "-start_number", "0", str(decoded / "%08d.png")])
        # Hash the original decoded pixels BEFORE resizing. Two thumbnails
        # looking alike is not sufficient to merge changing original frames.
        raw_hashes = scratch / "decoded-framehash.txt"
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
             "-i", str(video), "-map", "0:v:0", "-an", "-c:v", "rawvideo",
             "-fps_mode", "passthrough", "-f", "framehash", "-hash", "sha256", str(raw_hashes)])
        hashes = [line.rsplit(",", 1)[-1].strip()
                  for line in raw_hashes.read_text().splitlines()
                  if line.strip() and not line.startswith("#")]
        images = sorted(decoded.glob("*.png"))
        if len(images) != len(times) or len(hashes) != len(times):
            raise ValueError("Decoded/probed/hashed frame counts differ: %d/%d/%d" %
                             (len(images), len(times), len(hashes)))
        groups = []
        for index, (path, digest) in enumerate(zip(images, hashes)):
            if not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
                raise ValueError("Invalid full-resolution decoded-frame hash")
            if groups and groups[-1]["decoded_sha256"] == digest:
                groups[-1]["end"] = index
                groups[-1]["pts_end"] = times[index]
                groups[-1]["repeat_count"] += 1
            else:
                groups.append({"start": index, "end": index, "pts_start": times[index],
                               "pts_end": times[index], "repeat_count": 1,
                               "decoded_sha256": digest, "path": str(path)})
        if sum(group["repeat_count"] for group in groups) != len(times):
            raise AssertionError("Not every original frame is represented")
        entries = []
        for group in groups:
            start, end = group["start"], group["end"]
            delta = (float(times[start]) - float(times[start - 1])) * 1000 if start else 0
            label = "#%d" % start if start == end else "#%d-%d x%d" % (start, end, group["repeat_count"])
            label += "\nt=%.3f" % float(times[start])
            if start != end:
                label += "..%.3f" % float(times[end])
            label += "  dt=%+.1fms" % delta
            entries.append({"path": Path(group["path"]), "label": label})
        pages = sheets(entries, output, "video-" + identifier, tile_width, 8, 32, "all-video-frames")
        copied_hashes = output / ("video-" + identifier + "-framehash.txt")
        shutil.copyfile(raw_hashes, copied_hashes)
        for group in groups:
            group.pop("path")
        report = {"source": relative.as_posix(), "width": probe[0].get("width"),
                  "height": probe[0].get("height"), "decoded_frames": len(times),
                  "represented_frames": sum(group["repeat_count"] for group in groups),
                  "tiles": len(groups), "exact_consecutive_duplicates": len(times) - len(groups),
                  "timestamp_source": "ffprobe best_effort_timestamp_time/pts_time",
                  "first_pts": times[0], "last_pts": times[-1],
                  "frame_pts": times, "groups": groups,
                  "full_resolution_hashes": copied_hashes.name,
                  "sheets": [page["file"] for page in pages]}
        return report, pages


def emit_file(path, relative, mime):
    data = path.read_bytes()
    encoded = base64.b64encode(data).decode("ascii")
    digest = hashlib.sha256(data).hexdigest()
    count = math.ceil(len(encoded) / CHUNK_SIZE)
    metadata = "%s|mime=%s|bytes=%d|chars=%d|chunks=%d|sha256=%s" % (
        relative, mime, len(data), len(encoded), count, digest)
    print("CGEVIDENCE_BEGIN|" + metadata, flush=True)
    for index in range(count):
        print("CGEVIDENCE|%s|%06d|%s" % (
            relative, index, encoded[index * CHUNK_SIZE:(index + 1) * CHUNK_SIZE]), flush=True)
    print("CGEVIDENCE_END|" + metadata, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tile-width", type=int, default=180)
    parser.add_argument("--emit-chunks", action="store_true")
    args = parser.parse_args()
    if not 80 <= args.tile_width <= 200:
        parser.error("--tile-width must be 80..200")
    source, output = args.input.resolve(), args.output.resolve()
    if source == output or source in output.parents:
        parser.error("--output must be outside the downloaded artifact tree")
    output.mkdir(parents=True, exist_ok=True)
    files = sorted(path for path in source.rglob("*") if path.is_file() and
                   not is_bundle_member(path.relative_to(source)))
    screenshots = [path for path in files if path.suffix.lower() in IMAGE_EXTENSIONS]
    videos = [path for path in files if path.suffix.lower() in VIDEO_EXTENSIONS]
    report = {"format": "CodeGram UI visual evidence v1", "input": str(source),
              "screenshots": [], "videos": [], "reports": {}, "expected_frames": {},
              "images": [], "errors": [], "native_job_results": {}}
    native_results = __import__("os").environ.get("CODEGRAM_NATIVE_JOB_RESULTS")
    if native_results:
        try:
            report["native_job_results"] = json.loads(native_results)
        except ValueError:
            report["errors"].append("CODEGRAM_NATIVE_JOB_RESULTS is not JSON")
    entries = []
    for path in screenshots:
        relative = path.relative_to(source)
        try:
            with Image.open(path) as image:
                image.verify()
            entries.append({"path": path, "label": relative.as_posix()})
            report["screenshots"].append(relative.as_posix())
        except Exception as error:
            report["errors"].append(relative.as_posix() + ": " + str(error))
    report["images"].extend(sheets(entries, output, "screenshots", args.tile_width, 8, 32, "phase-screenshots"))
    large = [entry for entry in entries if LARGE_PHASES.search(entry["label"])]
    report["images"].extend(sheets(large, output, "large-ui", 360, 3, 6, "large-selected-phases"))
    for path in files:
        relative = path.relative_to(source).as_posix()
        if path.name in REPORT_NAMES or (path.suffix == ".json" and re.search(r"result|report|timeline", path.name, re.I)):
            try:
                report["reports"][relative] = json.loads(path.read_text())
            except Exception as error:
                report["errors"].append(relative + ": " + str(error))
        elif path.name == "expected-frames.txt":
            report["expected_frames"][relative] = path.read_text()[:32768]
    for path in videos:
        relative = path.relative_to(source)
        try:
            video, images = video_evidence(path, relative, output, args.tile_width)
            report["videos"].append(video)
            report["images"].extend(images)
        except Exception as error:
            report["errors"].append(relative.as_posix() + ": " + str(error))
    expected_artifacts = {
        "native-history": "CodeGram-history-UI-",
        "native-settings": "CodeGram-native-UI-",
        "native-material": "CodeGram-modern-material-",
        "native-video-status": "CodeGram-video-status-",
    }
    report["job_video_coverage"] = {}
    for job, prefix in expected_artifacts.items():
        covered = [video["source"] for video in report["videos"]
                   if any(part.startswith(prefix) for part in Path(video["source"]).parts)]
        report["job_video_coverage"][job] = covered
        if job in report["native_job_results"] and not covered:
            report["errors"].append("No decodable source video retained for " + job)
    if not videos:
        report["errors"].append("No source videos were retained by the native jobs")
    if not screenshots:
        report["errors"].append("No phase screenshots were retained by the native jobs")
    report["complete"] = not report["errors"]
    index = output / "evidence.json"
    index.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print("CGEVIDENCE_SUMMARY|" + json.dumps({
        "complete": report["complete"], "screenshots": len(report["screenshots"]),
        "videos": len(report["videos"]), "decoded_frames": sum(v["decoded_frames"] for v in report["videos"]),
        "represented_frames": sum(v["represented_frames"] for v in report["videos"]),
        "image_pages": len(report["images"]), "errors": report["errors"],
        "native_job_results": report["native_job_results"]}, ensure_ascii=True), flush=True)
    if args.emit_chunks:
        emit_file(index, index.name, "application/json")
        for item in report["images"]:
            emit_file(output / item["file"], item["file"], item["mime"])
    if report["errors"]:
        raise SystemExit("Visual evidence is incomplete; inspect evidence.json and retained source artifacts")


if __name__ == "__main__":
    main()
