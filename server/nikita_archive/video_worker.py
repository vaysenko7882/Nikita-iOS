"""Isolated public-only downloader. Never receives Telegram credentials or cookies."""
import errno
import ipaddress
import json
import math
import os
from pathlib import Path
import resource
import shutil
import socket
import subprocess
import sys
from urllib.parse import urlsplit
from .social_video import MAX_VIDEO_BYTES, VideoFailure, social_url

VIDEO_FORMAT = ("best[ext=mp4][protocol=https][vcodec~='^(avc1|h264)']/"
                "bestvideo[ext=mp4][protocol=https][vcodec~='^(avc1|h264)']+bestaudio[ext=m4a][protocol=https]/"
                "best[ext=mp4][protocol=https]")


def public_addresses(host, port, *args, **kwargs):
    addresses = _getaddrinfo(host,port,*args,**kwargs)
    if not addresses or any(not ipaddress.ip_address(item[4][0]).is_global for item in addresses):
        raise OSError("Private network destinations are not allowed")
    return addresses


_getaddrinfo = socket.getaddrinfo


def failure_code(error):
    """Reduce dependency/network exceptions to a fixed public vocabulary, never raw text."""
    pending, seen, messages, statuses = [error], set(), [], []
    while pending and len(seen) < 12:
        current = pending.pop()
        if not isinstance(current, BaseException) or id(current) in seen:
            continue
        seen.add(id(current))
        if isinstance(current, VideoFailure):
            return current.code
        if isinstance(current, ImportError):
            return "video_dependency_missing"
        if isinstance(current, OSError) and current.errno == errno.ENOSPC:
            return "insufficient_storage"
        if isinstance(current, (TimeoutError, subprocess.TimeoutExpired)):
            return "video_timeout"
        status = getattr(current, "status", None) or getattr(current, "code", None)
        if isinstance(status, int):
            statuses.append(status)
        messages.append(str(current).lower())
        pending.extend([getattr(current, "cause", None), current.__cause__, current.__context__])
        info = getattr(current, "exc_info", None)
        if isinstance(info, tuple) and len(info) > 1:
            pending.append(info[1])
    message = " ".join(messages)
    if 429 in statuses or any(text in message for text in ("http error 429", "rate limit", "rate-limit", "too many requests")):
        return "video_rate_limited"
    if 401 in statuses or any(text in message for text in ("login required", "log in", "sign in", "login page", "cookies", "private video", "private account")):
        return "video_login_required"
    if any(text in message for text in ("timed out", "timeout")):
        return "video_timeout"
    if any(text in message for text in ("requested format is not available", "no video formats", "unsupported codec")):
        return "video_unsupported_codec"
    if any(text in message for text in ("max-filesize", "max_filesize", "larger than max", "file too large")):
        return "video_too_large"
    if any(status in statuses for status in (403, 404, 410, 451)) or any(text in message for text in ("video unavailable", "not available", "no video in", "empty media response", "not found", "not accessible", "blocked")):
        return "video_source_unavailable"
    if any(isinstance(item, OSError) for item in (error, getattr(error, "cause", None))) or any(text in message for text in ("connection", "resolve", "network", "http error 5", "certificate verify")):
        return "video_network_error"
    return "video_unavailable"


def resolved_url(downloader, url):
    # Instagram's Share button can return a redirect route, not a post shortcode.
    # Resolve it through the same DNS-guarded Python transport as extraction.
    if urlsplit(url).path.startswith("/share/") and "instagram.com" == (urlsplit(url).hostname or "").removeprefix("www."):
        with downloader.urlopen(url) as response:
            target = response.url
        if urlsplit(target).path.startswith("/accounts/login"):
            raise VideoFailure("video_login_required")
        try:
            target = social_url(target)
        except ValueError:
            raise VideoFailure("video_source_unavailable") from None
        if urlsplit(target).path.startswith("/share/"):
            raise VideoFailure("video_source_unavailable")
        return target
    return url


