"""Lifecycle of the EC2 instance the game server runs on."""

import os

import boto3

ec2 = boto3.client("ec2")

INSTANCE_ID = os.environ["INSTANCE_ID"]
GAME_PORT = os.environ["GAME_PORT"]

# A request issued mid-transition either errors or silently does nothing, so
# these states are reported back instead of acted on.
TRANSIENT_STATES = ("pending", "stopping", "shutting-down")


def start():
    state = _state()
    if state == "running":
        return f"Already running. Address: {_address()}"
    if state in TRANSIENT_STATES:
        return f"The instance is {state}. Try again shortly."
    if state != "stopped":
        return f"Cannot start an instance that is {state}."

    ec2.start_instances(InstanceIds=[INSTANCE_ID])
    return "Starting. The game accepts connections a few minutes after boot."


def stop():
    state = _state()
    if state == "stopped":
        return "Already stopped."
    if state in TRANSIENT_STATES:
        return f"The instance is {state}. Try again shortly."
    if state != "running":
        return f"Cannot stop an instance that is {state}."

    ec2.stop_instances(InstanceIds=[INSTANCE_ID])
    return "Stopping. The world is saved during shutdown."


def status():
    state = _state()
    if state != "running":
        return f"State: {state}"

    return f"State: running, health checks {_health()}, address: {_address()}"


def _instance():
    response = ec2.describe_instances(InstanceIds=[INSTANCE_ID])
    return response["Reservations"][0]["Instances"][0]


def _state():
    return _instance()["State"]["Name"]


def _address():
    return f"{_instance().get('PublicIpAddress')}:{GAME_PORT}"


def _health():
    statuses = ec2.describe_instance_status(InstanceIds=[INSTANCE_ID]).get(
        "InstanceStatuses"
    )
    if not statuses:
        return "initializing"

    return f"{statuses[0]['InstanceStatus']['Status']}/{statuses[0]['SystemStatus']['Status']}"
