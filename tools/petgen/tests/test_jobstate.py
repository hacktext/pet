import pytest

from petgen.jobstate import Job, JobState, apply_redo, base_pose
from tests.fakes import claim


def test_claim_parses_and_orders_actions_stand_first():
    j = Job.from_claim(claim(actions=["play", "stand", "walk"]))
    assert j.actions == ("stand", "walk", "play")
    assert j.photos == ("https://oss.invalid/p1.jpg", "https://oss.invalid/p2.jpg")
    assert (j.id, j.pet_id, j.name, j.species, j.budget_cents, j.spent_cents) == (12, "custom-12", "豆豆", "dog", 8000, 0)


def test_budget_defaults_when_missing():
    assert Job.from_claim(claim(budget_cents=None)).budget_cents == 8000


@pytest.mark.parametrize("over, msg", [
    ({"species": "other"}, "不支持的类别 other"),
    ({"actions": ["stand", "spin"]}, "未知动作"),
    ({"actions": ["walk"]}, "缺少 stand"),
    ({"photos": []}, "没有用户照片"),
    ({"pet_id": "Custom 12"}, "pet_id"),
    ({"redo": {"actions": ["lick_paw"], "refs": False, "hint": ""}}, "重做的动作不在动作列表里"),
])
def test_claim_rejects_what_the_pipeline_cannot_make(over, msg):
    with pytest.raises(ValueError, match=msg):
        Job.from_claim(claim(**over))


def test_base_pose():
    assert [base_pose(a) for a in ("stand", "feed", "play", "walk", "sleep")] == ["front", "front", "front", "walk", "lie"]


def test_steps_cover_only_the_stills_the_actions_need():
    std = Job.from_claim(claim())
    assert std.poses() == ["front", "walk", "lie"]
    assert std.prop_stems() == ["front-bowl", "front-ball"]
    assert std.steps() == ["fetch", "ref:front", "ref:walk", "ref:lie", "propref",
                           "video:stand", "video:walk", "video:sleep", "video:feed", "video:play",
                           "package", "upload"]
    idle = Job.from_claim(claim(actions=["stand", "lick_paw"]))
    assert idle.steps() == ["fetch", "ref:front", "video:stand", "video:lick_paw", "package", "upload"]


def test_state_round_trips_and_writes_atomically(tmp_path):
    s = JobState.load(tmp_path / "state.json")
    s.step("ref:front")["done"] = True
    assert s.next_seq("stand") == 1 and s.next_seq("stand") == 2
    s.save()
    t = JobState.load(tmp_path / "state.json")
    assert t.done("ref:front") and not t.done("ref:walk")
    assert t.data["seq"] == {"stand": 2} and t.data["redo_seen"] is None
    assert not (tmp_path / "state.json.tmp").exists()


def _finished(tmp_path, job):
    """A job folder where every step is done and every file exists."""
    d = tmp_path / "job"
    d.mkdir()
    s = JobState.load(d / "state.json")
    for step in job.steps():
        s.step(step)["done"] = True
    for p in job.poses():
        for f in (f"ref-{p}.png", f"ref-{p}-green.png", f"ref-{p}-cutout.png"):
            (d / f).write_bytes(b"x")
    for a in job.actions:
        for f in (f"{a}.mp4", f"{a}-final.mp4"):
            (d / f).write_bytes(b"x")
    (d / "grade.json").write_text("{}", encoding="utf-8")
    s.data["seq"] = {a: 1 for a in job.actions}
    s.save()
    return d, s


def _not_done(s, job):
    return {k for k in job.steps() if not s.done(k)}


def test_redo_one_action_clears_only_that_clip(tmp_path):
    job = Job.from_claim(claim(redo={"actions": ["play"], "refs": False, "hint": "尾巴摆慢一点"}))
    d, s = _finished(tmp_path, job)
    apply_redo(s, job, d)
    assert _not_done(s, job) == {"video:play", "package", "upload"}
    assert not (d / "play.mp4").exists() and not (d / "play-final.mp4").exists()
    assert (d / "feed.mp4").exists() and (d / "grade.json").exists()
    assert s.data["hints"] == {"play": "尾巴摆慢一点"}
    assert s.data["seq"]["play"] == 1


def test_redo_with_refs_also_remakes_every_clip_from_that_still(tmp_path):
    job = Job.from_claim(claim(redo={"actions": ["play"], "refs": True, "hint": ""}))
    d, s = _finished(tmp_path, job)
    apply_redo(s, job, d)
    assert _not_done(s, job) == {"ref:front", "propref", "video:stand", "video:feed", "video:play", "package", "upload"}
    assert not (d / "ref-front-green.png").exists() and not (d / "grade.json").exists()
    assert (d / "ref-walk-green.png").exists() and (d / "walk.mp4").exists() and (d / "sleep.mp4").exists()


def test_redo_all_starts_over_but_keeps_the_photos(tmp_path):
    job = Job.from_claim(claim(redo={"all": True}))
    d, s = _finished(tmp_path, job)
    s.data["hints"] = {"play": "old"}
    apply_redo(s, job, d)
    assert _not_done(s, job) == set(job.steps()) - {"fetch"}
    assert s.data["hints"] == {} and s.data["seq"]["stand"] == 1


def test_the_same_redo_is_applied_once(tmp_path):
    job = Job.from_claim(claim(redo={"actions": ["play"], "refs": False, "hint": ""}))
    d, s = _finished(tmp_path, job)
    apply_redo(s, job, d)
    s.step("video:play")["done"] = True      # remade; then the worker died before the upload
    apply_redo(s, job, d)                     # re-claimed with the same redo
    assert s.done("video:play")
    s.data["redo_seen"] = None                # the finish went through and the server cleared it
    apply_redo(s, job, d)                     # an identical redo later is a new request
    assert not s.done("video:play")


def test_no_redo_changes_nothing(tmp_path):
    job = Job.from_claim(claim())
    d, s = _finished(tmp_path, job)
    apply_redo(s, job, d)
    assert _not_done(s, job) == set()


def test_hints_can_be_cleared_after_a_finished_upload(tmp_path):
    job = Job.from_claim(claim(redo={"actions": ["play"], "refs": False, "hint": "慢一点"}))
    d, s = _finished(tmp_path, job)
    apply_redo(s, job, d)
    assert s.data["hints"] == {"play": "慢一点"}
    s.clear_hints()
    s.data["redo_seen"] = None
    s.save()
    t = JobState.load(d / "state.json")
    assert t.data["hints"] == {}
    # a later redo of another action does not inherit the stale hint
    job2 = Job.from_claim(claim(redo={"actions": ["walk"], "refs": False, "hint": ""}))
    apply_redo(t, job2, d)
    assert t.data["hints"] == {"walk": ""}


def test_finish_done_forgets_the_redo_and_its_hints(tmp_path):
    job = Job.from_claim(claim(redo={"actions": ["play"], "refs": False, "hint": "慢一点"}))
    d, s = _finished(tmp_path, job)
    apply_redo(s, job, d)
    s.finish_done()
    assert s.data["hints"] == {} and s.data["redo_seen"] is None
    apply_redo(s, job, d)                     # the same redo again later is a new request
    assert not s.done("video:play")
