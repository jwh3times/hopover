"""
backup.py: the Backup module on Linux (docs/adr/0002-one-encrypted-backup-file.md), the Python
twin of lib/Backup.ps1. It finds, tests and unpacks Backups; making one comes with the Linux
capture. Standard library only, Python 3.10+, like restore_linux.py, which uses it.

7-Zip is the distro's: the 7zip package's 7z (7zz on Ubuntu 22.04 and Debian 12), or p7zip's 7za.
The password always goes in on standard input, never on 7-Zip's command line.

    python3 linux/backup.py find <folder>...          # list the Backups under these folders
    python3 linux/backup.py test <Backup>             # password on standard input, or typed
    python3 linux/backup.py unpack <Backup> [--restore-root <folder>]
"""

import argparse
import getpass
import hashlib
import json
import os
import shutil
import subprocess
import sys
from collections import namedtuple
from datetime import datetime, timezone
from pathlib import Path

# The suffix every Backup's file name ends with (split Backups add .001, .002, ...).
SUFFIX = ".hopover.7z"

# The hopover.json format this Hopover can restore, the newest first. Every older one stays
# readable; raise this only with a reader for the new format. lib/Backup.ps1 has the same number.
FORMAT_VERSION = 1

# 7-Zip's command, in the order they're looked for: the 7zip package's 7z, its 7zz on Ubuntu 22.04
# and Debian 12, then p7zip's 7za (Fedora 41 and 42 have no 7zip package).
SEVEN_ZIP_COMMANDS = ("7z", "7zz", "7za")

# The file in an unpacked copy that says which Backup it is and whether unpacking finished.
MARKER = ".hopover-unpacked.json"

Found = namedtuple("Found", "name path size split modified")
Tested = namedtuple("Tested", "result message")
Checked = namedtuple("Checked", "result manifest raw message")
Unpacked = namedtuple("Unpacked", "folder manifest reused")
# A 7-Zip run: its exit code, everything it printed as text (standard output, then standard
# error), and its standard output as bytes (a file it streamed with -so). The names follow
# Invoke-SevenZip's ExitCode, Output and Stdout.
Run = namedtuple("Run", "code output stdout")


class BackupError(Exception):
    """A Backup that can't be opened or unpacked, said in plain words."""


def find_seven_zip():
    """The path of the 7-Zip command installed here, or None."""
    for name in SEVEN_ZIP_COMMANDS:
        path = shutil.which(name)
        if path:
            return path
    return None


def read_password(prompt="Password"):
    """A Backup's password: one line from standard input when a program pipes it in, else typed
    once. Windows PowerShell 5.1 on a UTF-8 console puts a BOM in front of what it pipes: it isn't
    part of the password. None for an empty line."""
    if sys.stdin is None:
        return None
    if not sys.stdin.isatty():
        line = sys.stdin.buffer.readline().decode("utf-8", "replace")
        text = line.rstrip("\r\n").lstrip("\ufeff")
        return text or None
    return getpass.getpass(f"{prompt}: ") or None


def run_seven_zip(seven_zip, args, password=None, cwd=None):
    """Runs 7-Zip with the password, if any, as one UTF-8 line on its standard input: never on its
    command line, where other programs could read it. With no password, standard input is closed
    at once, so a prompt for one ends the run instead of waiting.

    7-Zip runs in a session of its own, with no terminal: p7zip reads a password from the terminal
    when there is one, and would wait there instead of reading standard input. It runs in a UTF-8
    locale too: p7zip in the C locale reads a non-ASCII password as other letters, which open
    nothing made on Windows. `seven_zip` is a path, or a command as a list (for tests)."""
    cmd = [*seven_zip, *args] if isinstance(seven_zip, (list, tuple)) else [str(seven_zip), *args]
    data = (password + "\n").encode("utf-8") if password else b""
    env = dict(os.environ, LC_ALL="C.UTF-8")
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=cwd,
        env=env,
        start_new_session=True,
    )
    try:
        out, err = proc.communicate(data)
    except BaseException:
        # Stopped part-way (Ctrl+C, an error): don't leave 7-Zip writing on its own.
        proc.kill()
        proc.wait()
        raise
    text = out.decode("utf-8", "replace") + err.decode("utf-8", "replace")
    return Run(proc.returncode, text, out)


