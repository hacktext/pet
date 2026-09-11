"""python -m petgen <command>   (run from tools/petgen with .venv\\Scripts\\python)"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]  # tools/petgen
WORK = HERE / "work"
REPO = HERE.parents[1]
ASSETS = REPO / "apps" / "aipet" / "assets" / "pets"
os.environ.setdefault("U2NET_HOME", str(WORK / "u2net"))  # before rembg is imported

from petgen import kling  # noqa: E402
from petgen.keycheck import score_file  # noqa: E402
from petgen.loopcheck import probe, psnr_series, seam_verdict  # noqa: E402
from petgen.package import ACTIONS, make_cover, pet_json  # noqa: E402
from petgen.prompts import PETS, POSE_ASPECT, REF_POSE_FOR_ACTION, action_prompt, pose_prompt, source_prompt  # noqa: E402

SPIKE_OUT = Path(r"C:\Users\Administrator\AppData\Local\Temp\claude\c--Users-Administrator-code-aipet"
                 r"\4fbc451a-51c9-48a5-9f6b-54b7e4f439b7\scratchpad\out")
VIDEO_UNITS = 3


def pet_dir(pet: str) -> Path:
    d = WORK / pet
    d.mkdir(parents=True, exist_ok=True)
    return d


def _video_units_left() -> float:
    packs = [p for p in kling.balance() if "视频" in p["resource_pack_name"] and p["status"] == "online"]
    return sum(float(p["remaining_quantity"]) for p in packs)


def cmd_balance(_a) -> int:
    for p in kling.balance():
        print(f"{p['resource_pack_name']} | {p['remaining_quantity']}/{p['total_quantity']} | {p['status']}")
    return 0


def cmd_import_spike(_a) -> int:
    missing = 0
    for pet in PETS:
        pairs = [(SPIKE_OUT / f"src-{pet}.png", pet_dir(pet) / "src.png")]
        pairs += [(SPIKE_OUT / f"ref-{pet}-{pose}.png", pet_dir(pet) / f"ref-{pose}.png") for pose in POSE_ASPECT]
        for src, dst in pairs:
            if src.exists():
                shutil.copy2(src, dst)
                print(f"imported {dst.relative_to(HERE)}")
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
    body = {"model_name": "kling-v3", "image_reference": "subject", "prompt": pose_prompt(a.pet, a.pose),
            "image": kling.b64(pet_dir(a.pet) / "src.png"), "aspect_ratio": POSE_ASPECT[a.pose],
            "resolution": "1k", "n": 1}
    d = kling.wait("image", kling.create_image(body))
    kling.download(d["task_result"]["images"][0]["url"], pet_dir(a.pet) / f"ref-{a.pose}.png")
    print(f"pose {a.pet}/{a.pose}: deduction {d.get('final_unit_deduction')}")
    return 0


def cmd_gate(a) -> int:
    from petgen.compose import EdgeError, compose
    try:
        r = compose(pet_dir(a.pet) / f"ref-{a.pose}.png", pet_dir(a.pet), f"ref-{a.pose}")
    except EdgeError as e:
        print(f"FAIL {a.pet}/{a.pose}: {e}")
        return 1
    s = score_file(r.green)
    print(f"{'PASS' if s.passed else 'FAIL'} {a.pet}/{a.pose}: floating={s.floating} blob_core={s.blob_core}")
    return 0 if s.passed else 1


def cmd_video(a) -> int:
    ref = pet_dir(a.pet) / f"ref-{REF_POSE_FOR_ACTION[a.action]}-green.png"
    if not ref.exists():
        print(f"no gated reference {ref.name}: run gate first")
        return 1
    left = _video_units_left()
    if left < VIDEO_UNITS:
        print(f"only {left} video units left -- stopping")
        return 2
    img = kling.b64(ref)
    body = {"model_name": "kling-v3", "image": img, "image_tail": img, "prompt": action_prompt(a.pet, a.action),
            "duration": "5", "mode": "std", "external_task_id": f"petgen-{a.pet}-{a.action}"}
    d = kling.wait("video", kling.create_video(body), every=10)
    kling.download(d["task_result"]["videos"][0]["url"], pet_dir(a.pet) / f"{a.action}.mp4")
    print(f"video {a.pet}/{a.action}: deduction {d.get('final_unit_deduction')}, {left - VIDEO_UNITS:.0f} units left")
    return 0


def _frame(video: Path, out: Path, last: bool) -> Path:
    seek = ["-sseof", "-0.05"] if last else []
    subprocess.run(["ffmpeg", "-v", "error", "-y", *seek, "-i", str(video), "-update", "1", "-frames:v", "1", str(out)],
                   check=True)
    return out


def cmd_qa(a) -> int:
    d = pet_dir(a.pet)
    v = d / f"{a.action}.mp4"
    fmt = probe(v)
    fmt_ok = fmt == {"width": 960, "height": 960, "fps": "24/1", "frames": 121}
    ok_seam, seam, worst = seam_verdict(*psnr_series(v, d / f"qa-{a.action}"))
    first = score_file(_frame(v, d / f"qa-{a.action}-first.png", last=False))
    last = score_file(_frame(v, d / f"qa-{a.action}-last.png", last=True))
    passed = fmt_ok and ok_seam and first.passed and last.passed
    print(json.dumps({"pet": a.pet, "action": a.action, "pass": passed, "format": fmt,
                      "seam": round(seam, 2), "worst_step": round(worst, 2),
                      "blob_core_first": first.blob_core, "blob_core_last": last.blob_core}, ensure_ascii=False))
    return 0 if passed else 1


def cmd_package(a) -> int:
    from PIL import Image
    d = pet_dir(a.pet)
    clips = [d / f"{k}.mp4" for k in ACTIONS]
    missing = [c.name for c in clips if not c.exists()]
    if missing:
        print(f"missing clips {missing}")
        return 1
    out = ASSETS / f"builtin-{a.pet}"
    out.mkdir(parents=True, exist_ok=True)
    for c in clips:
        shutil.copy2(c, out / c.name)
    make_cover(Image.open(d / "ref-stand-cutout.png").convert("RGBA")).save(out / "cover.png")
    (out / "pet.json").write_text(json.dumps(pet_json(a.pet), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"packaged {out.relative_to(REPO)}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="petgen")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("balance").set_defaults(fn=cmd_balance)
    sub.add_parser("import-spike").set_defaults(fn=cmd_import_spike)
    for name, fn, extra in [("source", cmd_source, None), ("pose", cmd_pose, ("pose", list(POSE_ASPECT))),
                            ("gate", cmd_gate, ("pose", list(POSE_ASPECT))), ("video", cmd_video, ("action", ACTIONS)),
                            ("qa", cmd_qa, ("action", ACTIONS)), ("package", cmd_package, None)]:
        p = sub.add_parser(name)
        p.add_argument("pet", choices=list(PETS))
        if extra:
            p.add_argument(extra[0], choices=extra[1])
        p.set_defaults(fn=fn)
    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
