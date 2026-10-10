"""One custom-pet job, step by step, in <work>/jobs/<id>/ (spec 2026-10-10 5.1).

Every step records itself in state.json, so a restart or a re-claim skips
what is done. A Kling task's id is saved before waiting and its result URL
before downloading: a crash or a dropped download (an IncompleteRead once
lost a paid clip) resumes the paid task instead of paying again."""
from __future__ import annotations

import hashlib
import shutil
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Protocol

from petgen import kling as kling_module
from petgen.config import Prices
from petgen.download import DownloadError
from petgen.download import fetch as http_fetch
from petgen.jobstate import Job, JobState, apply_redo
from petgen.kling import KlingError, KlingRejected, KlingTaskFailed
from petgen.prompts import POSE_ASPECT, REF_POSE_FOR_ACTION, custom_action_prompt, custom_pose_prompt
from petgen.props import PROP_REFS

IMAGE_UNITS = 8        # one kling-v3 still (HANDOFF 4)
VIDEO_UNITS = 4        # one 5 s pro clip
VIDEO_MODE = "pro"
MAX_GENERATIONS = 2    # a step pays for its first try and one retry, never more
MAX_LOOPS = 5          # plus free re-polls / re-downloads of a task already paid for
RETRY_WAIT = 30.0      # seconds before re-polling / re-downloading a task already paid for


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
    sleep: Callable[[float], None] = time.sleep         # the back-off before resuming a paid task


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


def _unknown_create(error: str) -> StepFailed:
    return StepFailed(f"可灵建任务结果未知，为避免重复扣费已停止：{error}"[:255])


def generate(run: Run, key: str, kind: str, make_body: Callable[[], dict], dest: Path) -> None:
    """One Kling result at dest. Raises KlingRejected / KlingTaskFailed (no
    task left: the caller may pay for a retry) or KlingError / DownloadError
    (transient: the task is kept and the next call only re-polls or
    re-downloads). A create that fails without an answer from Kling (network
    error, timeout) may still have been accepted and charged: it is marked
    in state.json and the step stops for good -- now and after any restart --
    rather than risk paying twice."""
    st = run.state.step(key)
    if st.get("pending_create"):
        raise _unknown_create(st["pending_create"]["error"])
    if st.get("task") is None:
        run.guard_budget(kind)
        body = make_body()
        st["attempts"] += 1              # counted before the call: a refused create still uses up the try
        run.state.save()
        create = run.env.kling.create_image if kind == "image" else run.env.kling.create_video
        try:
            task_id = create(body)
        except KlingRejected:
            raise                        # code != 0: refused, nothing charged
        except KlingError as e:
            st["pending_create"] = {"attempt": st["attempts"], "error": str(e)}
            run.state.save()
            raise _unknown_create(str(e)) from e
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
    """The prop pasted on the front still and scored. A missing or unreadable
    cutout, or one with no subject to place the prop by, fails the step."""
    from petgen import props
    from petgen.keycheck import score_file
    try:
        s = score_file(props.compose_prop(cutout, prop, kind, out))
    except (OSError, ValueError) as e:
        raise StepFailed(f"道具图生成失败：{e}"[:255]) from e
    return {"pass": s.passed, "floating": s.floating, "blob_core": s.blob_core}


def _retry(run: Run, st: dict, e: Exception) -> str:
    """After a transient KlingError / DownloadError: when a paid task is
    kept, wait before the next re-poll / re-download instead of burning
    every loop at once on the same outage."""
    if st.get("task") is not None:
        run.env.sleep(RETRY_WAIT)
    return str(e)


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
                last = _retry(run, st, e)
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


def finish_and_qa(raw: Path, final: Path, workdir: Path, action: str) -> dict:
    """Grade the raw clip with the pet's one gamma (solved from stand.mp4 and
    saved to grade.json, so every action looks alike), then QA it."""
    from petgen.finish import finish_clip, pet_gamma
    from petgen.qa import qa_clip
    finish_clip(raw, final, pet_gamma(workdir))
    return qa_clip(final, workdir, action)


def step_video(run: Run, action: str) -> None:
    """A 5 s pro clip from the action's green reference still, first frame =
    last frame. A clip that fails QA is paid for once more; a second miss is
    kept, marked qa.pass = false, for the reviewer to decide on."""
    key = f"video:{action}"
    st = run.state.step(key)
    raw, final = run.dir / f"{action}.mp4", run.dir / f"{action}-final.mp4"
    ref = run.dir / f"ref-{REF_POSE_FOR_ACTION[action]}-green.png"
    last = "未知原因"
    for _ in range(MAX_LOOPS):
        if not raw.exists():
            if st["task"] is None and st["attempts"] >= MAX_GENERATIONS:
                break

            def body() -> dict:
                n = run.state.next_seq(action)          # never reused: Kling rejects a repeated external_task_id
                img = kling_module.b64(ref)
                hint = run.state.data["hints"].get(action, "")
                return {"model_name": "kling-v3", "image": img, "image_tail": img,
                        "prompt": custom_action_prompt(run.job.species, action, hint),
                        "duration": "5", "mode": VIDEO_MODE,
                        "external_task_id": f"aipet-{run.job.id}-{action}-{n}"}

            try:
                generate(run, key, "video", body, raw)
            except (KlingError, DownloadError) as e:
                last = _retry(run, st, e)
                continue
        qa = finish_and_qa(raw, final, run.dir, action)
        if qa["pass"] or st["attempts"] >= MAX_GENERATIONS:
            st.update(done=True, qa=qa)                 # a second miss goes to review marked; a person decides
            run.state.save()
            return
        last = "成片质检未通过"
        raw.unlink()
        final.unlink(missing_ok=True)
        if action == "stand":
            (run.dir / "grade.json").unlink(missing_ok=True)   # the next stand sets the grade afresh
    raise StepFailed(f"动作 {action} 未能生成：{last}"[:255])


