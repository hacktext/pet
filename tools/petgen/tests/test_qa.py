import json
import subprocess

from petgen.qa import FORMAT, qa_clip


def _clip(path, size=960, frames=121):
    """Exact green with a still opaque box: a perfect loop with nothing floating."""
    b = size // 3
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"color=c=0x00FF00:s={size}x{size}:r=24",
                    "-vf", f"drawbox=x={b}:y={b}:w={b}:h={b}:color=0xC89664:t=fill",
                    "-frames:v", str(frames), "-c:v", "libx264", "-crf", "12", "-pix_fmt", "yuv420p", str(path)],
                   check=True)


def test_a_clean_square_loop_passes_and_reports_every_number(tmp_path):
    v = tmp_path / "stand-final.mp4"
    _clip(v)
    r = qa_clip(v, tmp_path, "stand")
    assert r["pass"] is True
    assert r["format"] == FORMAT
    assert set(r) == {"pass", "format", "seam", "worst_step", "blob_core_first", "blob_core_last", "blob_core_worst"}
    assert (tmp_path / "qa-stand-first.png").exists() and (tmp_path / "qa-stand-last.png").exists()
    json.dumps(r)


def test_the_wrong_format_fails(tmp_path):
    v = tmp_path / "x.mp4"
    _clip(v, size=480, frames=48)
    r = qa_clip(v, tmp_path, "x")
    assert r["pass"] is False and r["format"]["width"] == 480
