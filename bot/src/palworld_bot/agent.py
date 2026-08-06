"""One question, however many tool calls it takes."""

import json
import logging
import os

import anthropic
import boto3

from . import snapshot, tools

logger = logging.getLogger(__name__)

ssm = boto3.client("ssm")

MODEL = os.environ["CLAUDE_MODEL"]
REGION = os.environ["AWS_REGION"]
WORKSPACE_ID = os.environ["ANTHROPIC_AWS_WORKSPACE_ID"]
SYSTEM_PROMPT_PARAMETER = os.environ["SYSTEM_PROMPT_PARAMETER"]

# The ceiling covers thinking and the reply together: thinking is on unless
# disabled, and disabling it would make the model reach for tools less often,
# which is the opposite of what this is for.
MAX_TOKENS = 8000

# Six tools over one cached snapshot; a question that has not converged by here
# is not going to.
MAX_TURNS = 8


def answer(prompt):
    snapshot.reset()
    client = anthropic.AnthropicAWS(aws_region=REGION, workspace_id=WORKSPACE_ID)
    system = _system()
    messages = [{"role": "user", "content": prompt}]

    for _ in range(MAX_TURNS):
        response = client.messages.create(
            model=MODEL,
            max_tokens=MAX_TOKENS,
            # Not "low": this model honours effort strictly at the bottom end
            # and under-thinks moderately complex work, which choosing among
            # eight tools and filtering their output is.
            output_config={"effort": "medium"},
            system=system,
            tools=tools.DEFINITIONS + tools.WEB,
            messages=messages,
        )

        # The web tools run server-side and can exhaust their own iteration
        # budget mid-answer. Resending the turn resumes it; a "continue" user
        # message would derail it, so the assistant turn goes back alone.
        if response.stop_reason == "pause_turn":
            messages.append({"role": "assistant", "content": response.content})
            continue

        if response.stop_reason != "tool_use":
            return _text(response)

        messages.append({"role": "assistant", "content": response.content})
        messages.append({"role": "user", "content": _results(response)})

    return "I could not settle on an answer and had to give up."


def _system():
    # Read every invocation rather than at import: the prompt lives in Parameter
    # Store so it can be changed without touching the function.
    return ssm.get_parameter(Name=SYSTEM_PROMPT_PARAMETER)["Parameter"]["Value"]


def _results(response):
    results = []
    for item in response.content:
        if item.type != "tool_use":
            continue

        result = {"type": "tool_result", "tool_use_id": item.id}
        try:
            result["content"] = json.dumps(tools.run(item.name, item.input), ensure_ascii=False)
        except Exception as error:
            # Handed back rather than raised: the model can say what went wrong
            # far better than a generic failure message can.
            logger.exception("tool %s failed", item.name)
            result["content"] = str(error)
            result["is_error"] = True

        results.append(result)

    return results


def _text(response):
    return "\n".join(item.text for item in response.content if item.type == "text").strip()
