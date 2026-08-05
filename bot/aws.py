import os

import boto3
from dotenv import load_dotenv

load_dotenv()

aws_region = os.getenv("AWS_REGION")
aws_security_group_id = os.getenv("AWS_SECURITY_GROUP_ID")

GAME_PORT = 8211
GAME_PROTOCOL = "udp"

ec2 = boto3.client(
    "ec2",
    aws_access_key_id=os.getenv("AWS_ACCESS_KEY_ID"),
    aws_secret_access_key=os.getenv("AWS_SECRET_ACCESS_KEY"),
    region_name=aws_region,
)


def ensure_cidr_format(ip_address):
    if "/" not in ip_address:
        return f"{ip_address}/32"
    return ip_address


def get_instance_id_by_name(name):
    response = ec2.describe_instances(
        Filters=[
            {"Name": "tag:Name", "Values": [name]},
            {"Name": "instance-state-name", "Values": ["pending", "running", "stopping", "stopped"]},
        ]
    )

    for reservation in response.get("Reservations", []):
        for instance in reservation["Instances"]:
            return instance["InstanceId"]

    return None


def get_instance_state(instance_id):
    response = ec2.describe_instances(InstanceIds=[instance_id])
    return response["Reservations"][0]["Instances"][0]["State"]["Name"]


def get_public_ip(instance_id):
    response = ec2.describe_instances(InstanceIds=[instance_id])
    return response["Reservations"][0]["Instances"][0].get("PublicIpAddress")


def get_instance_status(instance_id):
    try:
        state = get_instance_state(instance_id)
        if state != "running":
            return f"State: {state}"

        response = ec2.describe_instance_status(InstanceIds=[instance_id])
        statuses = response.get("InstanceStatuses")
        if not statuses:
            return "State: running (health checks initializing)"

        instance_status = statuses[0]["InstanceStatus"]["Status"]
        system_status = statuses[0]["SystemStatus"]["Status"]
        address = get_public_ip(instance_id)
        return (
            f"State: running, Instance: {instance_status}, System: {system_status}, "
            f"Address: {address}:{GAME_PORT}"
        )
    except Exception as e:
        return f"Error checking instance status: {str(e)}"


def start_instance_by_id(instance_id):
    ec2.start_instances(InstanceIds=[instance_id])


def stop_instance_by_id(instance_id):
    ec2.stop_instances(InstanceIds=[instance_id])


def add_security_group_rule(ip_address):
    cidr = ensure_cidr_format(ip_address)

    try:
        ec2.authorize_security_group_ingress(
            GroupId=aws_security_group_id,
            IpPermissions=[
                {
                    "IpProtocol": GAME_PROTOCOL,
                    "FromPort": GAME_PORT,
                    "ToPort": GAME_PORT,
                    "IpRanges": [{"CidrIp": cidr, "Description": "palworld player"}],
                }
            ],
        )
        print(f"Added {GAME_PROTOCOL}/{GAME_PORT} ingress from {cidr} to {aws_security_group_id}")
    except Exception as e:
        print(f"Error adding ingress rule: {str(e)}")


def is_ip_authorized_in_security_group(ip_address):
    cidr = ensure_cidr_format(ip_address)

    try:
        response = ec2.describe_security_groups(GroupIds=[aws_security_group_id])
        for rule in response["SecurityGroups"][0]["IpPermissions"]:
            if rule.get("IpProtocol") != GAME_PROTOCOL or rule.get("FromPort") != GAME_PORT:
                continue
            for ip_range in rule.get("IpRanges", []):
                if ip_range.get("CidrIp") == cidr:
                    return True

        return False
    except Exception as e:
        print(f"Error checking security group rules: {str(e)}")
        return False
