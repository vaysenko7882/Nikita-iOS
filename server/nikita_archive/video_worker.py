"""Isolated public-only downloader. Never receives Telegram credentials or cookies."""
import ipaddress
import json
import math
import os
from pathlib import Path
import resource
import socket
import subprocess
import sys
from .social_video import MAX_VIDEO_BYTES, social_url


def public_addresses(host, port, *args, **kwargs):
    addresses = _getaddrinfo(host,port,*args,**kwargs)
    if not addresses or any(not ipaddress.ip_address(item[4][0]).is_global for item in addresses):
        raise OSError("Private network destinations are not allowed")
    return addresses


_getaddrinfo = socket.getaddrinfo


def main():
    url, directory = social_url(sys.argv[1]), Path(sys.argv[2]).resolve(strict=True)
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
    from yt_dlp import YoutubeDL
    from yt_dlp.globals import plugin_dirs
    plugin_dirs.value = []
    options = dict(quiet=True,no_warnings=True,noplaylist=True,playlistend=1,
                   cachedir=False,usenetrc=False,proxy="",enable_file_urls=False,
                   socket_timeout=15,retries=2,fragment_retries=1,
                   max_filesize=MAX_VIDEO_BYTES,concurrent_fragment_downloads=1,
                   outtmpl=str(directory/"download.%(ext)s"),
                   format="best[ext=mp4][protocol=https][vcodec^=avc1]/best[ext=mp4][protocol=https]",
                   allowed_extractors=["TikTok",r"vm\.tiktok","Instagram"],
                   noprogress=True,overwrites=False)
    with YoutubeDL(options) as downloader:
        result = downloader.extract_info(url,download=True)
        if result.get("entries"):
            result = next(iter(result["entries"]))
        path = Path(downloader.prepare_filename(result)).resolve(strict=True)
    if path.parent!=directory or not 0<path.stat().st_size<=MAX_VIDEO_BYTES:
        raise ValueError("Invalid download")
    probe = subprocess.run(["ffprobe","-v","error","-protocol_whitelist","file,pipe","-show_streams","-show_format","-of","json",str(path)],capture_output=True,timeout=20,check=True)
    metadata = json.loads(probe.stdout)
    video = next(s for s in metadata["streams"] if s.get("codec_type")=="video")
    duration = float(metadata.get("format",{}).get("duration",0))
    if not math.isfinite(duration) or not 0<duration<=3600 or video.get("codec_name")!="h264":
        raise ValueError("Unsupported video")
    # Remux only; no CPU-heavy video re-encoding. Enable progressive iPhone playback.
    target = directory/"video.mp4"
    subprocess.run(["ffmpeg","-nostdin","-v","error","-protocol_whitelist","file,pipe","-i",str(path),
                    "-map","0:v:0","-map","0:a:0?","-c","copy","-movflags","+faststart",str(target)],timeout=40,check=True)
    path.unlink()
    (directory/"result.json").write_text(json.dumps(dict(duration=duration,width=int(video["width"]),height=int(video["height"]))))


if __name__=="__main__":
    main()
