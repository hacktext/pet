import http.client
import io
import ssl
import json
import pytest
import urllib.error

from petgen import kling


@pytest.fixture(autouse=True)
def mock_cfg(monkeypatch):
    """All tests use fake API credentials to avoid reading secrets."""
    monkeypatch.setattr(kling, "_cfg", lambda: ("test-key", "https://example.invalid"))


class TestWait:
    def test_returns_data_on_succeed(self, monkeypatch):
        """wait() returns the data dict when poll says task_status is 'succeed'."""
        monkeypatch.setattr(kling, "_call", lambda *a, **k: {
            "code": 0,
            "data": {"task_status": "succeed", "result": "test"}
        })
        monkeypatch.setattr(kling.time, "sleep", lambda x: None)

        result = kling.wait("image", "task-123")
        assert result == {"task_status": "succeed", "result": "test"}

    def test_raises_on_error_code(self, monkeypatch):
        """wait() raises KlingError immediately if poll returns non-zero code."""
        monkeypatch.setattr(kling, "_call", lambda *a, **k: {
            "code": 1201,
            "message": "bad request"
        })
        monkeypatch.setattr(kling.time, "sleep", lambda x: None)

        with pytest.raises(kling.KlingError) as exc_info:
            kling.wait("image", "task-123")

        assert "image" in str(exc_info.value)
        assert "task-123" in str(exc_info.value)
        assert "1201" in str(exc_info.value)
        assert "bad request" in str(exc_info.value)

    def test_raises_on_failed_status(self, monkeypatch):
        """wait() raises KlingError when task_status is 'failed'."""
        monkeypatch.setattr(kling, "_call", lambda *a, **k: {
            "code": 0,
            "data": {"task_status": "failed", "task_status_msg": "timeout"}
        })
        monkeypatch.setattr(kling.time, "sleep", lambda x: None)

        with pytest.raises(kling.KlingError) as exc_info:
            kling.wait("video", "task-456")

        assert "failed" in str(exc_info.value).lower()

    def test_polls_through_processing(self, monkeypatch):
        """wait() keeps polling through 'processing' status then succeeds."""
        call_count = [0]

        def mock_call(*a, **k):
            call_count[0] += 1
            if call_count[0] < 3:
                return {"code": 0, "data": {"task_status": "processing"}}
            return {"code": 0, "data": {"task_status": "succeed", "result": "done"}}

        sleep_count = [0]
        def mock_sleep(x):
            sleep_count[0] += 1

        monkeypatch.setattr(kling, "_call", mock_call)
        monkeypatch.setattr(kling.time, "sleep", mock_sleep)

        result = kling.wait("image", "task-789")

        assert call_count[0] == 3
        assert sleep_count[0] == 2
        assert result["result"] == "done"


class TestCall:
    def test_non_json_http_error_returns_dict(self, monkeypatch):
        """_call returns error dict when HTTPError body is non-JSON HTML (body read once)."""
        html_body = "<html><body>502 Bad Gateway - the server is temporarily unavailable</body></html>"

        def mock_urlopen(req, timeout=None):
            # Create a real HTTPError with fp that can only be read once
            fp = io.BytesIO(html_body.encode())
            raise urllib.error.HTTPError("https://example.invalid", 502, "Bad Gateway", {}, fp)

        monkeypatch.setattr(kling.urllib.request, "urlopen", mock_urlopen)

        result = kling._call("GET", "/v1/images/generations/task-1")

        assert result["code"] == 502
        # Message should be the first 200 chars of the HTML body
        assert result["message"] == html_body[:200]

    def test_json_http_error_returns_parsed_dict(self, monkeypatch):
        """_call returns parsed JSON dict when HTTPError body is JSON."""
        json_body = '{"code": 1201, "message": "invalid request"}'

        def mock_urlopen(req, timeout=None):
            fp = io.BytesIO(json_body.encode())
            raise urllib.error.HTTPError("https://example.invalid", 400, "Bad Request", {}, fp)

        monkeypatch.setattr(kling.urllib.request, "urlopen", mock_urlopen)

        result = kling._call("POST", "/v1/images/generations")

        assert result == {"code": 1201, "message": "invalid request"}

    def test_urlerror_raises_kling_error(self, monkeypatch):
        """_call raises KlingError when URLError occurs."""
        def mock_urlopen(req, timeout=None):
            raise urllib.error.URLError("network unreachable")

        monkeypatch.setattr(kling.urllib.request, "urlopen", mock_urlopen)

        with pytest.raises(kling.KlingError) as exc_info:
            kling._call("GET", "/v1/images/generations/task-1")

        assert "network" in str(exc_info.value).lower() or "unreachable" in str(exc_info.value).lower()

    def test_timeout_error_raises_kling_error(self, monkeypatch):
        """_call raises KlingError when socket timeout occurs."""
        import socket

        def mock_urlopen(req, timeout=None):
            raise socket.timeout("request timed out")

        monkeypatch.setattr(kling.urllib.request, "urlopen", mock_urlopen)

        with pytest.raises(kling.KlingError) as exc_info:
            kling._call("GET", "/v1/images/generations/task-1")

        assert "timeout" in str(exc_info.value).lower()


