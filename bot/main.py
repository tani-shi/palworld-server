import os

import discord
from dotenv import load_dotenv

import aws

load_dotenv()

token = os.getenv("TOKEN")
default_version = os.getenv("DEFAULT_VERSION")

COMMAND_PREFIX = "/palworld"


def instance_name_for(version):
    return f"palworld-server-{version or default_version}"


class MyClient(discord.Client):
    async def on_ready(self):
        print("Logged on as {0}!".format(self.user))

    async def on_message(self, message):
        if message.author.bot:
            return

        args = message.content.split(" ")
        if args[0] != COMMAND_PREFIX:
            return

        command = args[1] if len(args) > 1 else None
        arg = args[2] if len(args) > 2 else None

        if command == "register":
            await self.register(message, arg)
            return

        name = instance_name_for(arg)
        instance_id = aws.get_instance_id_by_name(name)
        if not instance_id:
            await message.channel.send(f"Instance with name '{name}' not found.")
            return

        if command == "start":
            aws.start_instance_by_id(instance_id)
            await message.channel.send(f"Starting '{name}'...")
        elif command == "stop":
            aws.stop_instance_by_id(instance_id)
            await message.channel.send(f"Stopping '{name}'...")
        elif command == "status":
            status = aws.get_instance_status(instance_id)
            await message.channel.send(f"Status of '{name}': {status}")
        else:
            await message.channel.send(
                f"Usage: {COMMAND_PREFIX} <start|stop|status> [version] / "
                f"{COMMAND_PREFIX} register <ip>"
            )

    async def register(self, message, ip_address):
        if not ip_address:
            await message.channel.send("Please provide an IP address.")
            return

        if aws.is_ip_authorized_in_security_group(ip_address):
            await message.channel.send(f"The IP address '{ip_address}' is already authorized.")
            return

        aws.add_security_group_rule(ip_address)
        await message.channel.send(f"IP address '{ip_address}' added to the security group.")


intents = discord.Intents.default()
intents.message_content = True

client = MyClient(intents=intents)
client.run(token)
