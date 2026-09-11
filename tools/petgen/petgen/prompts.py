"""Built-in pets and every prompt used to make them (recipe from the M2 spike)."""
from __future__ import annotations

PETS = {
    "gold": {"species": "dog", "name": "金毛", "blurb": "温柔的大暖男，走到哪跟到哪",
             "breed": "金毛寻回犬",
             "features": "毛色是均匀的金黄色，胸前、腿后和尾巴上有长长的饰毛，耳朵下垂，表情温和"},
    "corgi": {"species": "dog", "name": "柯基", "blurb": "小短腿大耳朵，家里的开心果",
              "breed": "彭布罗克威尔士柯基犬",
              "features": "橘黄色和白色相间，白色的口鼻、脖子和胸口，一对大耳朵直立，四肢很短"},
    "ragdoll": {"species": "cat", "name": "布偶猫", "blurb": "蓝眼睛的小仙女，安静又粘人",
                "breed": "布偶猫",
                "features": "蓝色的眼睛，脸、耳朵和尾巴是深棕色的重点色，身体是奶白色的蓬松长毛"},
}

POSES = {
    "stand": "站立姿势，身体侧对镜头四分之三角度，头部、四条腿和尾巴全部完整入画，脚掌贴地。",
    "walk": ("正在走路的姿势，身体完全侧对镜头，一只前腿和对侧的后腿向前迈出，另外两条腿在后，"
             "四个脚掌都贴着地面，尾巴自然放松，从头到尾巴、四条腿全部完整入画。"),
    "lie": ("趴卧着睡觉的姿势，身体侧对镜头，四肢收在身下，下巴枕在前爪上，眼睛闭着，"
            "尾巴自然地弯过来收在身体旁边，不向外伸展，从头到尾巴完整入画。"),
}
# 1:1 and 16:9 let long bodies' tails touch the frame; lying needs 21:9 (spike).
POSE_ASPECT = {"stand": "16:9", "walk": "16:9", "lie": "21:9"}

# Stand-based one-shots start and end standing, so they hand back to idle
# seamlessly; walk needs a mid-stride still (a standing still gives
# stand -> walk -> stand); sleep needs the lying still.
REF_POSE_FOR_ACTION = {"stand": "stand", "lick_paw": "stand", "act_cute": "stand",
                       "walk": "walk", "sleep": "lie"}

_TAIL = "镜头完全固定，不推拉不摇移。背景始终是均匀的纯绿色，没有影子，没有地面。"
_ACTIONS = {
    "stand": ("{it}原地安静站立。整个五秒里一直有细微、连续的自然动作：胸口随呼吸缓慢起伏，"
              "耳朵偶尔轻轻抖动，尾巴慢慢小幅摆动，眨一两次眼。"
              "身体朝向和在画面中的位置全程保持不变，不走动，不转身，不坐下，不低头。"),
    "walk": ("{it}原地踏步行走，像在跑步机上一样，四条腿自然交替迈步，"
             "身体始终保持在画面中的同一位置，不向前移动，不转身。头随步伐轻轻晃动，尾巴轻摆。"),
    "sleep": "{it}趴着安静地睡觉，眼睛一直闭着，身体随呼吸缓慢起伏，耳朵偶尔轻轻抖一下。姿态和位置全程不变，不起身。",
    "lick_paw": ("{it}原地站着，低下头舔了几下自己的一只前爪，"
                 "然后抬起头，慢慢恢复到原来的站姿和朝向。身体位置全程不变，不走动。"),
}
_ACT_CUTE = {
    "dog": "{it}原地站着，开心地歪了歪头，尾巴快速摇了几下，然后恢复到原来的站姿和朝向。身体位置全程不变，不走动。",
    "cat": "{it}原地站着，歪头眨了眨眼，抬起一只前爪轻轻挥了挥，然后放下前爪恢复到原来的站姿和朝向。身体位置全程不变，不走动。",
}


def _it(pet: str) -> str:
    return f"这只{PETS[pet]['breed']}"


def source_prompt(pet: str) -> str:
    p = PETS[pet]
    return (f"一只{p['breed']}的写实摄影照片。{p['features']}。"
            "身体侧对镜头四分之三角度站立，从头到尾巴、四条腿全部完整入画。"
            "浅灰色无缝影棚背景，柔和的漫射光，毛发细节清晰锐利，画面里只有这一只动物。")


def pose_prompt(pet: str, pose: str) -> str:
    p = PETS[pet]
    return (f"参考图中这只{p['breed']}的全身照片，保持它的脸、毛色和花纹完全一样。{p['features']}。"
            + POSES[pose] +
            "它只占画面中间大约一半的宽度，四周留出大片空白，尾巴尖离画面边缘很远。"
            "背景是浅灰色的无缝影棚背景纸，颜色均匀中性，没有任何物体，画面没有边框。"
            "柔和的大面积漫射光，几乎没有投影，身下没有明显的影子。"
            "写实摄影，毛发细节清晰锐利，画面里只有这一只动物。")


def action_prompt(pet: str, action: str) -> str:
    template = _ACT_CUTE[PETS[pet]["species"]] if action == "act_cute" else _ACTIONS[action]
    return template.format(it=_it(pet)) + _TAIL
