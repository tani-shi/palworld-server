"""Runs a verified command and reports the outcome back to Discord."""

import logging

from botocore.exceptions import ClientError

from . import commands, interactions

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)


def handle(interaction, context):
    interactions.send_followup(
        interaction["application_id"], interaction["token"], _run(interaction)
    )


def _run(interaction):
    try:
        return commands.run(interaction)
    except commands.Rejected as rejected:
        return str(rejected)
    except ClientError as error:
        logger.exception("AWS call failed")
        return f"AWS refused the call: {error.response['Error']['Message']}"
    except Exception:
        logger.exception("Command failed")
        return "The command failed. The details are in CloudWatch Logs."
