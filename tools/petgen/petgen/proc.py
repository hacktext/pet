"""ffmpeg / ffprobe children in their own process group (session on POSIX):
a terminal Ctrl+C reaches only the worker, which finishes the step it is
in, instead of killing the ffmpeg under it and failing the job."""
from __future__ import annotations

import subprocess
import sys


def _detached() -> dict:
    if sys.platform == "win32":
        return {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP}
    return {"start_new_session": True}


def run(args: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(args, **_detached(), **kw)


def popen(args: list[str], **kw) -> subprocess.Popen:
    return subprocess.Popen(args, **_detached(), **kw)
