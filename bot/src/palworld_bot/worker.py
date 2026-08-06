"""Runs a verified command and reports the outcome back to Discord."""

import logging

from botocore.exceptions import ClientError

from . import commands, interactions

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)


def handle(interaction, context):
    _run(interaction)


def _run(interaction):
    try:
        result = commands.run(interaction)
    except commands.Rejected as rejected:
        result = str(rejected)
    except ClientError as error:
        logger.exception("AWS call failed")
        result = f"AWS refused the call: {error.response['Error']['Message']}"
    except Exception:
        logger.exception("Command failed")
        result = "The command failed. The details are in CloudWatch Logs."

    try:
        interactions.send_followup(
            interaction["application_id"], interaction["token"], result
        )
    except Exception:
        # Nowhere left to report to: the followup itself is the last chance to
        # reach the user. Async retries are disabled (see bot.tf) precisely so
        # a failure here does not re-run the whole command from scratch.
        logger.exception("Failed to post the followup")
