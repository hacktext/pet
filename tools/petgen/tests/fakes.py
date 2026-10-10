"""Test doubles shared by the pipeline and worker tests."""
from __future__ import annotations

import shutil
from pathlib import Path

from PIL import Image

from petgen.config import Prices
from petgen.download import DownloadError
from petgen.kling import KlingTaskFailed
from petgen.pipeline import Env, JobAborted, StopRequested


def claim(**over) -> dict:
    """A jobs/claim job as the server hands it out (standard plan, two photos)."""
    d = {"id": 12, "pet_id": "custom-12", "name": "豆豆", "species": "dog",
         "actions": ["stand", "walk", "feed", "play", "sleep"], "redo": None,
         "budget_cents": 8000, "spent_cents": 0,
         "photos": [{"url": "https://oss.invalid/p1.jpg"}, {"url": "https://oss.invalid/p2.jpg"}]}
    d.update(over)
    return d


def _png(path: Path, rgba) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGBA", (64, 64), rgba).save(path)


def _task_of(path: Path) -> str:
    """FakeKling.download writes the result URL into the file; its tail is the task id."""
    return Path(path).read_text(encoding="utf-8").rsplit("/", 1)[-1]


class FakeKling:
    """petgen.kling's create / wait / download / units_left without a network.
    Task ids are '<kind>-<n>' (n = 1-based count of creates)."""

    def __init__(self):
        self.created: list[tuple[str, dict]] = []
        self.waited: list[str] = []
        self.downloads: list[str] = []
        self.reject: list[Exception] = []        # raised by the next creates, in order
        self.fail_task: set[str] = set()         # wait() reports these tasks failed
        self.crash_wait: set[str] = set()        # wait() dies once: the worker was killed
        self.crash_download: set[str] = set()    # download() dies once
        self.download_errors = 0                 # this many downloads raise DownloadError
        self.balance = {"image": 1000.0, "video": 100.0}
        self.balance_error: Exception | None = None
        self.deduction = {"image": "8", "video": "4"}

    def _create(self, kind, body):
        self.created.append((kind, body))
        if self.reject:
            raise self.reject.pop(0)
        return f"{kind}-{len(self.created)}"

    def create_image(self, body):
        return self._create("image", body)

    def create_video(self, body):
        return self._create("video", body)

    def wait(self, kind, task_id, every=8.0, limit=120, on_poll=None):
        self.waited.append(task_id)
        if on_poll is not None:
            on_poll()
        if task_id in self.crash_wait:
            self.crash_wait.discard(task_id)
            raise RuntimeError("worker killed while waiting")
        if task_id in self.fail_task:
            raise KlingTaskFailed(f"{kind} task {task_id} failed: 内容审核未通过")
        key = "images" if kind == "image" else "videos"
        return {"task_status": "succeed", "final_unit_deduction": self.deduction[kind],
                "task_result": {key: [{"url": f"https://kling.invalid/{task_id}"}]}}

    def download(self, url, dest):
        task_id = url.rsplit("/", 1)[-1]
        if task_id in self.crash_download:
            self.crash_download.discard(task_id)
            raise RuntimeError("worker killed mid-download")
        if self.download_errors:
            self.download_errors -= 1
            raise DownloadError("download failed after 4 tries: IncompleteRead(0 bytes read)")
        dest = Path(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(url, encoding="utf-8")
        self.downloads.append(url)
        return dest

    def units_left(self, kind):
        if self.balance_error is not None:
            raise self.balance_error
        return self.balance[kind]


class FakeProgress:
    def __init__(self):
        self.calls: list[tuple] = []          # (kind, step, stage, done, total, message)
        self.costs = [0.0, 0.0, 0]
        self.step = None
        self.abort_step = None                # poll() raises JobAborted while this step runs
        self.stop_before = None               # begin() of this step raises StopRequested

    def begin(self, step, stage, done, total, message):
        if step == self.stop_before:
            raise StopRequested()
        self.step = step
        self.calls.append(("begin", step, stage, done, total, message))

    def end(self, step, stage, done, total, message):
        self.calls.append(("end", step, stage, done, total, message))

    def poll(self):
        if self.step is not None and self.step == self.abort_step:
            raise JobAborted()

    def cost(self, image_units, video_units, cents):
        self.costs[0] += image_units
        self.costs[1] += video_units
        self.costs[2] += cents


class FakeUploader:
    def __init__(self):
        self.requested: list[list[dict]] = []
        self.puts: list[tuple[str, str, str]] = []     # (url, file name, content type)
        self.finished: list[tuple[str, list[dict]]] = []
        self.events: list[tuple] = []
        self.fail_finish = 0

    def upload_urls(self, job_id, files):
        self.requested.append(files)
        return {f["path"]: f"https://oss.invalid/{f['path']}" for f in files}

    def put(self, url, path, content_type):
        self.puts.append((url, Path(path).name, content_type))

    def finish(self, job_id, walk_facing, files):
        if self.fail_finish:
            self.fail_finish -= 1
            raise RuntimeError("server down during finish")
        self.finished.append((walk_facing, files))
        self.events.append(("finish",))


def install_fake_tools(monkeypatch) -> dict:
    """Instant stand-ins for segmentation, prop compositing, finish + QA and
    facing detection. Put Kling task ids (or prop kinds) in the knobs' sets
    to make them fail."""
    from petgen import pipeline
    knobs = {"gate_fail": set(), "qa_fail": set(), "prop_fail": set(), "gated": [], "finished": []}

    def gate(raw, out_dir, stem):
        tid = _task_of(raw)
        knobs["gated"].append(tid)
        if tid in knobs["gate_fail"]:
            return {"pass": False, "floating": 9000, "blob_core": 999, "reason": f"抠像残留 blob_core=999（{tid}）"}
        _png(Path(out_dir) / f"{stem}-green.png", (0, 255, 0, 255))
        _png(Path(out_dir) / f"{stem}-cutout.png", (200, 150, 100, 255))
        return {"pass": True, "floating": 1, "blob_core": 0, "reason": ""}

    def prop_ref(cutout, prop, kind, out):
        if kind in knobs["prop_fail"]:
            return {"pass": False, "floating": 0, "blob_core": 500}
        _png(out, (0, 255, 0, 255))
        return {"pass": True, "floating": 0, "blob_core": 0}

    def finish_and_qa(raw, final, workdir, action):
        tid = _task_of(raw)
        knobs["finished"].append(tid)
        shutil.copy2(raw, final)
        return {"pass": tid not in knobs["qa_fail"], "seam": 40.0, "blob_core_worst": 10}

    monkeypatch.setattr(pipeline, "gate", gate)
    monkeypatch.setattr(pipeline, "prop_ref", prop_ref)
    monkeypatch.setattr(pipeline, "finish_and_qa", finish_and_qa, raising=False)   # added in Task 8
    monkeypatch.setattr(pipeline, "guess_facing", lambda video: "left", raising=False)
    return knobs


def fake_fetch(url, dest):
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(url, encoding="utf-8")
    return dest


def make_env(tmp_path, kling, uploader, prices=None) -> Env:
    props = Path(tmp_path) / "props"
    for kind in ("bowl", "ball"):
        _png(props / f"{kind}-cutout.png", (200, 0, 0, 255))
    return Env(work=Path(tmp_path) / "work", props=props, prices=prices or Prices(10.0, 100.0),
               uploader=uploader, kling=kling, fetch=fake_fetch)


class FakeServer(FakeUploader):
    """The PHP internal worker API in memory."""

    def __init__(self, jobs=()):
        super().__init__()
        self.jobs = list(jobs)
        self.progress_calls: list[tuple] = []     # (job_id, stage, done, total, message, cost)
        self.failed: list[tuple] = []             # (job_id, stage, reason)
        self.statuses: list[tuple] = []           # (paused, reason, balance)
        self.abort_at = None                      # (stage, message) that answers abort
        self.on_progress = None

    def claim(self):
        return {"job": self.jobs.pop(0) if self.jobs else None}

    def progress(self, job_id, stage, done, total, message, cost):
        self.progress_calls.append((job_id, stage, done, total, message, dict(cost)))
        self.events.append(("progress", stage, message))
        if self.on_progress is not None:
            self.on_progress(stage, message)
        return (stage, message) == self.abort_at

    def fail(self, job_id, stage, reason):
        self.failed.append((job_id, stage, reason))
        self.events.append(("fail", stage))

    def status(self, paused, reason, balance):
        self.statuses.append((paused, reason, dict(balance)))
