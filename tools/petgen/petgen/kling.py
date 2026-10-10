"""Minimal Kling open-platform client. Reads secrets/kling.env; never prints the key."""
from __future__ import annotations

import base64
import http.client
import json
import socket
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable

from petgen.config import read_env, secrets_dir
from petgen.download import fetch

_PATHS = {"image": "/v1/images/generations", "video": "/v1/videos/image2video"}
_PACK_NAMES = {"image": ("图像", "图片"), "video": ("视频",)}
POLL_GIVE_UP = 600.0     # seconds of failing polls in a row before wait() gives up


class KlingError(Exception):
    pass


class KlingRejected(KlingError):
    """The create call was refused (code != 0): bad input, a photo that fails
    content review, no balance. Never charged."""


class KlingTaskFailed(KlingError):
    """The task ran and ended 'failed'."""


def _cfg() -> tuple[str, str]:
    kv = read_env(secrets_dir() / "kling.env")
    return kv["KLING_API_KEY"], kv["KLING_BASE_URL"].rstrip("/")


def _exchange(method: str, path: str, body: dict | None = None) -> tuple[int | None, dict, bool]:
    """(HTTP error status or None, Kling's JSON answer, raw). An HTTP error
    without a JSON body comes back raw as {"code": status, "message": ...}.
    Anything else that goes wrong on the wire or in the body (a disconnect,
    a reset, TLS, a cut-short or non-JSON body) is a KlingError."""
    key, base = _cfg()
    req = urllib.request.Request(base + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("Content-Type", "application/json")
    try:
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                status, res = None, json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            body_text = e.read().decode("utf-8", "replace")
            try:
                status, res = e.code, json.loads(body_text or "{}")
            except ValueError:
                res = None
            if not isinstance(res, dict):
                return e.code, {"code": e.code, "message": body_text[:200]}, True
    except urllib.error.URLError as e:      # before OSError: URLError is one
        raise KlingError(f"network error: {e.reason}") from e
    except socket.timeout as e:
        raise KlingError(f"request timeout: {e}") from e
    except (http.client.HTTPException, OSError) as e:   # RemoteDisconnected, IncompleteRead, reset, SSL
        raise KlingError(f"connection error: {type(e).__name__}: {e}") from e
    except ValueError as e:                 # JSONDecodeError, UnicodeDecodeError
        raise KlingError(f"unreadable answer: {e}") from e
    if not isinstance(res, dict):
        raise KlingError(f"unexpected answer: {type(res).__name__}")
    return status, res, False


def _call(method: str, path: str, body: dict | None = None) -> dict:
    return _exchange(method, path, body)[1]


def b64(path: Path) -> str:
    return base64.b64encode(Path(path).read_bytes()).decode("ascii")


def _refused(status: int | None, res: dict, raw: bool) -> bool:
    """A definite refusal, never charged: an HTTP 4xx (not 408 / 429) with a
    JSON body, or a Kling client-side code 1000-4999. A 5xx, 408, 429, a
    non-JSON error page or a Kling server code (>= 5000) may hide an
    accepted task."""
    code = res.get("code")
    if status is not None:
        if status >= 500 or status in (408, 429) or raw:
            return False
        return not (isinstance(code, int) and code >= 5000)
    return isinstance(code, int) and 1000 <= code <= 4999


def _create(kind: str, body: dict) -> str:
    status, res, raw = _exchange("POST", _PATHS[kind], body)
    what = f"create {kind} failed: code={res.get('code')} {res.get('message')}"
    if res.get("code") != 0 or status is not None:
        if _refused(status, res, raw):
            raise KlingRejected(what)            # a rejected create is never charged
        raise KlingError(what)
    task_id = (res.get("data") or {}).get("task_id") if isinstance(res.get("data"), dict) else None
    if not task_id:
        raise KlingError(f"create {kind}: no task_id in the answer")
    return task_id


def create_image(body: dict) -> str:
    return _create("image", body)


def create_video(body: dict) -> str:
    return _create("video", body)


def wait(kind: str, task_id: str, every: float = 8.0, limit: int = 120,
         on_poll: Callable[[], None] | None = None, *,
         clock: Callable[[], float] | None = None, sleep: Callable[[float], None] | None = None) -> dict:
    """Poll until the task ends. on_poll runs before every poll -- the
    worker's abort check. A poll that fails (no answer, a 5xx, a code != 0)
    is a blip: the task is paid for and may well still be running, so it is
    polled again; only errors lasting more than POLL_GIVE_UP seconds in a row
    end the wait, with a plain KlingError -- the task's id stays worth
    keeping. Errors do not count towards limit."""
    clock = clock or time.monotonic
    sleep = sleep or time.sleep
    polls, failing_since = 0, None
    while polls < limit:
        if on_poll is not None:
            on_poll()
        try:
            res = _call("GET", f"{_PATHS[kind]}/{task_id}")
            if res.get("code") != 0:
                raise KlingError(f"{kind} task {task_id} error: code={res.get('code')} {res.get('message')}")
        except KlingError as e:
            now = clock()
            if failing_since is None:
                failing_since = now
            if now - failing_since > POLL_GIVE_UP:
                raise KlingError(f"{kind} task {task_id}: polls failing for {now - failing_since:.0f}s: {e}") from e
            sleep(every)
            continue
        failing_since = None
        polls += 1
        d = res.get("data") or {}
        if d.get("task_status") == "succeed":
            return d
        if d.get("task_status") == "failed":
            raise KlingTaskFailed(f"{kind} task {task_id} failed: {d.get('task_status_msg')}")
        sleep(every)
    raise KlingError(f"{kind} task {task_id} still running after {every * limit:.0f}s")


def download(url: str, dest: Path) -> Path:
    """Streamed to a .part file with retries and Range resume (petgen.download)."""
    return fetch(url, Path(dest))


def balance() -> list[dict]:
    now = int(time.time() * 1000)
    res = _call("GET", f"/account/costs?start_time={now - 90 * 86400 * 1000}&end_time={now}")
    return (res.get("data") or {}).get("resource_pack_subscribe_infos", [])


def units_left(kind: str) -> float:
    names = _PACK_NAMES[kind]
    return sum(float(p.get("remaining_quantity") or 0) for p in balance()
               if p.get("status") == "online" and any(n in p.get("resource_pack_name", "") for n in names))
