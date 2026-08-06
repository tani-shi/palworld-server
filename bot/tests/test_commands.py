def test_ask_hands_the_prompt_to_the_agent(env, monkeypatch):
    from palworld_bot import commands

    monkeypatch.setattr("palworld_bot.agent.answer", lambda prompt: f"answered: {prompt}")
    interaction = {
        "data": {"options": [{"name": "ask", "options": [{"name": "prompt", "value": "who is on?"}]}]}
    }
    assert commands.run(interaction) == "answered: who is on?"
