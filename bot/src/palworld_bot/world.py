"""The world as the server last saw it: fetched once, then queried in memory."""

import collections
import math

from . import palapi

# Unreal reports centimetres. The tools speak metres because that is what a
# question like "what is near me" means to a player.
CENTIMETRES_PER_METRE = 100

_snapshot = None


def reset():
    global _snapshot
    _snapshot = None


def load():
    global _snapshot
    # game-data has no server-side filter, so every question is answered from
    # the same response. The server itself only refreshes it on a collector
    # thread interval, so asking twice would not even return newer data.
    if _snapshot is None:
        _snapshot = palapi.get("game-data")

    return _snapshot


def summary():
    data = load()
    actors = data.get("ActorData", [])
    characters = [a for a in actors if a.get("Type") == "Character"]
    boxes = [a for a in actors if a.get("Type") == "PalBox"]

    return {
        "in_game_time": data.get("InGameTime"),
        "in_game_days": data.get("InGameDays"),
        "server_fps": round(data["FPS"], 1) if "FPS" in data else None,
        "total": len(actors),
        "pal_boxes": len(boxes),
        "by_unit_type": _count(a.get("UnitType") for a in characters),
        "by_species": _count(a.get("NickName") for a in characters if a.get("UnitType") != "Player"),
        "by_guild": _count(a.get("GuildName") for a in actors if a.get("GuildName")),
    }


def actors(unit_type=None, species=None, owner=None, near_player=None, radius_m=None, limit=20):
    origin = _player_location(near_player) if near_player else None
    if near_player and origin is None:
        return []

    found = []
    for actor in load()["ActorData"]:
        if unit_type and actor.get("UnitType") != unit_type:
            continue
        if species and species.lower() not in _species(actor).lower():
            continue
        if owner and actor.get("TrainerNickName") != owner:
            continue

        rendered = _render(actor)
        if origin is not None:
            rendered["distance_m"] = _distance_m(origin, actor)
            if radius_m is not None and rendered["distance_m"] > radius_m:
                continue

        found.append(rendered)

    if origin is not None:
        found.sort(key=lambda a: a["distance_m"])

    return found[:limit]


def _count(values):
    return dict(collections.Counter(values).most_common())


def _species(actor):
    return f"{actor.get('NickName', '')} {actor.get('Class', '')}"


def _player_location(name):
    for actor in load()["ActorData"]:
        if actor.get("UnitType") == "Player" and actor.get("NickName") == name:
            return actor

    return None


def _distance_m(origin, actor):
    return round(
        math.dist(
            (origin["LocationX"], origin["LocationY"], origin["LocationZ"]),
            (actor["LocationX"], actor["LocationY"], actor["LocationZ"]),
        )
        / CENTIMETRES_PER_METRE,
        1,
    )


def _render(actor):
    # ip and userid are dropped rather than selected around: they carry a
    # globally routable address and a Steam id, and everything downstream of
    # here ends up in a model's context.
    rendered = {
        "type": actor.get("Type"),
        "unit_type": actor.get("UnitType"),
        "name": actor.get("NickName") or actor.get("Name"),
        "species": actor.get("Class"),
        "guild": actor.get("GuildName"),
    }
    for key, field in (("owner", "TrainerNickName"), ("action", "AI_Action"), ("stage", "Stage")):
        if actor.get(field):
            rendered[key] = actor[field]
    if "HP" in actor:
        rendered["hp"] = f"{actor['HP']}/{actor['MaxHP']}"
    if "level" in actor:
        rendered["level"] = actor["level"]

    return rendered
