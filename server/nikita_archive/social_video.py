"""Bounded, authenticated, temporary conversion of public social-video links."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit, urlunsplit

MAX_VIDEO_BYTES = 250 * 1024 * 1024


def social_url(value):
    if not isinstance(value,str) or len(value)>2048 or any(ord(c)<33 for c in value):
        raise ValueError("Invalid video URL")
    url = urlsplit(value)
    if url.scheme.lower()!="https" or url.username is not None or url.password is not None or url.port not in (None,443):
        raise ValueError("A public HTTPS video link is required")
    host = (url.hostname or "").lower()
    if host in {"tiktok.com","www.tiktok.com","m.tiktok.com"}:
        valid = re.fullmatch(r"(?:/@[A-Za-z0-9_.-]+/video/[0-9]+|/t/[A-Za-z0-9_]+)/?",url.path)
    elif host in {"vm.tiktok.com","vt.tiktok.com"}:
        valid = re.fullmatch(r"/[A-Za-z0-9]+/?",url.path)
    elif host in {"instagram.com","www.instagram.com","m.instagram.com"}:
        valid = re.fullmatch(r"/(?:reel|reels|p|tv)/[A-Za-z0-9_-]+/?",url.path)
    else:
        valid = False
    if not valid:
        raise ValueError("Only TikTok videos and Instagram video posts are supported")
    host = {"m.instagram.com":"www.instagram.com","tiktok.com":"www.tiktok.com","m.tiktok.com":"www.tiktok.com"}.get(host,host)
    return urlunsplit(("https",host,url.path,"",""))


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
        directory.mkdir(mode=0o700)
        with self.lock:
            self.jobs[identifier]["state"]="downloading"
        try:
            if shutil.disk_usage(self.root).free < self.reserve + 2*MAX_VIDEO_BYTES:
                raise OSError("Not enough temporary disk space")
            result = subprocess.run([sys.executable,"-m","nikita_archive.video_worker",url,str(directory)],
                                    stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,
                                    timeout=180,check=False)
            if result.returncode:
                raise RuntimeError("Video unavailable")
            metadata = json.loads((directory/"result.json").read_text())
            path = directory/"video.mp4"
            if not path.is_file() or not 0<path.stat().st_size<=MAX_VIDEO_BYTES:
                raise ValueError("Invalid video result")
            with self.lock:
                self.jobs[identifier].update(state="ready",size=path.stat().st_size,
                    duration=metadata["duration"],width=metadata["width"],height=metadata["height"])
        except Exception:
            shutil.rmtree(directory,ignore_errors=True)
            with self.lock:
                self.jobs[identifier].update(state="failed",error="video_unavailable")

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
