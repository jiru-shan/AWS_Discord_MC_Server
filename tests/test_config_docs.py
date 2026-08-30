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
        # Most descriptions are heredocs; this covers the single-line quoted
        # form, which the parser reads down a different path.
        self.assertEqual(
            self.variables["discord_bot_username"]["description"],
            "Display name on webhook messages.",
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


class BlockBoundaryTestCase(unittest.TestCase):
    """read_blocks() finds the end of a variable by counting braces.

    Quantifier braces inside a validation regex are the case that makes that
    fragile, and two variables here already use them. If the count is thrown
    off, the block ends early and the reference quietly loses whatever came
    after -- including the next variable.
    """

    SOURCE = """
variable "example" {
  description = "A thing."
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^[a-z]{1,64}$", var.example))
    error_message = "must be short and lowercase."
  }
}

variable "after" {
  description = "The one that would go missing."
  type        = string
  default     = ""
}
"""

    def test_quantifier_braces_do_not_truncate_the_block(self):
        blocks = list(gen.read_blocks(self.SOURCE))
        self.assertEqual([name for _s, name, _b in blocks], ["example", "after"])

    def test_the_whole_block_is_captured(self):
        body = next(b for _s, name, b in gen.read_blocks(self.SOURCE) if name == "example")
        self.assertIn("error_message", body)
        self.assertIn("must be short and lowercase.", body)

    def test_the_variables_in_this_repo_all_survive_the_parse(self):
        # The real file, which is what actually has to keep working.
        with open(gen.VARIABLES, encoding="utf-8") as handle:
            source = handle.read()
        declared = sum(1 for line in source.splitlines() if line.startswith('variable "'))
        found = len(list(gen.read_blocks(source)))
        self.assertEqual(found, declared, "a variable was lost while parsing")
