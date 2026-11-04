"""Bounded, authenticated, temporary conversion of public social-video links."""
import concurrent.futures
import errno
import hashlib
import importlib.metadata
import json
import logging
import math
import os
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
    "video_unsupported_codec", "video_processing_failed", "video_dependency_missing", "insufficient_storage",
    "video_dns_error", "video_worker_failed", "video_worker_killed", "video_invalid_result",
    "video_unsupported_link", "video_extraction_failed"})
VIDEO_STAGES = frozenset({"prepare", "resolve", "extract", "download", "probe", "remux", "worker_start", "worker"})
MAX_DIAGNOSTIC_BYTES = 64 * 1024
_LOG = logging.getLogger(__name__)


class VideoFailure(Exception):
    def __init__(self, code, stage="", exception_type=""):
        self.code = code if isinstance(code, str) and code in VIDEO_ERRORS else "video_unavailable"
        self.stage = stage if isinstance(stage, str) and stage in VIDEO_STAGES else ""
        self.exception_type = exception_type if isinstance(exception_type, str) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,63}", exception_type) else ""
        super().__init__(self.code)


def run_worker(args, timeout=180):
    """Drain stderr while retaining a bounded diagnostic; never return it to HTTP."""
    diagnostic = bytearray()
    grouped = os.name=="posix"
    with subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                          stderr=subprocess.PIPE, bufsize=0, start_new_session=grouped) as process:
        def terminate_group():
            try:
                if grouped:
                    os.killpg(process.pid,signal.SIGKILL)
                elif process.poll() is None:
                    process.kill()
            except ProcessLookupError:
                pass
        def drain():
            try:
                while True:
                    chunk = process.stderr.read(8192)
                    if not chunk:
                        break
                    diagnostic.extend(chunk[:max(0,MAX_DIAGNOSTIC_BYTES-len(diagnostic))])
            except (OSError, ValueError):
                pass
        reader = threading.Thread(target=drain,daemon=True)
        reader.start()
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            terminate_group()
            process.wait()
            raise
        finally:
            # A failed worker can exit before ffmpeg. Clean up its dedicated
            # group on every exit, before joining the stderr reader or closing
            # its pipe. Preserve the leader's return code and written result.
            terminate_group()
            reader.join(timeout=1)
        return subprocess.CompletedProcess(args,process.returncode,stderr=bytes(diagnostic))


def worker_failure(result, directory):
    """Prefer the worker's typed result; classify startup failures separately."""
    value = None
    error_path = directory/"error.json"
    if error_path.is_file() and error_path.stat().st_size <= 1024:
        try:
            candidate = json.loads(error_path.read_text())
            if isinstance(candidate,dict) and candidate.get("error") in VIDEO_ERRORS:
                value = VideoFailure(candidate["error"],candidate.get("stage",""),candidate.get("exception_type",""))
        except (ValueError, TypeError, OSError, AttributeError):
            pass
    if result.returncode == -signal.SIGXFSZ:
        return VideoFailure("video_too_large","worker")
    if result.returncode == -signal.SIGXCPU:
        return VideoFailure("video_timeout","worker")
    if result.returncode < 0:
        return VideoFailure("video_worker_killed","worker")
    if value is not None:
        return value
    diagnostic = (getattr(result,"stderr",b"") or b"")[:MAX_DIAGNOSTIC_BYTES]
    if isinstance(diagnostic,bytes):
        diagnostic = diagnostic.decode("utf-8",errors="replace")
    if "ModuleNotFoundError" in diagnostic or "ImportError" in diagnostic:
        return VideoFailure("video_dependency_missing","worker_start","ImportError")
    # Without a typed result the process may have failed after startup as well.
    return VideoFailure("video_worker_failed","worker")


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
        try:
            self.service_version = importlib.metadata.version("nikita-archive")[:64]
        except importlib.metadata.PackageNotFoundError:
            self.service_version = "development"
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
        stage = "prepare"
        with self.lock:
            self.jobs[identifier]["state"]="downloading"
        try:
            directory.mkdir(mode=0o700)
            if shutil.disk_usage(self.root).free < self.reserve + 2*MAX_VIDEO_BYTES:
                raise VideoFailure("insufficient_storage")
            stage = "worker_start"
            result = run_worker([sys.executable,"-m","nikita_archive.video_worker",url,str(directory)],timeout=180)
            with self.lock:
                self.jobs[identifier]["worker_exit_code"] = int(result.returncode)
            stage = "worker"
            if result.returncode:
                raise worker_failure(result,directory)
            metadata_path = directory/"result.json"
            if not metadata_path.is_file() or metadata_path.stat().st_size>4096:
                raise VideoFailure("video_invalid_result","worker")
            metadata = json.loads(metadata_path.read_text())
            path = directory/"video.mp4"
            duration = metadata.get("duration") if isinstance(metadata,dict) else None
            dimensions = [metadata.get(k) for k in ("width","height")] if isinstance(metadata,dict) else []
            if (not path.is_file() or not 0<path.stat().st_size<=MAX_VIDEO_BYTES or
                    isinstance(duration,bool) or not isinstance(duration,(int,float)) or
                    not math.isfinite(duration) or not 0<duration<=3600 or
                    len(dimensions)!=2 or any(isinstance(v,bool) or not isinstance(v,int) or v<=0 for v in dimensions)):
                raise VideoFailure("video_invalid_result","worker")
            with self.lock:
                self.jobs[identifier].update(state="ready",size=path.stat().st_size,
                    duration=metadata["duration"],width=metadata["width"],height=metadata["height"])
        except Exception as error:
            if isinstance(error,VideoFailure):
                failure = error
            elif isinstance(error,subprocess.TimeoutExpired):
                failure = VideoFailure("video_timeout","worker")
            elif isinstance(error,OSError) and error.errno==errno.ENOSPC:
                failure = VideoFailure("insufficient_storage",stage,type(error).__name__)
            elif stage=="worker_start" and isinstance(error,(FileNotFoundError,PermissionError)):
                failure = VideoFailure("video_dependency_missing","worker_start",type(error).__name__)
            else:
                failure = VideoFailure("video_invalid_result" if stage=="worker" else "video_worker_failed",stage,type(error).__name__)
            shutil.rmtree(directory,ignore_errors=True)
            with self.lock:
                self.jobs[identifier].update(state="failed",error=failure.code,error_stage=failure.stage,
                    exception_type=failure.exception_type)
            _LOG.warning("Public video preparation failed: code=%s stage=%s exit=%s type=%s service=%s",
                         failure.code,failure.stage,self.jobs[identifier].get("worker_exit_code"),failure.exception_type,self.service_version)

    def status(self, identifier):
        if not re.fullmatch(r"[a-f0-9]{32}",identifier):
            raise ValueError("Invalid job")
        with self.lock:
            job = self.jobs.get(identifier)
            if not job:
                raise KeyError(identifier)
            return {"job_id":identifier,"service_version":self.service_version,
                    **{k:v for k,v in job.items() if k in ("state","size","duration","width","height","error","error_stage","worker_exit_code","exception_type")}}

    def ready(self, identifier):
        value = self.status(identifier)
        if value["state"]!="ready":
            raise BlockingIOError("Video is not ready")
        return self.root/identifier/"video.mp4",value

    def close(self):
        self.executor.shutdown(wait=False,cancel_futures=True)

