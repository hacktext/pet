import re
import subprocess
import sys
from pathlib import Path

from petgen import proc

PKG = Path(proc.__file__).parent


def test_children_get_their_own_process_group(monkeypatch):
    seen = []
    monkeypatch.setattr(proc.subprocess, "run", lambda args, **kw: seen.append(("run", args, kw)))
    monkeypatch.setattr(proc.subprocess, "Popen", lambda args, **kw: seen.append(("popen", args, kw)))
    proc.run(["ffmpeg", "-version"], check=True)
    proc.popen(["ffprobe"], stdout=subprocess.PIPE)
    for _, _, kw in seen:
        if sys.platform == "win32":
            assert kw["creationflags"] & subprocess.CREATE_NEW_PROCESS_GROUP
            assert "start_new_session" not in kw
        else:
            assert kw["start_new_session"] is True
    assert seen[0][2]["check"] is True and seen[1][2]["stdout"] is subprocess.PIPE


def test_every_child_process_in_the_package_goes_through_proc():
    """A terminal Ctrl+C must reach only the worker, which finishes its step:
    an ffmpeg in the same process group would die and fail the job."""
    direct = re.compile(r"subprocess\.(run|Popen|call|check_call|check_output)\(")
    offenders = [f.name for f in PKG.glob("*.py") if f.name != "proc.py" and direct.search(f.read_text(encoding="utf-8"))]
    assert offenders == []


def test_systemd_stops_only_the_main_process():
    unit = (PKG.parent / "deploy" / "aipet-worker.service").read_text(encoding="utf-8")
    assert re.search(r"^KillMode=mixed$", unit, re.M)
