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
    # 2026-09-19: the idle faces the user like the competitor's; dogs grin, cats don't.
    "front": {
        "dog": ("正面朝向镜头站立，身体只微微侧转约十五度，头部正对镜头，嘴巴微微张开、露出一点舌头，"
                "表情开心友好，四条腿都站在地上，尾巴自然翘起。头部、四条腿和尾巴全部完整入画，脚掌贴地，"
                "头顶和尾巴尖离画面上边缘很远。"),
        "cat": ("正面朝向镜头站立，身体只微微侧转约十五度，头部正对镜头，眼睛睁大，表情好奇友好，"
                "四条腿都站在地上，尾巴自然竖起。头部、四条腿和尾巴全部完整入画，脚掌贴地，"
                "头顶和尾巴尖离画面上边缘很远。"),
    },
}
# 1:1 and 16:9 let long bodies' tails touch the frame; lying needs 21:9 (spike).
# A front-facing animal is about as tall as it is wide: 1:1 (spike 2026-09-19).
POSE_ASPECT = {"stand": "16:9", "walk": "16:9", "lie": "21:9", "front": "1:1"}

# The idle family (stand, lick_paw, act_cute, feed, play) starts and ends on the
# front still, so switching between them never jumps. feed / play use the front
# still with their prop pasted in (petgen.props), so the prop is there on the
# first and last frame; walk needs a mid-stride still; sleep the lying still.
REF_POSE_FOR_ACTION = {"stand": "front", "lick_paw": "front", "act_cute": "front",
                       "feed": "front-bowl", "play": "front-ball", "walk": "walk", "sleep": "lie"}

# 2026-09-23: the lively front idle came back motion-blurred (corgi's per-frame
# sharpness swung 5.4-10.1 and its fast tail smeared into the green, keying as a
# ghost). The competitor manages the same motion at sharpness 11, so ask for it.
_TAIL = ("镜头完全固定，不推拉不摇移。背景始终是均匀的纯绿色，没有影子，没有地面。"
         "每一帧都清晰锐利，毛发丝缕分明，没有运动模糊，没有拖影和残影。")
_ACTIONS = {
    "stand": {
        # 2026-09-23: a fast-wagging tail smears into the green screen and keys
        # as a ghost, so the motion stays wide but slow.
        "dog": ("{it}面朝镜头站在原地，开心地张着嘴。整个五秒里一直在做明显、连续但缓慢从容的动作：头慢慢向左右转动看看四周，"
                "歪了歪头，尾巴慢慢地左右摆动，耳朵随之轻轻抖动，身体重心缓缓左右移动。"
                "所有动作都放慢，不要快速抖动或甩动。"
                "四只脚掌始终踩在原地，不走动，不转身，不坐下，不趴下。最后头回到正对镜头的姿势。"),
        "cat": ("{it}面朝镜头站在原地。整个五秒里一直在做明显、连续的动作：头向左右转动好奇地看看四周，"
                "歪了歪头，慢慢眨眼，耳朵灵活地转动，尾巴大幅度地慢慢摆动，身体重心轻轻左右移动。"
                "四只脚掌始终踩在原地，不走动，不转身，不坐下，不趴下。最后头回到正对镜头的姿势。"),
    },
    "walk": ("{it}原地踏步行走，像在跑步机上一样，四条腿自然交替迈步，"
             "身体始终保持在画面中的同一位置，不向前移动，不转身。头随步伐轻轻晃动，尾巴轻摆。"),
    "sleep": "{it}趴着安静地睡觉，眼睛一直闭着，身体随呼吸缓慢起伏，耳朵偶尔轻轻抖一下。姿态和位置全程不变，不起身。",
    "lick_paw": ("{it}原地站着，低下头舔了几下自己的一只前爪，"
                 "然后抬起头，慢慢恢复到原来的站姿和朝向。身体位置全程不变，不走动。"),
    "act_cute": {
        "dog": "{it}原地站着，开心地歪了歪头，尾巴快速摇了几下，然后恢复到原来的站姿和朝向。身体位置全程不变，不走动。",
        "cat": "{it}原地站着，歪头眨了眨眼，抬起一只前爪轻轻挥了挥，然后放下前爪恢复到原来的站姿和朝向。身体位置全程不变，不走动。",
    },
    "feed": {
        "dog": ("{it}面朝镜头站在原地，两只前爪前面放着一个装满狗粮的红色陶瓷碗。它低下头吃碗里的狗粮，吃了几口，"
                "然后抬起头舔了舔嘴，恢复到原来面朝镜头的站姿。碗始终在原地不动，一直都在，不消失。"
                "身体位置全程不变，不走动，不转身。"),
        "cat": ("{it}面朝镜头站在原地，两只前爪前面放着一个装满猫粮的红色陶瓷碗。它低下头小口地吃碗里的猫粮，吃了几口，"
                "然后抬起头舔了舔嘴，恢复到原来面朝镜头的站姿。碗始终在原地不动，一直都在，不消失。"
                "身体位置全程不变，不走动，不转身。"),
    },
    "play": {
        "dog": ("{it}面朝镜头站在原地，两只前爪前面的地上放着一个红色小球。它开心地低头用鼻子拱了拱球，"
                "用一只前爪轻轻拨了拨，尾巴快速摇摆，然后球回到原来的位置，它抬起头恢复到原来面朝镜头的站姿。"
                "球始终在画面里，不消失。身体位置全程不变，不走动，不转身。"),
        "cat": ("{it}面朝镜头站在原地，两只前爪前面的地上放着一个红色小球。它好奇地歪头看着球，"
                "抬起一只前爪轻轻拍了拍球，然后球回到原来的位置，它放下前爪恢复到原来面朝镜头的站姿。"
                "球始终在画面里，不消失。身体位置全程不变，不走动，不转身。"),
    },
}

