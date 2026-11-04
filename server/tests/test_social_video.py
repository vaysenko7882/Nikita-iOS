import http.client
import io
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import signal
import shutil
import subprocess
import tempfile
import sys
import threading
import time
import unittest
from unittest.mock import patch
from nikita_archive.archive import Archive
from nikita_archive.http_api import make_server
from nikita_archive.social_video import MAX_VIDEO_BYTES, MAX_DIAGNOSTIC_BYTES, SocialVideoStore, VideoFailure, social_cache_key, social_url, run_worker, worker_failure
from nikita_archive.video_worker import VIDEO_FORMAT, download_video, failure_code, progressive_mp4, public_addresses, resolved_url


class SocialURLTests(unittest.TestCase):
    def test_tiktok_head_fallback_preserves_method_specific_share_endpoints(self):
        from unittest.mock import MagicMock
        from yt_dlp.networking import Response
        from yt_dlp.networking.exceptions import HTTPError
        short="https://vt.tiktok.com/Abcd12/"
        target="https://www.tiktok.com/@owner/video/123456"
        def context(url):
            value=MagicMock();value.__enter__.return_value.url=url;return value
        for initial in [context(short),HTTPError(Response(io.BytesIO(),short,{},405))]:
            downloader=MagicMock()
            downloader.urlopen.side_effect=[initial,context(target)]
            self.assertEqual(resolved_url(downloader,short),target)
            self.assertEqual([call.args[0].method for call in downloader.urlopen.call_args_list],["GET","HEAD"])
        downloader=MagicMock()
        downloader.urlopen.side_effect=[HTTPError(Response(io.BytesIO(),short,{},405)),context(short)]
        with self.assertRaises(VideoFailure):resolved_url(downloader,short)
        self.assertEqual(downloader.urlopen.call_count,2)

    def test_tiktok_short_links_use_get_and_revalidate_the_public_video_target(self):
        from unittest.mock import MagicMock
        downloader = MagicMock()
        response = downloader.urlopen.return_value.__enter__.return_value
        response.url = "https://www.tiktok.com/@owner/video/123456?share=private"
        self.assertEqual(resolved_url(downloader,"https://vt.tiktok.com/ZSp8radxX/"),
                         "https://www.tiktok.com/@owner/video/123456")
        self.assertEqual(downloader.urlopen.call_args.args[0].method,"GET")
        response.url = "https://m.tiktok.com/v/123456.html?share=private"
        self.assertEqual(resolved_url(downloader,"https://vm.tiktok.com/Abcd12/"),
                         "https://www.tiktok.com/share/video/123456")
        for target in ["https://vt.tiktok.com/Abcd12/","https://127.0.0.1/video/123456",
                       "https://instagram.com/reel/abc/","https://www.tiktok.com/@owner/photo/123456"]:
            response.url = target
            with self.assertRaises(VideoFailure) as failure:
                resolved_url(downloader,"https://vt.tiktok.com/Abcd12/")
            self.assertEqual(failure.exception.code,"video_unsupported_link")
            self.assertEqual(failure.exception.stage,"resolve")

    def test_tiktok_share_resolver_uses_available_browser_target_object(self):
        from unittest.mock import MagicMock
        from yt_dlp.networking.impersonate import ImpersonateTarget
        target = ImpersonateTarget()
        downloader = MagicMock()
        downloader._parse_impersonate_targets.return_value = (target,[target])
        downloader.urlopen.return_value.__enter__.return_value.url = "https://www.tiktok.com/@owner/video/123456"
        self.assertEqual(resolved_url(downloader,"https://vt.tiktok.com/ZSp8radxX/"),
                         "https://www.tiktok.com/@owner/video/123456")
        self.assertIs(downloader.urlopen.call_args.args[0].extensions["impersonate"],target)

    def test_downloader_constructor_failure_never_reads_uninitialized_transport(self):
        with tempfile.TemporaryDirectory() as folder:
            with patch("nikita_archive.video_worker.shutil.which",return_value="/fixture/tool"):
                with patch("yt_dlp.YoutubeDL",side_effect=RuntimeError("constructor failure")):
                    with self.assertRaises(VideoFailure) as failure:
                        download_video("https://www.tiktok.com/@owner/video/123456",Path(folder))
        self.assertEqual(failure.exception.code,"video_dependency_missing")
        self.assertEqual(failure.exception.stage,"resolve")

    def test_shared_and_username_routes_are_normalized_to_supported_extractors(self):
        from yt_dlp.extractor.instagram import InstagramIE
        from yt_dlp.extractor.tiktok import TikTokIE
        for link in ["https://instagram.com/owner/reel/abc/?igsh=private", "https://m.instagram.com/reels/abc/"]:
            self.assertEqual(social_url(link), "https://" + ("www.instagram.com" if "m.instagram.com" in link else "instagram.com") + "/reel/abc/")
            self.assertTrue(InstagramIE.suitable(social_url(link)))
        self.assertTrue(TikTokIE.suitable(social_url("https://tiktok.com/share/video/123456/")))
        self.assertEqual(social_url("https://www.instagram.com/share/reel/abc/?igsh=secret"), "https://www.instagram.com/share/reel/abc/")

    def test_share_redirect_is_revalidated_and_never_accepts_an_arbitrary_endpoint(self):
        from unittest.mock import MagicMock
        downloader = MagicMock()
        response = downloader.urlopen.return_value.__enter__.return_value
        response.url = "https://www.instagram.com/owner/reel/abc/?igsh=secret"
        self.assertEqual(resolved_url(downloader, "https://instagram.com/share/reel/xyz/"), "https://www.instagram.com/reel/abc/")
        for url, code in [("https://instagram.com/accounts/login/?next=secret", "video_login_required"),
                          ("https://127.0.0.1/reel/abc/", "video_unsupported_link"),
                          ("https://instagram.com/share/reel/xyz/", "video_unsupported_link")]:
            response.url = url
            with self.assertRaises(VideoFailure) as failure:
                resolved_url(downloader, "https://instagram.com/share/reel/xyz/")
            self.assertEqual(failure.exception.code, code)

    def test_real_format_selector_prefers_supported_codec_over_higher_quality_hevc(self):
        from yt_dlp import YoutubeDL
        with YoutubeDL({"quiet":True}) as downloader:
            selector=downloader.build_format_selector(VIDEO_FORMAT)
            for codec in ["h264","avc1.640028"]:
                formats=[dict(format_id="supported",url="https://example.com/low.mp4",ext="mp4",protocol="https",vcodec=codec,acodec="aac",height=720),
                         dict(format_id="hevc",url="https://example.com/high.mp4",ext="mp4",protocol="https",vcodec="h265",acodec="aac",height=1080)]
                chosen=list(selector(dict(formats=formats,has_merged_format=False,incomplete_formats=False)))
                self.assertEqual(chosen[0]["format_id"],"supported")

    def test_real_extractors_include_short_tiktok_links(self):
        from yt_dlp import YoutubeDL
        from yt_dlp.globals import plugin_dirs
        plugin_dirs.value=[]
        with YoutubeDL({"quiet":True,"allowed_extractors":["TikTok",r"vm\.tiktok","Instagram"]}) as downloader:
            self.assertEqual(set(downloader._ies),{"TikTok","TikTokVM","Instagram"})
            from yt_dlp.extractor.tiktok import TikTokIE, TikTokVMIE
            for link in ["https://tiktok.com/@owner/video/123", "https://m.tiktok.com/@owner/video/123", "https://tiktok.com/t/ZP8abc_/"]:
                normalized=social_url(link)
                self.assertTrue(TikTokIE.suitable(normalized) or TikTokVMIE.suitable(normalized))

    def test_only_standalone_supported_https_video_routes_are_accepted(self):
        for url in ["https://www.tiktok.com/@user/video/123", "https://vm.tiktok.com/Abcd12/", "https://vt.tiktok.com/Abcd12/", "https://www.instagram.com/reel/ABC-def_1/", "https://instagram.com/p/ABC123/?igsh=private"]:
            self.assertTrue(social_url(url).startswith("https://"))
            self.assertNotIn("?",social_url(url))
        for url in ["http://instagram.com/reel/123/", "https://instagram.com.evil/reel/123/", "https://instagram.com@127.0.0.1/reel/123/", "https://user:pass@instagram.com/reel/123/", "https://instagram.com:80/reel/123/", "https://instagram.com/stories/person/123", "https://tiktok.com/@person", "file:///etc/passwd", "https://127.0.0.1/reel/1/", "https://www.tiktok.com/@user/video/123 ; id", "https://instagram.com/reel/%2e%2e/", "", None, "x"*2049]:
            with self.subTest(url=url):
                with self.assertRaises(ValueError): social_url(url)

    def test_every_resolved_destination_must_be_public(self):
        def address(ip): return (socket.AF_INET,socket.SOCK_STREAM,6,"",(ip,443))
        for ip in ["127.0.0.1","10.1.2.3","169.254.169.254","192.168.1.1","0.0.0.0","224.0.0.1","ff02::1"]:
            with patch("nikita_archive.video_worker._getaddrinfo",return_value=[address(ip)]):
                with self.assertRaises(OSError): public_addresses("example.com",443)
        with patch("nikita_archive.video_worker._getaddrinfo",return_value=[address("8.8.8.8"),address("127.0.0.1")]):
            with self.assertRaises(OSError): public_addresses("example.com",443)
        with patch("nikita_archive.video_worker._getaddrinfo",return_value=[address("8.8.8.8")]) as resolver:
            self.assertEqual(public_addresses("example.com",443),[address("8.8.8.8")])
            resolver.assert_called_once()


class SocialVideoTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.config = {"database_path":str(self.root/"archive.sqlite3")}
        self.store = SocialVideoStore(self.config)

    def tearDown(self):
        self.store.close();self.temp.cleanup()

    def test_duplicate_urls_share_a_job_and_queue_is_bounded(self):
        with patch.object(self.store,"run",return_value=None):
            first = self.store.create("https://instagram.com/reel/abc/?igsh=secret")
            duplicate = self.store.create("https://instagram.com/reel/abc/")
            self.assertEqual(first["job_id"],duplicate["job_id"])
            self.store.create("https://instagram.com/reel/def/")
            self.store.create("https://instagram.com/reel/ghi/")
            with self.assertRaises(BlockingIOError): self.store.create("https://instagram.com/reel/jkl/")
        self.assertNotIn("url",self.store.status(first["job_id"]))
        self.assertNotIn("key",self.store.status(first["job_id"]))

    def test_no_conversion_starts_without_disk_reserve(self):
        with patch("nikita_archive.social_video.shutil.disk_usage") as disk:
            disk.return_value.free=100
            with self.assertRaises(OSError): self.store.create("https://instagram.com/reel/abc/")
        self.assertEqual(self.store.jobs,{})

    def test_worker_publishes_only_a_complete_bounded_result(self):
        identifier="1"*32
        self.store.jobs[identifier] = dict(key="x",state="queued",created=time.time())
        def worker(args,**kwargs):
            directory=Path(args[-1]);(directory/"video.mp4").write_bytes(b"video")
            (directory/"result.json").write_text(json.dumps(dict(duration=2,width=720,height=1280)))
            class Result: returncode=0
            return Result()
        with patch("nikita_archive.social_video.run_worker",side_effect=worker) as process:
            self.store.run(identifier,"https://instagram.com/reel/abc/")
            args=process.call_args.args[0]
            self.assertIsInstance(args,list)
            self.assertNotIn("shell",process.call_args.kwargs)
        self.assertEqual(self.store.status(identifier)["state"],"ready")
        self.assertEqual(self.store.ready(identifier)[1]["size"],5)

    def test_failed_or_missing_output_is_never_published(self):
        identifier="2"*32
        self.store.jobs[identifier] = dict(key="x",state="queued",created=time.time())
        with patch("nikita_archive.social_video.run_worker",side_effect=RuntimeError("private URL/cookie must not reach response")):
            self.store.run(identifier,"https://instagram.com/reel/abc/")
        self.assertEqual(self.store.status(identifier)["error"],"video_worker_failed")
        self.assertNotIn("private",json.dumps(self.store.status(identifier)))
        self.assertFalse((self.store.root/identifier).exists())

    def test_worker_failures_preserve_only_known_error_codes_and_timeouts(self):
        for index, code in enumerate(["video_login_required", "video_rate_limited", "video_unsupported_codec", "secret cookie https://private.example/"]):
            identifier=f"{index+10:032x}"
            self.store.jobs[identifier] = dict(key="x",state="queued",created=time.time())
            def worker(args, **kwargs):
                (Path(args[-1])/"error.json").write_text(json.dumps({"error":code,"detail":"private cookies"}))
                return subprocess.CompletedProcess(args, 1)
            with patch("nikita_archive.social_video.run_worker",side_effect=worker):
                self.store.run(identifier,"https://instagram.com/reel/abc/")
            self.assertEqual(self.store.status(identifier)["error"],code if index<3 else "video_worker_failed")
            self.assertNotIn("private",json.dumps(self.store.status(identifier)))
            self.assertFalse((self.store.root/identifier).exists())
        identifier="e"*32
        self.store.jobs[identifier]=dict(key="x",state="queued",created=time.time())
        with patch("nikita_archive.social_video.run_worker",side_effect=subprocess.TimeoutExpired("private URL",180)):
            self.store.run(identifier,"https://instagram.com/reel/abc/")
        self.assertEqual(self.store.status(identifier)["error"],"video_timeout")

    def test_real_worker_stderr_is_drained_but_only_bounded_bytes_are_kept(self):
        result = run_worker([sys.executable,"-c","import sys; sys.stderr.buffer.write(b'x'*(2*1024*1024)); sys.exit(7)"],timeout=10)
        self.assertEqual(result.returncode,7)
        self.assertEqual(len(result.stderr),MAX_DIAGNOSTIC_BYTES)

    def test_real_worker_timeout_is_killed_without_waiting_for_the_child_sleep(self):
        start=time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            run_worker([sys.executable,"-c","import time; time.sleep(30)"],timeout=0.1)
        self.assertLess(time.monotonic()-start,5)

    @unittest.skipUnless(sys.platform.startswith("linux"),"Linux server process-group integration")
    def test_worker_exit_terminates_real_descendant_before_closing_its_stderr(self):
        pid_file=self.root/"exited-worker-child.pid"
        group_file=self.root/"exited-worker-group.pid"
        error_file=self.root/"error.json"
        child="import os,time; from pathlib import Path; Path("+repr(str(pid_file))+").write_text(str(os.getpid())); time.sleep(30)"
        parent=("import os,subprocess,sys,time; from pathlib import Path; "
                "Path("+repr(str(group_file))+").write_text(str(os.getpid())); "
                "subprocess.Popen([sys.executable,'-c',"+repr(child)+"]); "
                "\nwhile not Path("+repr(str(pid_file))+").is_file(): time.sleep(0.01)\n"
                "Path("+repr(str(error_file))+").write_text('{\"error\":\"video_network_error\",\"stage\":\"download\"}'); "
                "sys.stderr.write('worker finished\\n'); sys.stderr.flush(); os._exit(7)")
        watchdog_fired=threading.Event()
        def cleanup():
            if group_file.is_file():
                try:os.killpg(int(group_file.read_text()),signal.SIGKILL)
                except ProcessLookupError:pass
        def watchdog():
            watchdog_fired.set()
            cleanup()
        guard=threading.Timer(2,watchdog)
        guard.start()
        start=time.monotonic()
        try:
            result=run_worker([sys.executable,"-c",parent],timeout=0.5)
            self.assertLess(time.monotonic()-start,3)
            self.assertFalse(watchdog_fired.is_set(),"Exited worker's descendant held stderr until watchdog cleanup")
            self.assertEqual(result.returncode,7)
            self.assertEqual(result.stderr,b"worker finished\n")
            self.assertEqual(worker_failure(result,self.root).code,"video_network_error")
            self.assertTrue(pid_file.is_file(),"Descendant must have actually started")
            pid=int(pid_file.read_text())
            deadline=time.monotonic()+1
            while True:
                state=subprocess.run(["ps","-o","stat=","-p",str(pid)],capture_output=True,text=True,check=False).stdout.strip()
                if not state or state.startswith("Z"):break
                if time.monotonic()>=deadline:self.fail("Worker descendant survived leader exit: "+state)
                time.sleep(0.02)
        finally:
            guard.cancel()
            cleanup()

    @unittest.skipUnless(sys.platform.startswith("linux"),"Linux server process-group integration")
    def test_worker_timeout_terminates_its_real_descendant_and_releases_stderr(self):
        pid_file=self.root/"descendant.pid"
        child="import os,time; from pathlib import Path; Path("+repr(str(pid_file))+").write_text(str(os.getpid())); time.sleep(30)"
        parent="import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',"+repr(child)+"]); time.sleep(30)"
        start=time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            run_worker([sys.executable,"-c",parent],timeout=2)
        self.assertLess(time.monotonic()-start,8)
        self.assertTrue(pid_file.is_file(),"Descendant must have actually started")
        pid=int(pid_file.read_text())
        # A container init can retain an already-exited orphan as a zombie until
        # its next reap. Such a record cannot execute or retain an open pipe.
        deadline=time.monotonic()+2
        while True:
            result=subprocess.run(["ps","-o","stat=","-p",str(pid)],capture_output=True,text=True,check=False)
            state=result.stdout.strip()
            if not state or state.startswith("Z"):
                break
            if time.monotonic()>=deadline:
                self.fail("Worker descendant survived timeout: "+state)
            time.sleep(0.02)

    def test_startup_killed_and_missing_worker_result_are_distinct_and_safe(self):
        cases = [(subprocess.CompletedProcess([],1,stderr=b"ModuleNotFoundError: no module secret_token"),"video_dependency_missing"),
                 (subprocess.CompletedProcess([],1,stderr=b"private URL and cookies"),"video_worker_failed"),
                 (subprocess.CompletedProcess([],-signal.SIGKILL,stderr=b""),"video_worker_killed"),
                 (subprocess.CompletedProcess([],-signal.SIGXCPU,stderr=b""),"video_timeout"),
                 (subprocess.CompletedProcess([],-signal.SIGXFSZ,stderr=b""),"video_too_large"),
                 (subprocess.CompletedProcess([],0,stderr=b""),"video_invalid_result")]
        for index,(result,code) in enumerate(cases):
            identifier=f"{100+index:032x}"
            self.store.jobs[identifier]=dict(key="x",state="queued",created=time.time())
            with patch("nikita_archive.social_video.run_worker",return_value=result):
                self.store.run(identifier,"https://vt.tiktok.com/ZSp8radxX/")
            value=self.store.status(identifier)
            self.assertEqual(value["error"],code)
            self.assertEqual(value["worker_exit_code"],result.returncode)
            if code=="video_worker_failed":self.assertEqual(value["error_stage"],"worker")
            self.assertNotIn("secret",json.dumps(value))
            self.assertNotIn("cookies",json.dumps(value))
            self.assertIn("service_version",value)

    def test_typed_worker_stage_and_exception_are_sanitized_before_http(self):
        identifier="f"*32
        self.store.jobs[identifier]=dict(key="x",state="queued",created=time.time())
        def worker(args,**kwargs):
            (Path(args[-1])/"error.json").write_text(json.dumps({"error":"video_dns_error","stage":"resolve",
                "exception_type":"DownloadError","detail":"secret cookies https://private.example"}))
            return subprocess.CompletedProcess(args,1,stderr=b"secret cookies")
        with patch("nikita_archive.social_video.run_worker",side_effect=worker):
            self.store.run(identifier,"https://vt.tiktok.com/ZSp8radxX/")
        value=self.store.status(identifier)
        self.assertEqual((value["error"],value["error_stage"],value["exception_type"]),
                         ("video_dns_error","resolve","DownloadError"))
        self.assertNotIn("secret",json.dumps(value))

    def test_wrapped_dns_and_transport_errors_never_become_generic_unavailable(self):
        from yt_dlp.utils import DownloadError, ExtractorError
        from yt_dlp.networking.exceptions import TransportError, CertificateVerifyError
        transport=TransportError(cause=socket.gaierror(-3,"Temporary failure in name resolution"))
        extraction=ExtractorError("Unable to download webpage",cause=transport)
        error=DownloadError("wrapped error",exc_info=(ExtractorError,extraction,None))
        self.assertEqual(failure_code(error),"video_dns_error")
        for message in ["Name or service not known","nodename nor servname provided, or not known","getaddrinfo failed"]:
            self.assertEqual(failure_code(DownloadError(message)),"video_dns_error")
        self.assertEqual(failure_code(DownloadError("wrapper",exc_info=(CertificateVerifyError,CertificateVerifyError("bad TLS"),None))),"video_network_error")
        self.assertEqual(failure_code(DownloadError("No suitable extractor found for URL private")),"video_unsupported_link")

    def test_real_worker_reports_dns_stage_without_contacting_the_internet(self):
        # Run the actual isolated module, not a mocked extractor. Controlled DNS
        # fails before any destination connection; this matches the supplied URL's
        # reproducible failure in the restricted build environment.
        custom=self.root/"dns-fixture";custom.mkdir()
        (custom/"sitecustomize.py").write_text("import socket\ndef fail(*args,**kwargs):\n raise socket.gaierror(-3,'Temporary failure in name resolution')\nsocket.getaddrinfo=fail\n")
        # DNS must fail before media tools run. Satisfy the worker's executable
        # discovery on hosts without ffmpeg, and fail if that boundary changes.
        tools=custom/"bin";tools.mkdir()
        marker=custom/"media-tool-invoked"
        for name in ("ffmpeg","ffprobe"):
            sentinel=tools/name
            sentinel.write_text('#!/bin/sh\n: > "$CODEGRAM_DNS_MEDIA_MARKER"\nexit 99\n')
            sentinel.chmod(0o755)
        output=self.root/"worker-output";output.mkdir()
        env={**os.environ,"PYTHONPATH":str(custom)+os.pathsep+os.environ.get("PYTHONPATH",""),
             "PATH":str(tools)+os.pathsep+os.environ.get("PATH",""),"CODEGRAM_DNS_MEDIA_MARKER":str(marker)}
        result=subprocess.run([sys.executable,"-m","nikita_archive.video_worker","https://vt.tiktok.com/ZSp8radxX/",str(output)],
                              env=env,capture_output=True,timeout=15)
        self.assertEqual(result.returncode,1)
        self.assertFalse(marker.exists(),"DNS resolution must fail before a media executable is invoked")
        error=json.loads((output/"error.json").read_text())
        self.assertEqual((error["error"],error["stage"]),("video_dns_error","resolve"))
        self.assertNotIn("ZSp8",json.dumps(error))

    def test_failure_classifier_retains_cause_without_disclosing_messages(self):
        from yt_dlp.utils import DownloadError, ExtractorError
        for text, code in [("You need to log in to access this content", "video_login_required"),
                           ("HTTP Error 429 Too Many Requests", "video_rate_limited"),
                           ("Requested format is not available", "video_unsupported_codec"),
                           ("Connection refused", "video_network_error"),
                           ("This video is not available", "video_source_unavailable")]:
            self.assertEqual(failure_code(DownloadError(text)),code)
        wrapped=DownloadError("unexpected wrapper",exc_info=(VideoFailure,VideoFailure("video_too_large"),None))
        self.assertEqual(failure_code(wrapped),"video_too_large")

    def test_expiry_cleans_only_temporary_conversions(self):
        identifier="3"*32
        folder=self.store.root/identifier;folder.mkdir();(folder/"video.mp4").write_bytes(b"v")
        self.store.jobs[identifier]=dict(key="x",state="ready",created=time.time()-3601)
        archive_file=self.root/"important-archive.blob";archive_file.write_bytes(b"keep")
        self.store.clean()
        self.assertFalse(folder.exists());self.assertEqual(archive_file.read_bytes(),b"keep")

    def test_authenticated_http_jobs_and_download_require_account_and_epoch(self):
        archive=Archive(self.config["database_path"]);archive.set_account(123);archive.social_videos=self.store
        identifier="4"*32
        folder=self.store.root/identifier;folder.mkdir();(folder/"video.mp4").write_bytes(b"video")
        self.store.jobs[identifier]=dict(key="x",state="ready",created=time.time(),size=5,width=10,height=10,duration=1)
        server=make_server(archive,"s"*48,0)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        def call(method,path,body=None,headers=None):
            conn=http.client.HTTPConnection("127.0.0.1",server.server_address[1],timeout=5)
            conn.request(method,path,body=json.dumps(body) if body else None,headers=headers or {})
            r=conn.getresponse();data=r.read();conn.close();return r.status,data
        try:
            self.assertEqual(call("GET","/v1/video/"+identifier)[0],401)
            auth={"Authorization":"Bearer "+"s"*48}
            self.assertEqual(call("POST","/v1/video",{"url":"https://instagram.com/reel/abc/"},auth)[0],403)
            auth["X-CodeGram-Account-ID"]="123"
            self.assertEqual(call("POST","/v1/video",{"url":"file:///etc/passwd"},auth)[0],400)
            status,data=call("GET","/v1/video/"+identifier,headers=auth)
            self.assertEqual(status,200);self.assertEqual(json.loads(data)["account_id"],123)
            self.assertEqual(call("GET","/v1/video/"+identifier+"/file",headers=auth)[0],409)
            auth["X-Nikita-Archive-Epoch"]=archive.server_id
            self.assertEqual(call("GET","/v1/video/"+identifier+"/file",headers=auth),(200,b"video"))
            self.assertEqual(call("HEAD","/v1/video/"+identifier+"/file",headers=auth),(200,b""))
        finally:
            server.shutdown();server.server_close();thread.join()


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "ffmpeg/ffprobe required")
class VideoWorkerMediaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory()
        cls.root=Path(cls.temp.name)
        # Generate genuine encoded packets, then prove the production pipeline copies them.
        subprocess.run(["ffmpeg","-nostdin","-v","error","-f","lavfi","-i","color=c=blue:s=64x96:r=10:d=0.4",
                        "-f","lavfi","-i","sine=frequency=440:duration=0.4","-c:v","libx264","-pix_fmt","yuv420p","-c:a","aac","-shortest",str(cls.root/"combined.mp4")],check=True,capture_output=True,timeout=20)
        subprocess.run(["ffmpeg","-nostdin","-v","error","-i",str(cls.root/"combined.mp4"),
                        "-c","copy","-movflags","+faststart",str(cls.root/"faststart.mp4")],
                       check=True,capture_output=True,timeout=20)
        for path, mapping in [("video.mp4","0:v:0"),("audio.m4a","0:a:0")]:
            subprocess.run(["ffmpeg","-nostdin","-v","error","-i",str(cls.root/"combined.mp4"),"-map",mapping,"-c","copy",str(cls.root/path)],check=True,capture_output=True,timeout=20)
        class QuietHandler(SimpleHTTPRequestHandler):
            def log_message(self, *args): pass
        cls.server=ThreadingHTTPServer(("127.0.0.1",0),functools.partial(QuietHandler,directory=str(cls.root)))
        cls.thread=threading.Thread(target=cls.server.serve_forever,daemon=True);cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown();cls.server.server_close();cls.thread.join();cls.temp.cleanup()

    def pipeline(self, formats, folder):
        from yt_dlp import YoutubeDL
        from yt_dlp.extractor.common import InfoExtractor
        class FixtureIE(InfoExtractor):
            IE_NAME="codegram_fixture"
            _VALID_URL=r'https://instagram\.com/reel/(?P<id>[a-z]+)/'
            def _real_extract(self, url):
                return {"id":self._match_id(url),"title":"local fixture","formats":formats}
        class FixtureYDL(YoutubeDL):
            def __init__(self, options):
                super().__init__({**options,"allowed_extractors":["codegram_fixture"]},auto_init=False)
                self.add_info_extractor(FixtureIE())
        folder.mkdir()
        with patch("yt_dlp.YoutubeDL", FixtureYDL):
            download_video("https://instagram.com/reel/test/", folder)
        return folder/"video.mp4"

    def format(self, filename, **values):
        return dict(format_id=filename,url=f"http://127.0.0.1:{self.server.server_address[1]}/{filename}",
                    ext=filename.split(".")[-1],protocol="http",**values)

    def packets(self, path):
        result=subprocess.run(["ffprobe","-v","error","-show_packets","-show_data_hash","sha256","-of","json",str(path)],check=True,capture_output=True,timeout=20)
        return [packet["data_hash"] for packet in json.loads(result.stdout)["packets"] if packet["codec_type"]=="video"]

    def assert_playable_copy(self, output):
        result=subprocess.run(["ffprobe","-v","error","-show_streams","-of","json",str(output)],check=True,capture_output=True,timeout=20)
        codecs=[value["codec_name"] for value in json.loads(result.stdout)["streams"]]
        self.assertEqual(codecs,["h264","aac"])
        self.assertEqual(self.packets(output),self.packets(self.root/"combined.mp4"))
        data=output.read_bytes()
        self.assertLess(data.index(b"moov"),data.index(b"mdat"))

    def test_real_progressive_mp4_is_remuxed_without_reencoding(self):
        output=self.pipeline([self.format("combined.mp4",vcodec="h264",acodec="aac",height=96)],self.root/"progressive")
        self.assert_playable_copy(output)

    def test_already_progressive_mp4_skips_remux_and_keeps_exact_bytes(self):
        real_run = subprocess.run
        with patch("nikita_archive.video_worker.subprocess.run",wraps=real_run) as process:
            output = self.pipeline([self.format("faststart.mp4",vcodec="h264",acodec="aac",height=96)],
                                   self.root/"fast-reuse")
            self.assertEqual([call.args[0][0] for call in process.call_args_list],["ffprobe"])
        self.assertEqual(output.read_bytes(),(self.root/"faststart.mp4").read_bytes())
        self.assert_playable_copy(output)
        result = json.loads((output.parent/"result.json").read_text())
        self.assertTrue(result["reused_container"])
        self.assertEqual(result["cache_key"],social_cache_key("https://instagram.com/reel/test/"))

    def test_atom_scanner_requires_real_unfragmented_index_before_media(self):
        import struct
        def atom(kind,payload=b""):
            return struct.pack(">I4s",8+len(payload),kind)+payload
        ftyp = atom(b"ftyp",b"isom"+b"\0"*4+b"mp42")
        moov = atom(b"moov",atom(b"free"))
        cases = [(ftyp+moov+atom(b"mdat",b"payload"),True),
                 (ftyp+atom(b"mdat",b"payload")+moov,False),
                 (ftyp+atom(b"moov",atom(b"mvex"))+atom(b"mdat"),False),
                 (ftyp+moov+atom(b"moof")+atom(b"mdat"),False),
                 (ftyp+struct.pack(">I4s",999999,b"moov"),False),
                 (b"not an MP4",False)]
        for index,(data,expected) in enumerate(cases):
            path = self.root/f"atoms-{index}.mp4"
            path.write_bytes(data)
            self.assertEqual(progressive_mp4(path),expected)

    def test_public_http_h264_and_aac_are_merged_without_reencoding(self):
        formats=[self.format("audio.m4a",vcodec="none",acodec="mp4a.40.2"),
                 self.format("video.mp4",vcodec="avc1.640028",acodec="none",height=96)]
        output=self.pipeline(formats,self.root/"separate")
        self.assert_playable_copy(output)

    def test_real_http_source_failure_is_distinct_from_processing_failure(self):
        with self.assertRaises(VideoFailure) as failure:
            self.pipeline([self.format("missing.mp4",vcodec="h264",acodec="aac",height=96)],self.root/"missing")
        self.assertEqual(failure.exception.code,"video_source_unavailable")

    def test_progress_hook_enforces_combined_size_of_separate_downloads(self):
        from unittest.mock import MagicMock
        downloader=MagicMock()
        def construct(options):
            def extract(*args, **kwargs):
                hook=options["progress_hooks"][0]
                hook({"filename":"video.mp4","downloaded_bytes":MAX_VIDEO_BYTES})
                hook({"filename":"audio.m4a","downloaded_bytes":1})
            downloader.__enter__.return_value.extract_info.side_effect=extract
            return downloader
        folder=self.root/"oversize";folder.mkdir()
        with patch("yt_dlp.YoutubeDL",side_effect=construct):
            with self.assertRaises(VideoFailure) as failure:
                download_video("https://instagram.com/reel/test/",folder)
        self.assertEqual(failure.exception.code,"video_too_large")



class PersistentVideoCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.config = {"database_path":str(self.root/"archive.sqlite3"),"video_cache_max_entries":4}
        self.archive = Archive(self.config["database_path"])
        self.archive.set_account(123)
        self.disk = patch("nikita_archive.social_video.shutil.disk_usage")
        self.disk.start().return_value.free = 20*1024**3
        self.store = SocialVideoStore(self.config)

    def tearDown(self):
        self.store.close()
        self.disk.stop()
        self.temp.cleanup()

    def restart(self):
        self.store.close()
        self.store = SocialVideoStore(self.config)

    def complete(self, url, canonical=None):
        with patch.object(self.store.executor,"submit") as submit:
            value = self.store.create(url)
            self.assertEqual(submit.call_count,1)
        def worker(args,**kwargs):
            directory = Path(args[-1])
            (directory/"video.mp4").write_bytes(b"video")
            (directory/"result.json").write_text(json.dumps({
                "duration":2,"width":720,"height":1280,"cache_key":social_cache_key(canonical or url)}))
            return subprocess.CompletedProcess(args,0)
        with patch("nikita_archive.social_video.run_worker",side_effect=worker):
            self.store.run(value["job_id"],social_url(url))
        self.assertEqual(self.store.status(value["job_id"])["state"],"ready")
        return value["job_id"]

    def test_same_tiktok_id_deduplicates_inflight_despite_username_or_share_route(self):
        with patch.object(self.store.executor,"submit") as submit:
            first = self.store.create("https://www.tiktok.com/@first/video/123456?source=private")
            second = self.store.create("https://tiktok.com/@renamed/video/123456/")
            third = self.store.create("https://www.tiktok.com/share/video/123456/")
        self.assertEqual(first["job_id"],second["job_id"])
        self.assertEqual(first["job_id"],third["job_id"])
        self.assertFalse(first["cached"])
        self.assertEqual(submit.call_count,1)

    def test_ready_cache_survives_restart_without_download_or_private_url_metadata(self):
        identifier = self.complete("https://instagram.com/reel/abc/?igsh=secret")
        self.restart()
        with patch.object(self.store.executor,"submit") as submit:
            value = self.store.create("https://www.instagram.com/p/abc/")
        self.assertEqual(value["job_id"],identifier)
        self.assertEqual(value["state"],"ready")
        self.assertTrue(value["cached"])
        submit.assert_not_called()
        self.assertEqual(self.store.ready(identifier)[0].read_bytes(),b"video")
        manifest = (self.store.root/"cache.json").read_text()
        self.assertNotIn("https://",manifest)
        self.assertNotIn("secret",manifest)
        self.assertNotIn(str(self.root),manifest)
        if os.name == "posix":
            self.assertEqual((self.store.root/"cache.json").stat().st_mode & 0o777,0o600)

    def test_resolved_shortlink_alias_survives_restart(self):
        direct = "https://www.tiktok.com/@owner/video/123456"
        identifier = self.complete("https://vt.tiktok.com/ZSp8radxX/",canonical=direct)
        self.restart()
        with patch.object(self.store.executor,"submit") as submit:
            value = self.store.create(direct)
            original = self.store.create("https://vt.tiktok.com/ZSp8radxX/")
        submit.assert_not_called()
        self.assertEqual(value["job_id"],identifier)
        self.assertEqual(original["job_id"],identifier)
        self.assertTrue(value["cached"])

    def test_epoch_change_invalidates_ready_and_inflight_jobs(self):
        identifier = self.complete("https://instagram.com/reel/abc/")
        with patch.object(self.store.executor,"submit"):
            queued = self.store.create("https://instagram.com/reel/def/")["job_id"]
        with self.archive.connect() as db:
            db.execute("UPDATE meta SET value='new-epoch' WHERE key='server_id'")
        for job_id in (identifier,queued):
            with self.assertRaises(KeyError):
                self.store.status(job_id)
        self.assertFalse((self.store.root/identifier).exists())
        self.restart()
        self.assertEqual(self.store.jobs,{})

    def test_different_account_never_loads_previous_accounts_cache(self):
        identifier = self.complete("https://instagram.com/reel/abc/")
        with self.archive.connect() as db:
            db.execute("UPDATE meta SET value='456' WHERE key='account_id'")
        self.restart()
        self.assertEqual(self.store.jobs,{})
        self.assertFalse((self.store.root/identifier).exists())

    def test_cache_rejects_missing_modified_or_symlink_media(self):
        identifier = self.complete("https://instagram.com/reel/abc/")
        (self.store.root/identifier/"video.mp4").write_bytes(b"changed")
        self.restart()
        self.assertEqual(self.store.jobs,{})
        identifier = self.complete("https://instagram.com/reel/def/")
        path = self.store.root/identifier/"video.mp4"
        path.unlink()
        outside = self.root/"outside.mp4"
        outside.write_bytes(b"video")
        path.symlink_to(outside)
        self.restart()
        self.assertEqual(self.store.jobs,{})
        self.assertEqual(outside.read_bytes(),b"video")

    def test_lru_and_ttl_eviction_are_bounded_and_preserve_archive_data(self):
        identifiers = [self.complete(f"https://instagram.com/reel/post{index}/") for index in range(4)]
        # Accessing an older entry makes it more recent than the untouched entries.
        self.store.jobs[identifiers[0]]["last_access"] = time.time()+1
        newest = self.complete("https://instagram.com/reel/post4/")
        self.assertEqual(len(self.store.jobs),4)
        self.assertIn(identifiers[0],self.store.jobs)
        self.assertIn(newest,self.store.jobs)
        self.assertNotIn(identifiers[1],self.store.jobs)
        archive_file = self.root/"important-archive.blob"
        archive_file.write_bytes(b"keep")
        for job in self.store.jobs.values():
            job["last_access"] = time.time()-self.store.cache_ttl-1
        self.store.clean()
        self.assertEqual(self.store.jobs,{})
        self.assertEqual(archive_file.read_bytes(),b"keep")

    def test_cache_byte_budget_evicts_oldest_complete_entry(self):
        self.store.cache_bytes = 8
        first = self.complete("https://instagram.com/reel/abc/")
        second = self.complete("https://instagram.com/reel/def/")
        self.assertNotIn(first,self.store.jobs)
        self.assertIn(second,self.store.jobs)
        self.assertLessEqual(sum(job["size"] for job in self.store.jobs.values()),self.store.cache_bytes)

    def test_cache_metadata_write_failure_does_not_fail_completed_video(self):
        with patch("nikita_archive.social_video.os.replace",side_effect=OSError("metadata disk failure")):
            identifier = self.complete("https://instagram.com/reel/abc/")
        self.assertEqual(self.store.status(identifier)["state"],"ready")
        self.assertEqual(self.store.ready(identifier)[0].read_bytes(),b"video")

    def test_epoch_change_while_worker_runs_cannot_publish_old_scope_result(self):
        with patch.object(self.store.executor,"submit"):
            identifier = self.store.create("https://instagram.com/reel/abc/")["job_id"]
        def worker(args,**kwargs):
            directory = Path(args[-1])
            (directory/"video.mp4").write_bytes(b"video")
            (directory/"result.json").write_text(json.dumps({"duration":2,"width":720,"height":1280}))
            with self.archive.connect() as db:
                db.execute("UPDATE meta SET value='changed-during-download' WHERE key='server_id'")
            return subprocess.CompletedProcess(args,0)
        with patch("nikita_archive.social_video.run_worker",side_effect=worker):
            self.store.run(identifier,"https://instagram.com/reel/abc/")
        self.assertNotIn(identifier,self.store.jobs)
        self.assertFalse((self.store.root/identifier).exists())
