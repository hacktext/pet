"""python -m petgen <command>   (run from tools/petgen with .venv\\Scripts\\python)"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]  # tools/petgen
WORK = HERE / "work"
REPO = HERE.parents[1]
ASSETS = REPO / "apps" / "aipet" / "assets" / "pets"
os.environ.setdefault("U2NET_HOME", str(WORK / "u2net"))  # before rembg is imported

from petgen import kling, volc  # noqa: E402
from petgen.keycheck import score_file  # noqa: E402
from petgen.qa import qa_clip  # noqa: E402
from petgen.package import ACTIONS, chosen_facing, pet_json, write_pet_dir  # noqa: E402
from petgen.prompts import (PETS, POSE_ASPECT, PROPS, REF_POSE_FOR_ACTION, action_prompt, pose_prompt,  # noqa: E402
                            source_prompt)
from petgen.finish import finish_clip, frame_rgb, metrics, pet_gamma  # noqa: E402

# Pre-flight minimum per 5 s clip: std 3 units, pro 4 (measured 2026-09-12).
VIDEO_UNITS = {"std": 3, "pro": 4}
PROP_DIR = WORK / "props"


def _rel(p: Path, base: Path = HERE) -> Path:
    """For messages: relative to base when inside it, else as given (--out /
    --from may point anywhere)."""
    try:
        return p.relative_to(base)
    except ValueError:
        return p


def pet_dir(pet: str, tag: str | None = None) -> Path:
    d = WORK / pet / tag if tag else WORK / pet
    d.mkdir(parents=True, exist_ok=True)
    return d


def _video_task_id(pet: str, action: str, tag: str | None, mode: str) -> str:
    """Kling rejects a reused external_task_id, and re-generating a clip is the
    whole point of --tag: make every call's id unique."""
    return f"petgen-{pet}-{action}-{tag or 'main'}-{mode}-{int(time.time() * 1000)}"


def _video_units_left() -> float:
    return kling.units_left("video")


def cmd_balance(_a) -> int:
    for p in kling.balance():
        print(f"{p['resource_pack_name']} | {p['remaining_quantity']}/{p['total_quantity']} | {p['status']}")
    return 0


def cmd_import_spike(a) -> int:
    spike = a.src or (Path(os.environ["PETGEN_SPIKE_OUT"]) if os.environ.get("PETGEN_SPIKE_OUT") else None)
    if spike is None:
        print("pass --from <spike out folder> (or set PETGEN_SPIKE_OUT)")
        return 1
    missing = 0
    for pet in PETS:
        pairs = [(spike / f"src-{pet}.png", pet_dir(pet) / "src.png")]
        pairs += [(spike / f"ref-{pet}-{pose}.png", pet_dir(pet) / f"ref-{pose}.png") for pose in POSE_ASPECT]
        for src, dst in pairs:
            if src.exists():
                shutil.copy2(src, dst)
                print(f"imported {_rel(dst)}")
            else:
                missing += 1
                print(f"MISSING {src.name} -> regenerate with the source/pose command")
    return 1 if missing else 0


def cmd_source(a) -> int:
    body = {"model_name": "kling-v3", "prompt": source_prompt(a.pet),
            "negative_prompt": "卡通，插画，3D 渲染，多只动物，残缺肢体，文字，水印，边框",
            "aspect_ratio": "16:9", "resolution": "1k", "n": 1}
    d = kling.wait("image", kling.create_image(body))
    kling.download(d["task_result"]["images"][0]["url"], pet_dir(a.pet) / "src.png")
    print(f"source {a.pet}: deduction {d.get('final_unit_deduction')}")
    return 0


