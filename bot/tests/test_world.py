import json

import pytest
from conftest import fixture


@pytest.fixture
def loaded(env, monkeypatch):
    from palworld_bot import world

    world.reset()
    calls = []

    def fake_get(endpoint):
        calls.append(endpoint)
        return json.loads(fixture("game-data"))

    monkeypatch.setattr("palworld_bot.palapi.get", fake_get)
    return world, calls


def test_the_instance_is_asked_once_per_process(loaded):
    world, calls = loaded
    world.summary()
    world.actors(unit_type="WildPal")
    world.actors(unit_type="BaseCampPal")
    assert calls == ["game-data"]


def test_summary_counts_every_unit_type(loaded):
    world, _ = loaded
    summary = world.summary()
    assert summary["by_unit_type"]["WildPal"] >= 1
    assert summary["by_unit_type"]["Player"] >= 1
    assert summary["total"] == sum(summary["by_unit_type"].values()) + summary["pal_boxes"]
    assert ":" in summary["in_game_time"]


def test_actors_filter_by_unit_type(loaded):
    world, _ = loaded
    found = world.actors(unit_type="WildPal")
    assert found
    for actor in found:
        assert actor["unit_type"] == "WildPal"


def test_actors_never_expose_pii(loaded):
    world, _ = loaded
    found = world.actors(limit=100)
    assert found
    for actor in found:
        assert "ip" not in actor
        assert "userid" not in actor


def test_actors_near_a_player_are_within_the_radius(loaded):
    world, _ = loaded
    near = world.actors(near_player="PlayerOne", radius_m=50, limit=100)
    assert near
    assert all(actor["distance_m"] <= 50 for actor in near)


def test_summary_of_an_empty_world_does_not_raise(env, monkeypatch):
    from palworld_bot import world

    world.reset()
    monkeypatch.setattr(
        "palworld_bot.palapi.get",
        lambda endpoint: {"Time": "2026-08-06 09:09:27", "ActorData": []},
    )

    summary = world.summary()
    assert summary["total"] == 0
    assert summary["by_unit_type"] == {}
    assert summary["server_fps"] is None


def test_near_an_unknown_player_is_empty(loaded):
    world, _ = loaded
    assert world.actors(near_player="NoSuchPlayer", radius_m=50) == []
