from types import SimpleNamespace

import pytest

from petgen.jobstate import Job
from petgen.pipeline import Run
from tests.fakes import FakeKling, FakeProgress, FakeUploader, claim, install_fake_tools, make_env


@pytest.fixture
def rig(tmp_path, monkeypatch):
    """A pipeline on fakes, all sharing one work folder: rig.job(**over) is
    job 12 (claim() + over), rig.run(**over) a fresh Run of it -- a new Run
    over the same folder is what a restarted worker sees."""
    fk, up, prog = FakeKling(), FakeUploader(), FakeProgress()
    knobs = install_fake_tools(monkeypatch)
    env = make_env(tmp_path, fk, up)

    def job(**over):
        return Job.from_claim(claim(**over))

    return SimpleNamespace(fk=fk, up=up, prog=prog, env=env, knobs=knobs, job=job,
                           run=lambda **over: Run(job(**over), env, prog))
