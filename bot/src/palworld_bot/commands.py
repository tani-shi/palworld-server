"""Dispatch of the /palworld subcommands."""

import ipaddress

from . import access, server


class Rejected(Exception):
    """Input the user can correct, reported back verbatim."""


def run(interaction):
    subcommand = interaction["data"]["options"][0]
    name = subcommand["name"]
    options = {option["name"]: option["value"] for option in subcommand.get("options", [])}

    if name == "start":
        return server.start()
    if name == "stop":
        return server.stop()
    if name == "status":
        return server.status()
    if name == "register":
        return access.allow(_host_cidr(options["ip"]))
    if name == "unregister":
        return access.revoke(_host_cidr(options["ip"]))
    if name == "allowlist":
        return _render(access.allowed())

    raise Rejected(f"Unknown subcommand: {name}")


def _host_cidr(value):
    try:
        network = ipaddress.ip_network(value.strip(), strict=True)
    except ValueError as error:
        raise Rejected(f"Not an IP address: {error}") from error

    if network.version != 4:
        raise Rejected("Only IPv4 addresses can be registered.")
    # A shorter prefix would open the game port to a whole range; /0 above all.
    if network.prefixlen != 32:
        raise Rejected("Only a single address (/32) can be registered.")
    if not network.network_address.is_global:
        raise Rejected("Only globally routable addresses can be registered.")

    return str(network)


def _render(cidrs):
    if not cidrs:
        return "No address is allowed yet. Use `/palworld register` to add one."

    return "Allowed addresses:\n" + "\n".join(f"- {cidr}" for cidr in sorted(cidrs))
