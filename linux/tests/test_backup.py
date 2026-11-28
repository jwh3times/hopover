"""Tests for linux/backup.py, the Backup module on Linux (seam 1 of spec #12): finding, testing and
unpacking Backups. Standard library only, like the module:

python -m unittest discover -s linux/tests

The tests that open a Backup make one with a real 7-Zip: the distro's 7z, 7zz or 7za, or the one
HOPOVER_TEST_7Z names (on Windows, the pinned 7zr.exe). Without one they are skipped, except in CI,
where they fail: CI's Linux runner installs the 7zip package.
"""

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import backup  # noqa: E402
import restore_linux  # noqa: E402

SEVEN_ZIP = os.environ.get("HOPOVER_TEST_7Z") or backup.find_seven_zip()
MANIFEST = (
    '{ "formatVersion": 1, "hopoverVersion": "v0.5.3", "created": "2026-11-27T09:00:00.0000000Z", '
    '"sourceOs": "windows", "computerName": "FIXTURE-PC", "encrypted": true, '
    '"includesPasswordsAndKeys": false, "captured": ["settings"], "groups": ["settings"], "apps": [] }'
)
FILES = {
    "hopover.json": MANIFEST,
    "data/settings/dev/gitconfig": "[user]\n\tname = Fixture User\n",
    "data/settings/windows/Café.txt": "accented file name\n",
    "extras/manifest.json": '{ "Items": [] }',
}
PASSWORD = "correct horse battery"
# A hopover.json from a Hopover newer than this one.
NEWER = MANIFEST.replace('"formatVersion": 1', f'"formatVersion": {backup.FORMAT_VERSION + 1}')


