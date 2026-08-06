from botocore.exceptions import ClientError

INTERACTION = {"application_id": "app", "token": "tok", "data": {}}


def test_rejected_is_returned_verbatim(env, monkeypatch):
    from palworld_bot import commands, worker

    monkeypatch.setattr(commands, "run", lambda interaction: (_ for _ in ()).throw(commands.Rejected("not an IP")))
    posted = []
    monkeypatch.setattr(
        "palworld_bot.interactions.send_followup",
        lambda app, token, content: posted.append(content),
    )

    worker.handle(INTERACTION, None)

    assert posted == ["not an IP"]


def test_client_error_surfaces_the_aws_message(env, monkeypatch):
    from palworld_bot import commands, worker

    error = ClientError({"Error": {"Code": "AccessDenied", "Message": "not authorized"}}, "SendCommand")
    monkeypatch.setattr(commands, "run", lambda interaction: (_ for _ in ()).throw(error))
    posted = []
    monkeypatch.setattr(
        "palworld_bot.interactions.send_followup",
        lambda app, token, content: posted.append(content),
    )

    worker.handle(INTERACTION, None)

    assert posted == ["AWS refused the call: not authorized"]


def test_any_other_exception_collapses_to_the_cloudwatch_line(env, monkeypatch):
    from palworld_bot import commands, worker

    monkeypatch.setattr(commands, "run", lambda interaction: (_ for _ in ()).throw(ValueError("boom")))
    posted = []
    monkeypatch.setattr(
        "palworld_bot.interactions.send_followup",
        lambda app, token, content: posted.append(content),
    )

    worker.handle(INTERACTION, None)

    assert posted == ["The command failed. The details are in CloudWatch Logs."]


def test_a_failing_followup_does_not_escape_handle(env, monkeypatch):
    from palworld_bot import commands, worker

    monkeypatch.setattr(commands, "run", lambda interaction: "all good")
    monkeypatch.setattr(
        "palworld_bot.interactions.send_followup",
        lambda app, token, content: (_ for _ in ()).throw(TimeoutError("discord is slow")),
    )

    worker.handle(INTERACTION, None)
