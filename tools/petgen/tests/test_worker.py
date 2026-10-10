import json
import threading

import pytest

from petgen import pipeline
from petgen import worker as worker_mod
from petgen.download import DownloadError
from petgen.kling import KlingError, KlingRejected
from petgen.server import ServerAbort, ServerError
from petgen.worker import ERROR_WAIT, IDLE_WAIT, LOW_BALANCE, PAUSE_WAIT, Worker
from tests.fakes import FakeKling, FakeServer, claim, install_fake_tools, make_env


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


@pytest.fixture
def w(tmp_path, monkeypatch):
    """Worker on fakes: w.make(*jobs) -> (worker, server, kling, waits)."""
    knobs = install_fake_tools(monkeypatch)

    class Kit:
        pass

    kit = Kit()
    kit.knobs, kit.clock, kit.stop, kit.waits = knobs, Clock(), threading.Event(), []
    kit.fk = FakeKling()

    def make(*jobs):
        kit.srv = FakeServer(jobs)
        kit.env = make_env(tmp_path, kit.fk, kit.srv)
        return Worker(kit.srv, kit.env, kit.stop, heartbeat=3600, clock=kit.clock, wait=kit.waits.append)

    kit.make = make
    return kit


def test_low_balance_pauses_without_claiming(w):
    w.fk.balance = {"image": 1000.0, "video": 27.0}
    worker = w.make(claim())
    assert worker.tick() == "paused"
    assert w.srv.statuses == [(True, LOW_BALANCE, {"image": 1000, "video": 27})]
    assert len(w.srv.jobs) == 1
    assert w.waits == [PAUSE_WAIT]


def test_balance_back_reports_unpaused_then_claims(w):
    w.fk.balance = {"image": 31.0, "video": 100.0}
    worker = w.make(claim())
    assert worker.tick() == "paused"
    w.fk.balance = {"image": 1000.0, "video": 100.0}
    assert worker.tick() == "done"
    assert w.srv.statuses[1] == (False, "", {"image": 1000, "video": 100})
    assert len(w.srv.finished) == 1


def test_status_is_resent_only_on_change_or_every_five_minutes(w):
    worker = w.make()
    assert worker.tick() == "idle"
    assert worker.tick() == "idle"
    assert len(w.srv.statuses) == 1
    w.clock.t += 301
    worker.tick()
    assert len(w.srv.statuses) == 2


def test_a_failed_balance_check_waits_and_claims_nothing(w):
    w.fk.balance_error = KlingError("network error: timed out")
    worker = w.make(claim())
    assert worker.tick() == "balance-error"
    assert w.waits == [ERROR_WAIT] and len(w.srv.jobs) == 1


def test_no_job_waits_fifteen_seconds(w):
    worker = w.make()
    assert worker.tick() == "idle"
    assert w.waits == [IDLE_WAIT]


def test_a_job_runs_to_review_and_nothing_is_reported_after_the_finish(w):
    worker = w.make(claim())
    assert worker.tick() == "done"
    assert w.srv.failed == []
    assert w.srv.finished[0][0] == "left"
    assert w.srv.events[-1] == ("finish",)
    assert ("progress", "video", "play") in w.srv.events
    total = {"image_units": 0, "video_units": 0, "cents": 0}
    for *_, cost in w.srv.progress_calls:
        for k in total:
            total[k] += cost[k]
    assert total == {"image_units": 24, "video_units": 20, "cents": 2240}


def test_a_refused_photo_twice_fails_with_a_readable_reason(w):
    w.fk.reject = [KlingRejected("create image failed: code=1301 图片审核未通过")] * 2
    worker = w.make(claim())
    assert worker.tick() == "failed"
    [(job_id, stage, reason)] = w.srv.failed
    assert (job_id, stage) == (12, "ref:front")
    assert "参考图 front" in reason and "code=1301 图片审核未通过" in reason