class TempDir(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="hopover-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def folder(self):
        d = self.tmp / uuid.uuid4().hex
        d.mkdir()
        return d


def write_tree(root, files):
    for rel, text in files.items():
        p = Path(root) / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(text, bytes):
            p.write_bytes(text)
        else:
            p.write_text(text, encoding="utf-8", newline="\n")


def tree_of(root):
    """Every file under root, by its path relative to root, with its bytes."""
    root = Path(root)
    return {
        p.relative_to(root).as_posix(): p.read_bytes()
        for p in sorted(root.rglob("*"))
        if p.is_file() and p.name != ".hopover-unpacked.json"
    }


class NeedsSevenZip(TempDir):
    @classmethod
    def setUpClass(cls):
        if not SEVEN_ZIP:
            if os.environ.get("CI"):
                raise RuntimeError("No 7-Zip on this runner: CI installs the 7zip package.")
            raise unittest.SkipTest("no 7-Zip: install the 7zip package, or set HOPOVER_TEST_7Z")

    def make(self, name="Fixture PC", files=None, password=PASSWORD, volume=0, folder=None):
        """A Backup made with 7-Zip directly, the password on its command line (fine in a test),
        so these tests don't depend on how the module passes it."""
        stage = self.folder()
        write_tree(stage, FILES if files is None else files)
        out = folder or self.folder()
        archive = out / (name + backup.SUFFIX)
        cmd = [SEVEN_ZIP, "a", "-t7z", "-sccUTF-8", "-bd", "-y"]
        if password:
            cmd += [f"-p{password}", "-mhe=on"]
        if volume:
            cmd.append(f"-v{volume}b")
        cmd += [str(archive), "*"]
        env = dict(os.environ, LC_ALL="C.UTF-8")
        r = subprocess.run(cmd, cwd=stage, env=env, capture_output=True, stdin=subprocess.DEVNULL)
        self.assertEqual(r.returncode, 0, r.stdout.decode("utf-8", "replace"))
        return Path(f"{archive}.001") if volume else archive


class FindTests(TempDir):
    def test_lists_each_backup_once_by_name_a_split_one_by_its_first_piece_with_all_their_size(
        self,
    ):
        root = self.folder()
        write_tree(
            root,
            {
                "Laptop 2026-11-27.hopover.7z": b"x" * 10,
                "drive/Desk.hopover.7z.001": b"x" * 5,
                "drive/Desk.hopover.7z.002": b"x" * 7,
                # Beside the pieces, but not pieces of that Backup.
                "drive/Desk.hopover.7z.copy.001": b"x" * 300,
                "drive/Desk.hopover.7z.bak": b"x" * 300,
            },
        )
        found = {f.name: f for f in backup.find_backups([root])}
        self.assertEqual(sorted(found), ["Desk", "Laptop 2026-11-27"])
        self.assertEqual(found["Laptop 2026-11-27"].size, 10)
        self.assertFalse(found["Laptop 2026-11-27"].split)
        self.assertEqual(Path(found["Desk"].path), root / "drive" / "Desk.hopover.7z.001")
        self.assertEqual(found["Desk"].size, 12)
        self.assertTrue(found["Desk"].split)

    def test_skips_other_7z_files_later_pieces_and_anything_deeper_than_depth(self):
        root = self.folder()
        write_tree(
            root,
            {
                "photos.7z": b"x",
                "notes.hopover.7z.txt": b"x",
                "Lone.hopover.7z.002": b"x",
                "a/b/Two.hopover.7z": b"x",
                "a/b/c/Deep.hopover.7z": b"x",
            },
        )
        self.assertEqual([f.name for f in backup.find_backups([root])], ["Two"])
        self.assertEqual([f.name for f in backup.find_backups([root], depth=3)], ["Deep", "Two"])

    def test_finds_a_backup_whatever_the_case_of_its_extension(self):
        root = self.folder()
        write_tree(root, {"Old PC.HOPOVER.7Z": b"x"})
        self.assertEqual([f.name for f in backup.find_backups([root])], ["Old PC"])

    def test_passes_over_folders_that_are_not_there(self):
        root = self.folder()
        write_tree(root, {"Here.hopover.7z": b"x"})
        found = backup.find_backups([self.tmp / "not-mounted", root])
        self.assertEqual([f.name for f in found], ["Here"])


class OpenTests(NeedsSevenZip):
    def test_opens_with_its_password_and_refuses_any_other(self):
        b = self.make()
        self.assertEqual(backup.test_backup(b, PASSWORD, SEVEN_ZIP).result, "ok")
        self.assertEqual(
            backup.test_backup(b, "wrong horse battery", SEVEN_ZIP).result, "wrong-password"
        )
        self.assertEqual(backup.test_backup(b, None, SEVEN_ZIP).result, "password-needed")

    def test_takes_a_password_with_accented_and_non_latin_letters(self):
        pw = "pässwörd-日本"
        b = self.make(password=pw)
        self.assertEqual(backup.test_backup(b, pw, SEVEN_ZIP).result, "ok")
        self.assertEqual(backup.test_backup(b, "passwörd-日本", SEVEN_ZIP).result, "wrong-password")

    def test_opens_an_unprotected_backup_with_no_password(self):
        b = self.make(password=None)
        self.assertEqual(backup.test_backup(b, None, SEVEN_ZIP).result, "ok")

    def test_tells_a_missing_backup_from_a_damaged_one(self):
        self.assertEqual(
            backup.test_backup(self.tmp / "gone.hopover.7z", PASSWORD, SEVEN_ZIP).result, "missing"
        )
        junk = self.tmp / "junk.hopover.7z"
        junk.write_bytes(b"not a 7-Zip archive at all" * 40)
        self.assertEqual(backup.test_backup(junk, PASSWORD, SEVEN_ZIP).result, "damaged")

    def test_opens_a_split_backup_from_its_first_piece(self):
        files = dict(FILES, **{"extras/big.bin": os.urandom(60_000)})
        first = self.make(files=files, volume=20_000)
        self.assertTrue(first.name.endswith(".hopover.7z.001"))
        self.assertTrue(Path(str(first)[:-4] + ".003").exists())
        self.assertEqual(backup.test_backup(first, PASSWORD, SEVEN_ZIP).result, "ok")


class ManifestTests(NeedsSevenZip):
    def test_reads_hopover_json_without_unpacking_anything(self):
        b = self.make()
        checked = backup.read_manifest(b, PASSWORD, SEVEN_ZIP)
        self.assertEqual(checked.result, "ok")
        self.assertEqual(checked.raw, MANIFEST.encode("utf-8"))
        self.assertEqual(checked.manifest["computerName"], "FIXTURE-PC")
        self.assertEqual(sorted(p.name for p in b.parent.iterdir()), [b.name])

    def test_says_an_encrypted_backup_needs_its_password_and_a_wrong_one_does_not_open_it(self):
        b = self.make()
        needed = backup.read_manifest(b, None, SEVEN_ZIP)
        self.assertEqual(needed.result, "password-needed")
        self.assertIn("needs its password", needed.message)
        wrong = backup.read_manifest(b, "nope", SEVEN_ZIP)
        self.assertEqual(wrong.result, "wrong-password")
        self.assertIn('That password doesn\'t open the Backup "Fixture PC"', wrong.message)

    def test_refuses_a_backup_made_by_a_newer_hopover(self):
        b = self.make(files=dict(FILES, **{"hopover.json": NEWER}))
        checked = backup.read_manifest(b, PASSWORD, SEVEN_ZIP)
        self.assertEqual(checked.result, "newer")
        self.assertIn("made by a newer Hopover", checked.message)

    def test_calls_a_hopover_json_whose_format_version_is_not_a_number_damaged(self):
        odd = MANIFEST.replace('"formatVersion": 1', '"formatVersion": "one"')
        b = self.make(files=dict(FILES, **{"hopover.json": odd}))
        self.assertEqual(backup.read_manifest(b, PASSWORD, SEVEN_ZIP).result, "damaged")

    def test_calls_a_hopover_json_whose_format_version_is_true_or_false_damaged(self):
        odd = MANIFEST.replace('"formatVersion": 1', '"formatVersion": true')
        b = self.make(files=dict(FILES, **{"hopover.json": odd}))
        self.assertEqual(backup.read_manifest(b, PASSWORD, SEVEN_ZIP).result, "damaged")

    def test_calls_an_archive_without_a_hopover_json_damaged(self):
        b = self.make(files={"photo.txt": "not a Backup"})
        self.assertEqual(backup.read_manifest(b, PASSWORD, SEVEN_ZIP).result, "damaged")


class ExpandTests(NeedsSevenZip):
    def setUp(self):
        super().setUp()
        self.root = self.tmp / "restore"

    def test_unpacks_a_backup_into_a_folder_named_after_it(self):
        b = self.make()
        out = backup.expand_backup(b, PASSWORD, self.root, seven_zip=SEVEN_ZIP)
        self.assertEqual(Path(out.folder), self.root / "Fixture PC")
        self.assertFalse(out.reused)
        self.assertEqual(out.manifest["computerName"], "FIXTURE-PC")
        expected = {k: v.encode("utf-8") for k, v in FILES.items()}
        self.assertEqual(tree_of(out.folder), expected)

    def test_reuses_the_unpacked_copy_on_a_rerun_instead_of_unpacking_again(self):
        b = self.make()
        first = backup.expand_backup(b, PASSWORD, self.root, seven_zip=SEVEN_ZIP)
        (Path(first.folder) / "left by the first run.txt").write_text("x", encoding="utf-8")
        checked = backup.read_manifest(b, PASSWORD, SEVEN_ZIP)
        self.assertEqual(backup.unpacked_backup(b, checked, self.root), first.folder)
        again = backup.expand_backup(b, PASSWORD, self.root, seven_zip=SEVEN_ZIP)
        self.assertTrue(again.reused)
        self.assertTrue((Path(again.folder) / "left by the first run.txt").exists())

    def test_stops_on_a_wrong_password_in_plain_words_before_unpacking_anything(self):
        b = self.make()
        with self.assertRaisesRegex(backup.BackupError, "That password doesn't open"):
            backup.expand_backup(b, "nope", self.root, seven_zip=SEVEN_ZIP)
        self.assertFalse(self.root.exists())

    def test_refuses_a_backup_made_by_a_newer_hopover_before_unpacking_anything(self):
        b = self.make(files=dict(FILES, **{"hopover.json": NEWER}))
        with self.assertRaisesRegex(backup.BackupError, "newer Hopover"):
            backup.expand_backup(b, PASSWORD, self.root, seven_zip=SEVEN_ZIP)
        self.assertFalse(self.root.exists())

    def test_never_replaces_a_folder_of_that_name_that_hopover_did_not_unpack(self):
        b = self.make()
        mine = self.root / "Fixture PC"
        write_tree(mine, {"hopover.json": MANIFEST, "my notes.txt": "keep me"})
        with self.assertRaisesRegex(backup.BackupError, "in the way"):
            backup.expand_backup(b, PASSWORD, self.root, seven_zip=SEVEN_ZIP)
        self.assertEqual((mine / "my notes.txt").read_text(encoding="utf-8"), "keep me")

    def test_unpacks_again_over_its_own_copy_that_an_earlier_run_left_half_done(self):
        b = self.make()
        half = self.root / "Fixture PC"
        # The marker names this very Backup: only "complete" says the copy can't be reused.
        marker = {"backup": backup.backup_identity(MANIFEST.encode("utf-8")), "complete": False}
        write_tree(half, {backup.MARKER: json.dumps(marker), "partial.bin": "x"})
        out = backup.expand_backup(b, PASSWORD, self.root, seven_zip=SEVEN_ZIP)
        self.assertFalse(out.reused)
        self.assertFalse((half / "partial.bin").exists())
        self.assertTrue((half / "data" / "settings" / "dev" / "gitconfig").exists())

    def test_unpacks_afresh_when_a_different_backup_with_the_same_name_comes_along(self):
        first = self.make()
        backup.expand_backup(first, PASSWORD, self.root, seven_zip=SEVEN_ZIP)
        other = MANIFEST.replace("FIXTURE-PC", "OTHER-PC")
        second = self.make(files=dict(FILES, **{"hopover.json": other}))
        out = backup.expand_backup(second, PASSWORD, self.root, seven_zip=SEVEN_ZIP)
        self.assertFalse(out.reused)
        self.assertEqual(out.manifest["computerName"], "OTHER-PC")

    def test_removes_what_it_unpacked_when_7zip_fails_part_way(self):
        good = self.make()
        checked = backup.read_manifest(good, PASSWORD, SEVEN_ZIP)
        broken = self.folder() / good.name
        broken.write_bytes(good.read_bytes()[: good.stat().st_size // 2])
        with self.assertRaisesRegex(backup.BackupError, "couldn't unpack"):
            backup.expand_backup(broken, PASSWORD, self.root, checked=checked, seven_zip=SEVEN_ZIP)
        self.assertFalse((self.root / "Fixture PC").exists())

    def test_unpacks_a_split_backup_from_its_first_piece(self):
        big = os.urandom(60_000)
        first = self.make(files=dict(FILES, **{"extras/big.bin": big}), volume=20_000)
        out = backup.expand_backup(first, PASSWORD, self.root, seven_zip=SEVEN_ZIP)
        self.assertEqual(Path(out.folder).name, "Fixture PC")
        self.assertEqual((Path(out.folder) / "extras" / "big.bin").read_bytes(), big)

    @unittest.skipIf(os.name != "posix", "POSIX permissions")
    def test_keeps_the_unpacked_copy_readable_by_this_user_only(self):
        out = backup.expand_backup(self.make(), PASSWORD, self.root, seven_zip=SEVEN_ZIP)
        self.assertEqual(os.stat(out.folder).st_mode & 0o077, 0)

    @unittest.skipIf(os.name != "posix", "Windows finds the home folder another way")
    def test_the_restore_root_is_under_the_users_local_share(self):
        home = self.folder()
        with unittest.mock.patch.dict(os.environ, {"HOME": str(home)}, clear=False):
            os.environ.pop("XDG_DATA_HOME", None)
            self.assertEqual(
                backup.restore_root(), home / ".local" / "share" / "hopover" / "restore"
            )
            os.environ["XDG_DATA_HOME"] = str(home / "data")
            self.assertEqual(backup.restore_root(), home / "data" / "hopover" / "restore")


STUB = r"""
import json, os, sys
record, args = sys.argv[1], sys.argv[2:]
stdin = sys.stdin.buffer.read().decode("utf-8")
entry = {"args": args, "stdin": stdin, "lc_all": os.environ.get("LC_ALL")}
if hasattr(os, "getsid"):
    entry["session_leader"] = os.getsid(0) == os.getpid()
with open(record, "a", encoding="utf-8") as f:
    f.write(json.dumps(entry) + "\n")
if os.environ.get("STUB_PROMPTS"):
    # A 7-Zip whose prompt for a password read nothing, and says only that it asked.
    sys.stdout.write("Enter password (will not be echoed):\n")
    sys.exit(2)
if "-so" in args:
    sys.stdout.write('{"formatVersion": 1}')
"""


class PasswordTests(TempDir):
    """A 7-Zip stand-in that records its arguments and standard input."""

    def setUp(self):
        super().setUp()
        stub = self.tmp / "seven_zip_stub.py"
        stub.write_text(STUB, encoding="utf-8")
        self.record = self.tmp / "record.jsonl"
        self.seven_zip = [sys.executable, str(stub), str(self.record)]
        self.backup = self.tmp / "Stub PC.hopover.7z"
        self.backup.write_bytes(b"stand-in")

    def runs(self):
        lines = self.record.read_text(encoding="utf-8").splitlines()
        return [json.loads(x) for x in lines]

    def open_everything(self, password):
        backup.test_backup(self.backup, password, self.seven_zip)
        backup.read_manifest(self.backup, password, self.seven_zip)
        backup.expand_backup(self.backup, password, self.tmp / "restore", seven_zip=self.seven_zip)
        runs = self.runs()
        self.assertEqual([r["args"][0] for r in runs], ["t", "e", "e", "x"])
        return runs

    def test_gives_7zip_the_password_on_standard_input_when_testing_and_unpacking(self):
        for r in self.open_everything("s3cret-pässwörd"):
            self.assertEqual(r["stdin"], "s3cret-pässwörd\n")

    def test_never_puts_the_password_on_7zips_command_line(self):
        for r in self.open_everything("s3cret-pässwörd"):
            self.assertFalse([a for a in r["args"] if "s3cret" in a], r["args"])

    def test_passes_no_p_where_a_bare_p_would_mean_an_empty_password(self):
        for r in self.open_everything("s3cret-pässwörd"):
            self.assertFalse([a for a in r["args"] if a.startswith("-p")], r["args"])

    def test_closes_standard_input_at_once_when_there_is_no_password(self):
        for r in self.open_everything(None):
            self.assertEqual(r["stdin"], "")

    def test_runs_7zip_in_a_utf8_locale_so_p7zip_reads_the_password_as_typed(self):
        for r in self.open_everything("pw"):
            self.assertEqual(r["lc_all"], "C.UTF-8")

    def test_a_7zip_that_only_says_it_asked_for_a_password_needs_one(self):
        with unittest.mock.patch.dict(os.environ, {"STUB_PROMPTS": "1"}):
            self.assertEqual(
                backup.test_backup(self.backup, None, self.seven_zip).result, "password-needed"
            )

    @unittest.skipIf(os.name != "posix", "sessions are POSIX")
    def test_runs_7zip_in_a_session_of_its_own_so_p7zip_cannot_read_the_terminal(self):
        for r in self.open_everything("pw"):
            self.assertTrue(r["session_leader"])


@unittest.skipIf(os.name != "posix", "finds commands on a POSIX PATH")
class FindSevenZipTests(TempDir):
    def path_with(self, *names):
        bin_dir = self.folder()
        for n in names:
            p = bin_dir / n
            p.write_text("#!/bin/sh\n", encoding="utf-8")
            p.chmod(0o755)
        return str(bin_dir)

    def test_finds_7z_7zz_or_7za_in_that_order(self):
        for names, want in (
            (("7za", "7zz", "7z"), "7z"),
            (("7za", "7zz"), "7zz"),
            (("7za",), "7za"),
        ):
            with unittest.mock.patch.dict(os.environ, {"PATH": self.path_with(*names)}):
                self.assertEqual(Path(backup.find_seven_zip()).name, want)

    def test_finds_nothing_when_no_7zip_is_installed(self):
        with unittest.mock.patch.dict(os.environ, {"PATH": self.path_with("7zr")}):
            self.assertIsNone(backup.find_seven_zip())


class RestoreFromBackupTests(NeedsSevenZip):
    """restore_linux.py opening the Backup it restores from."""

    def setUp(self):
        super().setUp()
        self.root = self.tmp / "restore"
        self.asked = []
        quiet = contextlib.redirect_stdout(io.StringIO())
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)

    def ask(self, answer):
        def ask(prompt):
            self.asked.append(prompt)
            return answer

        return ask

    def open(self, b, dry_run=False, answer=PASSWORD):
        opened = restore_linux.open_backup(
            b, dry_run, ask=self.ask(answer), root=self.root, seven_zip=SEVEN_ZIP
        )
        self.addCleanup(restore_linux.close_backup, opened)
        return opened

    def test_a_restore_runs_against_the_copy_unpacked_into_the_restore_root(self):
        opened = self.open(self.make())
        self.assertEqual(Path(opened.folder), self.root / "Fixture PC")
        self.assertFalse(opened.temporary)
        self.assertTrue((Path(opened.folder) / "data" / "settings" / "dev" / "gitconfig").exists())
        self.assertEqual(self.asked, ["Password for Fixture PC"])

    def test_a_rerun_reuses_the_copy(self):
        b = self.make()
        first = self.open(b)
        (Path(first.folder) / "rerun.txt").write_text("x", encoding="utf-8")
        again = self.open(b)
        self.assertEqual(again.folder, first.folder)
        self.assertTrue((Path(again.folder) / "rerun.txt").exists())

    def test_a_dry_run_unpacks_into_a_temporary_copy_it_removes_and_leaves_the_restore_root_alone(
        self,
    ):
        opened = restore_linux.open_backup(
            self.make(), True, ask=self.ask(PASSWORD), root=self.root, seven_zip=SEVEN_ZIP
        )
        self.assertTrue(opened.temporary)
        self.assertTrue((Path(opened.folder) / "data").is_dir())
        self.assertFalse(self.root.exists())
        restore_linux.close_backup(opened)
        self.assertFalse(Path(opened.folder).exists())

    def test_closing_a_real_restore_keeps_its_copy_and_the_restore_root_for_the_next_run(self):
        opened = self.open(self.make())
        restore_linux.close_backup(opened)
        self.assertTrue((Path(opened.folder) / "hopover.json").exists())
        self.assertTrue(self.root.is_dir())

    def test_an_unprotected_backup_is_opened_without_asking_for_a_password(self):
        opened = self.open(self.make(password=None))
        self.assertEqual(self.asked, [])
        self.assertTrue((Path(opened.folder) / "hopover.json").exists())

    def test_a_wrong_password_stops_the_restore_before_anything_is_unpacked(self):
        with self.assertRaisesRegex(backup.BackupError, "That password doesn't open"):
            self.open(self.make(), answer="nope")
        self.assertFalse(self.root.exists())

    def test_a_backup_made_by_a_newer_hopover_stops_the_restore_before_anything_is_unpacked(self):
        with self.assertRaisesRegex(backup.BackupError, "newer Hopover"):
            self.open(self.make(files=dict(FILES, **{"hopover.json": NEWER})), dry_run=True)
        self.assertFalse(self.root.exists())


class ReadPasswordTests(unittest.TestCase):
    def piped(self, data):
        stdin = unittest.mock.Mock()
        stdin.isatty.return_value = False
        stdin.buffer = io.BytesIO(data)
        return unittest.mock.patch.object(sys, "stdin", stdin)

    def test_reads_one_line_piped_in_as_utf8(self):
        with self.piped("pässwörd\nnext line\n".encode()):
            self.assertEqual(backup.read_password("Password"), "pässwörd")

    def test_drops_the_bom_windows_powershell_puts_in_front_of_piped_text(self):
        with self.piped("\ufeffcorrect horse\r\n".encode()):
            self.assertEqual(backup.read_password("Password"), "correct horse")

    def test_gives_nothing_for_an_empty_line(self):
        with self.piped(b"\n"):
            self.assertIsNone(backup.read_password("Password"))


class NameTests(unittest.TestCase):
    def test_a_backup_is_named_by_its_file_without_the_extension(self):
        self.assertEqual(
            backup.backup_name("/media/u/E/Laptop 2026-11-27.hopover.7z"), "Laptop 2026-11-27"
        )
        self.assertEqual(backup.backup_name("/media/u/E/Laptop.hopover.7z.001"), "Laptop")

    def test_a_renamed_backup_keeps_its_own_name_less_the_extension(self):
        self.assertEqual(backup.backup_name("/home/u/Downloads/my stuff.7z"), "my stuff")

    def test_a_name_with_nothing_usable_left_is_backup(self):
        self.assertEqual(backup.backup_name("/tmp/.hopover.7z"), "Backup")


if __name__ == "__main__":
    unittest.main()
