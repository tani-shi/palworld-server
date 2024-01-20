import os
from dotenv import load_dotenv
import boto3

# Load environment variables from .env file
load_dotenv()

# Access environment variables
aws_access_key_id = os.getenv("AWS_ACCESS_KEY_ID")
aws_secret_access_key = os.getenv("AWS_SECRET_ACCESS_KEY")
aws_region = os.getenv("AWS_REGION")
aws_security_group_id = os.getenv("AWS_SECURITY_GROUP_ID")

ec2 = boto3.client('ec2', aws_access_key_id=aws_access_key_id, aws_secret_access_key=aws_secret_access_key, region_name=aws_region)

def ensure_cidr_format(ip_address):
    if '/' not in ip_address:
        return f"{ip_address}/32"
    return ip_address

def get_instance_id_by_name(name):
    # Use describe_instances to get information about all instances.
    response = ec2.describe_instances(
        Filters=[
            {
                'Name': 'tag:Name',
                'Values': [name]
            }
        ]
    )

    # Extract the instance ID if it exists.
    if 'Reservations' in response:
        for reservation in response['Reservations']:
            for instance in reservation['Instances']:
                return instance['InstanceId']

    return None

def get_instance_status(instance_id):
    try:
        # Use describe_instance_status to get the status of the instance.
        response = ec2.describe_instance_status(InstanceIds=[instance_id])

        if 'InstanceStatuses' in response and response['InstanceStatuses']:
            instance_status = response['InstanceStatuses'][0]['InstanceStatus']['Status']
            system_status = response['InstanceStatuses'][0]['SystemStatus']['Status']
            return f"Instance Status: {instance_status}, System Status: {system_status}"
        else:
            # If the instance status is not available, check if the instance exists.
            instance_response = ec2.describe_instances(InstanceIds=[instance_id])

            if 'Reservations' in instance_response:
                for reservation in instance_response['Reservations']:
                    for instance in reservation['Instances']:
                        state = instance['State']['Name']
                        return f"Instance is stopped (State: {state})"
            return "Instance not found."

    except Exception as e:
        return f"Error checking instance status: {str(e)}"

def start_instance_by_id(instance_id):
    ec2.start_instances(InstanceIds=[instance_id])

def stop_instance_by_id(instance_id):
    ec2.stop_instances(InstanceIds=[instance_id])

def add_security_group_rule(ip_address):
    group_id = aws_security_group_id

    try:
        response = ec2.authorize_security_group_ingress(
            GroupId=group_id,
            IpProtocol='tcp',
            FromPort=25565,
            ToPort=25565,
            CidrIp=ensure_cidr_format(ip_address)
        )
        print(f"Added ingress rule for port 25565 from {ensure_cidr_format(ip_address)} to Security Group {group_id}")
    except Exception as e:
        print(f"Error adding ingress rule: {str(e)}")

def is_ip_authorized_in_security_group(ip_address):
    group_id = aws_security_group_id
    
    try:
        response = ec2.describe_security_groups(GroupIds=[group_id])
        security_group = response['SecurityGroups'][0]

        # Check if any ingress rules match the provided IP address
        for rule in security_group['IpPermissions']:
            for ip_range in rule.get('IpRanges', []):
                if ip_range.get('CidrIp') == ensure_cidr_format(ip_address):
                    return True

        return False
    except Exception as e:
        print(f"Error checking security group rules: {str(e)}")
        return False