def guess_facing(video: Path) -> str:
    from petgen.package import walk_facing
    return walk_facing(video)


def step_package(run: Run) -> None:
    """The pet folder in a fresh <dir>/out/ -- a clip left over from an
    earlier package (a plan with more actions) must never be uploaded."""
    from petgen.package import custom_pet_json, write_pet_dir
    out = run.dir / "out"
    if out.exists():
        shutil.rmtree(out)
    facing = guess_facing(run.dir / "walk-final.mp4") if "walk" in run.job.actions else "right"
    meta = custom_pet_json(run.job.pet_id, run.job.name, run.job.species, run.job.actions, facing)
    write_pet_dir(out, {a: run.dir / f"{a}-final.mp4" for a in run.job.actions},
                  run.dir / "ref-front-cutout.png", meta)
    refs = out / "refs"
    refs.mkdir()
    for pose in run.job.poses():
        shutil.copy2(run.dir / f"ref-{pose}-green.png", refs / f"{pose}.png")
    run.state.step("package").update(done=True, walk_facing=facing)
    run.state.save()


CONTENT_TYPES = {".json": "application/json", ".png": "image/png", ".mp4": "video/mp4", ".jpg": "image/jpeg"}


def manifest(run: Run) -> list[dict]:
    """Every file under out/, with what upload-urls and finish need; 'local' is the file itself."""
    steps = run.state.data["steps"]
    qa = {f"{a}.mp4": steps[f"video:{a}"].get("qa") for a in run.job.actions}
    qa.update({f"refs/{p}.png": steps[f"ref:{p}"].get("score") for p in run.job.poses()})
    out = run.dir / "out"
    files = []
    for f in sorted(p for p in out.rglob("*") if p.is_file()):
        rel = f.relative_to(out).as_posix()
        data = f.read_bytes()
        files.append({"path": rel, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                      "content_type": CONTENT_TYPES[f.suffix], "qa": qa.get(rel),
                      "deliverable": not rel.startswith("refs/"), "local": f})
    return files


def step_upload(run: Run) -> None:
    """Upload and report every file every time: the server checks that the
    union of all finishes holds pet.json, cover.png and each clip."""
    files = manifest(run)
    up = run.env.uploader
    urls = up.upload_urls(run.job.id, [{"path": f["path"], "bytes": f["bytes"], "content_type": f["content_type"]}
                                       for f in files])
    for f in files:
        run.progress.poll()
        up.put(urls[f["path"]], f["local"], f["content_type"])
    up.finish(run.job.id, run.state.data["steps"]["package"]["walk_facing"],
              [{k: f[k] for k in ("path", "bytes", "sha256", "qa", "deliverable")} for f in files])
    run.state.step("upload")["done"] = True
    run.state.finish_done()                     # the server cleared the redo with the finish
    run.state.save()


SERVER_STAGES = {"fetch": "fetch", "ref": "refs", "propref": "propref", "video": "video",
                 "package": "package", "upload": "upload"}
_LABELS = {"fetch": "下载照片", "propref": "合成道具图", "package": "打包", "upload": "上传成品"}
_STEPS = {"fetch": step_fetch, "ref": step_ref, "propref": step_propref, "video": step_video,
          "package": step_package, "upload": step_upload}


def run_job(job: Job, env: Env, progress: Progress) -> Run:
    """Apply the job's redo once, then every step not yet done. The upload
    step ends with jobs/:id/finish, after which the job is the server's
    again -- no progress follows it."""
    run = Run(job, env, progress)
    apply_redo(run.state, job, run.dir)
    steps = job.steps()
    for step in steps:
        if run.state.done(step):
            continue
        kind, _, arg = step.partition(":")
        same = [s for s in steps if s.partition(":")[0] == kind]
        done = sum(run.state.done(s) for s in same)
        stage, message = SERVER_STAGES[kind], arg or _LABELS[kind]
        progress.begin(step, stage, done, len(same), message)
        _STEPS[kind](run, *([arg] if arg else []))
        if kind != "upload":
            progress.end(step, stage, done + 1, len(same), message)
    return run
