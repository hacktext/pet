import signal
import sys

import petgen.__main__ as cli
import petgen.worker as worker_mod


def _props(tmp_path):
    props = tmp_path / "work" / "props"
    props.mkdir(parents=True)
    for kind in ("bowl", "ball"):
        (props / f"{kind}-cutout.png").write_bytes(b"png")
    return props


def test_worker_without_config_names_the_file(monkeypatch, tmp_path, capsys):
    monkeypatch.setenv("PETGEN_SECRETS", str(tmp_path))
    monkeypatch.setattr(sys, "argv", ["petgen", "worker", "--server", "https://example.invalid"])
    assert cli.main() == 1
    assert "worker.env" in capsys.readouterr().out


def test_worker_refuses_to_start_without_the_props(monkeypatch, tmp_path, capsys):
    (tmp_path / "worker.env").write_text("AIPET_WORKER_KEY=k-1\n", encoding="utf-8")
    monkeypatch.setenv("PETGEN_SECRETS", str(tmp_path))
    monkeypatch.setattr(sys, "argv", ["petgen", "worker", "--server", "https://example.invalid",
                                      "--work", str(tmp_path / "work")])
    assert cli.main() == 1
    assert "bowl-cutout.png" in capsys.readouterr().out


def test_worker_starts_with_its_settings_and_never_prints_the_key(monkeypatch, tmp_path, capsys):
    (tmp_path / "worker.env").write_text("AIPET_WORKER_KEY=sekrit-value-123\n", encoding="utf-8")
    monkeypatch.setenv("PETGEN_SECRETS", str(tmp_path))
    _props(tmp_path)
    handlers = []
    monkeypatch.setattr(signal, "signal", lambda sig, fn: handlers.append(sig))
    seen = {}

    def fake_run(self, once=False):
        seen.update(server=self.server, env=self.env, once=once)
        return 0

    monkeypatch.setattr(worker_mod.Worker, "run", fake_run)
    monkeypatch.setattr(sys, "argv", ["petgen", "worker", "--server", "https://example.invalid/",
                                      "--work", str(tmp_path / "work"), "--once"])
    assert cli.main() == 0
    assert seen["server"].base == "https://example.invalid" and seen["once"] is True
    assert seen["env"].work == tmp_path / "work" and seen["env"].props == tmp_path / "work" / "props"
    assert signal.SIGINT in handlers
    out = capsys.readouterr()
    assert "sekrit-value-123" not in out.out + out.err


def test_a_second_signal_quits_with_130(monkeypatch, tmp_path):
    (tmp_path / "worker.env").write_text("AIPET_WORKER_KEY=k-1\n", encoding="utf-8")
    monkeypatch.setenv("PETGEN_SECRETS", str(tmp_path))
    _props(tmp_path)
    handlers = {}
    monkeypatch.setattr(signal, "signal", lambda sig, fn: handlers.__setitem__(sig, fn))

    def fake_run(self, once=False):
        handlers[signal.SIGINT](signal.SIGINT, None)
        assert self.stop.is_set()
        handlers[signal.SIGINT](signal.SIGINT, None)
        return 0

    monkeypatch.setattr(worker_mod.Worker, "run", fake_run)
    monkeypatch.setattr(sys, "argv", ["petgen", "worker", "--server", "https://example.invalid",
                                      "--work", str(tmp_path / "work")])
    assert cli.main() == 130
