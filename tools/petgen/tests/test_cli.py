from petgen.__main__ import _video_task_id


def test_video_task_ids_are_unique_per_call_and_name_their_inputs(monkeypatch):
    import petgen.__main__ as cli
    monkeypatch.setattr(cli.time, "time", lambda: 1789000000.123)
    a = _video_task_id("gold", "stand", "v2", "pro")
    assert a == "petgen-gold-stand-v2-pro-1789000000123"
    monkeypatch.setattr(cli.time, "time", lambda: 1789000000.456)
    assert _video_task_id("gold", "stand", "v2", "pro") != a
    assert _video_task_id("corgi", "walk", None, "std").startswith("petgen-corgi-walk-main-std-")


def test_voice_clones_the_reference_and_reports_failures(monkeypatch, tmp_path, capsys):
    import sys
    import petgen.__main__ as cli
    from petgen import volc
    sent = {}

    def fake_generate(body, out):
        sent.update(body)
        return {"duration": 2.0, "original_duration": 2.0}

    monkeypatch.setattr(volc, "generate", fake_generate)
    monkeypatch.setattr(volc, "default_speaker", lambda: "S_default")
    ref = tmp_path / "me.wav"
    ref.write_bytes(b"x")
    monkeypatch.setattr(sys, "argv", ["petgen", "voice", "@音频1 你好", "--out", str(tmp_path / "a.mp3"),
                                      "--ref", str(ref)])
    assert cli.main() == 0
    assert "audio_data" in sent["references"][0]  # the clip, not the default speaker

    monkeypatch.setattr(sys, "argv", ["petgen", "voice", "你好", "--out", str(tmp_path / "b.mp3")])
    assert cli.main() == 0
    assert sent["references"] == [{"speaker": "S_default"}]

    def boom(body, out):
        raise volc.VolcError("generate failed: code=45000010 invalid api key")

    monkeypatch.setattr(volc, "generate", boom)
    assert cli.main() == 1
    assert "FAIL voice" in capsys.readouterr().out
