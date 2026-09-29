import io
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