def test_a_crash_is_reported_with_its_stage_and_the_worker_carries_on(w, monkeypatch):
    def boom(raw, final, workdir, action):
        raise RuntimeError("ffmpeg exploded")

    monkeypatch.setattr(pipeline, "finish_and_qa", boom)
    worker = w.make(claim(), claim(id=13, pet_id="custom-13"))
    assert worker.tick() == "failed"
    assert w.srv.failed == [(12, "video:stand", "RuntimeError: ffmpeg exploded")]
    install_fake_tools(monkeypatch)
    assert worker.tick() == "done"


def test_a_server_abort_drops_the_job_without_failing_it(w):
    worker = w.make(claim())
    w.srv.abort_at = ("video", "walk")
    assert worker.tick() == "aborted"
    assert w.srv.failed == [] and w.srv.finished == []
    assert len(w.fk.created) == 4


def test_a_409_during_upload_is_an_abort_too(w, monkeypatch):
    worker = w.make(claim())

    def gone(job_id, walk_facing, files):
        raise ServerAbort("jobs/12/finish: HTTP 409 job is refunded", 409)

    monkeypatch.setattr(w.srv, "finish", gone)
    assert worker.tick() == "aborted"
    assert w.srv.failed == []


def test_stop_finishes_the_step_then_leaves_the_job_for_the_reaper(w, tmp_path):
    worker = w.make(claim())
    w.srv.on_progress = lambda stage, message: w.stop.set() if (stage, message) == ("refs", "walk") else None
    assert worker.tick() == "stopped"
    assert w.srv.failed == []
    state = json.loads((tmp_path / "work" / "jobs" / "12" / "state.json").read_text(encoding="utf-8"))
    assert state["steps"]["ref:walk"]["done"] is True and "ref:lie" not in state["steps"]


def test_a_budget_overrun_fails_the_job_before_any_call(w):
    worker = w.make(claim(spent_cents=7990))
    assert worker.tick() == "failed"
    [(job_id, stage, reason)] = w.srv.failed
    assert stage == "ref:front" and reason.startswith("超出单笔预算")
    assert w.fk.created == []


def test_bad_job_data_fails_at_claim(w):
    worker = w.make(claim(species="other"))
    assert worker.tick() == "failed"
    assert w.srv.failed == [(12, "claim", "任务数据不合法：不支持的类别 other")]


def test_run_returns_at_once_when_stopped(w):
    worker = w.make(claim())
    w.stop.set()
    assert worker.run() == 0
    assert len(w.srv.jobs) == 1


def test_once_exits_after_one_job(w):
    worker = w.make(claim(), claim(id=13, pet_id="custom-13"))
    assert worker.run(once=True) == 0
    assert len(w.srv.finished) == 1 and len(w.srv.jobs) == 1


# --- controller rulings -------------------------------------------------------------------------

def test_a_network_error_at_finish_leaves_the_job_for_the_reaper(w, monkeypatch, tmp_path):
    worker = w.make(claim())

    def down(job_id, walk_facing, files):
        raise ServerError("jobs/12/finish: HTTP 503 ", 503)

    monkeypatch.setattr(w.srv, "finish", down)
    assert worker.tick() == "dropped"
    assert w.srv.failed == []
    state = json.loads((tmp_path / "work" / "jobs" / "12" / "state.json").read_text(encoding="utf-8"))
    assert state["steps"]["video:sleep"]["done"] is True      # a re-claim resumes, nothing is paid again


def test_a_network_error_while_uploading_a_file_drops_the_job_too(w, monkeypatch):
    worker = w.make(claim())

    def broken(url, path, content_type):
        raise ServerError("upload cover.png failed: HTTP 500")

    monkeypatch.setattr(w.srv, "put", broken)
    assert worker.tick() == "dropped"
    assert w.srv.failed == []


