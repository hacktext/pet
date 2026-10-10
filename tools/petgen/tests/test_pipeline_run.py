import hashlib
import json
import re

import pytest

from petgen import kling
from petgen.kling import KlingError
from petgen.pipeline import BudgetExceeded, JobAborted, StepFailed, StopRequested, run_job

STD = ("stand", "walk", "sleep", "feed", "play")
ALL = ("stand", "walk", "sleep", "feed", "play", "lick_paw", "act_cute")
SERVER_PATH = re.compile(r"^(refs/)?[a-z0-9][a-z0-9_-]{0,47}\.(mp4|png|jpg|json)$")


def _videos(rig, start=0):
    return [b for k, b in rig.fk.created[start:] if k == "video"]


def test_a_standard_job_runs_to_upload(rig):
    run = run_job(rig.job(), rig.env, rig.prog)
    assert [k for k, _ in rig.fk.created] == ["image"] * 3 + ["video"] * 5
    vids = _videos(rig)
    assert [b["external_task_id"] for b in vids] == [f"aipet-12-{a}-1" for a in STD]
    assert all(b["mode"] == "pro" and b["duration"] == "5" and b["model_name"] == "kling-v3" for b in vids)
    assert all(b["image"] == b["image_tail"] for b in vids)
    assert vids[3]["image"] == kling.b64(run.dir / "ref-front-bowl-green.png")
    assert vids[1]["image"] == kling.b64(run.dir / "ref-walk-green.png")
    assert vids[2]["image"] == kling.b64(run.dir / "ref-lie-green.png")
    assert "这只狗" in vids[0]["prompt"] and "补充要求" not in vids[0]["prompt"]
    assert rig.prog.costs == [24.0, 20.0, 2240]

    walk_facing, files = rig.up.finished[0]
    assert walk_facing == "left"
    by_path = {f["path"]: f for f in files}
    assert set(by_path) == {"pet.json", "cover.png", *(f"{a}.mp4" for a in STD),
                            "refs/front.png", "refs/walk.png", "refs/lie.png"}
    assert {p for p, f in by_path.items() if not f["deliverable"]} == {"refs/front.png", "refs/walk.png", "refs/lie.png"}
    assert by_path["stand.mp4"]["qa"]["pass"] is True
    assert by_path["refs/front.png"]["qa"]["pass"] is True
    assert by_path["pet.json"]["qa"] is None and by_path["cover.png"]["qa"] is None
    pj = run.dir / "out" / "pet.json"
    assert json.loads(pj.read_text(encoding="utf-8")) == {
        "schema": 1, "id": "custom-12", "name": "豆豆", "species": "dog", "origin": "custom", "blurb": "",
        "cover": "cover.png", "actions": list(STD), "walkFacing": "left"}
    assert by_path["pet.json"]["sha256"] == hashlib.sha256(pj.read_bytes()).hexdigest()
    assert by_path["pet.json"]["bytes"] == pj.stat().st_size

    types = {url.split("oss.invalid/", 1)[1]: ct for url, _, ct in rig.up.puts}
    assert types["pet.json"] == "application/json" and types["stand.mp4"] == "video/mp4"
    assert types["cover.png"] == "image/png" and types["refs/front.png"] == "image/png"
    assert rig.up.requested[0] == [{"path": f["path"], "bytes": f["bytes"], "content_type": types[f["path"]]}
                                   for f in files]


def test_every_uploaded_path_is_one_the_server_accepts(rig):
    run_job(rig.job(actions=list(ALL)), rig.env, rig.prog)
    paths = [f["path"] for f in rig.up.finished[0][1]]
    assert {"lick_paw.mp4", "act_cute.mp4"} <= set(paths)
    assert all(SERVER_PATH.match(p) for p in paths), paths


def test_progress_reports_stage_counts_and_nothing_after_the_finish(rig):
    run_job(rig.job(), rig.env, rig.prog)
    begins = [c[1:] for c in rig.prog.calls if c[0] == "begin"]
    assert begins[:2] == [("fetch", "fetch", 0, 1, "下载照片"), ("ref:front", "refs", 0, 3, "front")]
    assert ("video:feed", "video", 3, 5, "feed") in begins
    ends = [c[1:] for c in rig.prog.calls if c[0] == "end"]
    assert ("video:play", "video", 5, 5, "play") in ends
    assert rig.prog.calls[-1] == ("begin", "upload", "upload", 0, 1, "上传成品")
    assert [c[1] for c in rig.prog.calls if c[0] == "begin"] == rig.job().steps()


