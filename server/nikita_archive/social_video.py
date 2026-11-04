"""Bounded, authenticated, temporary conversion of public social-video links."""
import concurrent.futures
import hashlib
import json
import logging
from pathlib import Path
import re
import secrets
import signal
import shutil
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit, urlunsplit

MAX_VIDEO_BYTES = 250 * 1024 * 1024
VIDEO_ERRORS = frozenset({"video_unavailable", "video_source_unavailable", "video_login_required",
    "video_rate_limited", "video_network_error", "video_timeout", "video_too_large",
    "video_unsupported_codec", "video_processing_failed", "video_dependency_missing", "insufficient_storage"})
_LOG = logging.getLogger(__name__)


class VideoFailure(Exception):
    def __init__(self, code):
        self.code = code if isinstance(code, str) and code in VIDEO_ERRORS else "video_unavailable"
        super().__init__(self.code)


def social_url(value):
    if not isinstance(value,str) or len(value)>2048 or any(ord(c)<33 for c in value):
        raise ValueError("Invalid video URL")
    url = urlsplit(value)
    if url.scheme.lower()!="https" or url.username is not None or url.password is not None or url.port not in (None,443):
        raise ValueError("A public HTTPS video link is required")
    host = (url.hostname or "").lower()
    path = url.path
    if host in {"tiktok.com","www.tiktok.com","m.tiktok.com"}:
        valid = re.fullmatch(r"(?:/@[\w.-]+/video/[0-9]+|/share/video/[0-9]+|/t/[A-Za-z0-9_]+)/?",path)
    elif host in {"vm.tiktok.com","vt.tiktok.com"}:
        valid = re.fullmatch(r"/[A-Za-z0-9]+/?",path)
    elif host in {"instagram.com","www.instagram.com","m.instagram.com"}:
        shared = re.fullmatch(r"/share/(?:reel|p)/[A-Za-z0-9_-]+/?",path)
        direct = re.fullmatch(r"/(?:[A-Za-z0-9_.]+/)?(reel|reels|p|tv)/([A-Za-z0-9_-]+)/?",path)
        valid = shared or direct
        if direct and not shared:
            kind = "reel" if direct[1] == "reels" else direct[1]
            path = f"/{kind}/{direct[2]}/"
    else:
        valid = False
    if not valid:
        raise ValueError("Only TikTok videos and Instagram video posts are supported")
    host = {"m.instagram.com":"www.instagram.com","tiktok.com":"www.tiktok.com","m.tiktok.com":"www.tiktok.com"}.get(host,host)
    return urlunsplit(("https",host,path,"",""))


class SocialVideoStore:
    def __init__(self, config):
        self.root = Path(config.get("video_path",Path(config["database_path"]).parent/"video-jobs"))
        self.root.mkdir(parents=True,exist_ok=True,mode=0o700)
        self.reserve = max(1024**3,int(config.get("media_min_free_bytes",1024**3)))
        self.jobs = {}
        self.lock = threading.RLock()
        self.executor = concurrent.futures.ThreadPoolExecutor(max_workers=1,thread_name_prefix="public-video")
        # Temporary conversions do not survive a service restart; archive files do.
        for path in self.root.iterdir():
            if path.is_dir() and re.fullmatch(r"[a-f0-9]{32}",path.name):
                shutil.rmtree(path)

    def clean(self):
        now = time.time()
        for identifier,job in list(self.jobs.items()):
            if job["state"] in ("ready","failed") and now-job["created"]>3600:
                shutil.rmtree(self.root/identifier,ignore_errors=True)
                del self.jobs[identifier]

    def create(self, value):
        url = social_url(value)
        key = hashlib.sha256(url.encode()).hexdigest()
        with self.lock:
            self.clean()
            for identifier,job in self.jobs.items():
                if job["key"]==key and job["state"]!="failed":
                    return self.status(identifier)
            if sum(j["state"] in ("queued","downloading") for j in self.jobs.values())>=3:
                raise BlockingIOError("Video queue is busy")
            if shutil.disk_usage(self.root).free < self.reserve + 2*MAX_VIDEO_BYTES:
                raise OSError("Not enough temporary disk space")
            # Bound completed cache as well as active downloads.
            ready = sorted(((j["created"],i) for i,j in self.jobs.items() if j["state"] in ("ready","failed")))
            for _,identifier in ready[:max(0,len(self.jobs)-5)]:
                shutil.rmtree(self.root/identifier,ignore_errors=True)
                del self.jobs[identifier]
            identifier = secrets.token_hex(16)
            self.jobs[identifier] = dict(key=key,state="queued",created=time.time())
            self.executor.submit(self.run,identifier,url)
            return self.status(identifier)

    def run(self, identifier, url):
        directory = self.root/identifier
        with self.lock:
            self.jobs[identifier]["state"]="downloading"
        try:
            directory.mkdir(mode=0o700)
            if shutil.disk_usage(self.root).free < self.reserve + 2*MAX_VIDEO_BYTES:
                raise VideoFailure("insufficient_storage")
            result = subprocess.run([sys.executable,"-m","nikita_archive.video_worker",url,str(directory)],
                                    stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,
                                    timeout=180,check=False)
            if result.returncode:
                code = "video_unavailable"
                error_path = directory/"error.json"
                if error_path.is_file() and error_path.stat().st_size <= 1024:
                    try:
                        code = json.loads(error_path.read_text()).get("error", code)
                    except (ValueError, TypeError, OSError, AttributeError):
                        pass
                if result.returncode == -signal.SIGXFSZ:
                    code = "video_too_large"
                elif result.returncode == -signal.SIGXCPU:
                    code = "video_timeout"
                raise VideoFailure(code)
            metadata = json.loads((directory/"result.json").read_text())
            path = directory/"video.mp4"
            if not path.is_file() or not 0<path.stat().st_size<=MAX_VIDEO_BYTES:
                raise ValueError("Invalid video result")
            with self.lock:
                self.jobs[identifier].update(state="ready",size=path.stat().st_size,
                    duration=metadata["duration"],width=metadata["width"],height=metadata["height"])
        except Exception as error:
            code = error.code if isinstance(error, VideoFailure) else "video_timeout" if isinstance(error, subprocess.TimeoutExpired) else "video_unavailable"
            shutil.rmtree(directory,ignore_errors=True)
            with self.lock:
                self.jobs[identifier].update(state="failed",error=code)
            _LOG.warning("Public video preparation failed: %s", code)

    def status(self, identifier):
        if not re.fullmatch(r"[a-f0-9]{32}",identifier):
            raise ValueError("Invalid job")
        with self.lock:
            job = self.jobs.get(identifier)
            if not job:
                raise KeyError(identifier)
            return {"job_id":identifier,**{k:v for k,v in job.items() if k in ("state","size","duration","width","height","error")}}

    def ready(self, identifier):
        value = self.status(identifier)
        if value["state"]!="ready":
            raise BlockingIOError("Video is not ready")
        return self.root/identifier/"video.mp4",value

    def close(self):
        self.executor.shutdown(wait=False,cancel_futures=True)

