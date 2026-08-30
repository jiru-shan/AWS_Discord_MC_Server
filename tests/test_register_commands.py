"""Tests for the slash-command registration script.

This is the one part of the setup a person runs by hand, and the one that fails
most visibly: a 401 from the wrong credential, a 403 from a bot that was never
invited. Those messages are the whole value of the script over a raw curl, so
they are what is pinned here.

urllib is stubbed, so nothing here touches the network.
"""

import io
import json
import os
import sys
import unittest
import urllib.error

sys.dont_write_bytecode = True

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
sys.path.insert(0, os.path.join(ROOT, "lambda"))

import register_commands  # noqa: E402


class FakeResponse:
    def __init__(self, body):
        self._body = body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def http_error(code, body=b"details"):
    return urllib.error.HTTPError(
        "https://discord.com/api/v10/x", code, "err", {}, io.BytesIO(body)
    )


class RequestTestCase(unittest.TestCase):
    """The error mapping, which is why this script exists rather than curl."""

    def setUp(self):
        self.calls = []
        self._real = register_commands.urllib.request.urlopen

    def tearDown(self):
        register_commands.urllib.request.urlopen = self._real
        for var in ("DISCORD_APPLICATION_ID", "DISCORD_BOT_TOKEN"):
            os.environ.pop(var, None)

    def serve(self, result):
        def fake(req):
            self.calls.append(req)
            if isinstance(result, Exception):
                raise result
            return FakeResponse(result)

        register_commands.urllib.request.urlopen = fake

    def test_a_json_body_is_decoded(self):
        self.serve(json.dumps([{"name": "start"}]).encode())
        self.assertEqual(
            register_commands.request("GET", "/x", "token"), [{"name": "start"}]
        )

    def test_an_empty_body_is_none_rather_than_a_json_error(self):
        # Discord answers 204 with no body when a PUT clears the command list.
        self.serve(b"")
        self.assertIsNone(register_commands.request("PUT", "/x", "token", []))

    def test_the_bot_token_is_sent_as_an_authorization_header(self):
        self.serve(b"{}")
        register_commands.request("GET", "/x", "sekrit")
        self.assertEqual(self.calls[0].get_header("Authorization"), "Bot sekrit")

    def test_401_names_the_credential_people_actually_get_wrong(self):
        self.serve(http_error(401))
        with self.assertRaises(SystemExit) as raised:
            register_commands.request("GET", "/x", "token")
        message = str(raised.exception)
        self.assertIn("Reset Token", message)
        self.assertIn("client secret", message)

    def test_403_names_the_missing_scope(self):
        # The failure a first-time setup actually hits: the bot was never
        # invited to the server, so the token is fine and the call still fails.
        self.serve(http_error(403))
        with self.assertRaises(SystemExit) as raised:
            register_commands.request("PUT", "/x", "token", [])
        self.assertIn("applications.commands", str(raised.exception))

    def test_429_says_to_wait(self):
        self.serve(http_error(429))
        with self.assertRaises(SystemExit) as raised:
            register_commands.request("PUT", "/x", "token", [])
        self.assertIn("Rate limited", str(raised.exception))

    def test_an_unexpected_status_carries_the_code_and_the_body(self):
        self.serve(http_error(500, b"upstream exploded"))
        with self.assertRaises(SystemExit) as raised:
            register_commands.request("PUT", "/x", "token", [])
        message = str(raised.exception)
        self.assertIn("500", message)
        self.assertIn("upstream exploded", message)

    def test_a_network_failure_is_not_a_traceback(self):
        self.serve(urllib.error.URLError("no route to host"))
        with self.assertRaises(SystemExit) as raised:
            register_commands.request("PUT", "/x", "token", [])
        self.assertIn("Could not reach Discord", str(raised.exception))


class _NotATerminal:
    def isatty(self):
        return False


class _ATerminal:
    def isatty(self):
        return True


class ResolveTestCase(unittest.TestCase):
    def tearDown(self):
        os.environ.pop("SOME_VAR", None)

    def test_an_explicit_value_wins_and_is_trimmed(self):
        os.environ["SOME_VAR"] = "from-env"
        self.assertEqual(
            register_commands.resolve("  from-cli  ", "SOME_VAR", "p: "), "from-cli"
        )

    def test_an_empty_argument_falls_through_to_the_environment(self):
        os.environ["SOME_VAR"] = "  from-env  "
        self.assertEqual(register_commands.resolve("", "SOME_VAR", "p: "), "from-env")
        self.assertEqual(register_commands.resolve(None, "SOME_VAR", "p: "), "from-env")

    def test_nothing_set_and_no_terminal_names_the_variable(self):
        # The CI case. Without this check the script would sit at a prompt
        # nobody can answer, which looks like a hang rather than a mistake.
        real = register_commands.sys.stdin
        register_commands.sys.stdin = _NotATerminal()
        try:
            with self.assertRaises(SystemExit) as raised:
                register_commands.resolve(None, "SOME_VAR", "p: ")
        finally:
            register_commands.sys.stdin = real
        self.assertIn("SOME_VAR", str(raised.exception))

    def test_a_blank_answer_at_the_prompt_is_refused(self):
        import builtins

        real_input = builtins.input
        real_stdin = register_commands.sys.stdin
        register_commands.sys.stdin = _ATerminal()
        builtins.input = lambda _prompt: "   "
        try:
            with self.assertRaises(SystemExit) as raised:
                register_commands.resolve(None, "SOME_VAR", "p: ")
        finally:
            builtins.input = real_input
            register_commands.sys.stdin = real_stdin
        self.assertIn("required", str(raised.exception))


class CommandSetTestCase(unittest.TestCase):
    """The registered names and the Lambda's handlers have to agree.

    Nothing else connects these two files. Registering a command the Lambda
    does not implement gets "Unknown command" in Discord; implementing one that
    is never registered means it simply does not appear, with nothing to say
    why.
    """

    def test_every_registered_command_has_a_handler(self):
        import types

        boto3 = types.ModuleType("boto3")
        boto3.client = lambda *a, **k: None
        sys.modules.setdefault("boto3", boto3)
        os.environ.setdefault("DISCORD_PUBLIC_KEY", "00" * 32)
        os.environ.setdefault("INSTANCE_ID", "i-0123456789abcdef0")
        import lambda_function

        registered = {command["name"] for command in register_commands.COMMANDS}
        handled = set(lambda_function.COMMANDS)
        self.assertEqual(
            registered,
            handled,
            "register_commands.py and the Lambda disagree about the command list",
        )

    def test_every_command_is_a_chat_input_command_with_a_description(self):
        for command in register_commands.COMMANDS:
            self.assertEqual(command["type"], 1, command["name"])
            self.assertTrue(command["description"].strip(), command["name"])
            # Discord rejects names that are not lowercase.
            self.assertEqual(command["name"], command["name"].lower())


if __name__ == "__main__":
    unittest.main()
