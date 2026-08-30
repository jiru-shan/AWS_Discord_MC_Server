#!/usr/bin/env python3
"""Register the slash commands with Discord.

Discord will not show a command until it has been registered against the
application, which is a one-time HTTP call that Terraform cannot make (it needs
the bot token, a credential Discord does not expose to AWS).

Usage:
    python scripts/register_commands.py                 # global, all servers
    python scripts/register_commands.py --guild <id>    # one server, instant
    python scripts/register_commands.py --list
    python scripts/register_commands.py --delete-all

Credentials are read from, in order: the command line, the environment
(DISCORD_APPLICATION_ID / DISCORD_BOT_TOKEN), or an interactive prompt.

Standard library only, so there is nothing to install.
"""

import argparse
import getpass
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://discord.com/api/v10"

COMMANDS = [
    {
        "name": "start",
        "description": "Start the Minecraft server",
        "type": 1,
    },
    {
        "name": "stop",
        "description": "Save the world and shut the Minecraft server down",
        "type": 1,
    },
    {
        "name": "status",
        "description": "Check whether the Minecraft server is running",
        "type": 1,
    },
    {
        "name": "address",
        "description": "Show the address to connect to",
        "type": 1,
    },
]


def request(method, path, token, payload=None):
    """Call the Discord API and return the decoded body, or None for 204."""
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        f"{API}{path}",
        data=data,
        method=method,
        headers={
            "Authorization": f"Bot {token}",
            "Content-Type": "application/json",
            # Discord asks every API client to identify itself.
            "User-Agent": "DiscordBot (aws-discord-mc-server, 1.0)",
        },
    )
    try:
        with urllib.request.urlopen(req) as response:
            body = response.read()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as err:
        detail = err.read().decode(errors="replace")
        if err.code == 401:
            raise SystemExit(
                "Discord rejected the bot token (401).\n"
                "Copy it from your application -> Bot -> Reset Token. It is not "
                "the client secret and not the public key."
            )
        if err.code == 403:
            raise SystemExit(
                "Discord returned 403.\n"
                "For --guild, the bot must have been invited to that server with "
                "the applications.commands scope."
            )
        if err.code == 429:
            raise SystemExit(f"Rate limited by Discord. Wait a minute and retry.\n{detail}")
        raise SystemExit(f"Discord API error {err.code} on {method} {path}:\n{detail}")
    except urllib.error.URLError as err:
        raise SystemExit(f"Could not reach Discord: {err.reason}")


def resolve(value, env_var, prompt, secret=False):
    if value:
        return value.strip()
    if os.environ.get(env_var):
        return os.environ[env_var].strip()
    if not sys.stdin.isatty():
        raise SystemExit(f"{env_var} is not set and there is no terminal to prompt on.")
    entered = getpass.getpass(prompt) if secret else input(prompt)
    if not entered.strip():
        raise SystemExit(f"{env_var} is required.")
    return entered.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--application-id", help="Discord application ID")
    parser.add_argument("--token", help="Discord bot token")
    parser.add_argument(
        "--guild",
        help=(
            "Register to a single server. Guild commands appear immediately, "
            "while global ones can take up to an hour to propagate."
        ),
    )
    parser.add_argument("--list", action="store_true", help="Show the registered commands and exit")
    parser.add_argument(
        "--delete-all", action="store_true", help="Remove every registered command"
    )
    args = parser.parse_args()

    app_id = resolve(
        args.application_id, "DISCORD_APPLICATION_ID", "Discord application ID: "
    )
    token = resolve(args.token, "DISCORD_BOT_TOKEN", "Discord bot token: ", secret=True)

    scope = f"/applications/{app_id}/commands"
    where = "globally"
    if args.guild:
        scope = f"/applications/{app_id}/guilds/{args.guild}/commands"
        where = f"in guild {args.guild}"

    if args.list:
        existing = request("GET", scope, token) or []
        if not existing:
            print(f"No commands registered {where}.")
            return
        print(f"Commands registered {where}:")
        for command in existing:
            print(f"  /{command['name']:<10} {command.get('description', '')}")
        return

    if args.delete_all:
        # Discord treats PUT as "make the list exactly this", so an empty list
        # clears everything in one call.
        request("PUT", scope, token, [])
        print(f"Removed all commands {where}.")
        return

    # PUT replaces the whole set, which makes this safe to re-run and means
    # commands removed from COMMANDS actually disappear.
    result = request("PUT", scope, token, COMMANDS) or []
    print(f"Registered {len(result)} commands {where}:")
    for command in result:
        print(f"  /{command['name']:<10} {command.get('description', '')}")

    if not args.guild:
        print(
            "\nGlobal commands can take up to an hour to appear. To test right "
            "away, re-run with --guild <your server ID>."
        )


if __name__ == "__main__":
    main()
