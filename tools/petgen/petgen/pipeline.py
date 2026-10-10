"""One custom-pet job, step by step, in <work>/jobs/<id>/ (spec 2026-10-10 5.1).

Every step records itself in state.json, so a restart or a re-claim skips
what is done. A Kling task's id is saved before waiting and its result URL
before downloading: a crash or a dropped download (an IncompleteRead once
lost a paid clip) resumes the paid task instead of paying again."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Protocol

from petgen import kling as kling_module
from petgen.config import Prices
from petgen.download import DownloadError
from petgen.download import fetch as http_fetch
from petgen.jobstate import Job, JobState
from petgen.kling import KlingError, KlingTaskFailed
from petgen.prompts import POSE_ASPECT, custom_pose_prompt
from petgen.props import PROP_REFS

IMAGE_UNITS = 8        # one kling-v3 still (HANDOFF 4)
VIDEO_UNITS = 4        # one 5 s pro clip
VIDEO_MODE = "pro"
MAX_GENERATIONS = 2    # a step pays for its first try and one retry, never more
MAX_LOOPS = 5          # plus free re-polls / re-downloads of a task already paid for


class StepFailed(Exception):
    """A step gave up; str(e) is the readable fail_reason."""


class BudgetExceeded(Exception):
    """The next Kling call would pass the job's budget_cents."""


class JobAborted(Exception):
    """The server says the job is no longer ours (an admin changed it)."""


class StopRequested(Exception):
    """Ctrl+C / SIGTERM: leave before the next step and report nothing."""


class Progress(Protocol):
    def begin(self, step: str, stage: str, done: int, total: int, message: str) -> None: ...
    def end(self, step: str, stage: str, done: int, total: int, message: str) -> None: ...
    def poll(self) -> None: ...
    def cost(self, image_units: float, video_units: float, cents: int) -> None: ...


class Uploader(Protocol):
    def upload_urls(self, job_id: int, files: list[dict]) -> dict[str, str]: ...
    def put(self, url: str, path: Path, content_type: str) -> None: ...
    def finish(self, job_id: int, walk_facing: str, files: list[dict]) -> None: ...


@dataclass
class Env:
    work: Path                  # job folders: <work>/jobs/<id>/
    props: Path                 # bowl-cutout.png, ball-cutout.png (shared, made once by `petgen prop`)
    prices: Prices
    uploader: Uploader
    kling: object = kling_module                       # create_image / create_video / wait / download / units_left
    fetch: Callable[[str, Path], Path] = http_fetch    # the user's photos from signed URLs


class Run:
    def __init__(self, job: Job, env: Env, progress: Progress):
        self.job, self.env, self.progress = job, env, progress
        self.dir = Path(env.work) / "jobs" / str(job.id)
        self.dir.mkdir(parents=True, exist_ok=True)
        self.state = JobState.load(self.dir / "state.json")
        self.run_cents = 0

    def photo_paths(self) -> list[Path]:
        return [self.dir / "photos" / f"{i}.jpg" for i in range(1, len(self.job.photos) + 1)]

    def guard_budget(self, kind: str) -> None:
        est = self.env.prices.cents(IMAGE_UNITS, 0) if kind == "image" else self.env.prices.cents(0, VIDEO_UNITS)
        spent = self.job.spent_cents + self.run_cents
        if spent + est > self.job.budget_cents:
            raise BudgetExceeded(f"超出单笔预算（已花 {spent / 100:.2f} 元，下一步约 {est / 100:.2f} 元，"
                                 f"预算 {self.job.budget_cents / 100:.2f} 元）")

    def charge(self, kind: str, units: float) -> None:
        image, video = (units, 0.0) if kind == "image" else (0.0, units)
        cents = self.env.prices.cents(image, video)
        self.run_cents += cents
        self.progress.cost(image, video, cents)


