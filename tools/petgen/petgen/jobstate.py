"""A custom-pet job as the server hands it out (spec 2026-10-10 4.3
jobs/claim) and its resumable <work>/jobs/<id>/state.json (5.1)."""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

from petgen.package import ACTIONS
from petgen.prompts import REF_POSE_FOR_ACTION
from petgen.props import PROP_REFS

SPECIES = ("dog", "cat")
POSE_ORDER = ("front", "walk", "lie")
DEFAULT_BUDGET_CENTS = 8000


def base_pose(action: str) -> str:
    """The generated still an action's reference comes from (front-bowl -> front)."""
    return REF_POSE_FOR_ACTION[action].split("-")[0]


@dataclass(frozen=True)
class Job:
    id: int
    pet_id: str
    name: str
    species: str
    actions: tuple[str, ...]
    redo: dict | None
    budget_cents: int
    spent_cents: int
    photos: tuple[str, ...]

    @classmethod
    def from_claim(cls, d: dict) -> "Job":
        wanted = list(d.get("actions") or [])
        unknown = sorted(set(wanted) - set(ACTIONS))
        if unknown:
            raise ValueError(f"未知动作 {unknown}")
        # Canonical order puts stand first: its clip sets the pet's grade (finish.pet_gamma).
        actions = tuple(a for a in ACTIONS if a in wanted)
        if "stand" not in actions:
            raise ValueError("动作列表缺少 stand")
        if d.get("species") not in SPECIES:
            raise ValueError(f"不支持的类别 {d.get('species')}")
        pet_id = str(d.get("pet_id") or "")
        if not re.fullmatch(r"[a-z0-9-]+", pet_id):
            raise ValueError(f"pet_id 不合法：{pet_id!r}")
        photos = tuple(p["url"] for p in d.get("photos") or [] if p.get("url"))
        if not photos:
            raise ValueError("没有用户照片")
        redo = d.get("redo") or None
        if redo and not redo.get("all"):
            extra = sorted(set(redo.get("actions") or []) - set(actions))
            if extra:
                raise ValueError(f"重做的动作不在动作列表里 {extra}")
        budget = d.get("budget_cents")
        return cls(int(d["id"]), pet_id, str(d.get("name") or ""), d["species"], actions, redo,
                   int(DEFAULT_BUDGET_CENTS if budget is None else budget), int(d.get("spent_cents") or 0), photos)

    def poses(self) -> list[str]:
        need = {base_pose(a) for a in self.actions} | {"front"}   # front also makes the cover
        return [p for p in POSE_ORDER if p in need]

    def prop_stems(self) -> list[str]:
        return [stem for stem in PROP_REFS if any(REF_POSE_FOR_ACTION[a] == stem for a in self.actions)]

    def steps(self) -> list[str]:
        s = ["fetch"] + [f"ref:{p}" for p in self.poses()]
        if self.prop_stems():
            s.append("propref")
        return s + [f"video:{a}" for a in self.actions] + ["package", "upload"]


class JobState:
    """state.json: steps -> {"done", "attempts", "task", ...}; seq -> the last
    external_task_id number per action (never reset); hints -> redo notes per
    action; redo_seen -> the redo already applied. Written atomically."""

    def __init__(self, path: Path, data: dict):
        self.path, self.data = Path(path), data

    @classmethod
    def load(cls, path: Path) -> "JobState":
        path = Path(path)
        data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
        data.setdefault("steps", {})
        data.setdefault("seq", {})
        data.setdefault("hints", {})
        data.setdefault("redo_seen", None)
        return cls(path, data)

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_name(self.path.name + ".tmp")
        tmp.write_text(json.dumps(self.data, ensure_ascii=False, indent=1), encoding="utf-8")
        tmp.replace(self.path)

    def step(self, key: str) -> dict:
        return self.data["steps"].setdefault(key, {"done": False, "attempts": 0, "task": None})

    def done(self, key: str) -> bool:
        return bool(self.data["steps"].get(key, {}).get("done"))

    def next_seq(self, action: str) -> int:
        n = int(self.data["seq"].get(action, 0)) + 1
        self.data["seq"][action] = n
        return n

    def clear(self, key: str) -> None:
        self.data["steps"].pop(key, None)

    def clear_hints(self) -> None:
        """Drop the redo hints once a finish succeeded, so a stale one never
        leaks into a later redo of another action."""
        self.data["hints"] = {}

    def finish_done(self) -> None:
        """The server accepted jobs/:id/finish and cleared its redo: forget
        the applied redo and its hints (the caller saves)."""
        self.clear_hints()
        self.data["redo_seen"] = None


def apply_redo(state: JobState, job: Job, d: Path) -> None:
    redo = job.redo
    if not redo or state.data["redo_seen"] == redo:
        return
    if redo.get("all"):
        poses, actions = job.poses(), list(job.actions)
        state.data["hints"] = {}
    else:
        listed = list(redo.get("actions") or [])
        poses, actions = [], listed
        if redo.get("refs"):
            # stills only, no action named: every still the job uses is remade
            poses = [p for p in POSE_ORDER if p in {base_pose(a) for a in listed}] if listed else job.poses()
            actions = [a for a in job.actions if base_pose(a) in poses]   # every clip made from a redone still
        hint = (redo.get("hint") or "").strip()
        for a in listed:
            state.data["hints"][a] = hint
    for p in poses:
        state.clear(f"ref:{p}")
        for name in (f"ref-{p}.png", f"ref-{p}-green.png", f"ref-{p}-cutout.png"):
            (d / name).unlink(missing_ok=True)
    if "front" in poses:
        state.clear("propref")
        (d / "grade.json").unlink(missing_ok=True)
    for a in actions:
        state.clear(f"video:{a}")
        for name in (f"{a}.mp4", f"{a}-final.mp4"):
            (d / name).unlink(missing_ok=True)
    state.clear("package")
    state.clear("upload")
    state.data["redo_seen"] = redo
    state.save()
