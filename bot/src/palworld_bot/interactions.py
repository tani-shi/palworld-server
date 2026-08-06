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

# Discord rejects a content over this outright, so a long answer has to arrive
# as several messages rather than one truncated one.
CONTENT_LIMIT = 2000


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
    for chunk in _chunks(content):
        request = urllib.request.Request(
            f"{API_BASE}/webhooks/{application_id}/{interaction_token}",
            # The model's reply carries untrusted text (wiki content, player
            # nicknames), and Discord resolves @everyone/@here/role mentions in
            # followups by default; parse: [] turns that off.
            data=json.dumps(
                {"content": chunk, "allowed_mentions": {"parse": []}}
            ).encode(),
            headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
            method="POST",
        )
        urllib.request.urlopen(request, timeout=10).close()


def _chunks(content):
    # An empty content is rejected too, so silence becomes a visible answer.
    remaining = content.strip() or "(no answer)"

    while remaining:
        if len(remaining) <= CONTENT_LIMIT:
            yield remaining
            return

        # Break where the writing already breaks; fall back to a hard cut only
        # when a single paragraph or line is longer than the limit.
        cut = remaining.rfind("\n\n", 0, CONTENT_LIMIT + 1)
        if cut <= 0:
            cut = remaining.rfind("\n", 0, CONTENT_LIMIT + 1)
        if cut <= 0:
            cut = CONTENT_LIMIT

        yield remaining[:cut].rstrip()
        remaining = remaining[cut:].lstrip()
