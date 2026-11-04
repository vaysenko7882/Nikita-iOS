"""Exercise the pinned yt-dlp browser handler without any external network."""
import ipaddress
import json
import socket
import unittest
from unittest.mock import patch

import curl_cffi.requests
from curl_cffi.const import CurlECode, CurlHttpVersion, CurlOpt
from yt_dlp import YoutubeDL
from yt_dlp.extractor.tiktok import TikTokIE
from yt_dlp.networking import Request
from yt_dlp.networking._curlcffi import CurlCFFIRH
from yt_dlp.networking.exceptions import (
    CertificateVerifyError, HTTPError, TransportError, UnsupportedRequest)
from yt_dlp.networking.impersonate import ImpersonateTarget

from nikita_archive.video_transport import install_public_transport, pinned_destination


def addresses(*values):
    return [
        (socket.AF_INET6 if ipaddress.ip_address(value).version == 6 else socket.AF_INET,
         socket.SOCK_STREAM, socket.IPPROTO_TCP, "",
         (value, 443, 0, 0) if ":" in value else (value, 443))
        for value in values
    ]


class PinnedDestinationTests(unittest.TestCase):
    def test_public_answers_are_deduplicated_and_ipv6_is_bracketed(self):
        calls = []
        def resolve(host, port, **kwargs):
            calls.append((host, port, kwargs))
            return addresses("93.184.216.34", "2606:4700:4700::1111", "93.184.216.34")
        result = pinned_destination("https://WWW.TIKTOK.COM/video", resolve)
        self.assertEqual(result, "www.tiktok.com:443:93.184.216.34,[2606:4700:4700::1111]")
        self.assertEqual(calls, [("www.tiktok.com", 443, {"type": socket.SOCK_STREAM})])

    def test_rejects_every_nonpublic_answer_even_among_public_answers(self):
        for address in ("127.0.0.1", "10.0.0.1", "169.254.169.254", "0.0.0.0",
                        "224.0.0.1", "ff02::1", "::1", "fe80::1", "fc00::1",
                        "::ffff:127.0.0.1"):
            with self.subTest(address=address), self.assertRaises(OSError):
                pinned_destination("https://www.tiktok.com/", lambda *a, **k: addresses("93.184.216.34", address))

    def test_empty_dns_and_untrusted_url_forms_are_rejected(self):
        with self.assertRaises(OSError):
            pinned_destination("https://www.tiktok.com/", lambda *a, **k: [])
        for url in ("file:///etc/passwd", "ftp://www.tiktok.com/video",
                    "https://user:secret@www.tiktok.com/", "https:///missing-host"):
            with self.subTest(url=url), self.assertRaises(OSError):
                pinned_destination(url, lambda *a, **k: addresses("93.184.216.34"))


