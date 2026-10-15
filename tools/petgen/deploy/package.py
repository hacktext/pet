"""Build the worker's deployment package: <repo>/dist/aipet-worker.tar.gz.

    python tools/petgen/deploy/package.py

Unpacked on the server it is one folder, aipet/, run with `bash run.sh`
(see DEPLOY.txt inside). Never packs secrets: only the .example templates.
Text files go in with LF endings, so a Windows checkout still yields a
package that runs on Linux."""
from __future__ import annotations

import io
import sys
import tarfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent          # tools/petgen/deploy
PETGEN = HERE.parent                            # tools/petgen
REPO = PETGEN.parents[1]
OUT = REPO / "dist" / "aipet-worker.tar.gz"
TEXT = {".py", ".sh", ".txt", ".service", ".example", ".md"}


def files() -> list[tuple[Path, str]]:
    """(source, path inside the archive) for everything that ships."""
    out = [(HERE / "run.sh", "aipet/run.sh"), (HERE / "DEPLOY.txt", "aipet/DEPLOY.txt"),
           (PETGEN / "requirements.txt", "aipet/tools/petgen/requirements.txt"),
           (HERE / "aipet-worker.service", "aipet/tools/petgen/deploy/aipet-worker.service")]
    out += [(p, f"aipet/tools/petgen/petgen/{p.name}") for p in sorted((PETGEN / "petgen").glob("*.py"))]
    out += [(PETGEN / "work" / "props" / f"{k}-cutout.png", f"aipet/work/props/{k}-cutout.png") for k in ("bowl", "ball")]
    # Only what the worker reads: Kling and its own key, never volc / vidu.
    out += [(REPO / "secrets" / f, f"aipet/secrets/{f}") for f in ("kling.env.example", "worker.env.example")]
    return out


def add_dir(tar: tarfile.TarFile, name: str, now: float) -> None:
    info = tarfile.TarInfo(name)
    info.type, info.mode, info.mtime = tarfile.DIRTYPE, 0o755, now
    tar.addfile(info)


def main() -> int:
    missing = [str(src) for src, _ in files() if not src.is_file()]
    if missing:
        print("缺少文件，未打包：\n  " + "\n  ".join(missing))
        return 1
    OUT.parent.mkdir(parents=True, exist_ok=True)
    now = time.time()
    with tarfile.open(OUT, "w:gz") as tar:
        add_dir(tar, "aipet", now)
        add_dir(tar, "aipet/u2net", now)        # the matting model goes here (see DEPLOY.txt)
        for src, name in files():
            data = src.read_bytes()
            if src.suffix in TEXT:
                data = data.replace(b"\r\n", b"\n")
            info = tarfile.TarInfo(name)
            info.size, info.mtime = len(data), now
            info.mode = 0o755 if name.endswith(".sh") else 0o644
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            tar.addfile(info, io.BytesIO(data))
    print(f"已生成 {OUT}（{OUT.stat().st_size / 1024:.0f} KB，{len(files())} 个文件）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
