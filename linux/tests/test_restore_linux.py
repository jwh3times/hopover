"""Unit tests for linux/restore_linux.py. Standard library only, like the script:

python -m unittest discover -s linux/tests
"""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

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

    def test_id_key_wins_over_bare_id(self):
        spec = {"id:ubuntu": "x", "ubuntu": "y"}
        self.assertEqual(restore_linux.pick(spec, UBUNTU), "x")

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


class LoadOptionsTests(unittest.TestCase):
    """Options: the data folder's config.json, then ~/.config/hopover/options.json over it."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.data = root / "data"
        self.data.mkdir()
        self.config_home = root / "config"
        (self.config_home / "hopover").mkdir(parents=True)
        self.options_file = self.config_home / "hopover" / "options.json"
        env = mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": str(self.config_home)})
        env.start()
        self.addCleanup(env.stop)
        self.addCleanup(self.tmp.cleanup)

    def write(self, path, obj):
        path.write_text(json.dumps(obj), encoding="utf-8")

    def test_no_files_means_no_options(self):
        self.assertEqual(restore_linux.load_options(self.data), {})

    def test_reads_options_json_from_the_config_folder(self):
        self.write(self.options_file, {"devRoot": "D:\\code", "linux": {"aur": "never"}})
        opt = restore_linux.load_options(self.data)
        self.assertEqual(opt["devRoot"], "D:\\code")
        self.assertEqual(opt["linux"], {"aur": "never"})

    def test_reads_config_json_when_there_is_no_options_json(self):
        self.write(self.data / "config.json", {"migrationRoot": "E:\\Hopover"})
        self.assertEqual(restore_linux.load_options(self.data)["migrationRoot"], "E:\\Hopover")

    def test_options_json_wins_key_by_key_one_level_deep(self):
        self.write(
            self.data / "config.json",
            {"devRoot": "D:\\code", "linux": {"aur": "never", "nodeMajor": 22}, "_comment": "x"},
        )
        self.write(
            self.options_file,
            {"linux": {"aur": "auto", "_aur": "y", "$id": "w"}, "$schema": "z"},
        )
        opt = restore_linux.load_options(self.data)
        self.assertEqual(opt["devRoot"], "D:\\code")
        self.assertEqual(opt["linux"], {"aur": "auto", "nodeMajor": 22})
        self.assertNotIn("_comment", opt)
        self.assertNotIn("$schema", opt)

    def test_reads_the_options_file_hopover_options_names(self):
        # As the elevated helper does: it runs as whoever approved the prompt, not the user.
        self.write(self.options_file, {"devRoot": "/admin"})
        users = Path(self.tmp.name) / "users-options.json"
        self.write(users, {"devRoot": "/work"})
        with mock.patch.dict(os.environ, {"HOPOVER_OPTIONS": str(users)}):
            self.assertEqual(restore_linux.options_path(), users)
            self.assertEqual(restore_linux.load_options(self.data)["devRoot"], "/work")

    def test_defaults_to_dot_config_without_xdg_config_home(self):
        home = Path(self.tmp.name) / "home"
        (home / ".config" / "hopover").mkdir(parents=True)
        self.write(home / ".config" / "hopover" / "options.json", {"repoDepth": 4})
        with mock.patch.dict(os.environ, {"HOME": str(home), "USERPROFILE": str(home)}):
            os.environ.pop("XDG_CONFIG_HOME")
            self.assertEqual(restore_linux.load_options(self.data)["repoDepth"], 4)


if __name__ == "__main__":
    unittest.main()