def seven_zip_result(run, password):
    """What a 7-Zip run on a Backup came to: ok, wrong-password, password-needed or damaged.
    With no password, 7-Zip says "Break signaled" (its prompt read nothing) and p7zip says
    "Wrong password"."""
    if run.code == 0:
        return "ok"
    if "Wrong password" in run.output:
        return "wrong-password" if password else "password-needed"
    if "Break signaled" in run.output or "Enter password" in run.output:
        return "password-needed"
    return "damaged"


def seven_zip_words(run, last=0):
    """7-Zip's own words about a run, for a message: its error lines, or with `last` its final
    lines."""
    lines = [x.strip() for x in run.output.strip().splitlines() if x.strip()]
    pick = lines[-last:] if last else [x for x in lines if "error" in x.lower()][:3]
    return " ".join(pick)


def need_seven_zip(seven_zip):
    seven_zip = seven_zip or find_seven_zip()
    if not seven_zip:
        raise BackupError(
            "No 7-Zip here (7z, 7zz or 7za): install the distro's 7zip package "
            "(p7zip on Fedora 41 and 42), or run linux/restore-linux.sh, which installs it."
        )
    return seven_zip


def test_backup(path, password=None, seven_zip=None):
    """Opens a Backup and checks every file in it. Result: ok, wrong-password, password-needed,
    missing, or damaged (with 7-Zip's words in the message)."""
    if not Path(path).is_file():
        return Tested("missing", f"No file at {path}")
    run = run_seven_zip(need_seven_zip(seven_zip), ["t", "-sccUTF-8", "-bd", str(path)], password)
    return Tested(seven_zip_result(run, password), seven_zip_words(run, last=3))


# Keep unittest from taking the module's test_backup for a test when a test imports it by name.
test_backup.__test__ = False


def read_manifest(path, password=None, seven_zip=None):
    """Reads a Backup's hopover.json without unpacking anything (7-Zip streams it to standard
    output). Result: ok (with the manifest and raw, its exact bytes), wrong-password,
    password-needed, missing, damaged, or newer when a newer Hopover made it; the message says it
    in plain words."""
    name = backup_name(path)
    if not Path(path).is_file():
        return Checked("missing", None, None, f"There is no Backup at {path}.")
    run = run_seven_zip(
        need_seven_zip(seven_zip),
        ["e", "-so", "-sccUTF-8", "-bd", str(path), "hopover.json"],
        password,
    )
    result = seven_zip_result(run, password)
    manifest = None
    if result == "ok":
        try:
            manifest = json.loads(run.stdout.decode("utf-8-sig"))
        except ValueError:
            manifest = None
        version = format_version(manifest)
        if version is None:
            result = "damaged"
        elif version > FORMAT_VERSION:
            result = "newer"
    message = {
        "ok": f"{name} opens.",
        "wrong-password": f'That password doesn\'t open the Backup "{name}".',
        "password-needed": f'The Backup "{name}" is encrypted: it needs its password.',
        "newer": "This Backup was made by a newer Hopover; download the latest.",
    }.get(result) or f"{path} isn't a Backup Hopover can open: {seven_zip_words(run, last=2)}"
    return Checked(result, manifest, run.stdout, message)


def open_manifest(path, ask=read_password, seven_zip=None):
    """read_manifest, asking for the password (ask(prompt) returns it) only when the Backup is
    encrypted. Returns the result and the password given, if any."""
    password = None
    checked = read_manifest(path, None, seven_zip)
    if checked.result == "password-needed":
        password = ask(f"Password for {backup_name(path)}")
        checked = read_manifest(path, password, seven_zip)
    return checked, password


