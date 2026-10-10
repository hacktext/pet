import pytest

from petgen import kling
from petgen.config import REPO, ConfigError, Prices, load_worker_config, read_env, secrets_dir


def test_secrets_dir_follows_PETGEN_SECRETS(monkeypatch, tmp_path):
    monkeypatch.setenv("PETGEN_SECRETS", str(tmp_path))
    assert secrets_dir() == tmp_path
    monkeypatch.delenv("PETGEN_SECRETS")
    assert secrets_dir() == REPO / "secrets"


def test_read_env_skips_comments_and_blank_lines(tmp_path):
    p = tmp_path / "x.env"
    p.write_text("# comment\n\nA = 1\nB=two=2\nnot a pair\n", encoding="utf-8")
    assert read_env(p) == {"A": "1", "B": "two=2"}


def test_kling_reads_its_key_from_the_secrets_dir(monkeypatch, tmp_path):
    (tmp_path / "kling.env").write_text("KLING_API_KEY=abc\nKLING_BASE_URL=https://k.invalid/\n", encoding="utf-8")
    monkeypatch.setenv("PETGEN_SECRETS", str(tmp_path))
    assert kling._cfg() == ("abc", "https://k.invalid")


def test_worker_config_reads_the_key_and_prices(tmp_path):
    p = tmp_path / "worker.env"
    p.write_text("AIPET_WORKER_KEY=k-123\nAIPET_PRICE_VIDEO_UNIT_CENTS=90\n", encoding="utf-8")
    cfg = load_worker_config(p)
    assert cfg.key == "k-123"
    assert cfg.prices == Prices(10.0, 90.0)
    assert "k-123" not in repr(cfg)


def test_the_template_key_is_refused_without_echoing_it(tmp_path):
    p = tmp_path / "worker.env"
    p.write_text("AIPET_WORKER_KEY=在这里填 worker 密钥\n", encoding="utf-8")
    with pytest.raises(ConfigError) as e:
        load_worker_config(p)
    assert "AIPET_WORKER_KEY" in str(e.value) and "在这里填" not in str(e.value)


def test_a_missing_worker_env_names_the_file(monkeypatch, tmp_path):
    monkeypatch.setenv("PETGEN_SECRETS", str(tmp_path))
    with pytest.raises(ConfigError, match="worker.env"):
        load_worker_config()


def test_a_bad_price_is_a_config_error(tmp_path):
    p = tmp_path / "worker.env"
    p.write_text("AIPET_WORKER_KEY=k\nAIPET_PRICE_IMAGE_UNIT_CENTS=ten\n", encoding="utf-8")
    with pytest.raises(ConfigError, match="AIPET_PRICE"):
        load_worker_config(p)


def test_prices_round_to_cents():
    assert Prices(10.0, 100.0).cents(8, 4) == 480
    assert Prices(12.4, 0.0).cents(1, 0) == 12
