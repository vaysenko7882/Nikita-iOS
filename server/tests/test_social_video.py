import http.client
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socket
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from nikita_archive.archive import Archive
from nikita_archive.http_api import make_server
from nikita_archive.social_video import MAX_VIDEO_BYTES, SocialVideoStore, VideoFailure, social_url
from nikita_archive.video_worker import VIDEO_FORMAT, download_video, failure_code, public_addresses, resolved_url


class SocialURLTests(unittest.TestCase):
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
                          ("https://127.0.0.1/reel/abc/", "video_source_unavailable"),
                          ("https://instagram.com/share/reel/xyz/", "video_source_unavailable")]:
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
        for ip in ["127.0.0.1","10.1.2.3","169.254.169.254","192.168.1.1","0.0.0.0"]:
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
        with patch("nikita_archive.social_video.subprocess.run",side_effect=worker) as process:
            self.store.run(identifier,"https://instagram.com/reel/abc/")
            args=process.call_args.args[0]
            self.assertIsInstance(args,list)
            self.assertNotIn("shell",process.call_args.kwargs)
        self.assertEqual(self.store.status(identifier)["state"],"ready")
        self.assertEqual(self.store.ready(identifier)[1]["size"],5)

    def test_failed_or_missing_output_is_never_published(self):
        identifier="2"*32
        self.store.jobs[identifier] = dict(key="x",state="queued",created=time.time())
        with patch("nikita_archive.social_video.subprocess.run",side_effect=RuntimeError("private URL/cookie must not reach response")):
            self.store.run(identifier,"https://instagram.com/reel/abc/")
        self.assertEqual(self.store.status(identifier)["error"],"video_unavailable")
        self.assertNotIn("private",json.dumps(self.store.status(identifier)))
        self.assertFalse((self.store.root/identifier).exists())

    def test_worker_failures_preserve_only_known_error_codes_and_timeouts(self):
        for index, code in enumerate(["video_login_required", "video_rate_limited", "video_unsupported_codec", "secret cookie https://private.example/"]):
            identifier=f"{index+10:032x}"
            self.store.jobs[identifier] = dict(key="x",state="queued",created=time.time())
            def worker(args, **kwargs):
                (Path(args[-1])/"error.json").write_text(json.dumps({"error":code,"detail":"private cookies"}))
                return subprocess.CompletedProcess(args, 1)
            with patch("nikita_archive.social_video.subprocess.run",side_effect=worker):
                self.store.run(identifier,"https://instagram.com/reel/abc/")
            self.assertEqual(self.store.status(identifier)["error"],code if index<3 else "video_unavailable")
            self.assertNotIn("private",json.dumps(self.store.status(identifier)))
            self.assertFalse((self.store.root/identifier).exists())
        identifier="e"*32
        self.store.jobs[identifier]=dict(key="x",state="queued",created=time.time())
        with patch("nikita_archive.social_video.subprocess.run",side_effect=subprocess.TimeoutExpired("private URL",180)):
            self.store.run(identifier,"https://instagram.com/reel/abc/")
        self.assertEqual(self.store.status(identifier)["error"],"video_timeout")

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
                    ext=filename.split(".")[-1],protocol="https",**values)

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

    def test_separate_https_h264_and_aac_are_merged_without_reencoding(self):
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

