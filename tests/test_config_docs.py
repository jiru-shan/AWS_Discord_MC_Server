"""The configuration reference must describe the variables that actually exist.

docs/configuration.md is generated from terraform/variables.tf. A reference that
can drift is worse than none at all -- it is confidently wrong -- so this fails
the build whenever the checked-in file stops matching what the generator
produces, and whenever the generator stops finding the parts of a variable that
make the reference useful.

Run with: python -m unittest discover -s tests
"""

import os
import sys
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "scripts"))

import generate_config_docs as gen  # noqa: E402


class ConfigDocsAreCurrent(unittest.TestCase):
    def test_checked_in_file_matches_the_generator(self):
        with open(gen.OUTPUT, encoding="utf-8") as handle:
            current = handle.read()
        self.assertEqual(
            current,
            gen.generate(),
            "docs/configuration.md is out of date with terraform/variables.tf. Run: make docs",
        )

    def test_every_variable_appears(self):
        with open(gen.VARIABLES, encoding="utf-8") as handle:
            variables = gen.parse(handle.read())
        rendered = gen.render(variables)

        self.assertGreater(len(variables), 40, "parser found suspiciously few variables")
        for variable in variables:
            self.assertIn(f"### `{variable['name']}`", rendered)


class ParsingVariablesTf(unittest.TestCase):
    """The generator only helps if it reads variables.tf correctly."""

    def setUp(self):
        with open(gen.VARIABLES, encoding="utf-8") as handle:
            self.variables = {v["name"]: v for v in gen.parse(handle.read())}

    def test_a_variable_with_no_default_is_required(self):
        self.assertTrue(self.variables["discord_public_key"]["required"])
        self.assertFalse(self.variables["instance_type"]["required"])

    def test_enumerated_validations_become_a_value_list(self):
        # The thing a reference is actually for: the accepted set is otherwise
        # only discoverable by reading a validation block or triggering it.
        self.assertEqual(
            self.variables["addressing_mode"]["allowed"],
            ["elastic_ip", "route53", "none"],
        )
        self.assertEqual(
            self.variables["server_difficulty"]["allowed"],
            ["peaceful", "easy", "normal", "hard"],
        )

    def test_a_regex_validation_falls_back_to_its_error_message(self):
        self.assertIn("64-character hex", self.variables["discord_public_key"]["constraint"])
        self.assertEqual(self.variables["discord_public_key"]["allowed"], [])

    def test_sensitive_variables_are_marked(self):
        self.assertTrue(self.variables["discord_webhook_url"]["sensitive"])
        self.assertFalse(self.variables["discord_bot_username"]["sensitive"])

    def test_heredoc_descriptions_are_dedented_and_kept_whole(self):
        description = self.variables["addressing_mode"]["description"]
        self.assertTrue(description.startswith("How players reach the server"))
        self.assertIn("  elastic_ip - attach a static IP.", description)

    def test_quoted_descriptions_are_read(self):
        self.assertEqual(
            self.variables["server_port"]["description"], "Port the server listens on."
        )

    def test_variables_are_grouped_by_the_banners_in_the_file(self):
        self.assertEqual(self.variables["instance_type"]["section"], "Compute")
        self.assertEqual(self.variables["addressing_mode"]["section"], "Addressing")
        self.assertEqual(self.variables["discord_public_key"]["section"], "Discord")

    def test_defaults_are_reported_as_written(self):
        self.assertEqual(self.variables["instance_type"]["default"], '"t4g.small"')
        self.assertEqual(self.variables["server_ops"]["default"], "[]")
        self.assertEqual(
            self.variables["server_mods"]["default"],
            '["lithium", "ferrite-core", "krypton"]',
        )


if __name__ == "__main__":
    unittest.main()