def format_version(manifest):
    """A hopover.json's formatVersion as a whole number, or None when it has none. Read the way
    lib/Backup.ps1 reads it: a number, or a string of digits."""
    v = manifest.get("formatVersion") if isinstance(manifest, dict) else None
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v
    if isinstance(v, str) and v.strip().isdigit():
        return int(v.strip())
    return None


def restore_root():
    """Where Backups are unpacked on Linux: $XDG_DATA_HOME/hopover/restore (~/.local/share)."""
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "share"
    )
    return Path(base) / "hopover" / "restore"


def unpack_folder(path, root=None):
    """Where a Backup is (or would be) unpacked: <restore root>/<its name>."""
    return Path(root or restore_root()) / backup_name(path)


def backup_identity(raw):
    """Which Backup a hopover.json belongs to: the SHA-256 of its exact bytes, as lib/Backup.ps1
    writes it in the marker."""
    return hashlib.sha256(raw).hexdigest().upper()


def read_marker(folder):
    try:
        with open(Path(folder) / MARKER, encoding="utf-8-sig") as f:
            m = json.load(f)
        return m if isinstance(m, dict) else None
    except (OSError, ValueError):
        return None


def write_marker(folder, marker):
    with open(Path(folder) / MARKER, "w", encoding="utf-8", newline="\n") as f:
        json.dump(marker, f, indent=2)


def unpacked_backup(path, checked, root=None):
    """The complete unpacked copy of this Backup, if an earlier run left one; None otherwise.
    `checked` is read_manifest's ok result for it. Unpacks nothing."""
    folder = unpack_folder(path, root)
    m = read_marker(folder)
    if m and m.get("complete") and m.get("backup") == backup_identity(checked.raw):
        return str(folder)
    return None


def expand_backup(path, password=None, root=None, checked=None, seven_zip=None):
    """Unpacks a Backup into <restore root>/<its name>, for the restore to run against. Refuses a
    wrong password or a newer Backup before unpacking anything. A rerun for the same Backup reuses
    the complete copy (reused). A different Backup with the same name, or a copy an earlier run
    left half-done, is unpacked again. Only a folder carrying Hopover's marker is ever replaced:
    the marker is written before unpacking starts and marked complete when it ends. The copy holds
    the Backup's files unencrypted, so only this user can read it. `checked` passes in a
    read_manifest result the caller already has, so hopover.json isn't read twice."""
    seven_zip = need_seven_zip(seven_zip)
    if checked is None:
        checked = read_manifest(path, password, seven_zip)
    if checked.result != "ok":
        raise BackupError(checked.message)

    folder = unpack_folder(path, root)
    if unpacked_backup(path, checked, root):
        return Unpacked(str(folder), checked.manifest, True)
    if folder.exists():
        if not (folder / MARKER).exists():
            raise BackupError(
                f"{folder} is in the way and wasn't unpacked by Hopover; move it, then try again."
            )
        shutil.rmtree(folder)
    folder.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    folder.mkdir(mode=0o700)
    marker = {
        "backup": backup_identity(checked.raw),
        "from": str(path),
        "complete": False,
        "unpacked": None,
    }
    write_marker(folder, marker)
    done = False
    try:
        run = run_seven_zip(
            seven_zip, ["x", "-y", "-sccUTF-8", "-bd", f"-o{folder}", str(path)], password
        )
        if run.code != 0:
            raise BackupError(
                f"7-Zip couldn't unpack the Backup (exit {run.code}): {seven_zip_words(run)}"
            )
        marker["complete"] = True
        marker["unpacked"] = datetime.now(timezone.utc).isoformat()
        write_marker(folder, marker)
        done = True
    finally:
        # Failed or stopped part-way: a half copy is no use, and it holds unencrypted files.
        if not done:
            shutil.rmtree(folder, ignore_errors=True)
    return Unpacked(str(folder), checked.manifest, False)