def test_a_restart_skips_finished_steps_and_resumes_the_paid_clip(rig):
    rig.fk.crash_download.add("video-7")         # feed: the worker is killed mid-download
    with pytest.raises(RuntimeError, match="mid-download"):
        run_job(rig.job(), rig.env, rig.prog)
    run_job(rig.job(), rig.env, rig.prog)
    assert len(rig.fk.created) == 8
    assert rig.prog.costs[1] == 20.0
    assert len(rig.up.finished) == 1


def test_a_clip_that_fails_qa_is_made_once_more(rig):
    rig.knobs["qa_fail"].add("video-4")
    run_job(rig.job(), rig.env, rig.prog)
    assert [b["external_task_id"] for b in _videos(rig)][:2] == ["aipet-12-stand-1", "aipet-12-stand-2"]
    files = {f["path"]: f for f in rig.up.finished[0][1]}
    assert files["stand.mp4"]["qa"]["pass"] is True


def test_a_clip_that_fails_qa_twice_goes_to_review_marked(rig):
    rig.knobs["qa_fail"].update({"video-4", "video-5"})
    run_job(rig.job(), rig.env, rig.prog)
    assert len(rig.fk.created) == 9
    files = {f["path"]: f for f in rig.up.finished[0][1]}
    assert files["stand.mp4"]["qa"]["pass"] is False


def test_a_discarded_stand_takes_its_grade_with_it(rig, monkeypatch):
    from petgen import pipeline
    fake = pipeline.finish_and_qa
    graded = []

    def finish_and_qa(raw, final, workdir, action):
        if action == "stand":
            graded.append((workdir / "grade.json").exists())
            (workdir / "grade.json").write_text('{"gamma": 1.2}', encoding="utf-8")
        return fake(raw, final, workdir, action)

    monkeypatch.setattr(pipeline, "finish_and_qa", finish_and_qa)
    rig.knobs["qa_fail"].add("video-4")
    run_job(rig.job(), rig.env, rig.prog)
    assert graded == [False, False]      # the second stand solves its own grade


def test_a_clip_whose_tasks_fail_twice_fails_the_step_and_stays_failed(rig):
    rig.fk.fail_task.update({"video-4", "video-5"})
    with pytest.raises(StepFailed, match="动作 stand 未能生成"):
        run_job(rig.job(), rig.env, rig.prog)
    assert len(rig.fk.created) == 5
    with pytest.raises(StepFailed, match="动作 stand 未能生成"):
        run_job(rig.job(), rig.env, rig.prog)      # restarted: both paid tries are used up
    assert len(rig.fk.created) == 5


def test_a_clip_create_with_an_unknown_outcome_stops_for_good(rig, monkeypatch):
    real = rig.fk.create_video

    def create_video(body):
        rig.fk.created.append(("video", body))
        raise KlingError("network error: timed out")

    monkeypatch.setattr(rig.fk, "create_video", create_video)
    with pytest.raises(StepFailed, match="可灵建任务结果未知"):
        run_job(rig.job(), rig.env, rig.prog)
    assert len(rig.fk.created) == 4
    monkeypatch.setattr(rig.fk, "create_video", real)
    with pytest.raises(StepFailed, match="可灵建任务结果未知"):
        run_job(rig.job(), rig.env, rig.prog)
    assert len(rig.fk.created) == 4


def test_redo_of_one_action_remakes_only_that_clip_with_the_hint(rig):
    run_job(rig.job(), rig.env, rig.prog)
    redo = {"actions": ["play"], "refs": False, "hint": "尾巴摆慢一点"}
    run_job(rig.job(redo=redo), rig.env, rig.prog)
    new = rig.fk.created[8:]
    assert [(k, b["external_task_id"]) for k, b in new] == [("video", "aipet-12-play-2")]
    assert new[0][1]["prompt"].endswith("补充要求：尾巴摆慢一点")
    assert len(rig.up.finished) == 2


