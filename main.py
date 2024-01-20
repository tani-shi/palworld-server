import os
from dotenv import load_dotenv
import discord
import aws

# Load environment variables from .env file
load_dotenv()

# Access environment variables
token = os.getenv('TOKEN')
default_version = os.getenv('DEFAULT_VERSION')

class MyClient(discord.Client):
    async def on_ready(self):
        print('Logged on as {0}!'.format(self.user))

    async def on_message(self, message):
        print('Message from {0.author}: {0.content}'.format(message))

        args = message.content.split(' ')

        if args[0] != '/palworld' or message.author.bot:
            return

        command = args[1] if len(args) > 1 else None
        arg = args[2] if len(args) > 2 else None

        if command == 'start':
            version = arg or default_version
            instance_name = f"palworld-server-{version}"

            # Get the instance ID by name using the AWS method
            instance_id = aws.get_instance_id_by_name(instance_name)

            if instance_id:
                # Start the instance using the AWS method
                aws.start_instance_by_id(instance_id)
                await message.channel.send(f"Starting server for version '{version}'...")
            else:
                await message.channel.send(f"Instance with name '{instance_name}' not found.")

        if command == 'stop':
            version = arg or default_version
            instance_name = f"palworld-server-{version}"

            # Get the instance ID by name using the AWS method
            instance_id = aws.get_instance_id_by_name(instance_name)

            if instance_id:
                # Stop the instance using the AWS method
                aws.stop_instance_by_id(instance_id)
                await message.channel.send(f"Stopping server for version '{version}'...")
            else:
                await message.channel.send(f"Instance with name '{instance_name}' not found.")

        if command == 'status':
            version = arg or default_version
            instance_name = f"palworld-server-{version}"

            # Get the instance ID by name
            instance_id = aws.get_instance_id_by_name(instance_name)

            if instance_id:
                # Get the status of the instance
                status = aws.get_instance_status(instance_id)
                await message.channel.send(f"Status of instance '{instance_name}': {status}")
            else:
                await message.channel.send(f"Instance with name '{instance_name}' not found.")

        if command == 'register':
            ip_address = arg
            if not ip_address:
                await message.channel.send('Please provide an IP address.')
                return

            # Check if the provided IP address is authorized in the security group
            is_authorized = aws.is_ip_authorized_in_security_group(ip_address)

            if is_authorized:
                await message.channel.send(f"The IP address '{ip_address}' is already authorized.")
            else:
                # Add the IP address to the security group using the AWS method
                aws.add_security_group_rule(ip_address)
                await message.channel.send(f"IP address '{ip_address}' added to the security group.")

intents = discord.Intents.default()
intents.message_content = True

client = MyClient(intents=intents)
client.run(token)