def backup_name(path):
    """The Backup's name: its file name without .hopover.7z (or .hopover.7z.001); a renamed file
    keeps its own name, less the extension. Safe as a folder name; "Backup" when nothing usable is
    left."""
    leaf = Path(path).name
    name = None
    for end in (SUFFIX + ".001", SUFFIX):
        if leaf.lower().endswith(end):
            name = leaf[: len(leaf) - len(end)]
            break
    if name is None:
        stem = leaf[:-4] if len(leaf) > 4 and leaf[-4] == "." and leaf[-3:].isdigit() else leaf
        name = stem.rsplit(".", 1)[0] if "." in stem.lstrip(".") else stem
    name = name.replace("/", "_").replace("\0", "_").strip().strip(".").strip()
    return name or "Backup"


def find_backups(roots, depth=2):
    """Every Backup under the given folders, at most `depth` folders down: files named
    *.hopover.7z, or a split Backup's first piece (*.hopover.7z.001), whose size is all its pieces
    together. Nothing inside a Backup can be read without its password, so Backups are recognized
    by name. Folders that aren't there, or can't be read, are passed over."""
    found = []
    for root in roots:
        root = Path(root)
        if not root.is_dir():
            continue
        for folder, dirs, files in os.walk(root, onerror=lambda e: None):
            here = Path(folder)
            if len(here.relative_to(root).parts) >= depth:
                dirs[:] = []
            for f in files:
                lower = f.lower()
                split = lower.endswith(SUFFIX + ".001")
                if not split and not lower.endswith(SUFFIX):
                    continue
                name = f[: len(f) - len(SUFFIX) - (4 if split else 0)]
                path = here / f
                try:
                    st = path.stat()
                except OSError:
                    continue
                size = st.st_size
                if split:
                    size = sum(p.stat().st_size for p in pieces(here, f[:-4]))
                modified = datetime.fromtimestamp(st.st_mtime, timezone.utc)
                found.append(Found(name, str(path), size, split, modified))
    return sorted(found, key=lambda b: (b.name.lower(), b.path))


def pieces(folder, file_name):
    """The pieces of the split Backup <file_name>.001, .002, ... in `folder`, in order."""
    prefix = file_name + "."
    return sorted(
        p
        for p in Path(folder).iterdir()
        if p.is_file()
        and p.name.startswith(prefix)
        and len(p.name) == len(prefix) + 3
        and p.name[-3:].isdigit()
    )


def emit(obj):
    """One JSON line on standard output, ASCII-safe whatever the console's encoding."""
    sys.stdout.write(json.dumps(obj, default=str) + "\n")


def main(argv=None):
    ap = argparse.ArgumentParser(description="Find, test and unpack Hopover Backups.")
    ap.add_argument("--seven-zip", help="the 7-Zip to run (default: 7z, 7zz or 7za on PATH)")
    sub = ap.add_subparsers(dest="command", required=True)
    f = sub.add_parser("find", help="list the Backups under these folders, one JSON line each")
    f.add_argument("folders", nargs="+")
    f.add_argument("--depth", type=int, default=2)
    t = sub.add_parser("test", help="check a Backup opens and every file in it is whole")
    t.add_argument("backup")
    u = sub.add_parser("unpack", help="unpack a Backup into the restore folder")
    u.add_argument("backup")
    u.add_argument("--restore-root", help="default: ~/.local/share/hopover/restore")
    args = ap.parse_args(argv)

    if args.command == "find":
        for b in find_backups(args.folders, args.depth):
            emit(b._asdict())
        return 0
    try:
        seven_zip = need_seven_zip(args.seven_zip)
        checked, password = open_manifest(args.backup, seven_zip=seven_zip)
        if checked.result != "ok":
            emit({"result": checked.result, "message": checked.message})
            return 1
        if args.command == "test":
            tested = test_backup(args.backup, password, seven_zip)
            emit(tested._asdict())
            return 0 if tested.result == "ok" else 1
        out = expand_backup(args.backup, password, args.restore_root, checked, seven_zip)
        emit({"result": "ok", "folder": out.folder, "reused": out.reused, "manifest": out.manifest})
        return 0
    except BackupError as e:
        emit({"result": "failed", "message": str(e)})
        return 1


if __name__ == "__main__":
    sys.exit(main())
