from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest


def block(**fields):
    return SimpleNamespace(**fields)


@pytest.fixture
def claude(env, monkeypatch):
    from palworld_bot import world

    world.reset()
    client = MagicMock()
    monkeypatch.setattr("anthropic.AnthropicAWS", lambda **kwargs: client)
    monkeypatch.setattr("palworld_bot.agent._system", lambda: "system prompt")
    return client


def test_a_plain_answer_comes_straight_back(claude, monkeypatch):
    claude.messages.create.return_value = SimpleNamespace(
        stop_reason="end_turn", content=[block(type="text", text="Nobody is online.")]
    )
    from palworld_bot import agent

    assert agent.answer("who is playing?") == "Nobody is online."


def test_the_web_tools_are_offered_alongside_the_local_ones(claude):
    claude.messages.create.return_value = SimpleNamespace(
        stop_reason="end_turn", content=[block(type="text", text="ok")]
    )
    from palworld_bot import agent, tools

    agent.answer("anything")
    offered = claude.messages.create.call_args.kwargs["tools"]
    assert len(offered) == len(tools.DEFINITIONS) + len(tools.WEB)


def test_a_paused_turn_is_resumed(claude):
    claude.messages.create.side_effect = [
        SimpleNamespace(stop_reason="pause_turn", content=[block(type="text", text="searching")]),
        SimpleNamespace(stop_reason="end_turn", content=[block(type="text", text="A Lamball is a sheep Pal.")]),
    ]
    from palworld_bot import agent

    assert agent.answer("what is a Lamball?") == "A Lamball is a sheep Pal."
    # The paused turn is handed back as the assistant's own content, with no
    # user message in between: a "continue" nudge would derail the resume.
    resumed = claude.messages.create.call_args_list[1].kwargs["messages"]
    assert resumed[-1]["role"] == "assistant"


def test_a_tool_use_is_executed_and_fed_back(claude, monkeypatch):
    claude.messages.create.side_effect = [
        SimpleNamespace(
            stop_reason="tool_use",
            content=[block(type="tool_use", id="t1", name="world_summary", input={})],
        ),
        SimpleNamespace(stop_reason="end_turn", content=[block(type="text", text="8 wild Pals.")]),
    ]
    monkeypatch.setattr("palworld_bot.tools.run", lambda name, arguments: {"total": 8})
    from palworld_bot import agent

    assert agent.answer("what is around?") == "8 wild Pals."
    second = claude.messages.create.call_args_list[1].kwargs
    assert second["messages"][-1]["content"][0]["tool_use_id"] == "t1"


def test_a_failing_tool_is_reported_to_the_model_not_raised(claude, monkeypatch):
    from palworld_bot import palapi

    claude.messages.create.side_effect = [
        SimpleNamespace(
            stop_reason="tool_use",
            content=[block(type="tool_use", id="t1", name="world_summary", input={})],
        ),
        SimpleNamespace(stop_reason="end_turn", content=[block(type="text", text="The server is down.")]),
    ]

    def boom(name, arguments):
        raise palapi.Unreachable("the server did not answer")

    monkeypatch.setattr("palworld_bot.tools.run", boom)
    from palworld_bot import agent

    assert agent.answer("what is around?") == "The server is down."
    result = claude.messages.create.call_args_list[1].kwargs["messages"][-1]["content"][0]
    assert result["is_error"] is True


def test_the_loop_stops_at_the_turn_limit(claude, monkeypatch):
    claude.messages.create.return_value = SimpleNamespace(
        stop_reason="tool_use",
        content=[block(type="tool_use", id="t1", name="world_summary", input={})],
    )
    monkeypatch.setattr("palworld_bot.tools.run", lambda name, arguments: {})
    from palworld_bot import agent

    assert "give up" in agent.answer("loop forever").lower()
    assert claude.messages.create.call_count == agent.MAX_TURNS
