"""Which addresses may reach the game port."""

import os

import boto3

ec2 = boto3.client("ec2")

SECURITY_GROUP_ID = os.environ["SECURITY_GROUP_ID"]
GAME_PORT = int(os.environ["GAME_PORT"])

PROTOCOL = "udp"
RULE_DESCRIPTION = "palworld player"


def allow(cidr):
    if cidr in allowed():
        return f"{cidr} is already allowed."

    ec2.authorize_security_group_ingress(
        GroupId=SECURITY_GROUP_ID,
        IpPermissions=[_permission([{"CidrIp": cidr, "Description": RULE_DESCRIPTION}])],
    )
    return f"{cidr} may now reach {PROTOCOL}/{GAME_PORT}."


def revoke(cidr):
    if cidr not in allowed():
        return f"{cidr} is not allowed, nothing to revoke."

    ec2.revoke_security_group_ingress(
        GroupId=SECURITY_GROUP_ID,
        IpPermissions=[_permission([{"CidrIp": cidr}])],
    )
    return f"{cidr} may no longer reach {PROTOCOL}/{GAME_PORT}."


def allowed():
    group = ec2.describe_security_groups(GroupIds=[SECURITY_GROUP_ID])["SecurityGroups"][0]

    return [
        ip_range["CidrIp"]
        for permission in group["IpPermissions"]
        if permission.get("IpProtocol") == PROTOCOL
        and permission.get("FromPort") == GAME_PORT
        for ip_range in permission.get("IpRanges", [])
    ]


def _permission(ip_ranges):
    return {
        "IpProtocol": PROTOCOL,
        "FromPort": GAME_PORT,
        "ToPort": GAME_PORT,
        "IpRanges": ip_ranges,
    }
