from petgen import kling
from petgen.config import REPO, read_env, secrets_dir


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
