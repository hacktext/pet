import http.client
import io
import json
import socket
import ssl
import urllib.error

import pytest

from petgen.server import Server, ServerAbort, ServerError


class Resp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def ok(body):
    return Resp(json.dumps(body, ensure_ascii=False).encode("utf-8"))


def http_error(code, body):
    return urllib.error.HTTPError("https://api.invalid/x", code, "err", {},
                                  io.BytesIO(json.dumps(body, ensure_ascii=False).encode("utf-8")))


class Opener:
    def __init__(self, *results):
        self.results = list(results)
        self.reqs = []

    def __call__(self, req, timeout=None):
        self.reqs.append(req)
        r = self.results.pop(0)
        if isinstance(r, Exception):
            raise r
        return r


def srv(opener, sleeps=None):
    sleep = (lambda s: None) if sleeps is None else sleeps.append
    return Server("https://api.invalid/", "secret-key-1", opener=opener, sleep=sleep)


def test_claim_posts_with_the_worker_key_and_returns_the_plain_body():
    o = Opener(ok({"job": None, "paused_reason": "生成额度不足"}))
    assert srv(o).claim() == {"job": None, "paused_reason": "生成额度不足"}
    req = o.reqs[0]
    assert req.full_url == "https://api.invalid/internal/aipet/jobs/claim" and req.get_method() == "POST"
    assert req.get_header("X-worker-key") == "secret-key-1"
    assert req.get_header("Content-type") == "application/json"
    assert json.loads(req.data) == {}


def test_progress_sends_the_step_and_the_cost_increment_and_returns_abort():
    o = Opener(ok({"abort": False}), ok({"abort": True}), http_error(409, {"error": "job is failed", "abort": True}))
    s = srv(o)
    cost = {"image_units": 8, "video_units": 0, "cents": 80}
    assert s.progress(12, "refs", 1, 3, "front", cost) is False
    assert json.loads(o.reqs[0].data) == {"stage": "refs", "done": 1, "total": 3, "message": "front", "cost": cost}
    assert o.reqs[0].full_url == "https://api.invalid/internal/aipet/jobs/12/progress"
    assert s.progress(12, "video", 1, 5, "walk", cost) is True
    assert s.progress(12, "video", 1, 5, "walk", cost) is True


def test_progress_and_claim_are_not_retried():
    o = Opener(urllib.error.URLError("reset"))
    with pytest.raises(ServerError):
        srv(o).progress(12, "video", 1, 5, "walk", {})
    assert len(o.reqs) == 1
    o = Opener(http_error(503, {"error": "busy"}))
    with pytest.raises(ServerError):
        srv(o).claim()
    assert len(o.reqs) == 1


def test_upload_urls_finish_fail_and_status_bodies():
    o = Opener(ok([{"path": "pet.json", "url": "https://oss.invalid/a?sig=1"}]), ok({}), ok({}), ok({}))
    s = srv(o)
    files = [{"path": "pet.json", "bytes": 10, "content_type": "application/json"}]
    assert s.upload_urls(12, files) == {"pet.json": "https://oss.invalid/a?sig=1"}
    done = [{"path": "pet.json", "bytes": 10, "sha256": "ab", "qa": None, "deliverable": True}]
    s.finish(12, "left", done)
    s.fail(12, "video:play", "x" * 300)
    s.status(True, "生成额度不足", {"image": 1000, "video": 27})
    bodies = [json.loads(r.data) for r in o.reqs]
    assert bodies == [{"files": files}, {"walk_facing": "left", "files": done},
                      {"stage": "video:play", "reason": "x" * 255},
                      {"paused": True, "reason": "生成额度不足", "balance": {"image": 1000, "video": 27}}]
    assert [r.full_url.rsplit("/aipet/", 1)[1] for r in o.reqs] == [
        "jobs/12/upload-urls", "jobs/12/finish", "jobs/12/fail", "worker/status"]


def test_an_http_error_carries_status_and_reason_but_never_the_key():
    o = Opener(http_error(401, {"error": "unauthorized"}))
    with pytest.raises(ServerError, match="HTTP 401 unauthorized") as e:
        srv(o).claim()
    assert e.value.status == 401 and not isinstance(e.value, ServerAbort)
    assert "secret-key-1" not in str(e.value)


def test_a_409_abort_is_a_server_abort_and_is_not_retried():
    o = Opener(http_error(409, {"error": "job is refunded", "abort": True}))
    with pytest.raises(ServerAbort, match="job is refunded"):
        srv(o).finish(12, "left", [])
    assert len(o.reqs) == 1


