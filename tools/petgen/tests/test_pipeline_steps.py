import http.client
import io
import json
import urllib.error

import pytest

from petgen import kling, props
from petgen.kling import KlingError, KlingRejected, KlingTaskFailed
from petgen.pipeline import MAX_GENERATIONS, MAX_LOOPS, RETRY_WAIT, BudgetExceeded, StepFailed, step_fetch, step_propref, step_ref
from petgen.pipeline import prop_ref as real_prop_ref   # bound before the rig swaps in the fake
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
    assert rig.env.sleep.calls == [RETRY_WAIT, RETRY_WAIT]      # backed off before each re-download


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


def test_a_create_with_an_unknown_outcome_stops_without_retrying(rig):
    rig.fk.reject = [KlingError("network error: timed out")]
    r = _ready(rig)
    with pytest.raises(StepFailed, match="可灵建任务结果未知.*network error: timed out"):
        step_ref(r, "front")
    assert len(rig.fk.created) == 1
    saved = json.loads((r.dir / "state.json").read_text(encoding="utf-8"))
    assert saved["steps"]["ref:front"]["pending_create"]["attempt"] == 1


def test_a_restart_after_an_unknown_create_stops_before_paying(rig):
    rig.fk.reject = [KlingError("network error: timed out")]
    with pytest.raises(StepFailed):
        step_ref(_ready(rig), "front")
    rig.fk.created.clear()
    with pytest.raises(StepFailed, match="可灵建任务结果未知.*network error: timed out"):
        step_ref(rig.run(), "front")
    assert rig.fk.created == []


def test_a_rejected_create_is_not_an_unknown_outcome(rig):
    rig.fk.reject = [KlingRejected("create image failed: code=1301 x")]
    r = _ready(rig)
    step_ref(r, "front")
    assert len(rig.fk.created) == 2 and "pending_create" not in r.state.data["steps"]["ref:front"]


def test_a_restart_with_both_tries_used_fails_without_paying(rig):
    r = _ready(rig)
    r.state.step("ref:front").update(attempts=MAX_GENERATIONS, task=None)
    r.state.save()
    with pytest.raises(StepFailed, match="参考图 front"):
        step_ref(rig.run(), "front")
    assert rig.fk.created == []


def test_a_prop_that_cannot_be_composed_fails_the_step(rig, monkeypatch):
    r = _ready(rig)
    with pytest.raises(StepFailed, match="道具图生成失败.*ref-front-cutout.png"):
        real_prop_ref(r.dir / "ref-front-cutout.png", rig.env.props / "bowl-cutout.png", "bowl", r.dir / "o.png")

    def no_subject(*a):
        raise ValueError("empty alpha: no subject")

    monkeypatch.setattr(props, "compose_prop", no_subject)
    with pytest.raises(StepFailed, match="道具图生成失败.*no subject"):
        real_prop_ref(rig.env.props / "bowl-cutout.png", rig.env.props / "bowl-cutout.png", "bowl", r.dir / "o.png")


def _real_create(rig, monkeypatch, urlopen):
    """The rig's Kling, but creates go through the real wrapper over urlopen."""
    monkeypatch.setattr(kling, "_cfg", lambda: ("test-key", "https://example.invalid"))
    monkeypatch.setattr(kling.urllib.request, "urlopen", urlopen)
    monkeypatch.setattr(rig.fk, "create_image", lambda body: (rig.fk.created.append(("image", body)),
                                                              kling.create_image(body))[1])


def test_a_disconnect_on_create_is_an_unknown_outcome(rig, monkeypatch):
    def urlopen(req, timeout=None):
        raise http.client.RemoteDisconnected("Remote end closed connection without response")

    _real_create(rig, monkeypatch, urlopen)
    r = _ready(rig)
    with pytest.raises(StepFailed, match="可灵建任务结果未知"):
        step_ref(r, "front")
    assert len(rig.fk.created) == 1
    assert r.state.data["steps"]["ref:front"]["pending_create"]["attempt"] == 1


def test_a_bad_gateway_on_create_is_an_unknown_outcome(rig, monkeypatch):
    def urlopen(req, timeout=None):
        raise urllib.error.HTTPError("https://example.invalid", 502, "Bad Gateway", {},
                                     io.BytesIO(b"<html>502 Bad Gateway</html>"))

    _real_create(rig, monkeypatch, urlopen)
    r = _ready(rig)
    with pytest.raises(StepFailed, match="可灵建任务结果未知"):
        step_ref(r, "front")
    assert len(rig.fk.created) == 1


def test_a_poll_that_gives_up_backs_off_and_resumes_the_same_task(rig):
    rig.fk.wait_errors = 2
    r = _ready(rig)
    step_ref(r, "front")
    assert len(rig.fk.created) == 1 and rig.fk.waited == ["image-1"] * 3
    assert rig.env.sleep.calls == [RETRY_WAIT, RETRY_WAIT]
    assert r.state.done("ref:front")


def test_a_rejected_create_is_retried_without_backing_off(rig):
    rig.fk.reject = [KlingRejected("create image failed: code=1301 x")]
    step_ref(_ready(rig), "front")
    assert rig.env.sleep.calls == []


def test_a_task_that_keeps_failing_to_poll_fails_the_step_only_after_backing_off(rig):
    rig.fk.wait_errors = 99
    r = _ready(rig)
    with pytest.raises(StepFailed, match="RemoteDisconnected"):
        step_ref(r, "front")
    assert len(rig.fk.created) == 1
    assert rig.env.sleep.calls == [RETRY_WAIT] * MAX_LOOPS
    assert r.state.data["steps"]["ref:front"]["task"]["id"] == "image-1"   # kept for a later re-claim
