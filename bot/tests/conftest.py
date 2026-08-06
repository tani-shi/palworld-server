import json
import pathlib
import sys

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).parent.parent / "src"))

FIXTURES = pathlib.Path(__file__).parent / "fixtures"


def fixture(name):
    return (FIXTURES / f"{name}.json").read_text()


@pytest.fixture(autouse=True)
def _reimport_palworld_bot():
    # Every palworld_bot module builds its boto3 clients at import time, so a
    # module cached from an earlier test would keep that test's mocks instead
    # of picking up the ones the current test just patched in.
    for name in [name for name in sys.modules if name.startswith("palworld_bot")]:
        del sys.modules[name]


@pytest.fixture
def env(monkeypatch):
    monkeypatch.setenv("INSTANCE_ID", "i-0123456789abcdef0")
    monkeypatch.setenv("COMMAND_OUTPUT_BUCKET", "palworld-command-output-test")
    monkeypatch.setenv("REST_API_PORT", "8212")
    monkeypatch.setenv("SERVER_SECRETS_PARAMETER", "/palworld/1.0/server_secrets")
    monkeypatch.setenv("AWS_REGION", "ap-northeast-1")
    monkeypatch.setenv("GAME_PORT", "8211")
    monkeypatch.setenv("SECURITY_GROUP_ID", "sg-0123456789abcdef0")
    monkeypatch.setenv("CLAUDE_MODEL", "claude-sonnet-5")
    monkeypatch.setenv("ANTHROPIC_AWS_WORKSPACE_ID", "wrkspc_01test")
    monkeypatch.setenv("SYSTEM_PROMPT_PARAMETER", "/palworld/1.0/ask_system_prompt")
