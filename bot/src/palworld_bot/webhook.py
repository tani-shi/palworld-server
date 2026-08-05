"""Entry point for Discord's webhook: verify, hand off, acknowledge."""

import base64
import json
import os

import boto3

from . import interactions

lambda_client = boto3.client("lambda")

PUBLIC_KEY = os.environ["DISCORD_PUBLIC_KEY"]
WORKER_FUNCTION_NAME = os.environ["WORKER_FUNCTION_NAME"]


def handle(event, context):
    body = _body(event)
    headers = {name.lower(): value for name, value in (event.get("headers") or {}).items()}

    if not interactions.verify(
        PUBLIC_KEY,
        headers.get("x-signature-ed25519", ""),
        headers.get("x-signature-timestamp", ""),
        body,
    ):
        return {"statusCode": 401}

    interaction = json.loads(body)
    if interaction["type"] == interactions.PING:
        return interactions.response({"type": interactions.PONG})

    # Discord drops the interaction after three seconds, so the work runs
    # elsewhere and reports back over the interaction token.
    lambda_client.invoke(
        FunctionName=WORKER_FUNCTION_NAME,
        InvocationType="Event",
        Payload=json.dumps(interaction).encode(),
    )
    return interactions.response({"type": interactions.DEFERRED_CHANNEL_MESSAGE})


def _body(event):
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        return base64.b64decode(body).decode()

    return body
