"""Discord interactions endpoint that starts and stops the Minecraft EC2 instance.

Reached through a Lambda function URL, or an API Gateway HTTP API where the
account will not serve a public function URL. Either way Discord calls it
directly as the application's "Interactions Endpoint URL", and the event looks
the same: API Gateway's 2.0 payload format supplies the same lowercase headers,
body and isBase64Encoded fields, so neither is a special case below.

Discord expects a reply within three seconds, so every command answers
immediately (response type 4) and does its work inline -- the EC2 and SSM calls
here are all sub-second.

Commands:
    /start    boot the instance if it is stopped
    /stop     ask the server to save, back up and shut down cleanly
    /status   report instance state and, when running, the connect address
    /address  report the connect address

Configuration arrives entirely through environment variables set by Terraform;
nothing in this file is specific to one deployment.
"""

import base64
import json
import logging
import os

import boto3

import ed25519_verify

logger = logging.getLogger()
logger.setLevel(logging.INFO)

PUBLIC_KEY = os.environ["DISCORD_PUBLIC_KEY"]
INSTANCE_ID = os.environ["INSTANCE_ID"]
CONNECT_ADDRESS = os.environ.get("CONNECT_ADDRESS", "")
SERVER_PORT = os.environ.get("SERVER_PORT", "25565")
STOP_SCRIPT = os.environ.get("STOP_SCRIPT", "/opt/minecraft/bin/request-stop.sh")


def _role_set(name):
    return {role.strip() for role in os.environ.get(name, "").split(",") if role.strip()}


ALLOWED_ROLE_IDS = _role_set("ALLOWED_ROLE_IDS")

# /stop controls. Turning the command off protects a shared server from being
# ended by anyone in it, deliberately or by mistake; the roles narrow it to the
# people running the server instead. Terraform also withholds the Lambda's
# ssm:SendCommand permission when the command is off, so this is a second lock
# on the same door rather than the only one.
ALLOW_STOP_COMMAND = os.environ.get("ALLOW_STOP_COMMAND", "true").lower() == "true"

# Whether a channel webhook is configured. Only the instance can post "Server
# is up", and only if it has somewhere to post it -- so without this the reply
# to /start would promise a message that is never coming, and players would sit
# waiting for it instead of running /status.
NOTIFICATIONS_ENABLED = os.environ.get("NOTIFICATIONS_ENABLED", "false").lower() == "true"
STOP_ROLE_IDS = _role_set("STOP_ROLE_IDS")
IDLE_TIMEOUT_MINUTES = os.environ.get("IDLE_TIMEOUT_MINUTES", "15")

# Discord interaction types.
PING = 1
APPLICATION_COMMAND = 2

# Discord interaction response types.
PONG = 1
CHANNEL_MESSAGE = 4

EPHEMERAL_FLAG = 64

ec2 = boto3.client("ec2")
ssm = boto3.client("ssm")


# --------------------------------------------------------------------------
# HTTP / Discord plumbing
# --------------------------------------------------------------------------


def _http(status, payload):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload),
    }


def _reply(content, ephemeral=False):
    data = {"content": content}
    if ephemeral:
        data["flags"] = EPHEMERAL_FLAG
    return _http(200, {"type": CHANNEL_MESSAGE, "data": data})


def _raw_body(event):
    """Return the request body exactly as Discord sent it.

    The signature covers the raw bytes, so the body must never be parsed and
    re-serialised before verification. Function URLs base64-encode the body only
    for binary content types, but handle both forms so the endpoint keeps
    working if that ever changes.
    """
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        return base64.b64decode(body).decode("utf-8")
    return body


def _is_authorised(body):
    """True when the invoking member holds one of the allowed roles.

    With ALLOWED_ROLE_IDS unset, everyone in the server may run commands, which
    is the sensible default for a small private server.
    """
    if not ALLOWED_ROLE_IDS:
        return True
    member = body.get("member") or {}
    return bool(ALLOWED_ROLE_IDS.intersection(member.get("roles") or []))


def _idles_out():
    """Whether the server really will stop on its own.

    idle_timeout_minutes = 0 disables the automatic shutdown entirely, so any
    message telling somebody to just wait would be sending them to wait for
    something that is never going to happen.
    """
    return IDLE_TIMEOUT_MINUTES not in ("0", "")


def _idle_sentence():
    """"It shuts down on its own after N minutes", when that is true."""
    if not _idles_out():
        return ""
    return " It shuts down on its own once nobody has been online for {} minutes.".format(
        IDLE_TIMEOUT_MINUTES
    )


def _stop_refusal(body):
    """Why this member may not stop the server, or None if they may.

    Separate from _is_authorised because the answers differ: one is "you may
    not use this bot", the other is "this server is not stopped by hand", and
    telling someone the wrong one sends them to argue with the wrong person.
    """
    if not ALLOW_STOP_COMMAND:
        return "Stopping the server from Discord is disabled here." + _idle_sentence()

    if STOP_ROLE_IDS:
        member = body.get("member") or {}
        if not STOP_ROLE_IDS.intersection(member.get("roles") or []):
            return "Only server admins can stop the server." + _idle_sentence()

    return None


# --------------------------------------------------------------------------
# EC2 helpers
# --------------------------------------------------------------------------


def _error_code(err):
    """AWS error code for a botocore exception, or "" for anything else.

    Read off the exception rather than importing botocore, so this module keeps
    its only dependency on what the Lambda runtime already provides and the
    tests can raise plain objects.
    """
    response = getattr(err, "response", None)
    if not isinstance(response, dict):
        return ""
    return response.get("Error", {}).get("Code", "")


