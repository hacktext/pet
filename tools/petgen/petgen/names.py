"""Chinese names for the log: the worker's log is read by whoever runs the
server, in Chinese."""
from __future__ import annotations

SPECIES = {"dog": "狗狗", "cat": "猫猫", "other": "其他宠物", "girl": "女生", "boy": "男生", "anime": "动漫角色"}
ACTIONS = {"stand": "站立", "walk": "走路", "sleep": "睡觉", "feed": "吃饭", "play": "玩耍",
           "lick_paw": "舔爪", "act_cute": "卖萌"}
POSES = {"front": "正面", "stand": "站姿", "walk": "走姿", "lie": "卧姿"}
KINDS = {"image": "图片", "video": "视频"}


def species(s: str) -> str:
    return SPECIES.get(s, s)


def action(a: str) -> str:
    return ACTIONS.get(a, a)


def actions(acts) -> str:
    return "、".join(action(a) for a in acts)


def step(s: str) -> str:
    """A pipeline step ("ref:front", "video:walk", "upload", ...) in words."""
    kind, _, arg = s.partition(":")
    return {
        "fetch": "下载用户照片",
        "ref": f"生成定妆图（{POSES.get(arg, arg)}）",
        "propref": "合成道具图",
        "video": f"生成动作视频（{action(arg)}）",
        "package": "打包成品",
        "upload": "上传成品",
        "claim": "领取任务",
        "state": "读取任务进度",
    }.get(kind, s)
