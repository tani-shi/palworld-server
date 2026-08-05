"""Which addresses may reach the game."""

import os

import boto3

ec2 = boto3.client("ec2")

SECURITY_GROUP_ID = os.environ["SECURITY_GROUP_ID"]
GAME_PORT = int(os.environ["GAME_PORT"])
QUERY_PORT = int(os.environ["QUERY_PORT"])

PROTOCOL = "udp"
RULE_DESCRIPTION = "palworld player"

# The server binds the Steam query port as well, and a client that joins through
# the server list queries it rather than the game port, so a registration covers
# both. Joining by address only ever touches the game port.
PORTS = (GAME_PORT, QUERY_PORT)


def allow(cidr):
    missing = [port for port in PORTS if cidr not in allowed(port)]
    if not missing:
        return f"{cidr} is already allowed."

    ec2.authorize_security_group_ingress(
        GroupId=SECURITY_GROUP_ID,
        IpPermissions=[
            _permission(port, [{"CidrIp": cidr, "Description": RULE_DESCRIPTION}])
            for port in missing
        ],
    )
    return f"{cidr} may now reach {'/'.join(str(port) for port in PORTS)}."


def revoke(cidr):
    present = [port for port in PORTS if cidr in allowed(port)]
    if not present:
        return f"{cidr} is not allowed, nothing to revoke."

    ec2.revoke_security_group_ingress(
        GroupId=SECURITY_GROUP_ID,
        IpPermissions=[_permission(port, [{"CidrIp": cidr}]) for port in present],
    )
    return f"{cidr} may no longer reach the server."


def allowed(port=GAME_PORT):
    group = ec2.describe_security_groups(GroupIds=[SECURITY_GROUP_ID])["SecurityGroups"][0]

    return [
        ip_range["CidrIp"]
        for permission in group["IpPermissions"]
        if permission.get("IpProtocol") == PROTOCOL and permission.get("FromPort") == port
        for ip_range in permission.get("IpRanges", [])
    ]


def _permission(port, ip_ranges):
    return {
        "IpProtocol": PROTOCOL,
        "FromPort": port,
        "ToPort": port,
        "IpRanges": ip_ranges,
    }
