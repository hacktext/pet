import json
import sys

from PIL import Image

import petgen.__main__ as cli
from petgen.package import ACTIONS, pet_json
from petgen.prompts import PETS, POSE_ASPECT


def _fake_pet(work, pet="gold"):
    d = work / pet
    d.mkdir(parents=True)
    for k in ACTIONS:
        (d / f"{k}-final.mp4").write_bytes(f"clip {k}".encode())
    Image.new("RGBA", (80, 60), (200, 150, 100, 255)).save(d / "ref-front-cutout.png")
    return d


def test_package_writes_to_out_when_given(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(cli, "WORK", tmp_path / "work")
    _fake_pet(tmp_path / "work")
    out = tmp_path / "anywhere" / "gold"
    monkeypatch.setattr(sys, "argv", ["petgen", "package", "gold", "--facing", "left", "--out", str(out)])
    assert cli.main() == 0
    assert json.loads((out / "pet.json").read_text(encoding="utf-8")) == pet_json("gold", "left")
    assert (out / "stand.mp4").read_bytes() == b"clip stand"
    assert (out / "cover.png").exists()
    assert "walkFacing left (--facing)" in capsys.readouterr().out


def test_package_defaults_to_the_app_assets(monkeypatch, tmp_path):
    monkeypatch.setattr(cli, "WORK", tmp_path / "work")
    monkeypatch.setattr(cli, "ASSETS", tmp_path / "assets")
    _fake_pet(tmp_path / "work")
    monkeypatch.setattr(sys, "argv", ["petgen", "package", "gold", "--facing", "right"])
    assert cli.main() == 0
    meta = json.loads((tmp_path / "assets" / "builtin-gold" / "pet.json").read_text(encoding="utf-8"))
    assert meta["walkFacing"] == "right"


def test_package_still_refuses_missing_clips(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(cli, "WORK", tmp_path / "work")
    d = _fake_pet(tmp_path / "work")
    (d / "play-final.mp4").unlink()
    monkeypatch.setattr(sys, "argv", ["petgen", "package", "gold", "--out", str(tmp_path / "out")])
    assert cli.main() == 1
    assert "missing clips ['play-final.mp4']" in capsys.readouterr().out


def test_import_spike_reads_the_given_folder(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(cli, "WORK", tmp_path / "work")
    src = tmp_path / "spike"
    src.mkdir()
    for pet in PETS:
        (src / f"src-{pet}.png").write_bytes(b"s")
        for pose in POSE_ASPECT:
            (src / f"ref-{pet}-{pose}.png").write_bytes(b"r")
    monkeypatch.setattr(sys, "argv", ["petgen", "import-spike", "--from", str(src)])
    assert cli.main() == 0
    assert (tmp_path / "work" / "gold" / "ref-front.png").read_bytes() == b"r"


def test_import_spike_without_a_folder_says_how(monkeypatch, capsys):
    monkeypatch.delenv("PETGEN_SPIKE_OUT", raising=False)
    monkeypatch.setattr(sys, "argv", ["petgen", "import-spike"])
    assert cli.main() == 1
    assert "--from" in capsys.readouterr().out


def test_qa_command_prints_the_same_report(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(cli, "WORK", tmp_path / "work")
    d = tmp_path / "work" / "gold"
    d.mkdir(parents=True)
    (d / "stand-final.mp4").write_bytes(b"x")
    report = {"pass": False, "format": {"width": 960}, "seam": 30.0, "worst_step": 31.0,
              "blob_core_first": 1, "blob_core_last": 2, "blob_core_worst": 3}
    monkeypatch.setattr(cli, "qa_clip", lambda v, workdir, stem: report)
    monkeypatch.setattr(sys, "argv", ["petgen", "qa", "gold", "stand"])
    assert cli.main() == 1
    printed = json.loads(capsys.readouterr().out)
    assert list(printed) == ["pet", "action", "pass", "format", "seam", "worst_step",
                             "blob_core_first", "blob_core_last", "blob_core_worst"]
    assert printed["pet"] == "gold" and printed["blob_core_worst"] == 3


def test_video_command_still_counts_only_video_packs(monkeypatch):
    from petgen import kling
    monkeypatch.setattr(kling, "balance", lambda: [
        {"resource_pack_name": "视频生成-100-5并发", "remaining_quantity": "40", "status": "online"},
        {"resource_pack_name": "图像生成-1000-9并发", "remaining_quantity": "968", "status": "online"},
    ])
    assert cli._video_units_left() == 40.0
