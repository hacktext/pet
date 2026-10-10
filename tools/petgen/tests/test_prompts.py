import json
from pathlib import Path

import pytest

from petgen.package import ACTIONS
from petgen.prompts import (BRIGHT, PETS, POSE_ASPECT, PROPS, REF_POSE_FOR_ACTION, SPECIES_NOUN, action_prompt,
                            custom_action_prompt, custom_pose_prompt, pose_prompt, source_prompt)

SNAPSHOT = Path(__file__).parent / "data" / "builtin_prompts.json"


def _all_builtin_prompts() -> dict:
    snap = {}
    for pet in PETS:
        snap[f"source/{pet}"] = source_prompt(pet)
        for pose in POSE_ASPECT:
            for bright in (False, True):
                snap[f"pose/{pet}/{pose}/{int(bright)}"] = pose_prompt(pet, pose, bright=bright)
        for action in ACTIONS:
            snap[f"action/{pet}/{action}"] = action_prompt(pet, action)
    return snap


def test_builtin_prompts_are_unchanged_by_the_custom_refactor():
    assert _all_builtin_prompts() == json.loads(SNAPSHOT.read_text(encoding="utf-8"))


def test_three_pets_with_pet_json_fields():
    assert set(PETS) == {"gold", "corgi", "ragdoll"}
    for p in PETS.values():
        assert p["species"] in {"dog", "cat"} and p["name"] and p["blurb"] and p["breed"] and p["features"]


def test_every_action_maps_to_a_reference_still():
    assert set(REF_POSE_FOR_ACTION) == set(ACTIONS)
    for ref in REF_POSE_FOR_ACTION.values():
        assert ref.split("-")[0] in POSE_ASPECT


def test_the_idle_family_starts_from_the_front_still():
    # They all begin and end in the idle pose, so switching between them never jumps.
    for a in ("stand", "lick_paw", "act_cute", "feed", "play"):
        assert REF_POSE_FOR_ACTION[a].startswith("front")
    assert REF_POSE_FOR_ACTION["feed"] != REF_POSE_FOR_ACTION["play"] != REF_POSE_FOR_ACTION["stand"]


@pytest.mark.parametrize("pet", ["gold", "corgi", "ragdoll"])
@pytest.mark.parametrize("action", ACTIONS)
def test_action_prompts_pin_camera_and_background(pet, action):
    text = action_prompt(pet, action)
    assert "镜头完全固定" in text and "纯绿色" in text
    assert PETS[pet]["breed"] in text


def test_breed_and_features_reach_every_prompt():
    for pet, p in PETS.items():
        assert p["breed"] in source_prompt(pet)
        assert p["features"] in pose_prompt(pet, "stand")
        assert p["features"] in pose_prompt(pet, "front")


@pytest.mark.parametrize("action", ["stand", "feed", "play", "act_cute"])
def test_cats_and_dogs_get_their_own_prompt(action):
    dog = action_prompt("gold", action).replace(PETS["gold"]["breed"], "X")
    cat = action_prompt("ragdoll", action).replace(PETS["ragdoll"]["breed"], "X")
    assert dog != cat


@pytest.mark.parametrize("pet", ["gold", "ragdoll"])
@pytest.mark.parametrize("action, prop", [("feed", "碗"), ("play", "球")])
def test_prop_clips_keep_the_prop_in_place(pet, action, prop):
    # spike 2026-09-19: a prop the model makes vanish dissolves into the green screen
    text = action_prompt(pet, action)
    assert prop in text and "不消失" in text


def test_front_pose_shows_the_face_and_fits_the_species():
    dog, cat = pose_prompt("gold", "front"), pose_prompt("ragdoll", "front")
    assert "头部正对镜头" in dog and "头部正对镜头" in cat
    assert "舌头" in dog and "舌头" not in cat


def test_every_prop_has_a_prompt():
    assert set(PROPS) == {"bowl", "ball"}
    assert all(PROPS.values())


def test_bright_pose_prompt_adds_the_lighting_and_keeps_the_rest():
    base = pose_prompt("gold", "stand")
    bright = pose_prompt("gold", "stand", bright=True)
    assert BRIGHT not in base
    assert bright == base + BRIGHT


def test_custom_pose_prompt_names_the_species_and_is_bright_by_default():
    dog = custom_pose_prompt("dog", "front")
    assert dog.startswith("参考图中这只狗的全身照片，保持它的脸、毛色和花纹完全一样。正面朝向镜头")
    assert "舌头" in dog and dog.endswith(BRIGHT)
    assert "。。" not in dog
    cat = custom_pose_prompt("cat", "lie", bright=False)
    assert "这只猫" in cat and "趴卧" in cat and BRIGHT not in cat


def test_custom_action_prompt_uses_the_species_text_and_the_fixed_camera():
    feed = custom_action_prompt("cat", "feed")
    assert feed.startswith("这只猫面朝镜头") and "猫粮" in feed and "镜头完全固定" in feed
    assert custom_action_prompt("dog", "walk").startswith("这只狗原地踏步行走")


def test_a_redo_hint_is_appended_and_a_blank_one_is_ignored():
    base = custom_action_prompt("dog", "play")
    assert custom_action_prompt("dog", "play", "尾巴摆慢一点") == base + "补充要求：尾巴摆慢一点"
    assert custom_action_prompt("dog", "play", "   ") == base


def test_only_dogs_and_cats_have_custom_prompts():
    assert set(SPECIES_NOUN) == {"dog", "cat"}
    with pytest.raises(KeyError):
        custom_pose_prompt("other", "front")
