"""python -m petgen worker: claim a paid custom-pet job, make it, upload it,
repeat (spec 2026-10-10 5.2). One job at a time.

Nothing here may crash the loop: a balance check, claim or status call that
fails in any way is logged and waited out. A job that fails is reported with
the step it failed in; a job the server took back (409 abort) is dropped
silently; a network / 5xx failure while uploading or finishing drops the job too,
for the server's reaper to hand back -- state.json lets the re-claim resume
without paying Kling again, so it is never deleted."""
from __future__ import annotations

import logging
import math
import subprocess
import threading
import time
from pathlib import Path

from petgen import names
from petgen.download import DownloadError
from petgen.jobstate import Job, JobState
from petgen.pipeline import BudgetExceeded, Env, JobAborted, StepFailed, StopRequested, run_job
from petgen.reporter import HEARTBEAT, Reporter
from petgen.server import ServerAbort, ServerError
from petgen.server import _transient as transient_server_error

log = logging.getLogger("petgen.worker")
IMAGE_NEED = 8 * 4       # four stills' worth (spec 4.5)
VIDEO_NEED = 7 * 4       # the largest plan: 7 actions x 4 units -- the plan is unknown before the claim
IDLE_WAIT = 15.0
PAUSE_WAIT = 300.0
ERROR_WAIT = 60.0
STATUS_EVERY = 300.0
IDLE_LOG_EVERY = 300.0   # while there is nothing to do, say so this often
LOW_BALANCE = "生成额度不足"
REASON_MAX = 255
# What one tick did with a job: run() --once stops after any of these.
JOB_OUTCOMES = ("done", "failed", "aborted", "dropped")