class FakeResponse:
    def __init__(self, body=b"fixture", status=200, headers=None):
        self.body = body
        self.status_code = status
        self.headers = {"Content-Type": "text/html; charset=utf-8", **(headers or {})}
        self.reason = "Fixture"
        self.url = ""
        self.session = None
        self.closed = False
        self.close_count = 0

    def iter_content(self):
        # A real streaming response still needs its session while being read.
        if self.session.closed:
            raise AssertionError("Session closed before the response was consumed")
        midpoint = max(1, len(self.body) // 2)
        for chunk in (self.body[:midpoint], self.body[midpoint:]):
            if chunk:
                yield chunk

    def close(self):
        self.closed = True
        self.close_count += 1


class FakeSession:
    def __init__(self, owner, options):
        self.owner = owner
        self.options = options
        self.closed = False
        self.close_count = 0

    def request(self, **kwargs):
        self.owner.calls.append((self, {**kwargs, "headers": dict(kwargs["headers"])}))
        if not self.owner.responses:
            raise AssertionError("Unexpected extra request: " + kwargs["url"])
        result = self.owner.responses.pop(0)
        if isinstance(result, BaseException):
            raise result
        result.url = kwargs["url"]
        result.session = self
        return result

    def close(self):
        self.closed = True
        self.close_count += 1


class PublicBrowserTransportTests(unittest.TestCase):
    def setUp(self):
        self.sessions = []
        self.calls = []
        self.responses = []
        self.dns_calls = []
        self.dns_results = {}
        self.session_patch = patch("curl_cffi.requests.Session", side_effect=self.new_session)
        self.session_patch.start()
        self.addCleanup(self.session_patch.stop)
        self.network_patch = patch.object(
            socket.socket, "connect", side_effect=AssertionError("External network is forbidden in this test"))
        self.network_patch.start()
        self.addCleanup(self.network_patch.stop)
        self.ydl = YoutubeDL({
            "quiet": True, "no_warnings": True, "cachedir": False,
            "proxy": "", "socket_timeout": 7,
        }, auto_init=False)
        self.addCleanup(self.ydl.close)
        self.assertTrue(install_public_transport(self.ydl, self.resolve))

    def new_session(self, **options):
        session = FakeSession(self, options)
        self.sessions.append(session)
        return session

    def resolve(self, host, port, **kwargs):
        self.dns_calls.append((host, port))
        result = self.dns_results.get(host, ["93.184.216.34"])
        if callable(result):
            result = result()
        return addresses(*result)

    def request(self, url="https://www.tiktok.com/@fixture/video/7412345678901234567", **kwargs):
        return Request(url, extensions={"impersonate": ImpersonateTarget()}, **kwargs)

    def open(self, url="https://www.tiktok.com/@fixture/video/7412345678901234567", **kwargs):
        return self.ydl.urlopen(self.request(url, **kwargs))

    def handler(self):
        return self.ydl._request_director.handlers["PublicCurlCFFI"]

    def test_unguarded_curl_is_removed_and_browser_target_is_resolved(self):
        handlers = self.ydl._request_director.handlers
        self.assertNotIn("CurlCFFI", handlers)
        self.assertEqual(
            [type(handler).__name__ for handler in handlers.values() if isinstance(handler, CurlCFFIRH)],
            ["PublicCurlCFFIRH"])
        self.responses.append(FakeResponse())
        response = self.open()
        self.assertIsInstance(response.extensions["impersonate"], ImpersonateTarget)
        self.assertTrue(self.calls[0][1]["impersonate"])
        response.close()

    def test_installation_replaces_an_already_cached_director(self):
        old = self.ydl._request_director
        with patch.object(old, "close", wraps=old.close) as close:
            self.assertTrue(install_public_transport(self.ydl, self.resolve))
            close.assert_called_once_with()
        self.assertIsNot(self.ydl._request_director, old)
        self.assertNotIn("CurlCFFI", self.ydl._request_director.handlers)

    def test_request_uses_pinned_dns_verified_tls_and_no_proxy_or_auto_redirect(self):
        self.responses.append(FakeResponse())
        response = self.open()
        options = self.sessions[0].options
        curl = options["curl_options"]
        self.assertIs(options["trust_env"], False)
        self.assertEqual(curl[CurlOpt.RESOLVE], ["www.tiktok.com:443:93.184.216.34"])
        self.assertEqual(curl[CurlOpt.FOLLOWLOCATION], 0)
        self.assertEqual(curl[CurlOpt.PROXY], "")
        self.assertEqual(curl[CurlOpt.NOPROXY], "*")
        self.assertEqual(curl[CurlOpt.ALTSVC_CTRL], 0)
        self.assertEqual(curl[CurlOpt.PROTOCOLS_STR], "http,https")
        self.assertEqual(curl[CurlOpt.REDIR_PROTOCOLS_STR], "http,https")
        self.assertEqual(curl[CurlOpt.HTTP_VERSION], CurlHttpVersion.V2TLS)
        kwargs = self.calls[0][1]
        self.assertIs(kwargs["verify"], True)
        self.assertEqual(kwargs["proxies"], {})
        self.assertIs(kwargs["allow_redirects"], False)
        self.assertEqual(kwargs["max_redirects"], 0)
        self.assertIs(kwargs["stream"], True)
        self.assertEqual(kwargs["http_version"], CurlHttpVersion.V2TLS)
        self.assertEqual(kwargs["timeout"], (7, 7))
        response.close()

    def test_global_certificate_bypass_does_not_disable_browser_tls_verification(self):
        self.ydl.params["nocheckcertificate"] = True
        self.responses.append(FakeResponse())
        response = self.open()
        self.assertIs(self.calls[0][1]["verify"], True)
        response.close()

    def test_browser_handler_rejects_non_tiktok_authorities(self):
        for url in ("https://example.com/", "https://tiktok.com.evil.test/",
                    "https://www.tiktok.com.evil.test/", "https://127.0.0.1/"):
            with self.subTest(url=url), self.assertRaises(UnsupportedRequest):
                self.handler().validate(self.request(url))
        self.assertEqual(self.sessions, [])

    def test_private_initial_dns_is_rejected_before_creating_a_session(self):
        self.dns_results["www.tiktok.com"] = ["93.184.216.34", "127.0.0.1"]
        with self.assertRaises(TransportError):
            self.open()
        self.assertEqual(self.sessions, [])

    def test_public_redirect_gets_a_fresh_session_and_fresh_dns_pin(self):
        first = FakeResponse(status=302, headers={"Location": "https://vt.tiktok.com/fixture"})
        self.responses.extend([first, FakeResponse(b"done")])
        self.dns_results["vt.tiktok.com"] = ["1.1.1.1"]
        response = self.open()
        self.assertEqual(response.read(), b"done")
        self.assertEqual(self.dns_calls, [("www.tiktok.com", 443), ("vt.tiktok.com", 443)])
        self.assertEqual(len(self.sessions), 2)
        self.assertTrue(first.closed)
        self.assertEqual(self.sessions[1].options["curl_options"][CurlOpt.RESOLVE], ["vt.tiktok.com:443:1.1.1.1"])
        self.assertTrue(all(session.closed for session in self.sessions))

    def test_dns_rebinding_on_same_host_is_rejected_before_second_connection(self):
        answers = iter([["93.184.216.34"], ["127.0.0.1"]])
        self.dns_results["www.tiktok.com"] = lambda: next(answers)
        first = FakeResponse(status=302, headers={"Location": "/rebound"})
        self.responses.append(first)
        with self.assertRaises(TransportError):
            self.open()
        self.assertEqual(len(self.dns_calls), 2)
        self.assertEqual(len(self.sessions), 1)
        self.assertTrue(first.closed)
        self.assertTrue(self.sessions[0].closed)

    def test_redirect_to_private_tiktok_dns_is_rejected(self):
        self.dns_results["vt.tiktok.com"] = ["169.254.169.254"]
        self.responses.append(FakeResponse(status=302, headers={"Location": "https://vt.tiktok.com/private"}))
        with self.assertRaises(TransportError):
            self.open()
        self.assertEqual(len(self.sessions), 1)
        self.assertTrue(self.sessions[0].closed)

    def test_redirect_outside_tiktok_never_reaches_dns_or_session(self):
        for target in ("http://127.0.0.1/private", "https://example.com/file",
                       "https://www.tiktok.com.evil.test/file"):
            with self.subTest(target=target):
                before_dns = len(self.dns_calls)
                before_sessions = len(self.sessions)
                self.responses.append(FakeResponse(status=302, headers={"Location": target}))
                with self.assertRaises(TransportError):
                    self.open()
                self.assertEqual(len(self.dns_calls), before_dns + 1)
                self.assertEqual(len(self.sessions), before_sessions + 1)
                self.assertTrue(self.sessions[-1].closed)

    def test_cross_authority_redirect_strips_explicit_sensitive_headers(self):
        self.responses.extend([
            FakeResponse(status=302, headers={"Location": "https://vt.tiktok.com/next"}),
            FakeResponse(),
        ])
        response = self.open(headers={
            "Authorization": "Bearer fixture", "Cookie": "secret=fixture",
            "Host": "www.tiktok.com", "Proxy-Authorization": "Basic fixture",
            "X-Fixture": "preserved",
        })
        first = {key.lower(): value for key, value in self.calls[0][1]["headers"].items()}
        second = {key.lower(): value for key, value in self.calls[1][1]["headers"].items()}
        self.assertEqual(first["authorization"], "Bearer fixture")
        for key in ("authorization", "cookie", "host", "proxy-authorization"):
            self.assertNotIn(key, second)
        self.assertEqual(second["x-fixture"], "preserved")
        response.close()

    def test_303_redirect_switches_post_to_get_and_drops_body_headers(self):
        self.responses.extend([
            FakeResponse(status=303, headers={"Location": "/get"}),
            FakeResponse(),
        ])
        response = self.open(data=b"fixture", headers={"Content-Type": "text/plain"})
        self.assertEqual(self.calls[0][1]["method"], "POST")
        self.assertEqual(self.calls[1][1]["method"], "GET")
        self.assertIsNone(self.calls[1][1]["data"])
        self.assertFalse({"content-type", "content-length"} & {
            key.lower() for key in self.calls[1][1]["headers"]})
        response.close()

    def test_307_redirect_preserves_post_body(self):
        self.responses.extend([
            FakeResponse(status=307, headers={"Location": "/same-method"}),
            FakeResponse(),
        ])
        response = self.open(data=b"fixture", headers={"Content-Type": "text/plain"})
        self.assertEqual(self.calls[1][1]["method"], "POST")
        self.assertEqual(self.calls[1][1]["data"], b"fixture")
        response.close()

    def test_redirect_limit_closes_every_session(self):
        self.responses.extend(FakeResponse(status=302, headers={"Location": "/again"}) for _ in range(6))
        with self.assertRaises(TransportError):
            self.open()
        self.assertEqual(len(self.calls), 6)
        self.assertTrue(all(session.closed for session in self.sessions))

    def test_streaming_response_keeps_session_alive_until_eof(self):
        fixture = FakeResponse(b"abcdef")
        self.responses.append(fixture)
        response = self.open()
        self.assertFalse(self.sessions[0].closed)
        self.assertEqual(response.read(1), b"a")
        self.assertFalse(self.sessions[0].closed)
        self.assertEqual(response.read(), b"bcdef")
        self.assertTrue(self.sessions[0].closed)
        self.assertEqual(self.sessions[0].close_count, 1)
        response.close()
        self.assertEqual(self.sessions[0].close_count, 1)

    def test_explicit_close_releases_unconsumed_stream_and_session(self):
        fixture = FakeResponse()
        self.responses.append(fixture)
        response = self.open()
        response.close()
        self.assertTrue(fixture.closed)
        self.assertEqual(self.sessions[0].close_count, 1)

    def test_http_error_response_can_be_closed_by_the_caller(self):
        self.responses.append(FakeResponse(status=403))
        with self.assertRaises(HTTPError) as raised:
            self.open()
        raised.exception.response.close()
        self.assertEqual(self.sessions[0].close_count, 1)

    def test_tls_failure_closes_session_and_preserves_certificate_error(self):
        self.responses.append(curl_cffi.requests.errors.RequestsError(
            "fixture certificate", code=CurlECode.PEER_FAILED_VERIFICATION))
        with self.assertRaises(CertificateVerifyError):
            self.open()
        self.assertEqual(self.sessions[0].close_count, 1)

    def test_real_tiktok_extractor_uses_browser_transport_and_parses_fixture(self):
        video_id = "7412345678901234567"
        media_url = "https://v16-webapp.tiktokcdn.com/video/fixture.mp4"
        item = {
            "id": video_id, "desc": "Transport fixture", "createTime": 1725000000,
            "author": {"id": "123", "uniqueId": "fixture", "nickname": "Fixture", "secUid": "fixture-sec"},
            "video": {"duration": 3, "width": 720, "height": 1280, "playAddr": media_url},
            "stats": {"playCount": 10, "diggCount": 2},
        }
        envelope = {"__DEFAULT_SCOPE__": {"webapp.video-detail": {
            "statusCode": 0, "itemInfo": {"itemStruct": item},
        }}}
        webpage = ('<html><script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">'
                   + json.dumps(envelope) + "</script></html>").encode()
        self.responses.append(FakeResponse(webpage))
        self.ydl.add_info_extractor(TikTokIE())
        result = self.ydl.extract_info(
            "https://www.tiktok.com/@fixture/video/" + video_id,
            download=False, ie_key="TikTok")
        self.assertEqual(result["id"], video_id)
        self.assertEqual(result["title"], "Transport fixture")
        self.assertEqual(result["url"], media_url)
        self.assertEqual(result["uploader"], "fixture")
        self.assertEqual(len(self.calls), 1)
        self.assertTrue(self.calls[0][1]["impersonate"])
        self.assertTrue(all(session.closed for session in self.sessions))


if __name__ == "__main__":
    unittest.main()
