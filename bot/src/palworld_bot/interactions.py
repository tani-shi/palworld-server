"""Discord Interactions protocol: signature checks and responses."""

import json
import urllib.request

from nacl.exceptions import BadSignatureError
from nacl.signing import VerifyKey

PING = 1

PONG = 1
DEFERRED_CHANNEL_MESSAGE = 5

API_BASE = "https://discord.com/api/v10"

# Cloudflare answers 1010 and never reaches Discord when the User-Agent is the
# one urllib sends by default.
USER_AGENT = "DiscordBot (https://github.com/tani-shi/palworld-server, 0.1.0)"


def verify(public_key, signature, timestamp, body):
    try:
        VerifyKey(bytes.fromhex(public_key)).verify(
            f"{timestamp}{body}".encode(), bytes.fromhex(signature)
        )
    except (BadSignatureError, ValueError):
        return False
    return True


def response(payload):
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload),
    }


def send_followup(application_id, interaction_token, content):
    request = urllib.request.Request(
        f"{API_BASE}/webhooks/{application_id}/{interaction_token}",
        data=json.dumps({"content": content}).encode(),
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
        method="POST",
    )
    urllib.request.urlopen(request, timeout=10).close()
