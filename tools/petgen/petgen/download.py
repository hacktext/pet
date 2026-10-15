"""Download to a .part file and rename. A dropped connection (an
IncompleteRead once lost a paid clip) is retried, resuming with Range when
the server allows it; an expired / refused URL is not retried."""
from __future__ import annotations

import http.client
import logging
import socket
import time
import urllib.error
import urllib.request
from pathlib import Path

log = logging.getLogger("petgen.download")
RETRIES = 3
CHUNK = 1 << 16


class DownloadError(Exception):
    pass


def fetch(url: str, dest: Path, *, retries: int = RETRIES, opener=None, sleep=time.sleep,
          timeout: float = 300) -> Path:
    opener = opener or urllib.request.urlopen
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    part.unlink(missing_ok=True)
    last: object = None
    for attempt in range(retries + 1):
        if attempt:
            log.warning("下载 %s 出错（%s），%d 秒后第 %d 次重试", dest.name, last, 2 ** attempt, attempt)
            sleep(2 ** attempt)
        have = part.stat().st_size if part.exists() else 0
        req = urllib.request.Request(url)
        if have:
            req.add_header("Range", f"bytes={have}-")
        try:
            with opener(req, timeout=timeout) as r:
                resume = bool(have) and getattr(r, "status", 200) == 206
                length = (r.headers or {}).get("Content-Length")
                expect = (have if resume else 0) + int(length) if length else None
                with open(part, "ab" if resume else "wb") as f:
                    while True:
                        buf = r.read(CHUNK)
                        if not buf:
                            break
                        f.write(buf)
            size = part.stat().st_size
            if expect is not None and size != expect:
                raise http.client.IncompleteRead(b"", expect - size)
            part.replace(dest)
            return dest
        except urllib.error.HTTPError as e:
            last = f"HTTP {e.code}"
            if e.code == 416:
                part.unlink(missing_ok=True)       # our Range ran past the end: start over
            elif 400 <= e.code < 500 and e.code not in (408, 429):
                raise DownloadError(f"download refused: HTTP {e.code}") from None
        except (http.client.HTTPException, urllib.error.URLError, socket.timeout, ConnectionError, OSError) as e:
            last = repr(e)
    raise DownloadError(f"download failed after {retries + 1} tries: {last}")
