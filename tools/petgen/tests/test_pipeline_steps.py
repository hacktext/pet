import pytest

from petgen import kling
from petgen.kling import KlingRejected, KlingTaskFailed
from petgen.pipeline import BudgetExceeded, StepFailed, step_fetch, step_propref, step_ref
from petgen.prompts import BRIGHT


def _ready(rig, **over):
    r = rig.run(**over)
    step_fetch(r)
    return r


def test_fetch_downloads_each_photo_once(rig):
    r = _ready(rig)
    assert [p.read_bytes() for p in r.photo_paths()] == [b"https://oss.invalid/p1.jpg", b"https://oss.invalid/p2.jpg"]
    assert r.state.done("fetch")


def test_ref_uses_the_production_recipe_and_records_the_cost(rig):
    r = _ready(rig)
    step_ref(r, "front")
    kind, body = rig.fk.created[0]
    assert kind == "image"
    assert (body["model_name"], body["image_reference"], body["resolution"], body["aspect_ratio"], body["n"]) == \
        ("kling-v3", "subject", "2k", "1:1", 1)
    assert body["image"] == kling.b64(r.photo_paths()[0])
    assert "这只狗" in body["prompt"] and body["prompt"].endswith(BRIGHT)
    assert r.state.done("ref:front") and r.state.data["steps"]["ref:front"]["score"]["pass"] is True
    assert (r.dir / "ref-front-green.png").exists() and (r.dir / "ref-front-cutout.png").exists()
    assert rig.prog.costs == [8.0, 0.0, 80]


def test_a_rejected_photo_is_retried_with_the_next_photo(rig):
    rig.fk.reject = [KlingRejected("create image failed: code=1301 图片审核未通过")]
    r = _ready(rig)
    step_ref(r, "front")
    assert [b["image"] for _, b in rig.fk.created] == [kling.b64(p) for p in r.photo_paths()]
    assert r.state.done("ref:front")


def test_two_failures_fail_the_step_with_a_readable_reason(rig):
    rig.fk.reject = [KlingRejected("create image failed: code=1301 图片审核未通过")] * 2
    r = _ready(rig)
    with pytest.raises(StepFailed, match="参考图 front.*code=1301 图片审核未通过"):
        step_ref(r, "front")
    assert len(rig.fk.created) == 2


def test_a_task_that_fails_review_counts_as_a_try(rig):
    rig.fk.fail_task = {"image-1"}
    r = _ready(rig)
    step_ref(r, "front")
    assert len(rig.fk.created) == 2 and rig.fk.created[1][1]["image"] == kling.b64(r.photo_paths()[1])
    assert rig.prog.costs[0] == 8.0       # the failed task was never charged


def test_one_photo_is_reused_for_the_retry(rig):
    rig.fk.reject = [KlingRejected("create image failed: code=1301 x")]
    r = _ready(rig, photos=[{"url": "https://oss.invalid/only.jpg"}])
    step_ref(r, "front")
    assert [b["image"] for _, b in rig.fk.created] == [kling.b64(r.photo_paths()[0])] * 2


def test_a_still_that_fails_the_gate_is_made_once_more(rig):
    rig.knobs["gate_fail"].add("image-1")
    r = _ready(rig)
    step_ref(r, "front")
    assert len(rig.fk.created) == 2 and rig.knobs["gated"] == ["image-1", "image-2"]
    assert rig.prog.costs[0] == 16.0


def test_two_gate_failures_fail_the_step(rig):
    rig.knobs["gate_fail"].update({"image-1", "image-2"})
    r = _ready(rig)
    with pytest.raises(StepFailed, match="参考图 front.*blob_core=999"):
        step_ref(r, "front")
    assert len(rig.fk.created) == 2


def test_the_budget_is_checked_before_every_kling_call(rig):
    r = _ready(rig, spent_cents=7930)            # 7930 + 80 > 8000
    with pytest.raises(BudgetExceeded, match="超出单笔预算"):
        step_ref(r, "front")
    assert rig.fk.created == []


def test_a_paid_still_is_not_paid_again_after_a_crash_mid_download(rig):
    rig.fk.crash_download.add("image-1")
    r = _ready(rig)
    with pytest.raises(RuntimeError, match="mid-download"):
        step_ref(r, "front")
    step_ref(rig.run(), "front")                 # a restarted worker: fresh Run, same folder
    assert len(rig.fk.created) == 1
    assert rig.fk.downloads == ["https://kling.invalid/image-1"]
    assert rig.prog.costs[0] == 8.0


def test_a_crash_while_waiting_resumes_the_same_task(rig):
    rig.fk.crash_wait.add("image-1")
    r = _ready(rig)
    with pytest.raises(RuntimeError, match="while waiting"):
        step_ref(r, "front")
    step_ref(rig.run(), "front")
    assert len(rig.fk.created) == 1 and rig.fk.waited == ["image-1", "image-1"]
    assert rig.prog.costs[0] == 8.0


def test_dropped_downloads_are_retried_without_paying(rig):
    rig.fk.download_errors = 2
    r = _ready(rig)
    step_ref(r, "front")
    assert len(rig.fk.created) == 1 and r.state.done("ref:front")


def test_propref_puts_the_props_on_the_front_still(rig):
    r = _ready(rig)
    step_ref(r, "front")
    step_propref(r)
    assert (r.dir / "ref-front-bowl-green.png").exists() and (r.dir / "ref-front-ball-green.png").exists()
    assert r.state.done("propref")


def test_a_prop_that_fails_its_gate_needs_a_person(rig):
    rig.knobs["prop_fail"].add("ball")
    r = _ready(rig)
    step_ref(r, "front")
    with pytest.raises(StepFailed, match="道具图 front-ball"):
        step_propref(r)
