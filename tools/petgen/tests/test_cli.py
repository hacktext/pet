from petgen.__main__ import _video_task_id


def test_video_task_ids_are_unique_per_call_and_name_their_inputs(monkeypatch):
    import petgen.__main__ as cli
    monkeypatch.setattr(cli.time, "time", lambda: 1789000000.123)
    a = _video_task_id("gold", "stand", "v2", "pro")
    assert a == "petgen-gold-stand-v2-pro-1789000000123"
    monkeypatch.setattr(cli.time, "time", lambda: 1789000000.456)
    assert _video_task_id("gold", "stand", "v2", "pro") != a
    assert _video_task_id("corgi", "walk", None, "std").startswith("petgen-corgi-walk-main-std-")
