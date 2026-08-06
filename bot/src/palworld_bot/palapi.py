"""The Palworld REST API, reached through Run Command and S3."""

import json
import os

import boto3

ssm = boto3.client("ssm")
s3 = boto3.client("s3")

INSTANCE_ID = os.environ["INSTANCE_ID"]
BUCKET = os.environ["COMMAND_OUTPUT_BUCKET"]
REST_API_PORT = os.environ["REST_API_PORT"]
SECRETS_PARAMETER = os.environ["SERVER_SECRETS_PARAMETER"]
REGION = os.environ["AWS_REGION"]

PREFIX = "restapi"
API = f"http://127.0.0.1:{REST_API_PORT}/v1/api"

# Fetched and used on the instance so the admin password never reaches Lambda.
PASSWORD = (
    f"$(aws ssm get-parameter --region {REGION} --name {SECRETS_PARAMETER}"
    " --with-decryption --query Parameter.Value --output text | jq -r .admin_password)"
)


class Unreachable(Exception):
    """The instance did not answer. Reported to the user as-is."""


def get(endpoint):
    return json.loads(_run(f'curl -fsS -u "admin:{PASSWORD}" {API}/{endpoint}'))


def announce(message):
    payload = json.dumps({"message": message})
    quoted = payload.replace("'", "'\\''")
    # A successful POST prints nothing, so SSM would write no stdout object and
    # _stdout would read that as Unreachable, telling the model the broadcast
    # failed when it already reached the game. The echo gives it something to
    # read; the cleanup runs unconditionally so a failed curl still gets its
    # real exit code back instead of being masked by rm's success.
    _run(
        f"printf %s '{quoted}' > /tmp/announce.json && "
        f'curl -fsS -X POST -u "admin:{PASSWORD}" -H "Content-Type: application/json" '
        f"-d @/tmp/announce.json {API}/announce && echo announced; "
        "RC=$?; rm -f /tmp/announce.json; exit $RC"
    )


def _run(command):
    try:
        command_id = ssm.send_command(
            InstanceIds=[INSTANCE_ID],
            DocumentName="AWS-RunShellScript",
            OutputS3BucketName=BUCKET,
            OutputS3KeyPrefix=PREFIX,
            Parameters={"commands": [command]},
        )["Command"]["CommandId"]

        ssm.get_waiter("command_executed").wait(
            CommandId=command_id, InstanceId=INSTANCE_ID
        )
    except Exception as error:
        # A stopped instance, a booting agent and a failed curl all arrive as
        # different exception types and all mean the same thing to the caller.
        raise Unreachable(f"the server did not answer: {error}") from error

    return _stdout(command_id)


def _stdout(command_id):
    # The key is looked up rather than assembled: the layout Run Command writes
    # under the prefix is not part of its API contract.
    listing = s3.list_objects_v2(Bucket=BUCKET, Prefix=f"{PREFIX}/{command_id}")
    keys = [
        item["Key"]
        for item in listing.get("Contents", [])
        if item["Key"].endswith("stdout")
    ]
    if not keys:
        raise Unreachable("the command wrote no output")

    return s3.get_object(Bucket=BUCKET, Key=keys[0])["Body"].read().decode()