def test_a_finished_redo_leaves_no_hint_for_the_next_one(rig):
    run_job(rig.job(), rig.env, rig.prog)
    run_job(rig.job(redo={"actions": ["play"], "refs": False, "hint": "尾巴摆慢一点"}), rig.env, rig.prog)
    # remaking the front still remakes stand, feed and play: play must not get the old note
    run_job(rig.job(redo={"actions": ["stand"], "refs": True, "hint": ""}), rig.env, rig.prog)
    play = [b for b in _videos(rig, 9) if b["external_task_id"].startswith("aipet-12-play-")]
    assert len(play) == 1 and "补充要求" not in play[0]["prompt"]
    state = json.loads((rig.env.work / "jobs" / "12" / "state.json").read_text(encoding="utf-8"))
    assert state["hints"] == {} and state["redo_seen"] is None


def test_a_redo_interrupted_before_upload_is_not_remade(rig):
    run_job(rig.job(), rig.env, rig.prog)
    redo = {"actions": ["play"], "refs": False, "hint": ""}
    rig.up.fail_finish = 1
    with pytest.raises(RuntimeError, match="server down"):
        run_job(rig.job(redo=redo), rig.env, rig.prog)
    run_job(rig.job(redo=redo), rig.env, rig.prog)   # re-claimed with the same redo
    assert len(rig.fk.created) == 9
    assert len(rig.up.finished) == 2


def test_redo_with_refs_remakes_the_still_and_the_clips_made_from_it(rig):
    run_job(rig.job(), rig.env, rig.prog)
    run_job(rig.job(redo={"actions": ["play"], "refs": True, "hint": ""}), rig.env, rig.prog)
    new = rig.fk.created[8:]
    assert [k for k, _ in new] == ["image", "video", "video", "video"]
    assert [b["external_task_id"] for b in _videos(rig, 8)] == ["aipet-12-stand-2", "aipet-12-feed-2", "aipet-12-play-2"]


def test_redo_all_remakes_everything(rig):
    run_job(rig.job(), rig.env, rig.prog)
    run_job(rig.job(redo={"all": True}), rig.env, rig.prog)
    assert len(rig.fk.created) == 16
    assert [b["external_task_id"] for b in _videos(rig, 8)] == [f"aipet-12-{a}-2" for a in STD]


def test_a_repackage_with_fewer_clips_uploads_no_stale_clip(rig):
    run = run_job(rig.job(actions=list(ALL)), rig.env, rig.prog)
    assert (run.dir / "out" / "lick_paw.mp4").exists()
    run_job(rig.job(redo={"all": True}), rig.env, rig.prog)
    paths = {f["path"] for f in rig.up.finished[1][1]}
    assert paths == {"pet.json", "cover.png", *(f"{a}.mp4" for a in STD),
                     "refs/front.png", "refs/walk.png", "refs/lie.png"}
    assert not (run.dir / "out" / "lick_paw.mp4").exists()


def test_the_budget_stops_the_job_mid_way(rig):
    # stills 3 x 80 = 240, then 400 a clip: 240 + 3 x 400 = 1440; the 4th clip would reach 1840
    with pytest.raises(BudgetExceeded, match="超出单笔预算"):
        run_job(rig.job(budget_cents=1490), rig.env, rig.prog)
    assert [k for k, _ in rig.fk.created] == ["image"] * 3 + ["video"] * 3


def test_an_abort_stops_inside_the_wait_and_keeps_the_task(rig):
    rig.prog.abort_step = "video:walk"
    with pytest.raises(JobAborted):
        run_job(rig.job(), rig.env, rig.prog)
    assert len(rig.fk.created) == 5
    state = json.loads((rig.env.work / "jobs" / "12" / "state.json").read_text(encoding="utf-8"))
    assert state["steps"]["video:walk"]["task"]["id"] == "video-5"
    assert rig.up.finished == []


def test_a_stop_request_ends_between_steps(rig):
    rig.prog.stop_before = "video:walk"
    with pytest.raises(StopRequested):
        run_job(rig.job(), rig.env, rig.prog)
    assert len(rig.fk.created) == 4
    state = json.loads((rig.env.work / "jobs" / "12" / "state.json").read_text(encoding="utf-8"))
    assert state["steps"]["video:stand"]["done"] is True and "video:walk" not in state["steps"]


def test_cat_jobs_use_cat_prompts(rig):
    run_job(rig.job(species="cat"), rig.env, rig.prog)
    assert all("这只猫" in b["prompt"] for _, b in rig.fk.created)
