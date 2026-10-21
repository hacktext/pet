"""The PHP side's internal worker API (spec 2026-10-10 4.3; contract in the
server README). POST JSON with X-Worker-Key; success is the plain JSON body,
an error is an HTTP status plus {"error": ...} -- and {"abort": true} when
the job is no longer 'generating'. The key is never logged or put in an error."""
from __future__ import annotations

import http.client
import json
import logging
import socket
import ssl
import time
import urllib.error
import urllib.request
from pathlib import Path

log = logging.getLogger("petgen.server")
PREFIX = "/internal/aipet/"
RETRY_TRIES = 3
# Everything that can go wrong on the wire, including while reading the body.
# HTTPError is a URLError (an OSError), so it must be caught before this.
NETWORK_ERRORS = (urllib.error.URLError, socket.timeout, TimeoutError, ConnectionError,
                  http.client.HTTPException, ssl.SSLError, OSError)


class ServerError(Exception):
    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


class ServerAbort(ServerError):
    """409 with abort: an admin changed the job; stop it, do not report a failure."""


def _transient(e: ServerError) -> bool:
    """Worth retrying: the network failed, or the server said 5xx / 408 / 429."""
    if isinstance(e, ServerAbort):
        return False
    return e.status is None or e.status >= 500 or e.status in (408, 429)


class Server:
    def __init__(self, base: str, key: str, *, opener=None, sleep=time.sleep, timeout: float = 30):
        self.base = base.rstrip("/")
        self._key = key
        self._open = opener or urllib.request.urlopen
        self._sleep = sleep
        self._timeout = timeout

    def __repr__(self) -> str:
        return f"Server({self.base!r})"

    def _post(self, path: str, body: dict):
        req = urllib.request.Request(self.base + PREFIX + path, method="POST",
                                     data=json.dumps(body, ensure_ascii=False).encode("utf-8"))
        req.add_header("Content-Type", "application/json")
        req.add_header("Accept", "application/json")
        req.add_header("X-Worker-Key", self._key)
        status = 200
        try:
            try:
                with self._open(req, timeout=self._timeout) as r:
                    text = r.read().decode("utf-8", "replace")
            except urllib.error.HTTPError as e:
                status, text = e.code, e.read().decode("utf-8", "replace")
        except NETWORK_ERRORS as e:
            raise ServerError(f"{path}: network error: {getattr(e, 'reason', None) or e}") from None
        try:
            res = json.loads(text)
        except ValueError:
            raise ServerError(f"{path}: HTTP {status}, not JSON: {text[:200]}", status) from None
        if status != 200:
            err = res.get("error", "") if isinstance(res, dict) else ""
            cls = ServerAbort if status == 409 and isinstance(res, dict) and res.get("abort") else ServerError
            raise cls(f"{path}: HTTP {status} {err}", status)
        return res

    def _post_idempotent(self, path: str, body: dict):
        """For calls that are safe to repeat: ride out a flaky network or a 5xx."""
        for attempt in range(1, RETRY_TRIES + 1):
            try:
                return self._post(path, body)
            except ServerError as e:
                if attempt == RETRY_TRIES or not _transient(e):
                    raise
                log.warning("请求后台 %s 出错，%d 秒后重试：%s", path, 2 ** attempt, e)
                self._sleep(2 ** attempt)

    def claim(self) -> dict:
        return self._post("jobs/claim", {}) or {}

    def progress(self, job_id: int, stage: str, done: int, total: int, message: str, cost: dict) -> bool:
        try:
            res = self._post(f"jobs/{job_id}/progress", {"stage": stage, "done": done, "total": total,
                                                         "message": message, "cost": cost})
        except ServerAbort:
            return True
        return bool((res or {}).get("abort"))

    def upload_urls(self, job_id: int, files: list[dict]) -> dict[str, str]:
        res = self._post_idempotent(f"jobs/{job_id}/upload-urls", {"files": files})
        return {x["path"]: x["url"] for x in res}

    def put(self, url: str, path: Path, content_type: str, retries: int = 3) -> None:
        data = Path(path).read_bytes()
        last = ""
        for attempt in range(retries + 1):
            if attempt:
                self._sleep(2 ** attempt)
            req = urllib.request.Request(url, data=data, method="PUT")
            req.add_header("Content-Type", content_type)   # must equal the type the URL was signed for
            try:
                with self._open(req, timeout=300) as r:
                    r.read()
                return
            except urllib.error.HTTPError as e:
                last = f"HTTP {e.code}"
                if 400 <= e.code < 500 and e.code not in (408, 429):
                    break                                   # signature / expiry: retrying cannot help
            except NETWORK_ERRORS as e:
                last = str(getattr(e, "reason", None) or e)
        raise ServerError(f"upload {Path(path).name} failed: {last}")

    def finish(self, job_id: int, walk_facing: str, files: list[dict]) -> None:
        self._post_idempotent(f"jobs/{job_id}/finish", {"walk_facing": walk_facing, "files": files})

    def character_upload_urls(self, code: str, files: list[dict]) -> dict[str, str]:
        res = self._post_idempotent(f"characters/{code}/upload-urls", {"files": files})
        return {x["path"]: x["url"] for x in res}

    def character_finish(self, code: str, files: list[dict]) -> dict:
        """Replaces the character's whole asset list: always send every file."""
        return self._post_idempotent(f"characters/{code}/finish", {"files": files})

    def fail(self, job_id: int, stage: str, reason: str) -> None:
        self._post_idempotent(f"jobs/{job_id}/fail", {"stage": stage, "reason": reason[:255]})

    def status(self, paused: bool, reason: str, balance: dict) -> None:
        self._post("worker/status", {"paused": paused, "reason": reason, "balance": balance})
