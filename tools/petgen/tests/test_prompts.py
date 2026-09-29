import pytest

from petgen.package import ACTIONS
from petgen.prompts import (BRIGHT, PETS, POSE_ASPECT, PROPS, REF_POSE_FOR_ACTION, action_prompt, pose_prompt,
                            source_prompt)


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
