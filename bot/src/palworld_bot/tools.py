"""The surface the model is allowed to touch."""

from . import palapi, world

UNIT_TYPES = ["Player", "OtomoPal", "BaseCampPal", "WildPal", "NPC"]

DEFINITIONS = [
    {
        "name": "server_status",
        "description": (
            "Server version, name, world id, FPS, how many players are connected,"
            " uptime in seconds, base camp count and the in-game day."
        ),
        "input_schema": {"type": "object", "properties": {}},
    },
    {
        "name": "online_players",
        "description": "The players connected right now, with level, ping and position.",
        "input_schema": {"type": "object", "properties": {}},
    },
    {
        "name": "server_settings",
        "description": (
            "The effective server settings: experience and capture rates, damage"
            " multipliers, decay speeds, PvP and guild limits."
        ),
        "input_schema": {"type": "object", "properties": {}},
    },
    {
        "name": "world_summary",
        "description": (
            "An overview of everything in the world right now: in-game time and day,"
            " and counts by unit type, by Pal species and by guild. Call this before"
            " world_actors to see what is out there."
        ),
        "input_schema": {"type": "object", "properties": {}},
    },
    {
        "name": "world_actors",
        "description": (
            "Individual actors in the world, filtered. Use near_player with radius_m"
            " to answer what is around someone. Results are sorted by distance when"
            " near_player is given."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "unit_type": {"type": "string", "enum": UNIT_TYPES},
                "species": {
                    "type": "string",
                    "description": "Matches the Pal name or blueprint, e.g. Lamball or BP_SheepBall_C.",
                },
                "owner": {
                    "type": "string",
                    "description": "The player a Pal belongs to. Only OtomoPal and BaseCampPal have one.",
                },
                "near_player": {"type": "string", "description": "Centre the search on this player."},
                "radius_m": {"type": "number", "description": "Metres from near_player."},
                "limit": {"type": "integer", "description": "At most this many actors. Default 20."},
            },
        },
    },
    {
        "name": "announce",
        "description": "Broadcast a message to everyone in game. Everyone playing sees it.",
        "input_schema": {
            "type": "object",
            "properties": {"message": {"type": "string"}},
            "required": ["message"],
        },
    },
]

# Japanese Palworld sites are overwhelmingly stale ad farms; paldb.cc is the
# one maintained database, serves plain HTML, and carries both the Japanese and
# English name of every Pal. Restricting to it also puts the injection surface
# back to people who can edit that wiki rather than anyone who can publish.
WIKI = "paldb.cc"

# Run on Anthropic's side: they arrive as server_tool_use and *_tool_result
# blocks, never as tool_use, so nothing here is dispatched through run().
# code_execution is deliberately absent — web_search_20260209 runs it itself for
# dynamic filtering, and a second execution environment confuses the model.
WEB = [
    {
        "type": "web_search_20260209",
        "name": "web_search",
        "max_uses": 5,
        "allowed_domains": [WIKI],
    },
    {
        "type": "web_fetch_20260209",
        "name": "web_fetch",
        "max_uses": 5,
        "allowed_domains": [WIKI],
    },
]


class Unknown(Exception):
    """A tool name the model invented."""


def run(name, arguments):
    if name == "server_status":
        return palapi.get("info") | palapi.get("metrics")
    if name == "online_players":
        return {"players": [_public(p) for p in palapi.get("players")["players"]]}
    if name == "server_settings":
        return palapi.get("settings")
    if name == "world_summary":
        return world.summary()
    if name == "world_actors":
        return {"actors": world.actors(**arguments)}
    if name == "announce":
        palapi.announce(arguments["message"])
        return {"sent": arguments["message"]}

    raise Unknown(f"no such tool: {name}")


def _public(player):
    # accountName, userId and iP identify a person outside the game; the rest
    # is what someone in the world can already see.
    return {
        key: value
        for key, value in player.items()
        if key not in ("accountName", "userId", "iP")
    }
