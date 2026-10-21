import hashlib
import json
from argparse import Namespace
from types import SimpleNamespace

import pytest

import petgen.config
import petgen.server
from petgen import __main__ as cli


class FakeSrv:
    instances = []

    def __init__(self, base, key):
        self.events = []
        FakeSrv.instances.append(self)

    def character_upload_urls(self, code, files):
        self.events.append(("urls", code, files))
        return {f["path"]: f"https://oss.invalid/{f['path']}" for f in files}

    def put(self, url, path, content_type):
        self.events.append(("put", url, path.name, content_type))

    def character_finish(self, code, files):
        self.events.append(("finish", code, files))
        return {"ok": True}


@pytest.fixture(autouse=True)
def fakes(monkeypatch):
    FakeSrv.instances = []
    monkeypatch.setattr(petgen.server, "Server", FakeSrv)
    monkeypatch.setattr(petgen.config, "load_worker_config", lambda p: SimpleNamespace(key="k"))


def args(d, code="suwan"):
    return Namespace(dir=d, code=code, server="https://x.invalid", config=None)


def make(d, **meta):
    d.mkdir(parents=True, exist_ok=True)
    (d / "pet.json").write_text(json.dumps({"id": "paid-suwan", "origin": "paid", **meta}), encoding="utf-8")
    (d / "card.jpg").write_bytes(b"jpgdata")
    (d / "clips").mkdir()
    (d / "clips" / "walk.mp4").write_bytes(b"mp4data")
    (d / "voice.wav").write_bytes(b"wav")


@pytest.mark.parametrize("meta,drop", [({"id": "paid-other"}, None), ({"origin": "custom"}, None),
                                       ({}, "card.jpg"), ({}, "pet.json")])
def test_publish_refuses_a_folder_that_is_not_a_paid_pet(tmp_path, capsys, meta, drop):
    make(tmp_path, **meta)
    if drop:
        (tmp_path / drop).unlink()
    assert cli.cmd_publish(args(tmp_path)) == 1
    assert FakeSrv.instances == [] and "FAIL" in capsys.readouterr().out


def test_publish_refuses_an_unknown_extension(tmp_path, capsys):
    make(tmp_path)
    (tmp_path / "notes.txt").write_text("x")
    assert cli.cmd_publish(args(tmp_path)) == 1
    assert "notes.txt" in capsys.readouterr().out and FakeSrv.instances == []


def test_publish_uploads_every_file_then_finishes(tmp_path, capsys):
    make(tmp_path)
    assert cli.cmd_publish(args(tmp_path)) == 0
    ev = FakeSrv.instances[0].events
    assert [e[0] for e in ev] == ["urls", "put", "put", "put", "put", "finish"]
    paths = [f["path"] for f in ev[0][2]]
    assert paths == ["card.jpg", "clips/walk.mp4", "pet.json", "voice.wav"]
    fin = {f["path"]: f for f in ev[-1][2]}
    assert fin["card.jpg"]["sha256"] == hashlib.sha256(b"jpgdata").hexdigest()
    assert fin["clips/walk.mp4"]["content_type"] == "video/mp4" and fin["voice.wav"]["content_type"] == "audio/wav"
    assert fin["card.jpg"]["bytes"] == 7
    assert capsys.readouterr().out.strip().splitlines()[-1] == "published suwan: 4 files"
