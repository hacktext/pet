import pytest

from petgen.prompts import PETS, POSE_ASPECT, REF_POSE_FOR_ACTION, action_prompt, pose_prompt, source_prompt

ACTIONS = ["stand", "walk", "sleep", "lick_paw", "act_cute"]


def test_three_pets_with_pet_json_fields():
    assert set(PETS) == {"gold", "corgi", "ragdoll"}
    for p in PETS.values():
        assert p["species"] in {"dog", "cat"} and p["name"] and p["blurb"] and p["breed"] and p["features"]


def test_every_action_maps_to_a_reference_pose():
    assert set(REF_POSE_FOR_ACTION) == set(ACTIONS)
    assert set(REF_POSE_FOR_ACTION.values()) <= set(POSE_ASPECT)


@pytest.mark.parametrize("pet", ["gold", "corgi", "ragdoll"])
@pytest.mark.parametrize("action", ACTIONS)
def test_action_prompts_pin_camera_and_background(pet, action):
    text = action_prompt(pet, action)
    assert "镜头完全固定" in text and "纯绿色" in text


def test_breed_and_features_reach_every_prompt():
    for pet, p in PETS.items():
        assert p["breed"] in source_prompt(pet)
        assert p["features"] in pose_prompt(pet, "stand")


def test_cats_and_dogs_act_cute_differently():
    dog = action_prompt("gold", "act_cute").replace(PETS["gold"]["breed"], "X")
    cat = action_prompt("ragdoll", "act_cute").replace(PETS["ragdoll"]["breed"], "X")
    assert dog != cat