def download_video(url, directory):
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        raise VideoFailure("video_dependency_missing")
    from yt_dlp import YoutubeDL
    from yt_dlp.globals import plugin_dirs
    plugin_dirs.value = []
    sizes = {}
    def progress(value):
        sizes[value.get("filename", "")] = int(value.get("downloaded_bytes") or 0)
        if sum(sizes.values()) > MAX_VIDEO_BYTES:
            raise VideoFailure("video_too_large")
    def match_filter(info, *, incomplete=False):
        if (info.get("filesize") or info.get("filesize_approx") or 0) > MAX_VIDEO_BYTES:
            raise VideoFailure("video_too_large")
    options = dict(quiet=True,no_warnings=True,noplaylist=True,playlistend=1,
                   cachedir=False,usenetrc=False,proxy="",enable_file_urls=False,
                   socket_timeout=15,retries=2,fragment_retries=1,
                   max_filesize=MAX_VIDEO_BYTES,concurrent_fragment_downloads=1,
                   outtmpl=str(directory/"download.%(ext)s"),
                   format=VIDEO_FORMAT,
                   merge_output_format="mp4", progress_hooks=[progress], match_filter=match_filter,
                   # Merging separate HTTPS video/audio tracks must only open local files.
                   postprocessor_args={"ffmpeg_i":["-protocol_whitelist","file,pipe"]},
                   allowed_extractors=["TikTok",r"vm\.tiktok","Instagram"],
                   noprogress=True,overwrites=False)
    try:
        with YoutubeDL(options) as downloader:
            result = downloader.extract_info(resolved_url(downloader, url),download=True)
            if result and result.get("entries"):
                result = next((entry for entry in result["entries"] if entry), None)
            if not result:
                raise VideoFailure("video_source_unavailable")
            # requested_downloads carries the postprocessor's final merged path.
            completed = result.get("requested_downloads") or []
            output = completed[0].get("filepath") if completed else None
            try:
                path = Path(output or downloader.prepare_filename(result)).resolve(strict=True)
            except (TypeError, OSError):
                raise VideoFailure("video_processing_failed") from None
    except Exception as error:
        raise VideoFailure(failure_code(error)) from None
    if path.parent!=directory or not 0<path.stat().st_size<=MAX_VIDEO_BYTES:
        raise VideoFailure("video_too_large" if path.stat().st_size>MAX_VIDEO_BYTES else "video_processing_failed")
    try:
        probe = subprocess.run(["ffprobe","-v","error","-protocol_whitelist","file,pipe","-show_streams","-show_format","-of","json",str(path)],capture_output=True,timeout=20,check=True)
        metadata = json.loads(probe.stdout)
        video = next(s for s in metadata["streams"] if s.get("codec_type")=="video")
        duration = float(metadata.get("format",{}).get("duration",0))
        if not math.isfinite(duration) or not 0<duration<=3600 or video.get("codec_name")!="h264":
            raise VideoFailure("video_unsupported_codec")
        # Remux only; no CPU-heavy video re-encoding. Enable progressive iPhone playback.
        target = directory/"video.mp4"
        subprocess.run(["ffmpeg","-nostdin","-v","error","-protocol_whitelist","file,pipe","-i",str(path),
                        "-map","0:v:0","-map","0:a:0?","-c","copy","-movflags","+faststart",str(target)],capture_output=True,timeout=40,check=True)
        path.unlink()
        (directory/"result.json").write_text(json.dumps(dict(duration=duration,width=int(video["width"]),height=int(video["height"]))))
    except VideoFailure:
        raise
    except (TimeoutError, subprocess.TimeoutExpired):
        raise VideoFailure("video_timeout") from None
    except OSError as error:
        raise VideoFailure("insufficient_storage" if error.errno == errno.ENOSPC else "video_processing_failed") from None
    except Exception:
        raise VideoFailure("video_processing_failed") from None


def main():
    directory = Path(sys.argv[2]).resolve(strict=True)
    os.umask(0o077)
    resource.setrlimit(resource.RLIMIT_CPU,(150,150))
    resource.setrlimit(resource.RLIMIT_FSIZE,(MAX_VIDEO_BYTES+1024*1024,MAX_VIDEO_BYTES+1024*1024))
    resource.setrlimit(resource.RLIMIT_NOFILE,(128,128))
    # Validate every resolved destination, including redirects and CDNs. Connections
    # use these exact resolved addresses, so a DNS rebind cannot reach local services.
    socket.getaddrinfo = public_addresses
    for key in list(os.environ):
        if key.lower().endswith("_proxy"):
            os.environ.pop(key,None)
    try:
        download_video(social_url(sys.argv[1]), directory)
    except Exception as error:
        (directory/"error.json").write_text(json.dumps({"error":failure_code(error)}))
        raise SystemExit(1) from None


if __name__=="__main__":
    main()