def cmd_pose(a) -> int:
    body = {"model_name": "kling-v3", "image_reference": "subject",
            "prompt": pose_prompt(a.pet, a.pose, bright=a.bright),
            "image": kling.b64(pet_dir(a.pet) / "src.png"), "aspect_ratio": POSE_ASPECT[a.pose],
            "resolution": a.resolution, "n": 1}
    d = kling.wait("image", kling.create_image(body))
    out = pet_dir(a.pet, a.tag) / f"ref-{a.pose}.png"
    kling.download(d["task_result"]["images"][0]["url"], out)
    print(f"pose {a.pet}/{a.pose} ({a.resolution}{', bright' if a.bright else ''}) -> {out.relative_to(HERE)}: "
          f"deduction {d.get('final_unit_deduction')}")
    return 0


def cmd_gate(a) -> int:
    from petgen.compose import EdgeError, compose
    try:
        d = pet_dir(a.pet, a.tag)
        r = compose(d / f"ref-{a.pose}.png", d, f"ref-{a.pose}", calibrate=a.calibrate)
    except EdgeError as e:
        print(f"FAIL {a.pet}/{a.pose}: {e}")
        return 1
    s = score_file(r.green)
    print(f"{'PASS' if s.passed else 'FAIL'} {a.pet}/{a.pose}: floating={s.floating} blob_core={s.blob_core}")
    return 0 if s.passed else 1


def cmd_prop(a) -> int:
    from petgen.compose import EdgeError
    from petgen.props import cut_prop
    body = {"model_name": "kling-v3", "prompt": PROPS[a.kind],
            "negative_prompt": "动物，人，文字，水印，边框，多个物体", "aspect_ratio": "1:1", "resolution": "1k", "n": 1}
    d = kling.wait("image", kling.create_image(body))
    src = PROP_DIR / f"{a.kind}.png"
    kling.download(d["task_result"]["images"][0]["url"], src)
    print(f"prop {a.kind} -> {src.relative_to(HERE)}: deduction {d.get('final_unit_deduction')}")
    try:
        out = cut_prop(src, PROP_DIR / f"{a.kind}-cutout.png")
    except EdgeError as e:
        print(f"FAIL prop {a.kind}: {e}")
        return 1
    print(f"PASS prop {a.kind} -> {out.relative_to(HERE)}")
    return 0


def cmd_propref(a) -> int:
    from petgen.props import PROP_REFS, compose_prop
    d = pet_dir(a.pet, a.tag)
    cut = d / "ref-front-cutout.png"
    if not cut.exists():
        print(f"no {cut.relative_to(HERE)}: run pose / gate front first")
        return 1
    ok = True
    for stem, kind in PROP_REFS.items():
        prop = PROP_DIR / f"{kind}-cutout.png"
        if not prop.exists():
            print(f"no {prop.relative_to(HERE)}: run prop {kind} first")
            return 1
        s = score_file(compose_prop(cut, prop, kind, d / f"ref-{stem}-green.png"))
        ok = ok and s.passed
        print(f"{'PASS' if s.passed else 'FAIL'} {a.pet}/{stem}: floating={s.floating} blob_core={s.blob_core}")
    return 0 if ok else 1


def cmd_video(a) -> int:
    d = pet_dir(a.pet, a.tag)
    ref = d / f"ref-{REF_POSE_FOR_ACTION[a.action]}-green.png"
    if not ref.exists():
        print(f"no gated reference {ref.relative_to(HERE)}: run gate first")
        return 1
    need = VIDEO_UNITS[a.mode]
    left = _video_units_left()
    if left < need:
        print(f"only {left} video units left, {a.mode} needs {need} -- stopping")
        return 2
    img = kling.b64(ref)
    body = {"model_name": "kling-v3", "image": img, "image_tail": img, "prompt": action_prompt(a.pet, a.action),
            "duration": "5", "mode": a.mode, "external_task_id": _video_task_id(a.pet, a.action, a.tag, a.mode)}
    r = kling.wait("video", kling.create_video(body), every=10)
    out = d / f"{a.action}.mp4"
    kling.download(r["task_result"]["videos"][0]["url"], out)
    print(f"video {a.pet}/{a.action} ({a.mode}) -> {out.relative_to(HERE)}: "
          f"deduction {r.get('final_unit_deduction')}, {_video_units_left():.0f} units left")
    return 0


