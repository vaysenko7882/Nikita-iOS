import http.client
import json
from pathlib import Path
import socket
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from nikita_archive.archive import Archive
from nikita_archive.http_api import make_server
from nikita_archive.social_video import MAX_VIDEO_BYTES, SocialVideoStore, social_url
from nikita_archive.video_worker import public_addresses


class SocialURLTests(unittest.TestCase):
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