def generate(run: Run, key: str, kind: str, make_body: Callable[[], dict], dest: Path) -> None:
    """One Kling result at dest. Raises KlingRejected / KlingTaskFailed (no
    task left: the caller may pay for a retry) or KlingError / DownloadError
    (transient: the task is kept and the next call only re-polls or
    re-downloads)."""
    st = run.state.step(key)
    if st.get("task") is None:
        run.guard_budget(kind)
        body = make_body()
        st["attempts"] += 1              # counted before the call: a refused create still uses up the try
        run.state.save()
        create = run.env.kling.create_image if kind == "image" else run.env.kling.create_video
        task_id = create(body)
        st["task"] = {"id": task_id, "url": None, "charged": False}
        run.state.save()
    task = st["task"]
    if task["url"] is None:
        try:
            d = run.env.kling.wait(kind, task["id"], every=8.0 if kind == "image" else 10.0,
                                   on_poll=run.progress.poll)
        except KlingTaskFailed:
            st["task"] = None
            run.state.save()
            raise
        task["url"] = d["task_result"]["images" if kind == "image" else "videos"][0]["url"]
        if not task["charged"]:
            units = d.get("final_unit_deduction")
            run.charge(kind, float(units) if units not in (None, "") else
                       float(IMAGE_UNITS if kind == "image" else VIDEO_UNITS))
            task["charged"] = True
        run.state.save()
    run.env.kling.download(task["url"], dest)
    st["task"] = None
    run.state.save()


def gate(raw: Path, out_dir: Path, stem: str) -> dict:
    """Segment the still off its grey backdrop onto exact green, exposure-
    calibrated like the production recipe, and score it like `petgen gate`."""
    from petgen.compose import EdgeError, compose
    from petgen.keycheck import score_file
    try:
        r = compose(raw, out_dir, stem, calibrate=True)
    except EdgeError as e:
        return {"pass": False, "floating": 0, "blob_core": 0, "reason": f"主体被画框截断 {e.sides}"}
    except ValueError as e:
        return {"pass": False, "floating": 0, "blob_core": 0, "reason": f"没分割出主体：{e}"}
    s = score_file(r.green)
    return {"pass": s.passed, "floating": s.floating, "blob_core": s.blob_core,
            "reason": "" if s.passed else f"抠像残留 blob_core={s.blob_core}"}


def prop_ref(cutout: Path, prop: Path, kind: str, out: Path) -> dict:
    from petgen.keycheck import score_file
    from petgen.props import compose_prop
    s = score_file(compose_prop(cutout, prop, kind, out))
    return {"pass": s.passed, "floating": s.floating, "blob_core": s.blob_core}


def step_fetch(run: Run) -> None:
    for url, dest in zip(run.job.photos, run.photo_paths()):
        if not dest.exists():
            run.env.fetch(url, dest)
    run.state.step("fetch")["done"] = True
    run.state.save()


def step_ref(run: Run, pose: str) -> None:
    """A full-body still of the customer's pet in this pose. The retry uses
    the next photo: a photo Kling's review refuses, or one that yields a
    cropped animal, is not worth paying for twice."""
    key = f"ref:{pose}"
    st = run.state.step(key)
    raw = run.dir / f"ref-{pose}.png"
    photos = run.photo_paths()
    last = "未知原因"
    for _ in range(MAX_LOOPS):
        if not raw.exists():
            if st["task"] is None and st["attempts"] >= MAX_GENERATIONS:
                break
            photo = photos[st["attempts"] % len(photos)]

            def body() -> dict:
                st["photo"] = photo.name
                return {"model_name": "kling-v3", "image_reference": "subject",
                        "prompt": custom_pose_prompt(run.job.species, pose), "image": kling_module.b64(photo),
                        "aspect_ratio": POSE_ASPECT[pose], "resolution": "2k", "n": 1}

            try:
                generate(run, key, "image", body, raw)
            except (KlingError, DownloadError) as e:
                last = str(e)
                continue
        verdict = gate(raw, run.dir, f"ref-{pose}")
        if verdict["pass"]:
            st.update(done=True, score=verdict)
            run.state.save()
            return
        last = verdict["reason"]
        raw.unlink()
    raise StepFailed(f"参考图 {pose} 未能生成（换照片重试后仍失败）：{last}"[:255])


def step_propref(run: Run) -> None:
    """The shared bowl / ball pasted in front of the paws. Deterministic, so
    a failure is not retried: it needs a person."""
    scores = {}
    for stem in run.job.prop_stems():
        kind = PROP_REFS[stem]
        s = prop_ref(run.dir / "ref-front-cutout.png", Path(run.env.props) / f"{kind}-cutout.png", kind,
                     run.dir / f"ref-{stem}-green.png")
        if not s["pass"]:
            raise StepFailed(f"道具图 {stem} 未通过质检 blob_core={s['blob_core']}")
        scores[stem] = s
    run.state.step("propref").update(done=True, scores=scores)
    run.state.save()