def cmd_finish(a) -> int:
    d = pet_dir(a.pet, a.tag)
    src = d / f"{a.action}.mp4"
    if not src.exists():
        print(f"missing {src.relative_to(HERE)}")
        return 1
    try:
        gamma = pet_gamma(d, a.gamma, PETS.get(a.pet, {}).get("grade"))
    except FileNotFoundError as e:
        print(f"{e}: pass --gamma")
        return 1
    dst = d / f"{a.action}-final.mp4"
    frames = finish_clip(src, dst, gamma)
    before, after = metrics(frame_rgb(src, 30)), metrics(frame_rgb(dst, 30))
    kbps = dst.stat().st_size * 8 / (frames / 24) / 1000
    print(json.dumps({"pet": a.pet, "action": a.action, "tag": a.tag, "gamma": gamma, "frames": frames,
                      "kbps": round(kbps), "luma": [round(before[0], 1), round(after[0], 1)],
                      "p95": [round(before[1], 1), round(after[1], 1)],
                      "sharpness": [round(before[2], 2), round(after[2], 2)]}, ensure_ascii=False))
    return 0


def cmd_qa(a) -> int:
    d = pet_dir(a.pet, a.tag)
    v = d / f"{a.action}-final.mp4"
    if not v.exists():
        print(f"missing {v.relative_to(HERE)}: run finish first")
        return 1
    r = qa_clip(v, d, a.action)
    print(json.dumps({"pet": a.pet, "action": a.action, **r}, ensure_ascii=False))
    return 0 if r["pass"] else 1


def cmd_package(a) -> int:
    d = pet_dir(a.pet, a.tag)
    clips = {k: d / f"{k}-final.mp4" for k in ACTIONS}
    missing = [c.name for c in clips.values() if not c.exists()]
    if missing:
        print(f"missing clips {missing}")
        return 1
    out = a.out or ASSETS / f"builtin-{a.pet}"
    facing = chosen_facing(a.facing, d / "walk-final.mp4")
    write_pet_dir(out, clips, d / "ref-front-cutout.png", pet_json(a.pet, facing))
    print(f"walkFacing {facing}{' (--facing)' if a.facing else ' (detected)'}")
    print(f"packaged {_rel(out, REPO)}")
    return 0


def cmd_voice(a) -> int:
    """One line of speech; --ref clones the voice in that clip on the fly
    (say @音频1 in the prompt), --speaker uses a registered voice."""
    speaker = a.speaker or (None if a.ref else volc.default_speaker())
    try:
        r = volc.generate(volc.body(a.prompt, ref=a.ref, speaker=speaker, speech_rate=a.rate), a.out)
    except (volc.VolcError, ValueError) as e:
        print(f"FAIL voice: {e}")
        return 1
    print(f"voice -> {a.out}: {r.get('duration')} s (billed {r.get('original_duration')} s)")
    return 0


def cmd_worker(a) -> int:
    """Claim paid custom-pet jobs and make them until stopped. The first
    Ctrl+C / SIGTERM finishes the step in hand (maybe a paid clip) and
    leaves the job for the server's reaper; a second one quits at once."""
    import logging
    import signal
    import threading
    from petgen.config import ConfigError, load_worker_config
    from petgen.pipeline import Env
    from petgen.server import Server
    from petgen.worker import Worker
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    try:
        cfg = load_worker_config(a.config)
    except ConfigError as e:
        print(f"FAIL worker: {e}")
        return 1
    work = a.work or WORK
    props = a.props or work / "props"
    missing = [f"{k}-cutout.png" for k in ("bowl", "ball") if not (props / f"{k}-cutout.png").exists()]
    if missing:
        print(f"FAIL worker: no {', '.join(missing)} in {props}: run `petgen prop bowl` / `petgen prop ball` "
              f"or copy work/props there")
        return 1
    stop = threading.Event()

    def on_signal(_signum, _frame):
        if stop.is_set():
            raise KeyboardInterrupt
        print("stopping after the current step (signal again to quit now)", flush=True)
        stop.set()

    signal.signal(signal.SIGINT, on_signal)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, on_signal)
    server = Server(a.server, cfg.key)
    env = Env(work=work, props=props, prices=cfg.prices, uploader=server)
    try:
        return Worker(server, env, stop).run(once=a.once)
    except KeyboardInterrupt:
        return 130


