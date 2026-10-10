import http.client
import io
import urllib.error

import pytest

from petgen.download import DownloadError, fetch


class Resp:
    """A urlopen response: chunks, a status, Content-Length; optionally drops
    the connection (IncompleteRead) after `fail_after` chunks."""

    def __init__(self, chunks, status=200, length=None, fail_after=None):
        self.status = status
        self._chunks = list(chunks)
        total = sum(len(c) for c in self._chunks)
        self.headers = {"Content-Length": str(total if length is None else length)}
        self._fail_after = fail_after
        self._n = 0

    def read(self, n=-1):
        if self._fail_after is not None and self._n == self._fail_after:
            raise http.client.IncompleteRead(b"", 10)
        self._n += 1
        return self._chunks.pop(0) if self._chunks else b""

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


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


def test_writes_via_a_part_file_and_renames(tmp_path):
    dest = tmp_path / "a" / "stand.mp4"
    fetch("https://x.invalid/a", dest, opener=Opener(Resp([b"abc", b"def"])), sleep=lambda s: None)
    assert dest.read_bytes() == b"abcdef"
    assert not dest.with_name("stand.mp4.part").exists()


def test_a_dropped_connection_resumes_with_range(tmp_path):
    sleeps = []
    o = Opener(Resp([b"abc", b"def"], fail_after=1), Resp([b"def"], status=206))
    dest = fetch("https://x.invalid/a", tmp_path / "v.mp4", opener=o, sleep=sleeps.append)
    assert dest.read_bytes() == b"abcdef"
    assert o.reqs[0].get_header("Range") is None
    assert o.reqs[1].get_header("Range") == "bytes=3-"
    assert sleeps == [2]


def test_a_server_that_ignores_range_is_read_from_the_start(tmp_path):
    o = Opener(Resp([b"abc", b"def"], fail_after=1), Resp([b"abcdef"], status=200))
    assert fetch("https://x.invalid/a", tmp_path / "v.mp4", opener=o, sleep=lambda s: None).read_bytes() == b"abcdef"


def test_a_short_body_without_an_error_is_retried(tmp_path):
    o = Opener(Resp([b"abc"], length=6), Resp([b"def"], status=206))
    assert fetch("https://x.invalid/a", tmp_path / "v.mp4", opener=o, sleep=lambda s: None).read_bytes() == b"abcdef"


def test_gives_up_after_three_retries(tmp_path):
    o = Opener(*[urllib.error.URLError("reset")] * 4)
    with pytest.raises(DownloadError, match="4 tries"):
        fetch("https://x.invalid/a", tmp_path / "v.mp4", opener=o, sleep=lambda s: None)
    assert len(o.reqs) == 4
    assert not (tmp_path / "v.mp4").exists()


def test_an_expired_url_is_not_retried(tmp_path):
    o = Opener(urllib.error.HTTPError("https://x.invalid/a", 403, "Forbidden", {}, io.BytesIO(b"")))
    with pytest.raises(DownloadError, match="403"):
        fetch("https://x.invalid/a", tmp_path / "v.mp4", opener=o, sleep=lambda s: None)
    assert len(o.reqs) == 1
