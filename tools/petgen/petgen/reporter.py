"""Progress to the server (spec 2026-10-10 5.2): at every step's start and
end, and every 60 s in between as the job's heartbeat (the reaper hands a
job back after 20 silent minutes). {abort: true} stops the job at the next
check; a stop request (Ctrl+C / SIGTERM) only before a step begins, so the
step in hand -- maybe a paid clip -- is finished first.

Cost is carried as increments: whatever has not been sent successfully stays
pending and goes out with the next progress call (step report or heartbeat).
A crash can therefore lose at most the cost since the last successful send.
After close() nothing is sent any more, so no heartbeat can follow finish."""
from __future__ import annotations

import logging
import threading
import time

from petgen.pipeline import JobAborted, StopRequested
from petgen.server import ServerAbort

log = logging.getLogger("petgen.worker")
HEARTBEAT = 60.0


class Reporter:
    def __init__(self, server, job_id: int, stop: threading.Event, *, interval: float = HEARTBEAT,
                 clock=time.monotonic):
        self._server, self._job_id, self._stop = server, job_id, stop
        self._interval, self._clock = interval, clock
        self._lock = threading.Lock()          # state: report args, pending cost
        self._send_lock = threading.Lock()     # one server call at a time; close() waits for it
        self._halt = threading.Event()
        self._thread: threading.Thread | None = None
        self.step = "claim"
        self._report_args = ("claim", 0, 0, "")          # stage, done, total, message
        self._pending = [0.0, 0.0, 0]                    # image units, video units, cents not yet reported
        self._sent_at = clock()
        self.aborted = False

    def start(self) -> "Reporter":
        self._thread = threading.Thread(target=self._beat, name=f"heartbeat-{self._job_id}", daemon=True)
        self._thread.start()
        return self

    def close(self) -> None:
        """Send the cost still pending -- units paid in a step that then
        failed get no end() report -- once, with the last stage, then stop.
        The server adds cost even when it answers abort, so this flushes
        regardless. Nothing is sent after close() returns."""
        with self._send_lock:                  # an in-flight heartbeat finishes; no later one starts
            if not self._halt.is_set():
                with self._lock:
                    pending = any(self._rounded_cost().values())
                if pending:
                    self._send_locked()
                self._halt.set()
        if self._thread is not None:
            self._thread.join(timeout=5)

    def begin(self, step: str, stage: str, done: int, total: int, message: str) -> None:
        if self._stop.is_set():
            raise StopRequested()
        self._report(step, stage, done, total, message)

    def end(self, step: str, stage: str, done: int, total: int, message: str) -> None:
        self._report(step, stage, done, total, message)

    def poll(self) -> None:
        if self.aborted:
            raise JobAborted()

    def cost(self, image_units: float, video_units: float, cents: int) -> None:
        with self._lock:
            self._pending[0] += image_units
            self._pending[1] += video_units
            self._pending[2] += cents

    def _report(self, step: str, stage: str, done: int, total: int, message: str) -> None:
        with self._lock:
            self.step = step
            self._report_args = (stage, done, total, message)
        self._send()
        self.poll()

    def _beat(self) -> None:
        while not self._halt.wait(min(5.0, self._interval)):
            if self._clock() - self._sent_at >= self._interval:
                self._send()

    def _rounded_cost(self) -> dict:
        image, video, cents = self._pending
        return {"image_units": round(image), "video_units": round(video), "cents": int(cents)}

    def _send(self) -> None:
        with self._send_lock:
            if self._halt.is_set():
                return
            self._send_locked()

    def _send_locked(self) -> None:
        """One progress call; the caller holds _send_lock."""
        with self._lock:
            args = self._report_args
            cost = self._rounded_cost()
        try:
            abort = self._server.progress(self._job_id, *args, cost)
        except ServerAbort:
            abort = True
        except Exception as e:                 # never let the heartbeat thread die; cost stays pending
            log.warning("任务 %s 的进度没能上报给后台（下次一起补报）：%s", self._job_id, e)
            return
        with self._lock:
            # The server added the increment; keep what rounding left behind and anything added meanwhile.
            self._pending[0] -= cost["image_units"]
            self._pending[1] -= cost["video_units"]
            self._pending[2] -= cost["cents"]
            self._sent_at = self._clock()
            if abort:
                self.aborted = True