def main() -> int:
    ap = argparse.ArgumentParser(prog="petgen")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("balance").set_defaults(fn=cmd_balance)
    vp = sub.add_parser("voice")
    vp.add_argument("prompt")
    vp.add_argument("--out", type=Path, required=True)
    vp.add_argument("--ref", type=Path, default=None, help="reference clip to clone (<= 30 s, <= 10 MB)")
    vp.add_argument("--speaker", default=None, help="voice id; defaults to VOLC_SPEAKER_ID")
    vp.add_argument("--rate", type=int, default=0, help="speech rate, -50 (0.5x) .. 100 (2x)")
    vp.set_defaults(fn=cmd_voice)
    wp = sub.add_parser("worker", help="claim paid custom-pet jobs from the server and make them")
    wp.add_argument("--server", required=True, help="e.g. https://aipei.pixpickai.com")
    wp.add_argument("--config", type=Path, default=None, help="worker.env; default <secrets>/worker.env")
    wp.add_argument("--work", type=Path, default=None, help="job folders go to <work>/jobs/<id>; default tools/petgen/work")
    wp.add_argument("--props", type=Path, default=None, help="bowl-cutout.png / ball-cutout.png; default <work>/props")
    wp.add_argument("--once", action="store_true", help="exit after one job (manual checks)")
    wp.set_defaults(fn=cmd_worker)
    ip = sub.add_parser("import-spike")
    ip.add_argument("--from", dest="src", type=Path, default=None,
                    help="the spike's out folder; default $PETGEN_SPIKE_OUT")
    ip.set_defaults(fn=cmd_import_spike)
    pp = sub.add_parser("prop")
    pp.add_argument("kind", choices=list(PROPS))
    pp.set_defaults(fn=cmd_prop)
    for name, fn, extra in [("source", cmd_source, None), ("pose", cmd_pose, ("pose", list(POSE_ASPECT))),
                            ("gate", cmd_gate, ("pose", list(POSE_ASPECT))), ("video", cmd_video, ("action", ACTIONS)),
                            ("finish", cmd_finish, ("action", ACTIONS)), ("qa", cmd_qa, ("action", ACTIONS)),
                            ("propref", cmd_propref, None), ("package", cmd_package, None)]:
        p = sub.add_parser(name)
        p.add_argument("pet", choices=list(PETS))
        if extra:
            p.add_argument(extra[0], choices=extra[1])
        if name != "source":
            p.add_argument("--tag", default=None, help="work/<pet>/<tag>/ instead of work/<pet>/")
        if name == "pose":
            p.add_argument("--resolution", choices=["1k", "2k"], default="1k")
            p.add_argument("--bright", action="store_true")
        if name == "gate":
            p.add_argument("--calibrate", action="store_true")
        if name == "video":
            p.add_argument("--mode", choices=list(VIDEO_UNITS), default="std")
        if name == "finish":
            p.add_argument("--gamma", type=float, default=None)
        if name == "package":
            p.add_argument("--facing", choices=["left", "right"], default=None)
            p.add_argument("--out", type=Path, default=None,
                           help="pet folder to write; default apps/aipet/assets/pets/builtin-<pet>")
        p.set_defaults(fn=fn)
    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
