from unittest.mock import MagicMock

import pytest
from conftest import fixture


def test_get_reads_the_body_out_of_s3(env, monkeypatch):
    ssm, s3 = MagicMock(), MagicMock()
    ssm.send_command.return_value = {"Command": {"CommandId": "cmd-1"}}
    s3.list_objects_v2.return_value = {
        "Contents": [{"Key": "restapi/cmd-1/i-0/awsrunShellScript/0.awsrunShellScript/stdout"}]
    }
    s3.get_object.return_value = {"Body": MagicMock(read=lambda: fixture("metrics").encode())}
    monkeypatch.setattr("boto3.client", lambda name: {"ssm": ssm, "s3": s3}[name])

    from palworld_bot import palapi

    # The metrics fixture is a captured response with a player online.
    assert palapi.get("metrics")["currentplayernum"] == 1


def test_get_raises_when_the_command_fails(env, monkeypatch):
    ssm, s3 = MagicMock(), MagicMock()
    ssm.send_command.return_value = {"Command": {"CommandId": "cmd-1"}}
    ssm.get_waiter.return_value.wait.side_effect = Exception("WaiterError")
    monkeypatch.setattr("boto3.client", lambda name: {"ssm": ssm, "s3": s3}[name])

    from palworld_bot import palapi

    with pytest.raises(palapi.Unreachable):
        palapi.get("metrics")


def test_announce_does_not_raise_when_the_command_produces_output(env, monkeypatch):
    ssm, s3 = MagicMock(), MagicMock()
    ssm.send_command.return_value = {"Command": {"CommandId": "cmd-1"}}
    s3.list_objects_v2.return_value = {
        "Contents": [{"Key": "restapi/cmd-1/i-0/awsrunShellScript/0.awsrunShellScript/stdout"}]
    }
    s3.get_object.return_value = {"Body": MagicMock(read=lambda: b"announced\n")}
    monkeypatch.setattr("boto3.client", lambda name: {"ssm": ssm, "s3": s3}[name])

    from palworld_bot import palapi

    palapi.announce("restarting soon")


def test_announce_command_reports_success_and_preserves_curls_exit_status(env, monkeypatch):
    ssm, s3 = MagicMock(), MagicMock()
    ssm.send_command.return_value = {"Command": {"CommandId": "cmd-1"}}
    s3.list_objects_v2.return_value = {
        "Contents": [{"Key": "restapi/cmd-1/i-0/awsrunShellScript/0.awsrunShellScript/stdout"}]
    }
    s3.get_object.return_value = {"Body": MagicMock(read=lambda: b"announced\n")}
    monkeypatch.setattr("boto3.client", lambda name: {"ssm": ssm, "s3": s3}[name])

    from palworld_bot import palapi

    palapi.announce("restarting soon")

    command = ssm.send_command.call_args.kwargs["Parameters"]["commands"][0]
    assert "&& echo announced" in command
    assert "; RC=$?; rm -f" in command
    assert "exit $RC" in command
