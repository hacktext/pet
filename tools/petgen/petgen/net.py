"""Every outgoing request names itself petgen. Kling's edge resets
connections that look like a stock Python client from some overseas hosts
(a Vultr box, 2026-10-13: urllib's default "Python-urllib/3.x" was reset,
the same request with any other User-Agent answered 200)."""
from __future__ import annotations

import urllib.request

USER_AGENT = "petgen/1.0"


def install() -> None:
    """urlopen() everywhere sends USER_AGENT unless a request sets its own."""
    opener = urllib.request.build_opener()
    opener.addheaders = [("User-Agent", USER_AGENT)]
    urllib.request.install_opener(opener)