class Worker:
    def __init__(self, server, env: Env, stop: threading.Event, *, heartbeat: float = HEARTBEAT,
                 clock=time.monotonic, wait=None):
        self.server, self.env, self.stop = server, env, stop
        self.heartbeat, self.clock = heartbeat, clock
        self.wait = wait or stop.wait
        self._last_status: tuple[bool, str] | None = None
        self._status_at = float("-inf")
        self._idle_logged_at: float | None = None   # None: the next idle round is logged

    def run(self, once: bool = False) -> int:
        while not self.stop.is_set():
            r = self.tick()
            if r == "stopped" or (once and r in JOB_OUTCOMES):
                break
        return 0

    def tick(self) -> str:
        """One round: "balance-error" | "paused" | "server-error" | "idle" |
        "stopped" | "done" | "failed" | "aborted" | "dropped"."""
        try:
            balance = {"image": float(self.env.kling.units_left("image")),
                       "video": float(self.env.kling.units_left("video"))}
        except Exception as e:  # noqa: BLE001 -- network, bad JSON, odd payload: all just mean "try later"
            log.warning("查询可灵余额失败，%d 秒后重试：%s", ERROR_WAIT, e)
            self.wait(ERROR_WAIT)
            return "balance-error"
        low = balance["image"] < IMAGE_NEED or balance["video"] < VIDEO_NEED
        self._status(low, LOW_BALANCE if low else "", balance)
        if low:
            log.info("可灵余额不足（图片 %.0f、视频 %.0f 单位），暂停领单，%d 秒后再查",
                     balance["image"], balance["video"], PAUSE_WAIT)
            self.wait(PAUSE_WAIT)
            return "paused"
        if self.stop.is_set():
            return "stopped"                      # never claim a job we would leave at once
        try:
            res = self.server.claim()
            if not isinstance(res, dict):
                raise ServerError(f"jobs/claim: unexpected answer {type(res).__name__}")
            job = res.get("job")
            if job is not None and not isinstance(job, dict):
                raise ServerError(f"jobs/claim: unexpected job {type(job).__name__}")
        except Exception as e:  # noqa: BLE001
            log.warning("向后台领取任务失败，%d 秒后重试：%s", ERROR_WAIT, e)
            self.wait(ERROR_WAIT)
            return "server-error"
        if not job:
            if res.get("paused_reason"):
                log.info("后台暂停派单：%s", res["paused_reason"])
            now = self.clock()
            if self._idle_logged_at is None or now - self._idle_logged_at >= IDLE_LOG_EVERY:
                log.info("暂无任务，每 %d 秒查询一次（可灵余额：图片 %.0f、视频 %.0f 单位）",
                         IDLE_WAIT, balance["image"], balance["video"])
                self._idle_logged_at = now
            self.wait(IDLE_WAIT)
            return "idle"
        self._idle_logged_at = None               # after a job, say again that we are waiting
        return self.process(job)

    def _status(self, paused: bool, reason: str, balance: dict) -> None:
        """worker/status on a change, and every STATUS_EVERY anyway (the admin
        page shows the balance). Unsent, it is tried again next round."""
        now = self.clock()
        if (paused, reason) == self._last_status and now - self._status_at < STATUS_EVERY:
            return
        try:
            self.server.status(paused, reason, {k: math.floor(v) for k, v in balance.items()})
        except Exception as e:  # noqa: BLE001
            log.warning("向后台上报 worker 状态失败：%s", e)
            return
        self._last_status, self._status_at = (paused, reason), now

    def process(self, raw: dict) -> str:
        try:
            job = Job.from_claim(raw)
        except Exception as e:  # noqa: BLE001 -- any malformed field
            self._fail(raw.get("id"), "claim", f"任务数据不合法：{e}")
            return "failed"
        state = Path(self.env.work) / "jobs" / str(job.id) / "state.json"
        try:
            JobState.load(state)
        except Exception as e:  # noqa: BLE001 -- kept as is: starting over could pay Kling twice
            log.error("任务 %s：进度文件 %s 损坏，无法继续", job.id, state)
            self._fail(job.id, "state", f"state.json 损坏：{e}")
            return "failed"
        log.info("领到任务 %s：%s「%s」，动作：%s", job.id, names.species(job.species), job.name,
                 names.actions(job.actions))
        rep = Reporter(self.server, job.id, self.stop, interval=self.heartbeat, clock=self.clock).start()
        try:
            try:
                run_job(job, self.env, rep)
            finally:
                rep.close()                       # no heartbeat after finish, nor after a fail report
            log.info("任务 %s 完成：成品已上传，等待后台审核", job.id)
            return "done"
        except StopRequested:
            log.info("正在停止：任务 %s 留给后台稍后重新派发", job.id)
            return "stopped"
        except (JobAborted, ServerAbort):
            # Also a retried finish whose first try went through: the job is the server's already.
            log.info("任务 %s 已在后台被修改或取消，放弃本次处理", job.id)
            return "aborted"
        except ServerError as e:
            if not transient_server_error(e):     # 4xx: retrying the same upload cannot help; settle the job
                self._fail(job.id, rep.step, f"服务器拒绝：{e}")
                return "failed"
            log.warning("任务 %s 暂时放弃（后台连不上），后台稍后会重新派发：%s", job.id, e)
            return "dropped"
        except (StepFailed, BudgetExceeded) as e:
            if self.stop.is_set() and isinstance(e.__cause__, (subprocess.SubprocessError, OSError)):
                return self._stopped(job.id, e)       # the shutdown killed the ffmpeg under the step
            self._fail(job.id, rep.step, str(e))
            return "failed"
        except DownloadError as e:
            self._fail(job.id, rep.step, f"照片下载失败：{e}")
            return "failed"
        except Exception as e:  # noqa: BLE001 -- any crash fails this job, the worker carries on
            if self.stop.is_set():
                return self._stopped(job.id, e)       # most likely the shutdown's own doing: not the job's fault
            log.exception("任务 %s 在「%s」出现程序异常", job.id, names.step(rep.step))
            self._fail(job.id, rep.step, f"{type(e).__name__}: {e}")
            return "failed"

    def _stopped(self, job_id, e: BaseException) -> str:
        log.info("正在停止：任务 %s 被中断（%s: %s），留给后台稍后重新派发", job_id, type(e).__name__, e)
        return "stopped"

    def _fail(self, job_id, stage: str, reason: str) -> None:
        if job_id is None:
            return
        log.error("任务 %s 失败，步骤「%s」：%s", job_id, names.step(stage), reason)
        try:
            self.server.fail(job_id, stage, reason[:REASON_MAX])
        except ServerAbort:
            pass                                  # a retried fail whose first try went through
        except Exception as e:  # noqa: BLE001
            log.error("任务 %s 的失败结果没能上报给后台：%s", job_id, e)