class TestWaitHooks:
    def test_on_poll_runs_before_every_poll(self, monkeypatch):
        replies = [{"code": 0, "data": {"task_status": "processing"}},
                   {"code": 0, "data": {"task_status": "succeed"}}]
        monkeypatch.setattr(kling, "_call", lambda *a, **k: replies.pop(0))
        monkeypatch.setattr(kling.time, "sleep", lambda x: None)
        polls = []
        kling.wait("video", "t-1", on_poll=lambda: polls.append(1))
        assert polls == [1, 1]

    def test_a_failed_task_is_a_task_failure(self, monkeypatch):
        monkeypatch.setattr(kling, "_call", lambda *a, **k: {
            "code": 0, "data": {"task_status": "failed", "task_status_msg": "内容审核未通过"}})
        with pytest.raises(kling.KlingTaskFailed, match="内容审核未通过"):
            kling.wait("image", "t-2")

    def test_a_refused_create_is_a_rejection(self, monkeypatch):
        monkeypatch.setattr(kling, "_exchange", lambda *a, **k: (None, {"code": 1301, "message": "图片审核未通过"}, False))
        with pytest.raises(kling.KlingRejected, match="code=1301 图片审核未通过"):
            kling.create_image({})


def test_units_left_sums_the_online_packs_of_a_kind(monkeypatch):
    monkeypatch.setattr(kling, "balance", lambda: [
        {"resource_pack_name": "视频生成-100-5并发", "remaining_quantity": "40", "status": "online"},
        {"resource_pack_name": "视频生成-50", "remaining_quantity": "9", "status": "expired"},
        {"resource_pack_name": "图像生成-1000-9并发", "remaining_quantity": "968", "status": "online"},
    ])
    assert kling.units_left("video") == 40.0
    assert kling.units_left("image") == 968.0


def test_download_goes_through_the_retrying_fetch(monkeypatch, tmp_path):
    seen = []
    monkeypatch.setattr(kling, "fetch", lambda url, dest: seen.append((url, dest)) or dest)
    kling.download("https://x.invalid/a.mp4", tmp_path / "a.mp4")
    assert seen == [("https://x.invalid/a.mp4", tmp_path / "a.mp4")]


class _Resp:
    """A urlopen() response whose read() returns body or raises it."""

    def __init__(self, body):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self):
        if isinstance(self.body, BaseException):
            raise self.body
        return self.body


def _urlopen_raising(exc):
    def urlopen(req, timeout=None):
        raise exc
    return urlopen


def _http_error(status, body):
    def urlopen(req, timeout=None):
        raise urllib.error.HTTPError("https://example.invalid", status, "x", {}, io.BytesIO(body.encode()))
    return urlopen


