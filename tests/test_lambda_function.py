"""Tests for the Discord interactions handler.

boto3 is stubbed out in sys.modules before the handler is imported, so these run
anywhere with a bare Python install -- no AWS credentials, no dependencies.
"""

import hashlib
import json
import os
import sys
import types
import unittest

# Keep the test run from dropping __pycache__ into lambda/, which would end up
# inside the deployment zip archive_file builds from that directory.
sys.dont_write_bytecode = True

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "lambda"))

import ed25519_verify  # noqa: E402


# --------------------------------------------------------------------------
# Test-only Ed25519 signing, built on the verifier's primitives so the tests can
# produce the signatures Discord would send. Never used in the Lambda itself.
# --------------------------------------------------------------------------


def _encode_point(point):
    x, y, z, _ = point
    inv_z = pow(z, ed25519_verify.P - 2, ed25519_verify.P)
    x = x * inv_z % ed25519_verify.P
    y = y * inv_z % ed25519_verify.P
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def _sign(secret_key, message):
    digest = hashlib.sha512(secret_key).digest()
    a = int.from_bytes(digest[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    public_key = _encode_point(ed25519_verify._scalar_mult(ed25519_verify.BASE_POINT, a))

    r = (
        int.from_bytes(hashlib.sha512(digest[32:] + message).digest(), "little")
        % ed25519_verify.L
    )
    big_r = _encode_point(ed25519_verify._scalar_mult(ed25519_verify.BASE_POINT, r))
    k = (
        int.from_bytes(
            hashlib.sha512(big_r + public_key + message).digest(), "little"
        )
        % ed25519_verify.L
    )
    s = (r + k * a) % ed25519_verify.L
    return public_key, big_r + s.to_bytes(32, "little")


SECRET_KEY = bytes(range(32))
PUBLIC_KEY, _ = _sign(SECRET_KEY, b"")
PUBLIC_KEY_HEX = PUBLIC_KEY.hex()

INSTANCE_ID = "i-0123456789abcdef0"


# --------------------------------------------------------------------------
# Fake AWS clients
# --------------------------------------------------------------------------


class FakeEc2:
    def __init__(self, state="stopped", public_ip=None):
        self.state = state
        self.public_ip = public_ip
        self.started = []

    def describe_instances(self, InstanceIds):
        if self.state == "missing":
            return {"Reservations": []}
        instance = {"InstanceId": InstanceIds[0], "State": {"Name": self.state}}
        if self.public_ip:
            instance["PublicIpAddress"] = self.public_ip
        return {"Reservations": [{"Instances": [instance]}]}

    def start_instances(self, InstanceIds):
        self.started.append(InstanceIds)
        return {}


class FakeSsm:
    def __init__(self):
        self.commands = []

    def send_command(self, **kwargs):
        self.commands.append(kwargs)
        return {"Command": {"CommandId": "fake"}}


def _load_handler(**env):
    """Import lambda_function fresh with the given environment and stubbed boto3."""
    sys.modules["boto3"] = types.SimpleNamespace(client=lambda *a, **k: None)
    sys.modules.pop("lambda_function", None)

    defaults = {
        "DISCORD_PUBLIC_KEY": PUBLIC_KEY_HEX,
        "INSTANCE_ID": INSTANCE_ID,
        "CONNECT_ADDRESS": "mc.example.com",
        "SERVER_PORT": "25565",
    }
    defaults.update(env)
    saved = {key: os.environ.get(key) for key in defaults}
    os.environ.update({k: v for k, v in defaults.items() if v is not None})
    for key, value in defaults.items():
        if value is None:
            os.environ.pop(key, None)
    try:
        import lambda_function

        return lambda_function
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def _event(payload, timestamp="1700000000", secret_key=SECRET_KEY, mangle=None):
    body = json.dumps(payload)
    _, signature = _sign(secret_key, (timestamp + body).encode())
    signature_hex = signature.hex()
    if mangle:
        signature_hex = mangle(signature_hex)
    return {
        "headers": {
            # Function URLs lowercase header names; use mixed case to prove the
            # handler normalises them.
            "X-Signature-Ed25519": signature_hex,
            "X-Signature-Timestamp": timestamp,
            "content-type": "application/json",
        },
        "body": body,
        "isBase64Encoded": False,
    }


def _content(response):
    return json.loads(response["body"])["data"]["content"]


class TestSignatureVerification(unittest.TestCase):
    def setUp(self):
        self.handler = _load_handler()
        self.handler.ec2 = FakeEc2()
        self.handler.ssm = FakeSsm()

    def test_ping_is_answered_with_pong(self):
        response = self.handler.lambda_handler(_event({"type": 1}), None)
        self.assertEqual(response["statusCode"], 200)
        self.assertEqual(json.loads(response["body"]), {"type": 1})

    def test_missing_signature_headers_are_rejected(self):
        event = _event({"type": 1})
        del event["headers"]["X-Signature-Ed25519"]
        self.assertEqual(self.handler.lambda_handler(event, None)["statusCode"], 401)

    def test_bad_signature_is_rejected(self):
        event = _event({"type": 1}, mangle=lambda s: ("0" if s[0] != "0" else "1") + s[1:])
        self.assertEqual(self.handler.lambda_handler(event, None)["statusCode"], 401)

    def test_signature_from_another_key_is_rejected(self):
        event = _event({"type": 1}, secret_key=bytes(range(1, 33)))
        self.assertEqual(self.handler.lambda_handler(event, None)["statusCode"], 401)

    def test_replayed_body_with_different_timestamp_is_rejected(self):
        event = _event({"type": 1}, timestamp="1700000000")
        event["headers"]["X-Signature-Timestamp"] = "1700000001"
        self.assertEqual(self.handler.lambda_handler(event, None)["statusCode"], 401)

    def test_base64_encoded_body_is_decoded_before_verifying(self):
        import base64

        event = _event({"type": 1})
        event["body"] = base64.b64encode(event["body"].encode()).decode()
        event["isBase64Encoded"] = True
        self.assertEqual(self.handler.lambda_handler(event, None)["statusCode"], 200)

    def test_unhandled_interaction_type(self):
        self.assertEqual(
            self.handler.lambda_handler(_event({"type": 99}), None)["statusCode"], 400
        )

    # The body is decoded before anything is verified, so these run entirely
    # unauthenticated. Anyone who can reach the URL can send them, and a raised
    # exception here is a 500 and a stack trace in the logs where a flat
    # refusal belongs.

    def test_undecodable_base64_body_is_refused_not_raised(self):
        event = _event({"type": 1})
        event["body"] = "!!! not base64 !!!"
        event["isBase64Encoded"] = True
        self.assertEqual(self.handler.lambda_handler(event, None)["statusCode"], 400)

    def test_non_utf8_body_is_refused_not_raised(self):
        import base64

        event = _event({"type": 1})
        event["body"] = base64.b64encode(bytes([0xff, 0xfe, 0x00])).decode()
        event["isBase64Encoded"] = True
        self.assertEqual(self.handler.lambda_handler(event, None)["statusCode"], 400)

    def test_an_undecodable_body_never_reaches_aws(self):
        event = _event({"type": 2, "data": {"name": "start"}})
        event["body"] = "!!! not base64 !!!"
        event["isBase64Encoded"] = True
        self.handler.lambda_handler(event, None)
        self.assertEqual(
            self.handler.ec2.started, [], "an unsigned request must not start the instance"
        )


class TestCommands(unittest.TestCase):
    def setUp(self):
        self.handler = _load_handler()
        self.ec2 = FakeEc2()
        self.ssm = FakeSsm()
        self.handler.ec2 = self.ec2
        self.handler.ssm = self.ssm

    def _run(self, name, member=None):
        payload = {"type": 2, "data": {"name": name}}
        if member is not None:
            payload["member"] = member
        return self.handler.lambda_handler(_event(payload), None)

    def test_start_boots_a_stopped_instance(self):
        response = self._run("start")
        self.assertEqual(self.ec2.started, [[INSTANCE_ID]])
        self.assertIn("Starting the server", _content(response))

    def test_start_is_a_no_op_when_already_running(self):
        self.ec2.state = "running"
        response = self._run("start")
        self.assertEqual(self.ec2.started, [])
        self.assertIn("already running", _content(response))
        self.assertIn("mc.example.com", _content(response))

    def test_start_reports_transitional_states(self):
        self.ec2.state = "pending"
        self.assertIn("already pending", _content(self._run("start")))

    def test_start_reports_a_terminated_instance(self):
        self.ec2.state = "missing"
        self.assertIn("Could not find", _content(self._run("start")))

    def test_stop_sends_the_graceful_stop_script(self):
        self.ec2.state = "running"
        response = self._run("stop")
        self.assertEqual(len(self.ssm.commands), 1)
        self.assertEqual(self.ssm.commands[0]["InstanceIds"], [INSTANCE_ID])
        self.assertEqual(
            self.ssm.commands[0]["Parameters"]["commands"],
            ["/opt/minecraft/bin/request-stop.sh"],
        )
        self.assertIn("Saving the world", _content(response))

    def test_stop_does_nothing_when_not_running(self):
        response = self._run("stop")
        self.assertEqual(self.ssm.commands, [])
        self.assertIn("not running", _content(response))

    def test_status_reports_the_connect_address(self):
        self.ec2.state = "running"
        self.assertIn("mc.example.com", _content(self._run("status")))

    def test_status_when_stopped(self):
        self.assertIn("stopped", _content(self._run("status")))

    def test_unknown_command_is_ephemeral(self):
        response = self._run("nonsense")
        data = json.loads(response["body"])["data"]
        self.assertEqual(data["flags"], 64)
        self.assertIn("Unknown command", data["content"])

    def test_aws_errors_do_not_leak_a_stack_trace(self):
        def boom(**kwargs):
            raise RuntimeError("AccessDenied")

        self.ec2.describe_instances = boom
        with self.assertLogs(self.handler.logger, level="ERROR"):
            response = self._run("status")
        self.assertEqual(response["statusCode"], 200)
        self.assertNotIn("AccessDenied", _content(response))


class TestNonDefaultPort(unittest.TestCase):
    def test_port_is_appended_when_not_the_default(self):
        handler = _load_handler(SERVER_PORT="25566")
        handler.ec2 = FakeEc2(state="running", public_ip="203.0.113.10")
        handler.ssm = FakeSsm()
        response = handler.lambda_handler(
            _event({"type": 2, "data": {"name": "address"}}), None
        )
        self.assertIn("mc.example.com:25566", _content(response))


class TestAddressFallback(unittest.TestCase):
    def test_public_ip_is_used_when_no_stable_address_is_configured(self):
        handler = _load_handler(CONNECT_ADDRESS="")
        handler.ec2 = FakeEc2(state="running", public_ip="203.0.113.10")
        handler.ssm = FakeSsm()
        response = handler.lambda_handler(
            _event({"type": 2, "data": {"name": "address"}}), None
        )
        self.assertIn("203.0.113.10", _content(response))


class TestRoleGate(unittest.TestCase):
    def setUp(self):
        self.handler = _load_handler(ALLOWED_ROLE_IDS="111, 222")
        self.ec2 = FakeEc2()
        self.handler.ec2 = self.ec2
        self.handler.ssm = FakeSsm()

    def _run(self, roles):
        return self.handler.lambda_handler(
            _event({"type": 2, "data": {"name": "start"}, "member": {"roles": roles}}),
            None,
        )

    def test_member_with_an_allowed_role_may_start(self):
        self._run(["999", "222"])
        self.assertEqual(self.ec2.started, [[INSTANCE_ID]])

    def test_member_without_an_allowed_role_is_refused(self):
        response = self._run(["999"])
        self.assertEqual(self.ec2.started, [])
        self.assertIn("do not have permission", _content(response))

    def test_interaction_with_no_member_is_refused(self):
        response = self.handler.lambda_handler(
            _event({"type": 2, "data": {"name": "start"}}), None
        )
        self.assertEqual(self.ec2.started, [])
        self.assertIn("do not have permission", _content(response))



class TestStopCommandControls(unittest.TestCase):
    """Who may end a session everyone else is in.

    The point of turning /stop off is that one person cannot end an evening for
    the rest of the server, so the tests care as much about the instance being
    left alone as about the wording of the refusal.
    """

    def _handler(self, **env):
        handler = _load_handler(**env)
        handler.ec2 = FakeEc2()
        handler.ssm = FakeSsm()
        handler.ec2.state = "running"
        return handler

    def _stop(self, handler, roles=None):
        payload = {"type": 2, "data": {"name": "stop"}}
        if roles is not None:
            payload["member"] = {"roles": roles}
        return handler.lambda_handler(_event(payload), None)

    # -- disabled outright ---------------------------------------------------

    def test_stop_is_refused_when_disabled(self):
        handler = self._handler(ALLOW_STOP_COMMAND="false", IDLE_TIMEOUT_MINUTES="15")
        response = self._stop(handler)

        self.assertIn("disabled", _content(response))
        self.assertEqual(handler.ssm.commands, [], "no stop may reach the instance")

    def test_a_refusal_says_when_the_server_will_stop_by_itself(self):
        handler = self._handler(ALLOW_STOP_COMMAND="false", IDLE_TIMEOUT_MINUTES="20")
        self.assertIn("20 minutes", _content(self._stop(handler)))

    def test_a_refusal_omits_the_idle_promise_when_idling_is_off(self):
        # idle_timeout_minutes = 0 means it never stops on its own; promising
        # that it will would be a lie.
        handler = self._handler(ALLOW_STOP_COMMAND="false", IDLE_TIMEOUT_MINUTES="0")
        content = _content(self._stop(handler))
        self.assertIn("disabled", content)
        self.assertNotIn("on its own", content)

    def test_a_refusal_is_ephemeral(self):
        handler = self._handler(ALLOW_STOP_COMMAND="false")
        data = json.loads(self._stop(handler)["body"])["data"]
        self.assertEqual(data.get("flags"), 64, "only the asker should see it")

    def test_the_other_commands_still_work_with_stop_disabled(self):
        handler = self._handler(ALLOW_STOP_COMMAND="false")
        response = handler.lambda_handler(
            _event({"type": 2, "data": {"name": "start"}}), None
        )
        self.assertIn("already running", _content(response).lower())

    # -- restricted to roles -------------------------------------------------

    def test_stop_roles_admit_the_holder(self):
        handler = self._handler(STOP_ROLE_IDS="900,901")
        self._stop(handler, roles=["901"])
        self.assertEqual(len(handler.ssm.commands), 1)

    def test_stop_roles_refuse_everyone_else(self):
        handler = self._handler(STOP_ROLE_IDS="900,901")
        response = self._stop(handler, roles=["777"])

        self.assertIn("admins", _content(response))
        self.assertEqual(handler.ssm.commands, [])

    def test_stop_roles_refuse_a_member_with_no_roles_at_all(self):
        handler = self._handler(STOP_ROLE_IDS="900")
        self._stop(handler, roles=[])
        self.assertEqual(handler.ssm.commands, [])

    def test_stop_roles_refuse_an_interaction_carrying_no_member(self):
        # A DM has no member object. Failing open here would hand /stop to
        # anyone who could invoke the bot outside the server.
        handler = self._handler(STOP_ROLE_IDS="900")
        self._stop(handler)
        self.assertEqual(handler.ssm.commands, [])

    # -- defaults and interactions ------------------------------------------

    def test_stop_is_allowed_by_default(self):
        handler = self._handler()
        self._stop(handler)
        self.assertEqual(len(handler.ssm.commands), 1)

    def test_an_unset_flag_defaults_to_allowed(self):
        handler = self._handler(ALLOW_STOP_COMMAND=None)
        self._stop(handler)
        self.assertEqual(len(handler.ssm.commands), 1)

    def test_the_flag_is_read_case_insensitively(self):
        handler = self._handler(ALLOW_STOP_COMMAND="False")
        self.assertEqual(handler.ssm.commands, [])

    def test_disabled_beats_a_stop_role(self):
        # Belt and braces set together must not cancel out.
        handler = self._handler(ALLOW_STOP_COMMAND="false", STOP_ROLE_IDS="900")
        self._stop(handler, roles=["900"])
        self.assertEqual(handler.ssm.commands, [])

    def test_the_general_role_gate_still_applies_to_stop(self):
        handler = self._handler(ALLOWED_ROLE_IDS="111", STOP_ROLE_IDS="900")
        response = self._stop(handler, roles=["900"])

        self.assertIn("do not have permission", _content(response))
        self.assertEqual(handler.ssm.commands, [])



class TestStartReplyMatchesReality(unittest.TestCase):
    """/start must not promise a message that nothing will send.

    Only the instance can post "Server is up", and only when a channel webhook
    is configured. Promising it unconditionally leaves people waiting for an
    announcement that is never coming instead of running /status.
    """

    def _start(self, **env):
        handler = _load_handler(**env)
        handler.ec2 = FakeEc2()
        handler.ssm = FakeSsm()
        handler.ec2.state = "stopped"
        response = handler.lambda_handler(
            _event({"type": 2, "data": {"name": "start"}}), None
        )
        return handler, _content(response)

    def test_with_a_webhook_it_promises_a_message(self):
        handler, content = self._start(NOTIFICATIONS_ENABLED="true")
        self.assertIn("message here when it is ready", content)
        self.assertEqual(handler.ec2.started, [[INSTANCE_ID]])

    def test_without_a_webhook_it_points_at_status_instead(self):
        _, content = self._start(NOTIFICATIONS_ENABLED="false")
        self.assertNotIn("message here", content)
        self.assertIn("/status", content)

    def test_the_safe_default_is_to_promise_nothing(self):
        # An unset variable must not fall back to promising a message.
        _, content = self._start(NOTIFICATIONS_ENABLED=None)
        self.assertNotIn("message here", content)

    def test_the_server_is_started_either_way(self):
        handler, _ = self._start(NOTIFICATIONS_ENABLED="false")
        self.assertEqual(handler.ec2.started, [[INSTANCE_ID]])


class TestNoPromiseOfAnIdleShutdownThatCannotHappen(unittest.TestCase):
    """idle_timeout_minutes = 0 disables the automatic shutdown entirely.

    Every message that tells somebody to just wait has to check that first, or
    it sends them to wait for something that is never going to happen.
    """

    def _refusal(self, **env):
        handler = _load_handler(**env)
        handler.ec2 = FakeEc2()
        handler.ssm = FakeSsm()
        handler.ec2.state = "running"
        payload = {"type": 2, "data": {"name": "stop"}, "member": {"roles": ["999"]}}
        return _content(handler.lambda_handler(_event(payload), None))

    def test_disabled_stop_mentions_the_idle_shutdown_when_there_is_one(self):
        content = self._refusal(ALLOW_STOP_COMMAND="false", IDLE_TIMEOUT_MINUTES="15")
        self.assertIn("15 minutes", content)

    def test_disabled_stop_stays_quiet_when_there_is_not(self):
        content = self._refusal(ALLOW_STOP_COMMAND="false", IDLE_TIMEOUT_MINUTES="0")
        self.assertIn("disabled", content)
        self.assertNotIn("on its own", content)

    def test_role_refusal_mentions_the_idle_shutdown_when_there_is_one(self):
        content = self._refusal(STOP_ROLE_IDS="111", IDLE_TIMEOUT_MINUTES="20")
        self.assertIn("20 minutes", content)

    def test_role_refusal_stays_quiet_when_there_is_not(self):
        # The branch that had the bug: it promised a shutdown unconditionally.
        content = self._refusal(STOP_ROLE_IDS="111", IDLE_TIMEOUT_MINUTES="0")
        self.assertIn("admins", content)
        self.assertNotIn("on its own", content)

    def test_the_booting_message_does_not_promise_one_either(self):
        handler = _load_handler(IDLE_TIMEOUT_MINUTES="0")
        handler.ec2 = FakeEc2()
        handler.ec2.state = "running"

        class Unreachable(Exception):
            response = {"Error": {"Code": "InvalidInstanceId"}}

        class FailingSsm:
            def send_command(self, **kwargs):
                raise Unreachable()

        handler.ssm = FailingSsm()
        content = _content(
            handler.lambda_handler(_event({"type": 2, "data": {"name": "stop"}}), None)
        )
        self.assertIn("booting", content)
        self.assertNotIn("shut down on its own", content)

if __name__ == "__main__":
    unittest.main()


class AwsError(Exception):
    """Shaped like a botocore ClientError, without importing botocore."""

    def __init__(self, code):
        super().__init__(code)
        self.response = {"Error": {"Code": code, "Message": code}}


class TestAwsErrorHandling(unittest.TestCase):
    def setUp(self):
        self.handler = _load_handler()
        self.ec2 = FakeEc2()
        self.ssm = FakeSsm()
        self.handler.ec2 = self.ec2
        self.handler.ssm = self.ssm

    def _run(self, name):
        return self.handler.lambda_handler(
            _event({"type": 2, "data": {"name": name}}), None
        )

    def test_terminated_instance_is_reported_as_missing(self):
        # describe_instances raises for an unknown ID rather than returning an
        # empty result set, so this is the path that actually fires.
        def gone(**kwargs):
            raise AwsError("InvalidInstanceID.NotFound")

        self.ec2.describe_instances = gone
        self.assertIn("Could not find", _content(self._run("start")))

    def test_malformed_instance_id_is_reported_as_missing(self):
        def gone(**kwargs):
            raise AwsError("InvalidInstanceID.Malformed")

        self.ec2.describe_instances = gone
        self.assertIn("Could not find", _content(self._run("status")))

    def test_other_aws_errors_still_surface_as_a_generic_failure(self):
        def denied(**kwargs):
            raise AwsError("UnauthorizedOperation")

        self.ec2.describe_instances = denied
        with self.assertLogs(self.handler.logger, level="ERROR"):
            response = self._run("status")
        content = _content(response)
        self.assertIn("Something went wrong", content)
        self.assertNotIn("UnauthorizedOperation", content)

    def test_stop_explains_when_the_ssm_agent_is_not_ready_yet(self):
        self.ec2.state = "running"

        def not_ready(**kwargs):
            raise AwsError("InvalidInstanceId")

        self.ssm.send_command = not_ready
        content = _content(self._run("stop"))
        self.assertIn("booting and cannot be reached yet", content)

    def test_other_ssm_errors_are_not_swallowed(self):
        self.ec2.state = "running"

        def denied(**kwargs):
            raise AwsError("AccessDeniedException")

        self.ssm.send_command = denied
        with self.assertLogs(self.handler.logger, level="ERROR"):
            content = _content(self._run("stop"))
        self.assertIn("Something went wrong", content)

    def test_error_code_of_a_plain_exception_is_empty(self):
        self.assertEqual(self.handler._error_code(RuntimeError("boom")), "")
        self.assertEqual(self.handler._error_code(AwsError("X")), "X")

        class Weird(Exception):
            response = "not a dict"

        self.assertEqual(self.handler._error_code(Weird()), "")


class TestMalformedEvents(unittest.TestCase):
    def setUp(self):
        self.handler = _load_handler()
        self.ec2 = FakeEc2()
        self.handler.ec2 = self.ec2
        self.handler.ssm = FakeSsm()

    def test_event_with_no_headers_is_rejected(self):
        self.assertEqual(
            self.handler.lambda_handler({"body": "{}"}, None)["statusCode"], 401
        )

    def test_event_with_null_headers_is_rejected(self):
        self.assertEqual(
            self.handler.lambda_handler(
                {"headers": None, "body": None}, None
            )["statusCode"],
            401,
        )

    def test_a_signed_but_unparseable_body_is_a_400(self):
        timestamp = "1700000000"
        body = "{not json"
        _, signature = _sign(SECRET_KEY, (timestamp + body).encode())
        event = {
            "headers": {
                "x-signature-ed25519": signature.hex(),
                "x-signature-timestamp": timestamp,
            },
            "body": body,
        }
        self.assertEqual(self.handler.lambda_handler(event, None)["statusCode"], 400)

    def test_a_command_with_no_data_key_is_handled(self):
        response = self.handler.lambda_handler(_event({"type": 2}), None)
        self.assertEqual(response["statusCode"], 200)
        self.assertIn("Unknown command", _content(response))

    def test_address_on_a_terminated_instance_is_clear(self):
        def gone(**kwargs):
            raise AwsError("InvalidInstanceID.NotFound")

        self.ec2.describe_instances = gone
        response = self.handler.lambda_handler(
            _event({"type": 2, "data": {"name": "address"}}), None
        )
        data = json.loads(response["body"])["data"]
        self.assertIn("Could not find", data["content"])
        self.assertEqual(data["flags"], 64, "an error should stay private")
