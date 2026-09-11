from pathlib import Path

import pytest

from petgen.keycheck import score_file

SPIKE_OUT = Path(r"C:\Users\Administrator\AppData\Local\Temp\claude\c--Users-Administrator-code-aipet"
                 r"\4fbc451a-51c9-48a5-9f6b-54b7e4f439b7\scratchpad\out")
CASES = [
    ("ref-0-crop800.png", False),         # dachshund generated straight on green: spill + shadow
    ("comp800.png", True),                # competitor reference frame
    ("ref-gold-stand-green.png", True),   # golden retriever: thin fur fringe only
    ("walkf100.png", False),              # motion-blurred video frame
]


@pytest.mark.parametrize("name,expected", CASES)
def test_gate_matches_known_verdict(name, expected):
    p = SPIKE_OUT / name
    if not p.exists():
        pytest.skip(f"spike artefact {p} is gone")
    assert score_file(p).passed is expected