# Asking about an instance that no longer exists is an API error, not an empty
# result set, so this is the branch that actually fires after a terminate.
_GONE = ("InvalidInstanceID.NotFound", "InvalidInstanceID.Malformed")


def _describe():
    """Return (state, public_ip). state is "missing" when the instance is gone."""
    try:
        response = ec2.describe_instances(InstanceIds=[INSTANCE_ID])
    except Exception as err:
        if _error_code(err) in _GONE:
            return "missing", None
        raise

    for reservation in response.get("Reservations", []):
        for instance in reservation.get("Instances", []):
            return instance["State"]["Name"], instance.get("PublicIpAddress")
    return "missing", None


def _connect_string(public_ip):
    """Prefer the stable DNS name or Elastic IP; fall back to whatever AWS gave us."""
    host = CONNECT_ADDRESS or public_ip
    if not host:
        return None
    if SERVER_PORT == "25565":
        return host
    return "{}:{}".format(host, SERVER_PORT)


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

MISSING_MESSAGE = "Could not find the server instance. It may have been terminated."


def _cmd_start():
    state, public_ip = _describe()

    if state == "running":
        address = _connect_string(public_ip)
        suffix = " Connect at `{}`.".format(address) if address else ""
        return _reply("Server is already running.{}".format(suffix))
    if state == "stopped":
        ec2.start_instances(InstanceIds=[INSTANCE_ID])
        if NOTIFICATIONS_ENABLED:
            return _reply(
                "Starting the server. It usually takes a couple of minutes to accept "
                "connections -- you will get a message here when it is ready."
            )
        return _reply(
            "Starting the server. It usually takes a couple of minutes to accept "
            "connections -- run /status to check on it."
        )
    if state in ("pending", "stopping", "shutting-down"):
        return _reply(
            "Server is already {}. Give it a moment and try again.".format(state)
        )
    if state == "missing":
        return _reply(MISSING_MESSAGE, ephemeral=True)
    return _reply("Server is in an unexpected state: `{}`.".format(state), ephemeral=True)


def _cmd_stop():
    state, _ = _describe()

    if state != "running":
        return _reply("Server is not running (currently `{}`).".format(state))

    # Run the on-instance stop script rather than calling ec2:StopInstances, so
    # the world is saved and backed up before the box goes away.
    try:
        ssm.send_command(
            InstanceIds=[INSTANCE_ID],
            DocumentName="AWS-RunShellScript",
            Comment="Discord /stop",
            Parameters={"commands": [STOP_SCRIPT]},
        )
    except Exception as err:
        # The instance reports "running" as soon as EC2 has booted it, but the
        # SSM agent takes another few seconds to register. Say so plainly
        # instead of reporting a generic failure.
        if _error_code(err) == "InvalidInstanceId":
            tail = (
                ", or let it shut down on its own when nobody is playing."
                if _idles_out()
                else "."
            )
            return _reply(
                "The server is booting and cannot be reached yet. Try again in a "
                "minute" + tail
            )
        raise

    return _reply(
        "Saving the world and shutting the server down. This takes about a minute."
    )


def _cmd_status():
    state, public_ip = _describe()

    if state == "missing":
        return _reply(MISSING_MESSAGE, ephemeral=True)

    address = _connect_string(public_ip)
    if state == "running":
        if address:
            return _reply("Server is **running** at `{}`.".format(address))
        return _reply("Server is **running** but has no public address yet.")
    return _reply("Server is **{}**. Use `/start` to boot it.".format(state))


def _cmd_address():
    state, public_ip = _describe()

    if state == "missing":
        return _reply(MISSING_MESSAGE, ephemeral=True)

    address = _connect_string(public_ip)
    if address:
        return _reply(
            "Connect at `{}` (server is currently `{}`).".format(address, state)
        )
    return _reply("No address available yet -- the server is `{}`.".format(state))


COMMANDS = {
    "start": _cmd_start,
    "stop": _cmd_stop,
    "status": _cmd_status,
    "address": _cmd_address,
}


def handle_command(body):
    name = (body.get("data") or {}).get("name", "")
    handler = COMMANDS.get(name)

    if handler is None:
        return _reply("Unknown command `/{}`.".format(name), ephemeral=True)
    if not _is_authorised(body):
        return _reply("You do not have permission to use this command.", ephemeral=True)

    if name == "stop":
        refusal = _stop_refusal(body)
        if refusal is not None:
            # Ephemeral: only the person who asked sees it, so a refusal does
            # not read as an announcement to the channel.
            return _reply(refusal, ephemeral=True)

    try:
        return handler()
    except Exception:  # never surface a stack trace into a Discord channel
        logger.exception("command /%s failed", name)
        return _reply(
            "Something went wrong talking to AWS. Check the Lambda logs.",
            ephemeral=True,
        )


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------


def lambda_handler(event, context):
    headers = {
        key.lower(): value for key, value in (event.get("headers") or {}).items()
    }
    signature = headers.get("x-signature-ed25519", "")
    timestamp = headers.get("x-signature-timestamp", "")
    raw_body = _raw_body(event)

    if not signature or not timestamp:
        return _http(401, "missing request signature")

    if not ed25519_verify.verify_hex(
        PUBLIC_KEY, signature, (timestamp + raw_body).encode()
    ):
        # Discord probes this deliberately when you save the endpoint URL; it
        # will not accept an endpoint that answers anything but 401 here.
        return _http(401, "invalid request signature")

    try:
        body = json.loads(raw_body)
    except ValueError:
        return _http(400, "malformed request body")

    interaction_type = body.get("type")

    if interaction_type == PING:
        return _http(200, {"type": PONG})
    if interaction_type == APPLICATION_COMMAND:
        return handle_command(body)
    return _http(400, "unhandled interaction type")
