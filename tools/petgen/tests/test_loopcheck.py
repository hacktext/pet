import subprocess

from petgen.loopcheck import probe, psnr_series, seam_verdict


def test_seam_inside_normal_motion_is_ok():
    ok, seam, worst = seam_verdict([48.0, 40.0, 47.4], [55.8, 39.1, 60.0])
    assert ok and seam == 47.4 and worst == 39.1


def test_seam_below_every_step_is_visible():
    ok, _, _ = seam_verdict([48.0, 20.0, 11.5], [55.0, 35.8, 60.0])
    assert not ok


def make_static_video(path):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "color=c=red:s=32x32:d=1:r=10",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", str(path)], check=True)


def test_probe_reads_format(tmp_path):
    v = tmp_path / "static.mp4"
    make_static_video(v)
    assert probe(v) == {"width": 32, "height": 32, "fps": "10/1", "frames": 10}


def test_static_video_loops_perfectly(tmp_path):
    v = tmp_path / "static.mp4"
    make_static_video(v)
    vs_first, consecutive = psnr_series(v, tmp_path / "psnr")
    assert len(vs_first) == 10 and len(consecutive) == 9
    assert seam_verdict(vs_first, consecutive)[0]


def test_filtergraphs_never_name_an_absolute_path(monkeypatch, tmp_path):
    """A Windows drive colon breaks filtergraph syntax and a Linux server has
    none: the stats files are named relative to ffmpeg's cwd."""
    import petgen.loopcheck as lc
    calls = []

    def fake_run(args, check, cwd):
        calls.append((args, cwd))
        for name in ("vs_f0.log", "consec.log"):
            (cwd / name).write_text("n:1 psnr_avg:inf\n", encoding="utf-8")

    monkeypatch.setattr(lc.subprocess, "run", fake_run)
    work = tmp_path / "psnr"
    lc.psnr_series(tmp_path / "v.mp4", work)
    assert len(calls) == 2
    for args, cwd in calls:
        graph = args[args.index("-filter_complex") + 1]
        assert cwd == work
        assert str(tmp_path) not in graph and "/" not in graph and "\\" not in graph
