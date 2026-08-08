import json

import pytest
from conftest import fixture


@pytest.fixture
def wired(env, monkeypatch):
    from palworld_bot import tools, world

    world.reset()
    monkeypatch.setattr(
        "palworld_bot.palapi.get", lambda endpoint: json.loads(fixture(endpoint))
    )
    sent = []
    monkeypatch.setattr("palworld_bot.palapi.announce", lambda message: sent.append(message))
    return tools, sent


def test_every_definition_has_a_schema(wired):
    tools, _ = wired
    for definition in tools.DEFINITIONS:
        assert definition["name"]
        assert definition["description"]
        assert definition["input_schema"]["type"] == "object"


def test_every_definition_is_dispatchable(wired):
    tools, _ = wired
    for definition in tools.DEFINITIONS:
        if definition["name"] == "announce":
            tools.run("announce", {"message": "hi"})
        else:
            tools.run(definition["name"], {})


def test_server_status_merges_info_and_metrics(wired):
    tools, _ = wired
    status = tools.run("server_status", {})
    assert status["version"] == "v1.0.2.101103"
    assert "currentplayernum" in status


def test_online_players_drop_pii(wired):
    tools, _ = wired
    players = tools.run("online_players", {})["players"]
    assert players
    for player in players:
        assert "iP" not in player
        assert "userId" not in player
        assert "accountName" not in player


def test_announce_reports_what_it_sent(wired):
    tools, sent = wired
    result = tools.run("announce", {"message": "restarting soon"})
    assert sent == ["restarting soon"]
    assert "restarting soon" in result["sent"]


def test_unknown_tool_raises(wired):
    tools, _ = wired
    with pytest.raises(tools.Unknown):
        tools.run("drop_database", {})


def test_web_tools_are_server_side_and_never_dispatched(wired):
    tools, _ = wired
    for definition in tools.WEB:
        assert "input_schema" not in definition
        with pytest.raises(tools.Unknown):
            tools.run(definition["name"], {})


def test_code_execution_is_not_declared(wired):
    # web_search_20260209 runs it internally for dynamic filtering; declaring a
    # second execution environment confuses the model.
    tools, _ = wired
    assert not any("code_execution" in d["type"] for d in tools.WEB)


def test_both_web_tools_are_confined_to_the_wiki(wired):
    tools, _ = wired
    for definition in tools.WEB:
        assert definition["allowed_domains"] == [tools.WIKI]
