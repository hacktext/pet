"""Where secrets live, and the worker's settings. Never prints a value."""
from __future__ import annotations

import os
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]


class ConfigError(Exception):
    pass


def secrets_dir() -> Path:
    """$PETGEN_SECRETS on a server where tools/petgen is not inside the repo;
    the repo's secrets/ otherwise."""
    return Path(os.environ.get("PETGEN_SECRETS") or REPO / "secrets")


def read_env(path: Path) -> dict[str, str]:
    kv: dict[str, str] = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            kv[k.strip()] = v.strip()
    return kv
