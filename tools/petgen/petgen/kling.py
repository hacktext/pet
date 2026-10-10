"""Minimal Kling open-platform client. Reads secrets/kling.env; never prints the key."""
from __future__ import annotations

import base64
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


def _call(method: str, path: str, body: dict | None = None) -> dict:
    key, base = _cfg()
    req = urllib.request.Request(base + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body_text = e.read().decode("utf-8", "replace")
        try:
            return json.loads(body_text or "{}")
        except (json.JSONDecodeError, ValueError):
            return {"code": e.code, "message": body_text[:200]}
    except urllib.error.URLError as e:
        raise KlingError(f"network error: {e.reason}")
    except socket.timeout as e:
        raise KlingError(f"request timeout: {e}")


def b64(path: Path) -> str:
    return base64.b64encode(Path(path).read_bytes()).decode("ascii")


def _create(kind: str, body: dict) -> str:
    res = _call("POST", _PATHS[kind], body)
    if res.get("code") != 0:  # a rejected create is never charged
        raise KlingRejected(f"create {kind} failed: code={res.get('code')} {res.get('message')}")
    return res["data"]["task_id"]


def create_image(body: dict) -> str:
    return _create("image", body)


def create_video(body: dict) -> str:
    return _create("video", body)


def wait(kind: str, task_id: str, every: float = 8.0, limit: int = 120,
         on_poll: Callable[[], None] | None = None) -> dict:
    """Poll until the task ends. on_poll runs before every poll -- the
    worker's abort check. A poll error is a plain KlingError: the task may
    still be running, so its id stays worth keeping."""
    for _ in range(limit):
        if on_poll is not None:
            on_poll()
        res = _call("GET", f"{_PATHS[kind]}/{task_id}")
        if res.get("code") != 0:
            raise KlingError(f"{kind} task {task_id} error: code={res.get('code')} {res.get('message')}")
        d = res.get("data") or {}
        if d.get("task_status") == "succeed":
            return d
        if d.get("task_status") == "failed":
            raise KlingTaskFailed(f"{kind} task {task_id} failed: {d.get('task_status_msg')}")
        time.sleep(every)
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