class TestTransportFailures:
    """Every way the connection can break is a plain KlingError -- never a
    crash, never a rejection (the create may have gone through)."""

    @pytest.mark.parametrize("exc", [
        http.client.RemoteDisconnected("Remote end closed connection without response"),
        ConnectionResetError(104, "Connection reset by peer"),
        ssl.SSLError("EOF occurred in violation of protocol"),
    ])
    def test_a_broken_connection_is_a_kling_error(self, monkeypatch, exc):
        monkeypatch.setattr(kling.urllib.request, "urlopen", _urlopen_raising(exc))
        with pytest.raises(kling.KlingError) as e:
            kling.create_image({})
        assert type(e.value) is kling.KlingError

    def test_a_body_cut_short_is_a_kling_error(self, monkeypatch):
        monkeypatch.setattr(kling.urllib.request, "urlopen",
                            lambda req, timeout=None: _Resp(http.client.IncompleteRead(b"{", 10)))
        with pytest.raises(kling.KlingError) as e:
            kling.create_video({})
        assert type(e.value) is kling.KlingError

    def test_a_non_json_success_body_is_a_kling_error(self, monkeypatch):
        monkeypatch.setattr(kling.urllib.request, "urlopen", lambda req, timeout=None: _Resp(b"<html>oops</html>"))
        with pytest.raises(kling.KlingError) as e:
            kling._call("GET", "/v1/images/generations/t")
        assert type(e.value) is kling.KlingError


class TestCreateVerdict:
    """KlingRejected only for a definite refusal; anything that may have been
    accepted is a plain KlingError (pipeline: outcome unknown, stop)."""

    @pytest.mark.parametrize("status,body", [
        (502, "<html>502 Bad Gateway</html>"),
        (503, '{"code": 5000, "message": "server busy"}'),
        (500, '{"code": 1201, "message": "odd"}'),
        (408, '{"code": 1201, "message": "timeout"}'),
        (429, '{"code": 1302, "message": "too many requests"}'),
        (400, "<html>bad</html>"),
    ])
    def test_an_answer_that_may_hide_an_accepted_task_is_not_a_rejection(self, monkeypatch, status, body):
        monkeypatch.setattr(kling.urllib.request, "urlopen", _http_error(status, body))
        with pytest.raises(kling.KlingError) as e:
            kling.create_video({})
        assert type(e.value) is kling.KlingError

    def test_no_resource_pack_is_a_rejection(self, monkeypatch):
        monkeypatch.setattr(kling.urllib.request, "urlopen",
                            lambda req, timeout=None: _Resp(b'{"code": 1102, "message": "no resource pack"}'))
        with pytest.raises(kling.KlingRejected, match="1102"):
            kling.create_video({})

    def test_a_4xx_with_a_kling_code_is_a_rejection(self, monkeypatch):
        monkeypatch.setattr(kling.urllib.request, "urlopen", _http_error(400, '{"code": 1201, "message": "bad"}'))
        with pytest.raises(kling.KlingRejected, match="1201"):
            kling.create_image({})

    def test_a_server_side_kling_code_is_not_a_rejection(self, monkeypatch):
        monkeypatch.setattr(kling.urllib.request, "urlopen",
                            lambda req, timeout=None: _Resp(b'{"code": 5001, "message": "internal"}'))
        with pytest.raises(kling.KlingError) as e:
            kling.create_image({})
        assert type(e.value) is kling.KlingError

    def test_success_without_a_task_id_is_not_a_rejection(self, monkeypatch):
        monkeypatch.setattr(kling.urllib.request, "urlopen", lambda req, timeout=None: _Resp(b'{"code": 0, "data": {}}'))
        with pytest.raises(kling.KlingError) as e:
            kling.create_image({})
        assert type(e.value) is kling.KlingError

    def test_a_task_id_is_returned(self, monkeypatch):
        monkeypatch.setattr(kling.urllib.request, "urlopen",
                            lambda req, timeout=None: _Resp(b'{"code": 0, "data": {"task_id": "T1"}}'))
        assert kling.create_image({}) == "T1"
