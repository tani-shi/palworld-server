"""Register the /palworld slash command with Discord.

Run once after the command definitions below change:

    uv run --env-file .env scripts/deploy_commands.py
"""

import json
import os
import urllib.error
import urllib.request

SUBCOMMAND = 1
STRING = 3

# Cloudflare answers 1010 and never reaches Discord when the User-Agent is the
# one urllib sends by default.
USER_AGENT = "DiscordBot (https://github.com/tani-shi/palworld-server, 0.1.0)"

IP_OPTION = {
    "type": STRING,
    "name": "ip",
    "description": "Your global IPv4 address",
    "required": True,
}

COMMAND = {
    "name": "palworld",
    "description": "Control the Palworld dedicated server",
    "options": [
        {"type": SUBCOMMAND, "name": "start", "description": "Start the server"},
        {"type": SUBCOMMAND, "name": "stop", "description": "Stop the server"},
        {"type": SUBCOMMAND, "name": "status", "description": "Show state and address"},
        {
            "type": SUBCOMMAND,
            "name": "register",
            "description": "Allow an address to reach the game port",
            "options": [IP_OPTION],
        },
        {
            "type": SUBCOMMAND,
            "name": "unregister",
            "description": "Revoke an allowed address",
            "options": [IP_OPTION],
        },
        {"type": SUBCOMMAND, "name": "allowlist", "description": "List allowed addresses"},
        {
            "type": SUBCOMMAND,
            "name": "ask",
            "description": "Ask about the server in plain language",
            "options": [
                {
                    "type": STRING,
                    "name": "prompt",
                    "description": "What do you want to know?",
                    "required": True,
                }
            ],
        },
    ],
}


def main():
    application_id = os.environ["DISCORD_APPLICATION_ID"]
    request = urllib.request.Request(
        f"https://discord.com/api/v10/applications/{application_id}/commands",
        data=json.dumps([COMMAND]).encode(),
        headers={
            "Authorization": f"Bot {os.environ['DISCORD_BOT_TOKEN']}",
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        },
        # A bulk overwrite keeps Discord's registry equal to this file rather
        # than accumulating commands that were renamed or removed here.
        method="PUT",
    )

    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            registered = json.load(response)
    except urllib.error.HTTPError as error:
        # Discord states the reason in the body; a bare status code is opaque.
        raise SystemExit(f"Discord refused the request: {error.code} {error.read().decode()}")

    print(f"registered {len(registered)} command(s): {', '.join(c['name'] for c in registered)}")


if __name__ == "__main__":
    main()