def test_once_exits_after_a_dropped_job(w, monkeypatch):
    worker = w.make(claim(), claim(id=13, pet_id="custom-13"))
    monkeypatch.setattr(w.srv, "upload_urls", lambda job_id, files: (_ for _ in ()).throw(ServerError("x")))
    assert worker.run(once=True) == 0
    assert len(w.srv.jobs) == 1


def test_an_abort_answering_the_fail_report_is_settled(w, monkeypatch):
    worker = w.make(claim(species="other"), claim(id=13, pet_id="custom-13"))

    def settled(job_id, stage, reason):
        raise ServerAbort(f"jobs/{job_id}/fail: HTTP 409 job is failed", 409)

    monkeypatch.setattr(w.srv, "fail", settled)
    assert worker.tick() == "failed"
    assert worker.tick() == "done"


def test_a_corrupt_state_file_fails_the_job_and_is_kept(w, tmp_path):
    worker = w.make(claim())
    state = tmp_path / "work" / "jobs" / "12" / "state.json"
    state.parent.mkdir(parents=True)
    state.write_text("{not json", encoding="utf-8")
    assert worker.tick() == "failed"
    [(job_id, stage, reason)] = w.srv.failed
    assert (job_id, stage) == (12, "state") and reason.startswith("state.json 损坏：")
    assert state.read_text(encoding="utf-8") == "{not json"
    assert w.fk.created == []


def test_a_photo_that_cannot_be_downloaded_fails_with_a_readable_reason(w):
    worker = w.make(claim())

    def expired(url, dest):
        raise DownloadError("download refused: HTTP 403")

    w.env.fetch = expired
    assert worker.tick() == "failed"
    assert w.srv.failed == [(12, "fetch", "照片下载失败：download refused: HTTP 403")]


@pytest.mark.parametrize("error", [ValueError("Expecting value: line 1"), KeyError("data"), RuntimeError("?")])
def test_any_balance_check_error_waits_and_claims_nothing(w, error):
    w.fk.balance_error = error
    worker = w.make(claim())
    assert worker.tick() == "balance-error"
    assert w.waits == [ERROR_WAIT] and len(w.srv.jobs) == 1


@pytest.mark.parametrize("answer", [ServerError("jobs/claim: network error: timed out"),
                                    ValueError("not JSON"), ["not", "a", "dict"], {"job": "12"}, None])
def test_a_failed_or_malformed_claim_waits(w, monkeypatch, answer):
    worker = w.make()

    def bad_claim():
        if isinstance(answer, Exception):
            raise answer
        return answer

    monkeypatch.setattr(w.srv, "claim", bad_claim)
    assert worker.tick() == "server-error"
    assert w.waits == [ERROR_WAIT] and w.srv.failed == []


def test_a_failed_status_report_does_not_stop_the_claim_and_is_retried(w, monkeypatch):
    worker = w.make(claim())
    calls = []

    def flaky(paused, reason, balance):
        calls.append(paused)
        if len(calls) == 1:
            raise ValueError("worker/status: HTTP 200, not JSON")

    monkeypatch.setattr(w.srv, "status", flaky)
    assert worker.tick() == "done"
    assert worker.tick() == "idle"
    assert calls == [False, False]


def test_the_reporter_is_closed_before_the_failure_is_reported(w, monkeypatch):
    worker = w.make(claim())
    w.fk.reject = [KlingRejected("code=1301")] * 2
    real_close = worker_mod.Reporter.close

    def close(self):
        w.srv.events.append(("close",))
        real_close(self)

    monkeypatch.setattr(worker_mod.Reporter, "close", close)
    assert worker.tick() == "failed"
    assert w.srv.events[-2:] == [("close",), ("fail", "ref:front")]


def test_a_stop_before_the_claim_takes_no_job(w):
    worker = w.make(claim())
    w.fk.units_left = lambda kind: (w.stop.set(), 1000.0)[1]
    assert worker.tick() == "stopped"
    assert len(w.srv.jobs) == 1 and w.srv.failed == []
