import unittest

from release_notes import section_for


class ReleaseNotesTests(unittest.TestCase):
    NOTES = (
        "# ForgeSign 2.9.0\n\n"
        "## What's new in 2.9.0\n\n- New thing.\n\n"
        "## Validation\n\nTests pass.\n\n"
        "## What's new in 2.8.6\n\n- Older thing.\n"
    )

    def test_publishes_only_the_current_section(self):
        notes = section_for("2.9.0", self.NOTES)
        self.assertIn("New thing.", notes)
        self.assertIn("Tests pass.", notes)
        self.assertNotIn("Older thing.", notes)

    def test_refuses_a_file_for_another_version(self):
        with self.assertRaisesRegex(ValueError, "must start with '# ForgeSign 2.9.1'"):
            section_for("2.9.1", self.NOTES)


if __name__ == "__main__":
    unittest.main()
