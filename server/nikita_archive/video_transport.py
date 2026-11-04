"""Browser TLS for TikTok with the same public-network boundary as Python downloads.

libcurl resolves outside Python's socket hooks. Every request is therefore pinned
to validated public addresses, and every redirect is followed explicitly.
"""
import ipaddress
import math
import socket
from urllib.parse import urljoin, urlsplit

TIKTOK_HOSTS = frozenset({"tiktok.com","www.tiktok.com","m.tiktok.com","vt.tiktok.com","vm.tiktok.com"})


def pinned_destination(url, resolver):
    parsed = urlsplit(url)
    if (parsed.scheme.lower() not in ("http","https") or not parsed.hostname
            or parsed.username is not None or parsed.password is not None):
        raise OSError("Unsupported network destination")
    host = parsed.hostname.encode("idna").decode("ascii").lower()
    port = parsed.port or (443 if parsed.scheme.lower() == "https" else 80)
    addresses = resolver(host,port,type=socket.SOCK_STREAM)
    values = []
    for item in addresses:
        address = ipaddress.ip_address(item[4][0])
        if not address.is_global or address.is_multicast:
            raise OSError("Private network destinations are not allowed")
        value = "["+str(address)+"]" if address.version == 6 else str(address)
        if value not in values:
            values.append(value)
    if not values:
        raise OSError("No public network destination")
    return f"{host}:{port}:"+",".join(values)


def install_public_transport(downloader, resolver):
    """Replace native curl's unguarded resolver; ordinary CDN requests use urllib."""
    try:
        import curl_cffi.requests as curl_requests
        from curl_cffi.const import CurlECode, CurlHttpVersion, CurlOpt
        from yt_dlp.networking._curlcffi import CurlCFFIRH, CurlCFFIResponseAdapter
        from yt_dlp.networking.exceptions import (
            CertificateVerifyError, HTTPError, SSLError, TransportError, UnsupportedRequest)
    except ImportError:
        return False

    class PublicResponse(CurlCFFIResponseAdapter):
        def __init__(self, response, session):
            self._public_session = session
            super().__init__(response)

        def close(self):
            try:
                super().close()
            finally:
                session, self._public_session = self._public_session, None
                if session is not None:
                    session.close()

    class PublicCurlCFFIRH(CurlCFFIRH):
        RH_NAME = "public curl_cffi"

        def _validate(self, request):
            super()._validate(request)
            if (urlsplit(request.url).hostname or "").lower() not in TIKTOK_HOSTS:
                raise UnsupportedRequest("Browser transport is restricted to TikTok")

        def _send(self, request):
            url, method, data = request.url, request.method, request.data
            headers = dict(self._get_impersonate_headers(request))
            target = self._get_request_target(request)
            timeout = max(1,min(20,self._calculate_timeout(request)))
            cookiejar = self._get_cookiejar(request)
            for hop in range(6):
                parsed = urlsplit(url)
                if (parsed.hostname or "").lower() not in TIKTOK_HOSTS:
                    raise TransportError("TikTok redirected to an unsupported destination")
                try:
                    pin = pinned_destination(url,resolver)
                except (OSError,ValueError,TypeError) as error:
                    raise TransportError(cause=error) from error
                # A fresh session prevents connection/DNS reuse from defeating the
                # validation above. HTTP/3 and Alt-Svc cannot change destinations.
                session = curl_requests.Session(
                    cookies=cookiejar,trust_env=False,curl_options={
                        CurlOpt.RESOLVE:[pin],CurlOpt.FOLLOWLOCATION:0,
                        CurlOpt.PROXY:"",CurlOpt.NOPROXY:"*",
                        CurlOpt.ALTSVC_CTRL:0,CurlOpt.PROTOCOLS_STR:"http,https",
                        CurlOpt.REDIR_PROTOCOLS_STR:"http,https",
                        CurlOpt.HTTP_VERSION:CurlHttpVersion.V2TLS,
                        CurlOpt.LOW_SPEED_LIMIT:1,CurlOpt.LOW_SPEED_TIME:math.ceil(timeout)})
                try:
                    response = session.request(
                        method=method,url=url,headers=headers,data=data,
                        verify=True,proxies={},allow_redirects=False,max_redirects=0,
                        timeout=(min(10,timeout),timeout),stream=True,
                        http_version=CurlHttpVersion.V2TLS,
                        impersonate=self._SUPPORTED_IMPERSONATE_TARGET_MAP.get(target))
                except curl_requests.errors.RequestsError as error:
                    session.close()
                    if error.code == CurlECode.PEER_FAILED_VERIFICATION:
                        raise CertificateVerifyError(cause=error) from error
                    if error.code in (CurlECode.SSL_CONNECT_ERROR,CurlECode.SSL_CERTPROBLEM):
                        raise SSLError(cause=error) from error
                    raise TransportError(cause=error) from error
                except Exception:
                    session.close()
                    raise
                status = response.status_code
                location = response.headers.get("Location")
                if status in (301,302,303,307,308) and location:
                    response.close()
                    session.close()
                    if hop == 5:
                        raise TransportError("Too many TikTok redirects")
                    next_url = urljoin(url,location)
                    before, after = urlsplit(url),urlsplit(next_url)
                    # Explicit headers are not cookie-jar scoped. Never forward
                    # credentials or a forced Host to a different authority.
                    if before.netloc.lower() != after.netloc.lower():
                        headers = {key:value for key,value in headers.items()
                                   if key.lower() not in ("authorization","cookie","host","proxy-authorization")}
                    if status == 303 and method != "HEAD" or status in (301,302) and method == "POST":
                        method, data = "GET",None
                        headers = {key:value for key,value in headers.items()
                                   if key.lower() not in ("content-type","content-length")}
                    url = next_url
                    continue
                try:
                    adapted = PublicResponse(response,session)
                except Exception:
                    response.close()
                    session.close()
                    raise
                if not 200 <= status < 300:
                    raise HTTPError(adapted)
                return adapted
            raise TransportError("Too many TikTok redirects")

    original = downloader.build_request_director
    def build_public_director(handlers, preferences=None):
        # Never leave the native resolver available as a fallback. Preferences
        # registered on CurlCFFIRH also cover this subclass and impersonate=True.
        safe = [handler for handler in handlers if not issubclass(handler,CurlCFFIRH)]
        safe.append(PublicCurlCFFIRH)
        return original(safe,preferences=preferences)
    downloader.build_request_director = build_public_director
    cached = downloader.__dict__.pop("_request_director",None)
    if cached is not None:
        cached.close()
    return True
