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
import sqlite3
import tempfile
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


def social_cache_key(value):
    """Share identifiers across harmless host, username and post-route variants."""
    normalized = social_url(value)
    parsed = urlsplit(normalized)
    host = parsed.hostname or ""
    identity = normalized
    if host.endswith("tiktok.com"):
        match = re.fullmatch(r"/(?:@[\w.-]+/video|share/video)/([0-9]+)/?", parsed.path)
        if match:
            identity = "tiktok-video:" + match[1]
    elif host.endswith("instagram.com"):
        match = re.fullmatch(r"/(?:reel|p|tv)/([A-Za-z0-9_-]+)/?", parsed.path)
        if match:
            identity = "instagram-post:" + match[1]
    return hashlib.sha256(identity.encode()).hexdigest()


class SocialVideoStore:
    def __init__(self, config):
        self.database_path = Path(config["database_path"]).resolve()
        self.root = Path(config.get("video_path",self.database_path.parent/"video-jobs"))
        self.root.mkdir(parents=True,exist_ok=True,mode=0o700)
        self.reserve = max(1024**3,int(config.get("media_min_free_bytes",1024**3)))
        self.cache_ttl = max(3600,min(30*86400,int(config.get("video_cache_ttl_seconds",7*86400))))
        self.cache_bytes = max(MAX_VIDEO_BYTES,min(8*1024**3,int(config.get("video_cache_max_bytes",1024**3))))
        self.cache_count = max(4,min(128,int(config.get("video_cache_max_entries",32))))
        self.workers = max(1,min(2,int(config.get("video_workers",2))))
        self.jobs = {}
        self.scope = self._read_scope()
        try:
            self.service_version = importlib.metadata.version("nikita-archive")[:64]
        except importlib.metadata.PackageNotFoundError:
            self.service_version = "development"
        self.lock = threading.RLock()
        self.executor = concurrent.futures.ThreadPoolExecutor(max_workers=self.workers,thread_name_prefix="public-video")
        self._load_cache()
        # Retain only verified complete cache entries; interrupted downloads are temporary.
        for path in self.root.iterdir():
            if path.is_dir() and re.fullmatch(r"[a-f0-9]{32}",path.name) and path.name not in self.jobs:
                shutil.rmtree(path,ignore_errors=True)

    def _read_scope(self):
        if not self.database_path.is_file():
            return None
        db = None
        try:
            db = sqlite3.connect(self.database_path.as_uri()+"?mode=ro",uri=True,timeout=1)
            values = dict(db.execute("SELECT key,value FROM meta WHERE key IN ('account_id','server_id')"))
            account = int(values.get("account_id","0"))
            epoch = values.get("server_id","")
            if account > 0 and isinstance(epoch,str) and 0 < len(epoch) <= 128:
                return {"account_id":account,"server_id":epoch}
        except (OSError,sqlite3.Error,TypeError,ValueError):
            pass
        finally:
            if db is not None:
                db.close()
        return None

    def _refresh_scope(self):
        current = self._read_scope()
        if current != self.scope:
            if self.scope is not None:
                for identifier in self.jobs:
                    shutil.rmtree(self.root/identifier,ignore_errors=True)
                self.jobs.clear()
            self.scope = current
            # The account may be activated after the service starts. HTTP never
            # creates a video job before activation; adopt only this initial scope.
            for job in self.jobs.values():
                job["scope"] = current

    def _valid_file(self, identifier, job):
        path = self.root/identifier/"video.mp4"
        try:
            stat = path.stat()
            return (not (self.root/identifier).is_symlink() and not path.is_symlink()
                    and path.is_file() and 0 < stat.st_size <= MAX_VIDEO_BYTES
                    and stat.st_size == job.get("size")
                    and ("file_mtime_ns" not in job or stat.st_mtime_ns == job["file_mtime_ns"]))
        except OSError:
            return False

    def _load_cache(self):
        manifest = self.root/"cache.json"
        try:
            if self.scope is None or not manifest.is_file() or manifest.stat().st_size > 512*1024:
                return
            value = json.loads(manifest.read_text())
            if not isinstance(value,dict) or value.get("version") != 1 or value.get("scope") != self.scope:
                return
            jobs = value.get("jobs")
            if not isinstance(jobs,dict) or len(jobs) > 128:
                return
            for identifier,job in jobs.items():
                if not isinstance(identifier,str) or not re.fullmatch(r"[a-f0-9]{32}",identifier) or not isinstance(job,dict):
                    continue
                duration = job.get("duration")
                if (job.get("state") != "ready" or not isinstance(job.get("key"),str)
                        or not re.fullmatch(r"[a-f0-9]{64}",job["key"])
                        or isinstance(duration,bool) or not isinstance(duration,(int,float))
                        or not math.isfinite(duration) or not 0 < duration <= 3600
                        or any(isinstance(job.get(k),bool) or not isinstance(job.get(k),int)
                               or job[k] <= 0 for k in ("width","height"))
                        or any(isinstance(job.get(k),bool) or not isinstance(job.get(k),(int,float))
                               or not math.isfinite(job[k]) for k in ("created","last_access"))
                        or not self._valid_file(identifier,job)):
                    continue
                aliases = job.get("aliases",[])
                if not isinstance(aliases,list) or len(aliases) > 16:
                    continue
                if any(not isinstance(key,str) or not re.fullmatch(r"[a-f0-9]{64}",key) for key in aliases):
                    continue
                allowed = ("key","aliases","state","created","last_access","size","duration","width","height","file_mtime_ns")
                self.jobs[identifier] = {k:job[k] for k in allowed if k in job}
                self.jobs[identifier]["scope"] = self.scope
            self.clean()
        except (OSError,ValueError,TypeError,AttributeError):
            self.jobs.clear()

    def _save_cache(self):
        # A cache metadata failure must never fail a successfully prepared video.
        temporary = None
        try:
            if self.scope is None:
                return
            allowed = ("key","aliases","state","created","last_access","size","duration","width","height","file_mtime_ns")
            jobs = {identifier:{k:job[k] for k in allowed if k in job}
                    for identifier,job in self.jobs.items()
                    if job["state"] == "ready" and job.get("scope") == self.scope
                    and isinstance(job.get("key"),str) and re.fullmatch(r"[a-f0-9]{64}",job["key"])
                    and self._valid_file(identifier,job)}
            with tempfile.NamedTemporaryFile("w",dir=self.root,prefix=".cache-",delete=False) as stream:
                temporary = Path(stream.name)
                os.chmod(temporary,0o600)
                json.dump({"version":1,"scope":self.scope,"jobs":jobs},stream,separators=(",",":"))
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary,self.root/"cache.json")
        except (OSError,ValueError,TypeError):
            _LOG.warning("Public video cache metadata could not be persisted")
        finally:
            if temporary is not None:
                try:
                    temporary.unlink(missing_ok=True)
                except OSError:
                    pass

    def clean(self, protected=None):
        now = time.time()
        for identifier,job in list(self.jobs.items()):
            state = job["state"]
            expired = (state == "ready" and now-job.get("last_access",job["created"]) > self.cache_ttl
                       or state == "failed" and now-job["created"] > 60)
            invalid = state == "ready" and not self._valid_file(identifier,job)
            if (expired or invalid) and identifier != protected and now >= job.get("leased_until",0):
                shutil.rmtree(self.root/identifier,ignore_errors=True)
                del self.jobs[identifier]
        ready = sorted((j.get("last_access",j["created"]),i,j.get("size",0))
                       for i,j in self.jobs.items() if j["state"] == "ready")
        count, size = len(ready),sum(row[2] for row in ready)
        for _,identifier,bytes_ in ready:
            if count <= self.cache_count and size <= self.cache_bytes:
                break
            if identifier == protected or now < self.jobs[identifier].get("leased_until",0):
                continue
            shutil.rmtree(self.root/identifier,ignore_errors=True)
            del self.jobs[identifier]
            count -= 1
            size -= bytes_

    def create(self, value):
        url = social_url(value)
        key = social_cache_key(url)
        with self.lock:
            self._refresh_scope()
            self.clean()
            for identifier,job in self.jobs.items():
                if key in (job["key"],*job.get("aliases",[])) and job["state"] != "failed":
                    job["last_access"] = time.time()
                    cached = job["state"] == "ready"
                    if cached:
                        self._save_cache()
                    return {**self.status(identifier),"cached":cached}
            if sum(j["state"] in ("queued","downloading") for j in self.jobs.values()) >= 3:
                raise BlockingIOError("Video queue is busy")
            if shutil.disk_usage(self.root).free < self.reserve + 2*MAX_VIDEO_BYTES*self.workers:
                raise OSError("Not enough temporary disk space")
            identifier = secrets.token_hex(16)
            self.jobs[identifier] = dict(key=key,aliases=[],state="queued",created=time.time(),
                                         last_access=time.time(),scope=self.scope)
            self.executor.submit(self.run,identifier,url)
            return {**self.status(identifier),"cached":False}

    def run(self, identifier, url):
        directory = self.root/identifier
        stage = "prepare"
        with self.lock:
            job = self.jobs.get(identifier)
            if job is None:
                return
            scope = job.get("scope",self.scope)
            job["state"] = "downloading"
        try:
            directory.mkdir(mode=0o700)
            if shutil.disk_usage(self.root).free < self.reserve + 2*MAX_VIDEO_BYTES:
                raise VideoFailure("insufficient_storage")
            stage = "worker_start"
            result = run_worker([sys.executable,"-m","nikita_archive.video_worker",url,str(directory)],timeout=180)
            with self.lock:
                if self.jobs.get(identifier) is not job:
                    shutil.rmtree(directory,ignore_errors=True)
                    return
                job["worker_exit_code"] = int(result.returncode)
            stage = "worker"
            if result.returncode:
                raise worker_failure(result,directory)
            metadata_path = directory/"result.json"
            if not metadata_path.is_file() or metadata_path.stat().st_size > 4096:
                raise VideoFailure("video_invalid_result","worker")
            metadata = json.loads(metadata_path.read_text())
            path = directory/"video.mp4"
            duration = metadata.get("duration") if isinstance(metadata,dict) else None
            dimensions = [metadata.get(k) for k in ("width","height")] if isinstance(metadata,dict) else []
            if (path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= MAX_VIDEO_BYTES or
                    isinstance(duration,bool) or not isinstance(duration,(int,float)) or
                    not math.isfinite(duration) or not 0 < duration <= 3600 or
                    len(dimensions) != 2 or any(isinstance(v,bool) or not isinstance(v,int) or v <= 0 for v in dimensions)):
                raise VideoFailure("video_invalid_result","worker")
            with self.lock:
                self._refresh_scope()
                if self.jobs.get(identifier) is not job or scope != self.scope:
                    shutil.rmtree(directory,ignore_errors=True)
                    return
                aliases = job.setdefault("aliases",[])
                canonical = metadata.get("cache_key")
                if isinstance(canonical,str) and re.fullmatch(r"[a-f0-9]{64}",canonical) and canonical != job["key"]:
                    aliases[:] = list(dict.fromkeys([*aliases,canonical]))[-16:]
                job.update(state="ready",size=path.stat().st_size,duration=duration,
                           width=metadata["width"],height=metadata["height"],
                           file_mtime_ns=path.stat().st_mtime_ns,last_access=time.time(),scope=self.scope)
                self.clean(protected=identifier)
                self._save_cache()
        except Exception as error:
            if isinstance(error,VideoFailure):
                failure = error
            elif isinstance(error,subprocess.TimeoutExpired):
                failure = VideoFailure("video_timeout","worker")
            elif isinstance(error,OSError) and error.errno == errno.ENOSPC:
                failure = VideoFailure("insufficient_storage",stage,type(error).__name__)
            elif stage == "worker_start" and isinstance(error,(FileNotFoundError,PermissionError)):
                failure = VideoFailure("video_dependency_missing","worker_start",type(error).__name__)
            else:
                failure = VideoFailure("video_invalid_result" if stage == "worker" else "video_worker_failed",stage,type(error).__name__)
            shutil.rmtree(directory,ignore_errors=True)
            with self.lock:
                if self.jobs.get(identifier) is not job:
                    return
                job.update(state="failed",error=failure.code,error_stage=failure.stage,
                           exception_type=failure.exception_type)
                exit_code = job.get("worker_exit_code")
            _LOG.warning("Public video preparation failed: code=%s stage=%s exit=%s type=%s service=%s",
                         failure.code,failure.stage,exit_code,failure.exception_type,self.service_version)

    def status(self, identifier):
        if not re.fullmatch(r"[a-f0-9]{32}",identifier):
            raise ValueError("Invalid job")
        with self.lock:
            self._refresh_scope()
            job = self.jobs.get(identifier)
            if not job:
                raise KeyError(identifier)
            return {"job_id":identifier,"service_version":self.service_version,
                    **{k:v for k,v in job.items() if k in ("state","size","duration","width","height","error","error_stage","worker_exit_code","exception_type")}}

    def ready(self, identifier):
        with self.lock:
            value = self.status(identifier)
            if value["state"] != "ready" or not self._valid_file(identifier,self.jobs[identifier]):
                raise BlockingIOError("Video is not ready")
            # Protect the short interval between HTTP path lookup and opening it.
            self.jobs[identifier]["leased_until"] = time.time()+30
            self.jobs[identifier]["last_access"] = time.time()
            return self.root/identifier/"video.mp4",value

    def close(self):
        self.executor.shutdown(wait=False,cancel_futures=True)
