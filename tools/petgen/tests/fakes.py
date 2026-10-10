"""Test doubles shared by the pipeline and worker tests."""


def claim(**over) -> dict:
    """A jobs/claim job as the server hands it out (standard plan, two photos)."""
    d = {"id": 12, "pet_id": "custom-12", "name": "豆豆", "species": "dog",
         "actions": ["stand", "walk", "feed", "play", "sleep"], "redo": None,
         "budget_cents": 8000, "spent_cents": 0,
         "photos": [{"url": "https://oss.invalid/p1.jpg"}, {"url": "https://oss.invalid/p2.jpg"}]}
    d.update(over)
    return d
