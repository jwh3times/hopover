"""Unit tests for linux/restore_linux.py. Standard library only, like the script:

python -m unittest discover -s linux/tests
"""

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import restore_linux  # noqa: E402

UBUNTU = SimpleNamespace(id="ubuntu", base="debian", family="apt")
FEDORA = SimpleNamespace(id="fedora", base="fedora", family="dnf")


class PickTests(unittest.TestCase):
    def test_plain_value_applies_everywhere(self):
        self.assertEqual(restore_linux.pick("git", UBUNTU), "git")

    def test_distro_id_wins_over_family_and_default(self):
        spec = {"ubuntu": "a", "apt": "b", "default": "c"}
        self.assertEqual(restore_linux.pick(spec, UBUNTU), "a")

    def test_falls_back_to_default(self):
        spec = {"apt": "b", "default": "c"}
        self.assertEqual(restore_linux.pick(spec, FEDORA), "c")

    def test_no_match_is_none(self):
        self.assertIsNone(restore_linux.pick({"apt": "b"}, FEDORA))

    def test_any_spec_is_returned_whole(self):
        spec = {"any": ["a", "b"]}
        self.assertEqual(restore_linux.pick(spec, UBUNTU), spec)


class NamesOfTests(unittest.TestCase):
    def test_shapes(self):
        self.assertEqual(restore_linux.names_of("git"), ("all", ["git"]))
        self.assertEqual(restore_linux.names_of(["a", "b"]), ("all", ["a", "b"]))
        self.assertEqual(restore_linux.names_of({"any": ["a", "b"]}), ("any", ["a", "b"]))
        self.assertIsNone(restore_linux.names_of(None))
        self.assertIsNone(restore_linux.names_of({"apt": "x"}))


class KindOfTests(unittest.TestCase):
    def test_first_known_method_key(self):
        self.assertEqual(restore_linux.kind_of({"distro": "git", "flatpak": "x"}), "distro")
        self.assertIsNone(restore_linux.kind_of({"note": "manual"}))


if __name__ == "__main__":
    unittest.main()
