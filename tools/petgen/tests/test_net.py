import http.server
import threading
import urllib.request

import pytest

from petgen import net


@pytest.fixture
def seen():
    got = []

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            got.append(self.headers.get("User-Agent"))
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"{}")

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield got, f"http://127.0.0.1:{srv.server_address[1]}/"
    srv.shutdown()
    urllib.request.install_opener(None)


def test_requests_name_petgen_not_python(seen):
    got, url = seen
    net.install()
    urllib.request.urlopen(urllib.request.Request(url, headers={"Authorization": "Bearer x"}), timeout=5).read()
    assert got == [net.USER_AGENT]


def test_a_request_may_still_set_its_own(seen):
    got, url = seen
    net.install()
    urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "other"}), timeout=5).read()
    assert got == ["other"]
