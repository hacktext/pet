import threading
import time

import pytest

from petgen.pipeline import JobAborted, StopRequested
from petgen.reporter import Reporter
from petgen.server import ServerAbort, ServerError


class Srv:
    def __init__(self):
        self.calls = []
        self.abort = False
        self.down = False
        self.raises = None

    def progress(self, job_id, stage, done, total, message, cost):
        if self.raises:
            raise self.raises
        if self.down:
            raise ServerError("jobs/12/progress: network error: down")
        self.calls.append({"job": job_id, "stage": stage, "done": done, "total": total,
                           "message": message, "cost": dict(cost)})
        return self.abort


ZERO = {"image_units": 0, "video_units": 0, "cents": 0}


def test_begin_and_end_report_the_stage_and_the_cost_since_the_last_report():
    s = Srv()
    r = Reporter(s, 12, threading.Event(), interval=3600)
    r.cost(8, 0, 80)
    r.begin("ref:front", "refs", 0, 3, "front")
    r.end("ref:front", "refs", 1, 3, "front")
    assert s.calls[0] == {"job": 12, "stage": "refs", "done": 0, "total": 3, "message": "front",
                          "cost": {"image_units": 8, "video_units": 0, "cents": 80}}
    assert s.calls[1]["done"] == 1 and s.calls[1]["cost"] == ZERO
    assert r.step == "ref:front"


def test_cost_survives_a_failed_report():
    s = Srv()
    r = Reporter(s, 12, threading.Event(), interval=3600)
    r.cost(0, 4, 400)
    s.down = True
    r.begin("video:stand", "video", 0, 5, "stand")
    s.down = False
    r.end("video:stand", "video", 1, 5, "stand")
    assert s.calls == [{"job": 12, "stage": "video", "done": 1, "total": 5, "message": "stand",
                        "cost": {"image_units": 0, "video_units": 4, "cents": 400}}]


def test_any_exception_from_the_server_call_is_swallowed_and_cost_kept():
    s = Srv()
    r = Reporter(s, 12, threading.Event(), interval=3600)
    r.cost(8, 0, 80)
    s.raises = ValueError("boom")
    r.begin("ref:front", "refs", 0, 3, "front")        # must not raise
    s.raises = None
    r.end("ref:front", "refs", 1, 3, "front")
    assert s.calls[0]["cost"] == {"image_units": 8, "video_units": 0, "cents": 80}


def test_a_server_abort_stops_at_once_and_at_every_later_check():
    s = Srv()
    r = Reporter(s, 12, threading.Event(), interval=3600)
    s.abort = True
    with pytest.raises(JobAborted):
        r.begin("video:walk", "video", 1, 5, "walk")
    with pytest.raises(JobAborted):
        r.poll()


def test_a_raised_server_abort_also_sets_the_flag():
    s = Srv()
    r = Reporter(s, 12, threading.Event(), interval=3600)
    s.raises = ServerAbort("409", 409)
    with pytest.raises(JobAborted):
        r.begin("video:walk", "video", 1, 5, "walk")


def test_a_stop_request_lets_the_step_finish_and_stops_before_the_next():
    s = Srv()
    stop = threading.Event()
    r = Reporter(s, 12, stop, interval=3600)
    r.begin("video:stand", "video", 0, 5, "stand")
    stop.set()
    r.poll()                                     # mid-step: carry on
    r.end("video:stand", "video", 1, 5, "stand")
    with pytest.raises(StopRequested):
        r.begin("video:walk", "video", 1, 5, "walk")
    assert [c["message"] for c in s.calls] == ["stand", "stand"]


def test_the_heartbeat_repeats_the_last_progress_while_a_step_runs():
    s = Srv()
    r = Reporter(s, 12, threading.Event(), interval=0.05).start()
    try:
        r.begin("video:stand", "video", 0, 5, "stand")
        time.sleep(0.4)
    finally:
        r.close()
    assert len([c for c in s.calls if c["message"] == "stand"]) >= 3


def test_the_heartbeat_carries_unsent_cost():
    s = Srv()
    r = Reporter(s, 12, threading.Event(), interval=0.05).start()
    try:
        r.begin("video:stand", "video", 0, 5, "stand")
        r.cost(0, 4, 400)
        time.sleep(0.3)
    finally:
        r.close()
    assert sum(c["cost"]["cents"] for c in s.calls) == 400


def test_an_abort_seen_by_the_heartbeat_reaches_poll():
    s = Srv()
    r = Reporter(s, 12, threading.Event(), interval=0.05).start()
    try:
        r.begin("video:stand", "video", 0, 5, "stand")
        s.abort = True
        time.sleep(0.3)
        with pytest.raises(JobAborted):
            r.poll()
    finally:
        r.close()


def test_close_stops_the_heartbeat():
    s = Srv()
    r = Reporter(s, 12, threading.Event(), interval=0.05).start()
    r.close()
    n = len(s.calls)
    time.sleep(0.2)
    assert len(s.calls) == n


def test_nothing_is_sent_after_close_even_by_a_report():
    s = Srv()
    r = Reporter(s, 12, threading.Event(), interval=3600)
    r.close()
    r.end("upload", "upload", 1, 1, "done")
    assert s.calls == []


def test_close_waits_for_an_in_flight_heartbeat():
    entered, release = threading.Event(), threading.Event()

    class Slow(Srv):
        def progress(self, *a):
            entered.set()
            release.wait(2)
            return super().progress(*a)

    s = Slow()
    r = Reporter(s, 12, threading.Event(), interval=0.02).start()
    assert entered.wait(2)
    closer = threading.Thread(target=r.close)
    closer.start()
    time.sleep(0.1)
    assert closer.is_alive()                     # still waiting on the in-flight call
    release.set()
    closer.join(3)
    assert not closer.is_alive()
    n = len(s.calls)
    time.sleep(0.15)
    assert len(s.calls) == n


def test_close_sends_the_pending_cost_once_with_the_last_stage():
    s = Srv()
    r = Reporter(s, 12, threading.Event(), interval=3600)
    r.begin("ref:front", "refs", 0, 3, "front")
    r.cost(8, 0, 80)                               # paid, then the step failed: no end()
    r.close()
    r.close()
    assert s.calls[1:] == [{"job": 12, "stage": "refs", "done": 0, "total": 3, "message": "front",
                            "cost": {"image_units": 8, "video_units": 0, "cents": 80}}]
    r.end("ref:front", "refs", 1, 3, "front")
    assert len(s.calls) == 2


def test_close_flushes_even_after_an_abort_and_swallows_errors():
    s = Srv()
    r = Reporter(s, 12, threading.Event(), interval=3600)
    s.abort = True
    with pytest.raises(JobAborted):
        r.begin("video:walk", "video", 1, 5, "walk")
    r.cost(0, 4, 400)
    r.close()
    assert s.calls[-1]["cost"] == {"image_units": 0, "video_units": 4, "cents": 400}
    s2 = Srv()
    r2 = Reporter(s2, 12, threading.Event(), interval=3600)
    r2.cost(0, 4, 400)
    s2.raises = RuntimeError("down")
    r2.close()                                     # must not raise
    assert s2.calls == []


def test_close_sends_nothing_when_no_cost_is_pending():
    s = Srv()
    r = Reporter(s, 12, threading.Event(), interval=3600)
    r.end("upload", "upload", 1, 1, "upload")      # e.g. after finish: no progress may follow it
    r.close()
    assert len(s.calls) == 1
