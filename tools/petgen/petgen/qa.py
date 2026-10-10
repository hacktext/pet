"""The finished clip's QA verdict -- format, loop seam, keyed ghosts --
shared by `petgen qa` and the worker."""
from __future__ import annotations

from pathlib import Path

from petgen import proc
from petgen.keycheck import FRAME_BLOB_MAX, frame_scores, score_file
from petgen.loopcheck import probe, psnr_series, seam_verdict

FORMAT = {"width": 960, "height": 960, "fps": "24/1", "frames": 121}


def frame_png(video: Path, out: Path, last: bool) -> Path:
    seek = ["-sseof", "-0.05"] if last else []
    proc.run(["ffmpeg", "-v", "error", "-y", *seek, "-i", str(video), "-update", "1", "-frames:v", "1", str(out)],
             check=True)
    return out


def qa_clip(video: Path, workdir: Path, stem: str) -> dict:
    fmt = probe(video)
    ok_seam, seam, worst_step = seam_verdict(*psnr_series(video, workdir / f"qa-{stem}"))
    first = score_file(frame_png(video, workdir / f"qa-{stem}-first.png", last=False))
    last = score_file(frame_png(video, workdir / f"qa-{stem}-last.png", last=True))
    worst = max(frame_scores(video))
    passed = fmt == FORMAT and ok_seam and first.passed and last.passed and worst < FRAME_BLOB_MAX
    return {"pass": passed, "format": fmt, "seam": round(seam, 2), "worst_step": round(worst_step, 2),
            "blob_core_first": first.blob_core, "blob_core_last": last.blob_core, "blob_core_worst": worst}