# Props are generated once, alone, and pasted into the front still (petgen.props).
# Matte red: stainless steel mirrors the green screen and keys full of holes.
PROPS = {
    "bowl": ("一个哑光的红色陶瓷宠物食碗，碗里装满棕色的颗粒粮，从斜上方约二十度俯视，碗完整入画、居中，"
             "只占画面中间大约一半的宽度。背景是浅灰色的无缝影棚背景纸，颜色均匀中性，柔和的漫射光，几乎没有投影。"
             "写实摄影，画面里只有这一个碗。"),
    "ball": ("一个哑光的红色橡胶小球，表面干净，完整入画、居中，只占画面中间大约三分之一的宽度。"
             "背景是浅灰色的无缝影棚背景纸，颜色均匀中性，柔和的漫射光，几乎没有投影。写实摄影，画面里只有这一个球。"),
}


def _it(pet: str) -> str:
    return f"这只{PETS[pet]['breed']}"


def _pick(text: str | dict, pet: str) -> str:
    """A prompt that differs by species is a {species: text} dict."""
    return text[PETS[pet]["species"]] if isinstance(text, dict) else text


def source_prompt(pet: str) -> str:
    p = PETS[pet]
    return (f"一只{p['breed']}的写实摄影照片。{p['features']}。"
            "身体侧对镜头四分之三角度站立，从头到尾巴、四条腿全部完整入画。"
            "浅灰色无缝影棚背景，柔和的漫射光，毛发细节清晰锐利，画面里只有这一只动物。")


# Recipe v2 (2026-09-12): bright high-key studio light. Our first references
# came out dim (subject luma ~128) and Kling carries the reference's exposure
# straight into the video.
BRIGHT = "明亮柔和的高调影棚光，整体曝光充足，毛色鲜亮饱满，每一缕毛丝都清晰可见，焦点清晰。"


def pose_prompt(pet: str, pose: str, bright: bool = False) -> str:
    p = PETS[pet]
    base = (f"参考图中这只{p['breed']}的全身照片，保持它的脸、毛色和花纹完全一样。{p['features']}。"
            + _pick(POSES[pose], pet) +
            "它只占画面中间大约一半的宽度，四周留出大片空白，尾巴尖离画面边缘很远。"
            "背景是浅灰色的无缝影棚背景纸，颜色均匀中性，没有任何物体，画面没有边框。"
            "柔和的大面积漫射光，几乎没有投影，身下没有明显的影子。"
            "写实摄影，毛发细节清晰锐利，画面里只有这一只动物。")
    return base + BRIGHT if bright else base


def action_prompt(pet: str, action: str) -> str:
    return _pick(_ACTIONS[action], pet).format(it=_it(pet)) + _TAIL
