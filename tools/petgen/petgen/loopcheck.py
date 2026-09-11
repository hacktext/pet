"""Clip format and loop-seam checks (ffmpeg / ffprobe must be on PATH)."""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path


def probe(video: Path) -> dict:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height,r_frame_rate,nb_frames", "-of", "json", str(video)],
        check=True, capture_output=True, text=True).stdout
    s = json.loads(out)["streams"][0]
    return {"width": int(s["width"]), "height": int(s["height"]),
            "fps": s["r_frame_rate"], "frames": int(s["nb_frames"])}


def _psnr_avgs(stats: Path) -> list[float]:
    vals = []
    for line in stats.read_text(encoding="utf-8").splitlines():
        m = re.search(r"psnr_avg:(\S+)", line)
        if m:
            vals.append(99.0 if m.group(1) == "inf" else float(m.group(1)))
    return vals


def psnr_series(video: Path, workdir: Path) -> tuple[list[float], list[float]]:
    """Per-frame PSNR against frame 0, and between consecutive frames.

    ffmpeg runs with cwd=workdir and relative stats-file names: a Windows
    path's drive colon would break the filtergraph syntax."""
    workdir.mkdir(parents=True, exist_ok=True)
    video = Path(video).resolve()

    def run(args: list[str]) -> None:
        subprocess.run(["ffmpeg", "-v", "error", *args], check=True, cwd=workdir)

    run(["-y", "-i", str(video), "-frames:v", "1", "f0.png"])
    run(["-i", str(video), "-loop", "1", "-i", "f0.png", "-filter_complex",
         "[1:v]format=yuv420p[r];[0:v]format=yuv420p[m];[m][r]psnr=stats_file=vs_f0.log:shortest=1",
         "-f", "null", "-"])
    run(["-i", str(video), "-filter_complex",
         "[0:v]split[a][b];[b]trim=start_frame=1,setpts=PTS-STARTPTS[b1];[a][b1]psnr=stats_file=consec.log:shortest=1",
         "-f", "null", "-"])
    return _psnr_avgs(workdir / "vs_f0.log"), _psnr_avgs(workdir / "consec.log")


def seam_verdict(vs_first: list[float], consecutive: list[float]) -> tuple[bool, float, float]:
    """A loop's seam (last -> first) is invisible when it is no bigger a jump
    than the largest step the clip already makes between neighbouring frames."""
    seam, worst = vs_first[-1], min(consecutive)
    return seam >= worst, seam, worst