def test_a_422_is_a_plain_error_and_is_not_retried():
    o = Opener(http_error(422, {"error": "content_type 与扩展名不符：stand.mp4"}))
    with pytest.raises(ServerError, match="HTTP 422 content_type") as e:
        srv(o).upload_urls(12, [])
    assert not isinstance(e.value, ServerAbort)
    assert len(o.reqs) == 1


def test_non_json_and_network_errors_raise():
    with pytest.raises(ServerError, match="not JSON"):
        srv(Opener(Resp(b"<html>502</html>"))).claim()
    with pytest.raises(ServerError, match="network error"):
        srv(Opener(urllib.error.URLError("refused"))).claim()


@pytest.mark.parametrize("exc", [
    socket.timeout("timed out"), TimeoutError("t"), ConnectionResetError("reset"),
    http.client.IncompleteRead(b"x"), http.client.RemoteDisconnected("bye"),
    ssl.SSLError("bad record"), OSError("network unreachable"),
])
def test_every_transport_failure_becomes_a_server_error(exc):
    with pytest.raises(ServerError, match="network error"):
        srv(Opener(exc)).claim()


def test_a_failure_while_reading_the_body_is_a_server_error():
    class Broken(Resp):
        def read(self, *a):
            raise ConnectionResetError("mid-body")
    with pytest.raises(ServerError, match="network error"):
        srv(Opener(Broken(b"{}"))).claim()


def test_a_200_with_a_non_json_body_is_a_server_error():
    with pytest.raises(ServerError, match="not JSON") as e:
        srv(Opener(Resp(b"ok"))).status(False, "", {})
    assert e.value.status == 200


def test_idempotent_calls_retry_network_and_5xx_with_backoff():
    sleeps = []
    o = Opener(urllib.error.URLError("reset"), http_error(502, {"error": "bad gateway"}), ok({}))
    srv(o, sleeps).finish(12, "left", [])
    assert len(o.reqs) == 3 and sleeps == [2, 4]

    sleeps = []
    o = Opener(http_error(429, {"error": "slow down"}), http_error(408, {"error": "t"}),
               ok([{"path": "a.png", "url": "u"}]))
    assert srv(o, sleeps).upload_urls(12, []) == {"a.png": "u"}
    assert sleeps == [2, 4]


def test_idempotent_calls_give_up_after_three_tries():
    sleeps = []
    o = Opener(*[http_error(503, {"error": "down"}) for _ in range(3)])
    with pytest.raises(ServerError, match="HTTP 503") as e:
        srv(o, sleeps).fail(12, "claim", "boom")
    assert e.value.status == 503 and len(o.reqs) == 3 and sleeps == [2, 4]


def test_idempotent_calls_do_not_retry_other_4xx():
    for code in (400, 401, 403, 404, 422):
        o = Opener(http_error(code, {"error": "no"}))
        with pytest.raises(ServerError):
            srv(o).fail(12, "claim", "boom")
        assert len(o.reqs) == 1


def test_put_uploads_with_the_signed_content_type_and_no_worker_key(tmp_path):
    f = tmp_path / "stand.mp4"
    f.write_bytes(b"MP4")
    o = Opener(urllib.error.URLError("reset"), Resp(b""))
    srv(o).put("https://oss.invalid/stand.mp4?sig=1", f, "video/mp4")
    req = o.reqs[1]
    assert req.get_method() == "PUT" and req.data == b"MP4"
    assert req.get_header("Content-type") == "video/mp4"
    assert req.get_header("X-worker-key") is None


def test_put_does_not_retry_a_refused_signature(tmp_path):
    f = tmp_path / "stand.mp4"
    f.write_bytes(b"MP4")
    o = Opener(urllib.error.HTTPError("https://oss.invalid", 403, "Forbidden", {}, io.BytesIO(b"")))
    with pytest.raises(ServerError, match="upload stand.mp4 failed: HTTP 403"):
        srv(o).put("https://oss.invalid/stand.mp4?sig=1", f, "video/mp4")
    assert len(o.reqs) == 1


def test_put_retries_ssl_and_os_errors(tmp_path):
    f = tmp_path / "stand.mp4"
    f.write_bytes(b"MP4")
    o = Opener(ssl.SSLError("x"), OSError("y"), Resp(b""))
    srv(o).put("https://oss.invalid/stand.mp4?sig=1", f, "video/mp4")
    assert len(o.reqs) == 3


def test_repr_hides_the_key():
    assert "secret" not in repr(srv(Opener()))
