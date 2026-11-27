#!/usr/bin/env python3
"""
restore_linux.py: set up a Linux install from the exports a Windows PC made with
this tool: the winget app list, package lists, git / VS Code / Claude Code /
Codex config, the repo list and the extras archives.

Run it through restore-linux.sh, which installs python3 and curl first if needed:

    linux/restore-linux.sh --dry-run     # show what would happen, change nothing
    linux/restore-linux.sh               # do it (asks for sudo when needed)
    linux/restore-linux.sh --list        # list the steps

Apps are translated with catalog/linux-packages.json. For each app the first
install method that works on this distro is used, ranked by the linux.prefer option
(default: the vendor's own repo, package or installer, then the distro's
apt/dnf/pacman package, then an AppImage or tarball, then Flathub).

Supports apt (Debian, Ubuntu, Linux Mint, Pop!_OS...), dnf (Fedora) and pacman
(Arch, CachyOS, EndeavourOS, Manjaro) systems. Standard library only, Python 3.10+.
"""

import argparse
import fnmatch
import getpass
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from collections import namedtuple
from pathlib import Path

TOOL = Path(__file__).resolve().parent.parent
CATALOG = TOOL / "catalog"
STAMP = time.strftime("%Y%m%d-%H%M%S")
USER_AGENT = "hopover-restore-linux"

STEPS = [
    ("packages", "Apps: vendor repos, packages, AppImages, Flatpaks"),
    ("dev-packages", "npm, .NET, Go, Cargo, uv and PowerShell packages"),
    ("git-config", "Git config, translated from Windows"),
    ("repos", "Clone repos into the Linux dev root"),
    ("dev-extras", "Untracked dev folders, .env files and patches from the extras archive"),
    ("vscode", "VS Code settings and extensions"),
    ("claude", "Claude Code config, memory and MCP servers"),
    ("codex", "Codex config"),
    ("docker-volumes", "Docker named volumes from the extras archive"),
]

DEFAULT_LINUX = {
    "devRoot": "~/dev",
    "prefer": ["vendor", "distro", "portable", "flatpak"],
    "aur": "auto",
    "flatpak": True,
    "nodeMajor": 24,
    "extra": [],
    "skip": [],
}
TIER_OF = {
    "repo": "vendor",
    "deb": "vendor",
    "rpm": "vendor",
    "script": "vendor",
    "aur": "vendor",
    "distro": "distro",
    "appimage": "portable",
    "tarball": "portable",
    "flatpak": "flatpak",
}
UBUNTU_VERSIONS = {
    "jammy": "22.04",
    "noble": "24.04",
    "oracular": "24.10",
    "plucky": "25.04",
    "questing": "25.10",
    "resolute": "26.04",
}
DEBIAN_VERSIONS = {"bullseye": "11", "bookworm": "12", "trixie": "13", "forky": "14"}
# Newest releases vendors usually publish for; used when this release isn't published yet.
APT_FALLBACK = {
    "ubuntu": [("24.04", "noble"), ("22.04", "jammy")],
    "debian": [("13", "trixie"), ("12", "bookworm")],
}
# Text that marks a copied config file as written for Windows.
WINDOWS_ISMS = re.compile(
    r"(?i)(\bpowershell(\.exe)?\b|\bpwsh\.exe\b|\.ps1\b|\.exe\b|\.cmd\b|\b[a-z]:(\\\\|\\|/))"
)

Proc = namedtuple("Proc", "code out")

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
TTY = sys.stdout.isatty()


def color(code, text):
    return f"\033[{code}m{text}\033[0m" if TTY else text


def head(text):
    print()
    print(color("36;1", f"== {text}"))


def info(text):
    print(f"  {text}")


def warn(text):
    print(color("33", f"  {text}"))


def good(text):
    print(color("32", f"  {text}"))


# ---------------------------------------------------------------------------
# Files and network
# ---------------------------------------------------------------------------
def load_json(path, default=None):
    try:
        with open(path, encoding="utf-8-sig") as f:  # PowerShell 5.1 writes a BOM
            return json.load(f)
    except FileNotFoundError:
        return default


def expand(path):
    return Path(os.path.expandvars(os.path.expanduser(str(path))))


def options_path():
    """Where Hopover keeps its Options on Linux: $XDG_CONFIG_HOME/hopover/options.json (~/.config)."""
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return Path(base) / "hopover" / "options.json"


def load_options(data):
    """Hopover's Options, in layers: the data folder's config.json (the layout from before
    Options), then options.json over it. A later layer wins key by key, one level deep for
    nested sections, so a config.json key options.json doesn't set still applies. $schema and
    _comment keys are dropped at both levels. lib/Common.ps1's Get-Options follows the same rule."""
    opt = {}
    for path in (Path(data) / "config.json", options_path()):
        layer = load_json(path, {}) or {}
        for k, v in layer.items():
            if k.startswith(("$", "_")):
                continue
            if isinstance(v, dict):
                section = dict(opt.get(k) or {}) if isinstance(opt.get(k), dict) else {}
                section.update({k2: v2 for k2, v2 in v.items() if not k2.startswith(("$", "_"))})
                opt[k] = section
            else:
                opt[k] = v
    return opt


def http_get(url, timeout=60, headers=None):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def download(url, dest, timeout=120):
    """Stream url to dest (installers can be hundreds of MB)."""
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as r, open(dest, "wb") as f:
        shutil.copyfileobj(r, f, 1024 * 1024)


def http_ok(url, timeout=20):
    for method in ("HEAD", "GET"):
        try:
            req = urllib.request.Request(
                url, method=method, headers={"User-Agent": USER_AGENT, "Range": "bytes=0-0"}
            )
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status < 400
        except urllib.error.HTTPError as e:
            if e.code in (403, 405) and method == "HEAD":
                continue
            return False
        except Exception:
            return False
    return False


_GITHUB_CACHE = {}


def github_asset(repo, pattern):
    """(name, url) of the newest release asset of repo matching pattern, or None."""
    if repo not in _GITHUB_CACHE:
        headers = {"Accept": "application/vnd.github+json"}
        token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
        if token:
            headers["Authorization"] = f"Bearer {token}"
        try:
            _GITHUB_CACHE[repo] = json.loads(
                http_get(f"https://api.github.com/repos/{repo}/releases/latest", headers=headers)
            )
        except Exception as e:
            _GITHUB_CACHE[repo] = {"_error": str(e)}
    rel = _GITHUB_CACHE[repo]
    for a in rel.get("assets", []):
        if re.search(pattern, a.get("name", "")):
            return a["name"], a["browser_download_url"]
    return None


# ---------------------------------------------------------------------------
# The running system
# ---------------------------------------------------------------------------
class System:
    def __init__(self):
        osr = {}
        for p in ("/etc/os-release", "/usr/lib/os-release"):
            if os.path.exists(p):
                with open(p, encoding="utf-8") as f:
                    for line in f:
                        if "=" in line and not line.startswith("#"):
                            k, v = line.rstrip("\n").split("=", 1)
                            osr[k] = v.strip().strip('"').strip("'")
                break
        self.id = osr.get("ID", "").lower()
        self.like = osr.get("ID_LIKE", "").lower().split()
        self.pretty = osr.get("PRETTY_NAME", self.id or "unknown Linux")
        self.version_id = osr.get("VERSION_ID", "")
        ids = [self.id] + self.like
        codename = osr.get("VERSION_CODENAME", "")
        self.family = None
        if any(x in ids for x in ("debian", "ubuntu")):
            self.family = "apt"
        elif any(x in ids for x in ("fedora", "rhel", "centos")):
            self.family = "dnf"
        elif "arch" in ids:
            self.family = "pacman"
        elif shutil.which("apt-get"):
            self.family = "apt"
        elif shutil.which("dnf"):
            self.family = "dnf"
        elif shutil.which("pacman"):
            self.family = "pacman"

        self.base, self.codename, self.base_version, self.fedora = "", codename, "", ""
        if self.family == "apt":
            if self.id == "ubuntu" or "ubuntu" in self.like or osr.get("UBUNTU_CODENAME"):
                self.base = "ubuntu"
                self.codename = osr.get("UBUNTU_CODENAME") or codename
                self.base_version = (
                    self.version_id
                    if self.id == "ubuntu"
                    else UBUNTU_VERSIONS.get(self.codename, "")
                )
            else:
                self.base = "debian"
                self.codename = osr.get("DEBIAN_CODENAME") or codename
                self.base_version = (
                    self.version_id.split(".")[0]
                    if self.id == "debian"
                    else DEBIAN_VERSIONS.get(self.codename, "")
                )
        elif self.family == "dnf":
            self.base = "fedora" if "fedora" in ids else (self.id or "fedora")
            self.fedora = self.version_id
        elif self.family == "pacman":
            self.base = "arch"

        self.machine = platform.machine()
        self.dpkg_arch = {"x86_64": "amd64", "aarch64": "arm64", "armv7l": "armhf"}.get(
            self.machine, self.machine
        )
        self.goarch = {"x86_64": "amd64", "aarch64": "arm64"}.get(self.machine, self.machine)
        self.is_root = os.geteuid() == 0
        self.user = getpass.getuser()
        self.home = Path.home()
        self.systemd = os.path.isdir("/run/systemd/system")
        self.aur_helper = next((h for h in ("paru", "yay") if shutil.which(h)), None)
        self.tags = {t for t in [self.id, self.family, self.base] + self.like if t} | {
            f"id:{self.id}"
        }

    def describe(self):
        bits = [self.pretty, f"{self.family or 'unknown'} family"]
        if self.family == "apt":
            bits.append(f"{self.base} {self.base_version or '?'} ({self.codename or '?'})")
        if self.aur_helper:
            bits.append(f"AUR helper {self.aur_helper}")
        bits.append(self.machine)
        return ", ".join(bits)


# ---------------------------------------------------------------------------
# Running commands
# ---------------------------------------------------------------------------
class Runner:
    def __init__(self, system, dry):
        self.sys = system
        self.dry = dry

    def run(self, cmd, root=False, env=None, cwd=None, capture=False, change=True, show=True):
        """Run cmd (a list, or a string for bash -c). root: via sudo unless already root.
        change=False marks a read-only command that also runs in a dry run."""
        shell = isinstance(cmd, str)
        shown = cmd if shell else " ".join(shlex.quote(str(a)) for a in cmd)
        prefix = "sudo " if root and not self.sys.is_root else ""
        if self.dry and change:
            print(color("36", f"  would: {prefix}{shown}"))
            return Proc(0, "")
        argv = ["bash", "-c", cmd] if shell else [str(a) for a in cmd]
        run_env = dict(os.environ)
        if env:
            run_env.update(env)
        if root and not self.sys.is_root:
            argv = ["sudo"] + (["env"] + [f"{k}={v}" for k, v in env.items()] if env else []) + argv
        if show:
            print(color("90", f"  $ {prefix}{shown}"))
        try:
            p = subprocess.run(
                argv,
                env=run_env,
                cwd=cwd,
                text=True,
                stdout=subprocess.PIPE if capture else None,
                stderr=subprocess.STDOUT if capture else None,
            )
        except FileNotFoundError as e:
            return Proc(127, str(e))
        return Proc(p.returncode, p.stdout or "")

    def query(self, cmd, cwd=None):
        """Read-only command, run quietly even in a dry run; stderr is dropped."""
        argv = ["bash", "-c", cmd] if isinstance(cmd, str) else [str(a) for a in cmd]
        try:
            p = subprocess.run(
                argv, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
            )
        except FileNotFoundError:
            return Proc(127, "")
        return Proc(p.returncode, p.stdout or "")

    def write_root_file(self, dest, content, mode="644"):
        """Write a file that needs root (under /etc and the like)."""
        if self.dry:
            print(color("36", f"  would: write {dest}"))
            return True
        data = content.encode() if isinstance(content, str) else content
        with tempfile.NamedTemporaryFile(delete=False) as tmp:
            tmp.write(data)
        try:
            return (
                self.run(
                    ["install", "-D", "-m", mode, tmp.name, str(dest)], root=True, show=False
                ).code
                == 0
            )
        finally:
            os.unlink(tmp.name)


# ---------------------------------------------------------------------------
# Package managers
# ---------------------------------------------------------------------------
class PackageManager:
    def __init__(self, ctx):
        self.ctx = ctx
        self.family = ctx.sys.family
        self.ready = False  # metadata refreshed, so availability checks mean something
        self._avail = {}

    def refresh(self, upgrade_ok=True):
        r = self.ctx.run
        allowed = not self.ctx.dry or self.ctx.args.refresh
        if not allowed:
            return
        if self.family == "apt":
            code = r.run(["apt-get", "update"], root=True, change=not self.ctx.args.refresh).code
        elif self.family == "dnf":
            code = r.run(["dnf", "makecache"], root=True, change=not self.ctx.args.refresh).code
        else:
            # Arch doesn't support partial upgrades: refresh and upgrade together for real runs.
            cmd = (
                ["pacman", "-Syu", "--noconfirm"]
                if (upgrade_ok and not self.ctx.dry)
                else ["pacman", "-Sy"]
            )
            code = r.run(cmd, root=True, change=not self.ctx.args.refresh).code
        self.ready = code == 0
        self._avail = {}

    def installed(self, name):
        q = self.ctx.run.query
        if self.family == "apt":
            return "install ok installed" in q(["dpkg-query", "-W", "-f=${Status}", name]).out
        if self.family == "dnf":
            return q(["rpm", "-q", "--whatprovides", name]).code == 0
        return q(["pacman", "-Q", name]).code == 0

    def available(self, name):
        """True/False, or None when the metadata hasn't been refreshed (dry run without --refresh)."""
        if not self.ready:
            return None
        if name in self._avail:
            return self._avail[name]
        q = self.ctx.run.query
        if self.family == "apt":
            out = q(["apt-cache", "policy", name]).out
            m = re.search(r"Candidate:\s*(\S+)", out)
            ok = bool(m and m.group(1) != "(none)")
        elif self.family == "dnf":
            ok = q(["dnf", "-q", "info", name]).code == 0
        else:
            ok = q(["pacman", "-Si", name]).code == 0 or q(["pacman", "-Sg", name]).code == 0
        self._avail[name] = ok
        return ok

    def install(self, names):
        names = list(dict.fromkeys(names))
        if not names:
            return True
        r = self.ctx.run
        if self.family == "apt":
            return (
                r.run(
                    ["apt-get", "install", "-y", *names],
                    root=True,
                    env={"DEBIAN_FRONTEND": "noninteractive"},
                ).code
                == 0
            )
        if self.family == "dnf":
            return r.run(["dnf", "install", "-y", *names], root=True).code == 0
        return r.run(["pacman", "-S", "--needed", "--noconfirm", *names], root=True).code == 0

    def install_file(self, path):
        r = self.ctx.run
        if self.family == "apt":
            return (
                r.run(
                    ["apt-get", "install", "-y", str(path)],
                    root=True,
                    env={"DEBIAN_FRONTEND": "noninteractive"},
                ).code
                == 0
            )
        return r.run(["dnf", "install", "-y", str(path)], root=True).code == 0


# ---------------------------------------------------------------------------
# Context: settings, plan, results
# ---------------------------------------------------------------------------
class Ctx:
    def __init__(self, args):
        self.args = args
        self.sys = System()
        self.dry = args.dry_run
        self.run = Runner(self.sys, self.dry)
        self.data = Path(args.data).expanduser().resolve()
        self.settings = self.data / "settings"
        cfg = load_options(self.data)
        self.config = cfg
        linux = dict(DEFAULT_LINUX)
        linux.update(cfg.get("linux") or {})
        if args.prefer:
            linux["prefer"] = [x.strip() for x in args.prefer.split(",") if x.strip()]
        if args.no_flatpak:
            linux["flatpak"] = False
        if args.aur:
            linux["aur"] = args.aur
        self.linux = linux
        self.dev_root = expand(args.dev_root or linux["devRoot"])
        self.win_dev_root = cfg.get("devRoot") or "C:\\dev"
        self.pm = PackageManager(self)

        plan = {} if args.ignore_plan else (load_json(self.data / "restore-plan.json", {}) or {})
        self.plan_file = None if args.ignore_plan or not plan else self.data / "restore-plan.json"
        self.skip = {
            g: {str(k).lower() for k in (keys or [])}
            for g, keys in (plan.get("Skip") or {}).items()
        }
        self.skip_steps = {s.lower() for s in (plan.get("LinuxSkipSteps") or [])}
        self.plan_hits = 0

        self.manual = []
        self.results = []
        self.report = {
            "installed": [],
            "present": [],
            "planned": [],
            "none": [],
            "windows_only": [],
            "unmapped": [],
            "failed": [],
            "notes": [],
        }

    def planned(self, group, key):
        """False when restore-plan.json unticks this item (and counts it)."""
        if str(key).lower() in self.skip.get(group, ()):
            self.plan_hits += 1
            return False
        return True

    def todo(self, text):
        if text not in self.manual:
            self.manual.append(text)

    def fmt(self, text, extra=None):
        if not isinstance(text, str):
            return text
        values = {
            "base": self.sys.base,
            "codename": self.sys.codename,
            "version": self.sys.base_version,
            "fedora": self.sys.fedora,
            "arch": self.sys.dpkg_arch,
            "rpmarch": self.sys.machine,
            "goarch": self.sys.goarch,
            "node": str(self.linux.get("nodeMajor", 24)),
            "user": self.sys.user,
            "home": str(self.sys.home),
        }
        values.update(extra or {})
        return re.sub(r"\{(\w+)\}", lambda m: values.get(m.group(1), m.group(0)), text)

    def tool(self, name):
        return shutil.which(name) is not None


def extend_path(dirs):
    parts = os.environ.get("PATH", "").split(":")
    for d in dirs:
        p = str(expand(d))
        if p not in parts:
            parts.insert(0, p)
    os.environ["PATH"] = ":".join(parts)


PROFILE_START = "# >>> hopover restore-linux >>>"
PROFILE_END = "# <<< hopover restore-linux <<<"


def add_profile_paths(ctx, dirs):
    """Keep one block in ~/.profile with PATH entries the installers don't add themselves."""
    profile = ctx.sys.home / ".profile"
    text = profile.read_text(encoding="utf-8") if profile.exists() else ""
    old = re.search(re.escape(PROFILE_START) + r".*?" + re.escape(PROFILE_END) + r"\n?", text, re.S)
    have = re.findall(r'export PATH="([^"$]+):\$PATH"', old.group(0)) if old else []
    want = list(dict.fromkeys(have + [str(d).replace(str(ctx.sys.home), "$HOME") for d in dirs]))
    if old and set(want) == set(have):
        return
    block = (
        PROFILE_START
        + "\n"
        + "".join(f'export PATH="{d}:$PATH"\n' for d in want)
        + PROFILE_END
        + "\n"
    )
    if ctx.dry:
        print(color("36", f"  would: add {', '.join(want)} to PATH in ~/.profile"))
        return
    text = (
        text.replace(old.group(0), block)
        if old
        else (text.rstrip("\n") + "\n\n" + block if text else block)
    )
    profile.write_text(text, encoding="utf-8")
    info(f"PATH in ~/.profile now includes {', '.join(want)} (log out and in, or: . ~/.profile)")


# ---------------------------------------------------------------------------
# Catalog
# ---------------------------------------------------------------------------
class Catalog:
    def __init__(self):
        p = load_json(CATALOG / "linux-packages.json")
        r = load_json(CATALOG / "linux-repos.json")
        self.packages = p["packages"]
        self.aliases = {k.lower(): v for k, v in p.get("aliases", {}).items()}
        self.patterns = p.get("patterns", [])
        self.windows_only = p.get("windowsOnly", [])
        self.repos = r["repos"]
        self.scripts = r["scripts"]
        self.prereqs = r["prereqs"]
        self.base = r["base"]
        self.fuse2 = r["fuse2"]
        self.flatpak = r["flatpak"]
        self._lower = {k.lower(): k for k in self.packages}

    def lookup(self, source_id):
        """("entry", key, entry, vars) | ("windows-only", ...) | None."""
        sid = source_id.lower()
        if sid in self._lower:
            k = self._lower[sid]
            return ("entry", k, self.packages[k], {})
        if sid in self.aliases:
            target = self.aliases[sid]
            found = self.lookup(target)
            if found:
                return found
        for pat in self.patterns:
            rx = "^" + re.escape(pat["match"].lower()).replace(r"\*", "(.*?)") + "$"
            m = re.match(rx, sid)
            if m:
                key = pat["use"]
                if key in self.packages:
                    return (
                        "entry",
                        key,
                        self.packages[key],
                        {str(i + 1): g for i, g in enumerate(m.groups())},
                    )
        for w in self.windows_only:
            if fnmatch.fnmatchcase(sid, w.lower()):
                return ("windows-only", source_id, None, {})
        return None


def pick(spec, system):
    """A per-distro value: a plain value, or a dict keyed by distro id, base or family (or default)."""
    if isinstance(spec, dict) and "any" not in spec:
        for k in (f"id:{system.id}", system.id, system.base, system.family, "default"):
            if k and k in spec:
                return spec[k]
        return None
    return spec


def names_of(spec):
    """("all", [...]) or ("any", [...]) for a distro package spec value."""
    if spec is None:
        return None
    if isinstance(spec, str):
        return ("all", [spec])
    if isinstance(spec, list):
        return ("all", list(spec))
    if isinstance(spec, dict) and "any" in spec:
        return ("any", list(spec["any"]))
    return None


def kind_of(m):
    for k in ("repo", "script", "aur", "distro", "flatpak", "deb", "rpm", "appimage", "tarball"):
        if k in m:
            return k
    return None


Choice = namedtuple("Choice", "key name kind method packages url asset tier vars source")


class Resolver:
    def __init__(self, ctx, catalog):
        self.ctx = ctx
        self.cat = catalog
        self.prefer = ctx.linux["prefer"]

    def tags_match(self, values):
        return any(v.lower() in self.ctx.sys.tags for v in values)

    def prereq_possible(self, name):
        d = self.cat.prereqs.get(name)
        if not d:
            return True
        s = self.ctx.sys
        check = (d.get("check") or {}).get(s.family)
        if check and self.ctx.run.query(check).code == 0:
            return True
        if d.get(s.family):
            return True
        manual = d.get("manual") or {}
        if manual.get(s.family) or manual.get(s.base):
            return False
        return True  # nothing needed on this family

    def pending_prereqs(self, m):
        """Prerequisites of m that still need setting up on this system."""
        out = []
        for name in self.prereqs_of(m):
            check = (self.cat.prereqs.get(name, {}).get("check") or {}).get(self.ctx.sys.family)
            if check and self.ctx.run.query(check).code != 0:
                out.append(name)
        return out

    def prereqs_of(self, m):
        p = m.get("prereq") or []
        if isinstance(p, dict):
            p = p.get(self.ctx.sys.family, []) + p.get(self.ctx.sys.base, [])
        return list(p)

    def applicable(self, m, kind):
        s = self.ctx.sys
        if m.get("only") and not self.tags_match(m["only"]):
            return False
        if m.get("except") and self.tags_match(m["except"]):
            return False
        arches = m.get("arches") or (
            ["x86_64"] if kind in ("deb", "rpm", "appimage", "tarball") else None
        )
        if arches and s.machine not in arches:
            return False
        if kind == "repo":
            rdef = self.cat.repos.get(m["repo"], {}).get(s.family)
            if not rdef:
                return False
            if (
                s.family == "apt"
                and rdef.get("arches")
                and s.dpkg_arch not in rdef["arches"].split(",")
            ):
                return False
        elif kind == "deb" and s.family != "apt" or kind == "rpm" and s.family != "dnf":
            return False
        elif kind == "aur":
            if (
                s.family != "pacman"
                or self.ctx.linux.get("aur") == "never"
                or not s.aur_helper
                or s.is_root
            ):
                return False
        elif kind == "distro":
            if names_of(pick(m["distro"], s)) is None:
                return False
        elif kind == "script":
            if m["script"] not in self.cat.scripts:
                return False
        elif kind == "flatpak":
            if not self.ctx.linux.get("flatpak", True):
                return False
        if any(not self.prereq_possible(p) for p in self.prereqs_of(m)):
            return False
        return True

    def rank(self, m, kind):
        tier = m.get("tier") or TIER_OF.get(kind, "portable")
        return self.prefer.index(tier) if tier in self.prefer else len(self.prefer)

    def blocked_reason(self, m, kind):
        """Why a method that would otherwise fit this distro can't be used, for the report."""
        s = self.ctx.sys
        if kind == "aur" and s.family == "pacman" and self.ctx.linux.get("aur") != "never":
            return (
                "it's in the AUR; install yay or paru and run this as your user (not root)"
                if (not s.aur_helper or s.is_root)
                else None
            )
        for p in self.prereqs_of(m):
            if not self.prereq_possible(p):
                manual = self.cat.prereqs.get(p, {}).get("manual") or {}
                return manual.get(s.family) or manual.get(s.base)
        return None

    def choose(self, key, entry, vars, source):
        name = self.ctx.fmt(entry.get("name", key), vars)
        options, blocked = [], []
        for i, m in enumerate(entry.get("methods", [])):
            kind = kind_of(m)
            if not kind:
                continue
            tier = m.get("tier") or TIER_OF.get(kind, "portable")
            if self.applicable(m, kind):
                if tier in self.prefer:
                    options.append((self.rank(m, kind), i, m, kind, tier))
            else:
                why = self.blocked_reason(m, kind)
                if why:
                    blocked.append((self.rank(m, kind), why))
        choice = self._first_working(
            key, name, sorted(options, key=lambda o: (o[0], o[1])), vars, source
        )
        best_rank = self.rank(choice.method, choice.kind) if choice else len(self.prefer) + 1
        for rank, why in blocked:
            if rank < best_rank:
                if choice:
                    self.ctx.todo(
                        f"{name}: installed as {choice.kind}; for the preferred package, {why[0].lower() + why[1:]}"
                    )
                else:
                    self.ctx.report["failed"].append((name, why))
                    return False
                break
        return choice

    def _first_working(self, key, name, options, vars, source):
        for _, _, m, kind, tier in options:
            pkgs, url, asset = [], None, None
            if kind == "distro":
                mode, cands = names_of(pick(m["distro"], self.ctx.sys))
                cands = [self.ctx.fmt(c, vars) for c in cands]
                # A prerequisite repo (RPM Fusion, i386...) that isn't set up yet hides its packages,
                # so only check names when the method needs nothing more.
                avail = self.ctx.pm.available if not self.pending_prereqs(m) else (lambda _n: None)
                if mode == "any":
                    found = next((c for c in cands if avail(c) is not False), None)
                    if not found:
                        continue
                    pkgs = [found]
                else:
                    if any(avail(c) is False for c in cands):
                        continue
                    pkgs = cands
            elif kind == "repo":
                pkg = m.get("package")
                pkgs = [self.ctx.fmt(p, vars) for p in (pkg if isinstance(pkg, list) else [pkg])]
            elif kind == "aur":
                pkgs = [
                    self.ctx.fmt(p, vars)
                    for p in (m["aur"] if isinstance(m["aur"], list) else [m["aur"]])
                ]
            elif kind == "flatpak":
                pkgs = [m["flatpak"]]
            elif kind in ("deb", "rpm", "appimage", "tarball"):
                spec = self.ctx.fmt(pick(m[kind], self.ctx.sys), vars)
                if not spec:
                    continue
                if "github" in m:
                    found = github_asset(m["github"], spec)
                    if not found:
                        continue
                    asset, url = found
                else:
                    url = spec
                    if not http_ok(url):
                        continue
                if m.get("package"):
                    pkgs = [self.ctx.fmt(m["package"], vars)]
            return Choice(key, name, kind, m, pkgs, url, asset, tier, vars, source)
        return None


# ---------------------------------------------------------------------------
# Step: packages
# ---------------------------------------------------------------------------
def source_ids(ctx):
    """(id, where it came from) for every app the Windows PC had, plus config linux.extra."""
    out = []
    w = load_json(ctx.data / "winget-packages.json", {}) or {}
    for src in w.get("Sources", []):
        for p in src.get("Packages", []):
            out.append((p["PackageIdentifier"], "winget"))
    pk = load_json(ctx.settings / "dev" / "packages.json", {}) or {}
    for c in pk.get("Choco") or []:
        out.append((f"choco:{c}", "choco"))
    for e in ctx.linux.get("extra") or []:
        out.append((e, "config"))
    if (ctx.settings / "claude").is_dir():
        out.append(("linux:claude-code", "Claude Code config"))
    if ctx.args.only:
        wanted = {x.strip().lower() for x in ctx.args.only.split(",") if x.strip()}
        out = [o for o in out if o[0].lower() in wanted] + [
            (x, "--only")
            for x in ctx.args.only.split(",")
            if x.strip() and x.strip().lower() not in {o[0].lower() for o in out}
        ]
    return out


def resolve_all(ctx, cat):
    res = Resolver(ctx, cat)
    skip_cfg = {str(x).lower() for x in ctx.linux.get("skip") or []}
    choices, seen = [], {}
    for sid, _src in source_ids(ctx):
        unticked = (
            not ctx.planned("choco", sid[6:])
            if sid.startswith("choco:")
            else not ctx.planned("winget", sid)
        )
        if sid.lower() in skip_cfg or unticked or not ctx.planned("linux-packages", sid):
            ctx.report["planned"].append(sid)
            continue
        found = cat.lookup(sid)
        if not found:
            ctx.report["unmapped"].append(sid)
            continue
        if found[0] == "windows-only":
            ctx.report["windows_only"].append(sid)
            continue
        _, key, entry, vars = found
        chain = []
        while "via" in entry:
            if entry.get("note"):
                ctx.todo(f"{ctx.fmt(entry.get('name', key), vars)}: {ctx.fmt(entry['note'], vars)}")
            chain.append(key)
            key = entry["via"]
            entry = cat.packages.get(key)
            if entry is None or key in chain:
                break
        if entry is None:
            ctx.report["unmapped"].append(sid)
            continue
        if not ctx.planned("linux-packages", key):
            ctx.report["planned"].append(sid)
            continue
        ident = key + json.dumps(vars, sort_keys=True)
        if ident in seen:
            continue
        seen[ident] = True
        name = ctx.fmt(entry.get("name", key), vars)
        if "none" in entry:
            ctx.report["none"].append((name, entry["none"], entry.get("alternatives", [])))
            continue
        choice = res.choose(key, entry, vars, sid)
        if choice is False:  # already reported with the reason
            continue
        if not choice:
            ctx.report["failed"].append((name, "no install method works on this system"))
            continue
        # Several Windows versions (VS 2019 and 2022 Build Tools, Python 3.13 and 3.14) can land on one Linux package.
        same = (choice.kind, tuple(choice.packages), choice.url)
        if same in seen:
            continue
        seen[same] = True
        choices.append(choice)
        for note in (entry.get("note"), choice.method.get("note")):
            text = f"{name}: {ctx.fmt(note, vars)}" if note else None
            if text and text not in ctx.report["notes"]:
                ctx.report["notes"].append(text)
    return choices


def ensure_prereqs(ctx, cat, choices):
    s, changed = ctx.sys, False
    names = []
    for c in choices:
        p = c.method.get("prereq") or []
        if isinstance(p, dict):
            p = p.get(s.family, []) + p.get(s.base, [])
        names += p
    for name in dict.fromkeys(names):
        d = cat.prereqs.get(name, {})
        check = (d.get("check") or {}).get(s.family)
        if check and ctx.run.query(check).code == 0:
            continue
        cmd = d.get(s.family)
        if cmd:
            info(f"prerequisite {name}")
            ctx.run.run(ctx.fmt(cmd), root=True)
            changed = True
    return changed


def add_apt_repo(ctx, rid, rdef):
    run, s = ctx.run, ctx.sys
    sources_dir = Path("/etc/apt/sources.list.d")
    keyring = rdef.get("keyring", f"/etc/apt/keyrings/{rid}.gpg")
    dest = sources_dir / rdef.get("file", f"{rid}.list")
    pairs = [(s.base_version, s.codename)] + [
        p for p in APT_FALLBACK.get(s.base, []) if p != (s.base_version, s.codename)
    ]
    templated = (
        "{codename}" in rdef["suite"] or "{version}" in rdef["url"] or "{codename}" in rdef["url"]
    )
    url = suite = None
    for ver, cn in pairs if templated else pairs[:1]:
        extra = {"version": ver, "codename": cn}
        u, su = ctx.fmt(rdef["url"], extra).rstrip("/"), ctx.fmt(rdef["suite"], extra)
        if (
            not templated
            or http_ok(f"{u}/dists/{su}/InRelease")
            or http_ok(f"{u}/dists/{su}/Release")
        ):
            keys = rdef["key"] if isinstance(rdef["key"], list) else [rdef["key"]]
            url, suite, keyurls = u, su, [ctx.fmt(k, extra) for k in keys]
            if templated and (ver, cn) != (s.base_version, s.codename):
                info(f"{rid}: no packages for {s.codename or '?'} yet; using {cn}")
            break
    if not url:
        warn(f"{rid}: no published suite for this release")
        return False
    # Don't add a second entry for a repo the vendor's own package already configured.
    existing = ctx.run.query(
        f"grep -rlsF {shlex.quote(url)} /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null"
    ).out.split()
    if any(Path(e) != dest for e in existing):
        info(f"{rid}: already configured in {existing[0]}")
        return True
    arches = rdef.get("arches")
    arch = s.dpkg_arch if not arches else ",".join(a for a in arches.split(",") if a == s.dpkg_arch)
    line = f"deb [arch={arch} signed-by={keyring}] {url} {suite} {rdef['components']}\n"
    if dest.exists() and dest.read_text(encoding="utf-8", errors="replace") == line:
        return True
    info(f"adding repo {rdef.get('name', rid)}")
    # The keyring is rewritten every time: several repos can share one (all of Microsoft's),
    # and each must end up with every key any of them needs.
    if ctx.dry:
        print(color("36", f"  would: download {', '.join(keyurls)} -> {keyring}"))
    else:
        blobs = []
        for keyurl in keyurls:
            key = http_get(keyurl)
            if key.lstrip().startswith(b"-----BEGIN") and not rdef.get("keepArmored"):
                p = subprocess.run(
                    ["gpg", "--dearmor"],
                    input=key,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                )
                if p.returncode != 0 or not p.stdout:
                    warn(f"{rid}: couldn't dearmor the signing key {keyurl}")
                    return False
                key = p.stdout
            blobs.append(key)
        run.write_root_file(keyring, b"".join(blobs))
    run.write_root_file(dest, line)
    pin = rdef.get("pin")
    if pin:
        run.write_root_file(
            Path("/etc/apt/preferences.d") / rid,
            f"Package: *\nPin: origin {pin['origin']}\nPin-Priority: {pin['priority']}\n",
        )
    return True


def add_dnf_repo(ctx, rid, rdef):
    run = ctx.run
    if "repofile" in rdef:
        url = ctx.fmt(rdef["repofile"])
        dest = Path("/etc/yum.repos.d") / url.rsplit("/", 1)[-1]
        if dest.exists():
            return True
        info(f"adding repo {rid}")
        if ctx.dry:
            print(color("36", f"  would: download {url} -> {dest}"))
            return True
        return run.write_root_file(dest, http_get(url))
    dest = Path("/etc/yum.repos.d") / rdef.get("file", f"{rid}.repo")
    if dest.exists():
        return True
    gpg = rdef.get("gpgcheck", True)
    body = f"[{rid}]\nname={rid}\nbaseurl={ctx.fmt(rdef['baseurl'])}\nenabled=1\ngpgcheck={1 if gpg else 0}\n"
    if gpg and rdef.get("gpgkey"):
        body += f"gpgkey={ctx.fmt(rdef['gpgkey'])}\n"
    info(f"adding repo {rid}")
    return run.write_root_file(dest, body)


def install_appimage(ctx, choice):
    apps = ctx.sys.home / "Applications"
    slug = re.sub(r"[^A-Za-z0-9]+", "-", choice.name).strip("-")
    target = apps / f"{slug}.AppImage"
    if target.exists():
        ctx.report["present"].append(choice.name)
        return True
    if ctx.dry:
        print(color("36", f"  would: download {choice.url} -> {target}"))
        return True
    apps.mkdir(parents=True, exist_ok=True)
    info(f"downloading {choice.asset or choice.url}")
    download(choice.url, target)
    target.chmod(0o755)
    desktop = ctx.sys.home / ".local/share/applications" / f"{slug}.desktop"
    desktop.parent.mkdir(parents=True, exist_ok=True)
    desktop.write_text(
        f"[Desktop Entry]\nType=Application\nName={choice.name}\nExec={target} %U\nTerminal=false\nCategories=Utility;\n",
        encoding="utf-8",
    )
    return True


def install_tarball(ctx, choice):
    import tarfile

    bins = choice.method.get("bin") or []
    local_bin = ctx.sys.home / ".local/bin"
    if bins and all((local_bin / b).exists() or ctx.tool(b) for b in bins):
        ctx.report["present"].append(choice.name)
        return True
    if ctx.dry:
        print(
            color(
                "36",
                f"  would: download {choice.url} and put {', '.join(bins) or 'it'} in ~/.local/bin",
            )
        )
        return True
    dest = ctx.sys.home / ".local/opt" / choice.key.lower()
    dest.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(delete=False, suffix=".tar.gz") as tmp:
        pass
    download(choice.url, tmp.name)
    try:
        with tarfile.open(tmp.name) as t:
            for member in t.getmembers():
                if member.name.startswith("/") or ".." in Path(member.name).parts:
                    continue
                t.extract(member, dest)
    finally:
        os.unlink(tmp.name)
    local_bin.mkdir(parents=True, exist_ok=True)
    for b in bins:
        found = next((p for p in dest.rglob(b) if p.is_file()), None)
        if found:
            found.chmod(0o755)
            link = local_bin / b
            if link.exists() or link.is_symlink():
                link.unlink()
            link.symlink_to(found)
    extend_path(["~/.local/bin"])
    return True


def step_packages(ctx):
    cat = Catalog()
    s, pm = ctx.sys, ctx.pm
    if not s.family:
        return "FAILED: no apt-get, dnf or pacman found"
    pm.refresh()
    base = [n for n in cat.base.get(s.family, []) if not pm.installed(n)]
    if base:
        info(f"base tools: {' '.join(base)}")
        pm.install(base)

    choices = resolve_all(ctx, cat)
    if ensure_prereqs(ctx, cat, choices):
        pm.refresh(upgrade_ok=False)

    repos = list(dict.fromkeys(c.method["repo"] for c in choices if c.kind == "repo"))
    added = False
    for rid in repos:
        rdef = cat.repos[rid].get(s.family)
        ok = (
            add_apt_repo(ctx, rid, dict(rdef, name=cat.repos[rid].get("name", rid)))
            if s.family == "apt"
            else add_dnf_repo(ctx, rid, rdef)
        )
        added = added or ok
        if not ok:
            for c in [c for c in choices if c.kind == "repo" and c.method["repo"] == rid]:
                ctx.report["failed"].append((c.name, f"couldn't add the {rid} repo"))
            choices = [c for c in choices if not (c.kind == "repo" and c.method["repo"] == rid)]
    if added:
        pm.refresh(upgrade_ok=False)

    def done(c, ok, already=False):
        if already:
            ctx.report["present"].append(c.name)
        elif ok:
            ctx.report["installed"].append(f"{c.name} ({describe(c, s.family)})")
        else:
            ctx.report["failed"].append((c.name, describe(c, s.family)))

    # Distro and vendor-repo packages, in one go when possible.
    pkg_choices = [c for c in choices if c.kind in ("distro", "repo")]
    todo = [c for c in pkg_choices if not all(pm.installed(p) for p in c.packages)]
    for c in pkg_choices:
        if c not in todo:
            done(c, True, already=True)
    if todo:
        names = [p for c in todo for p in c.packages]
        info(f"installing {len(names)} package(s)")
        if pm.install(names):
            for c in todo:
                done(c, True)
        else:
            warn("the batch install failed; trying one at a time")
            for c in todo:
                done(c, pm.install(c.packages))

    for c in [c for c in choices if c.kind in ("deb", "rpm")]:
        if c.packages and all(pm.installed(p) for p in c.packages):
            done(c, True, already=True)
            continue
        if ctx.dry:
            print(color("36", f"  would: download {c.url} and install it"))
            done(c, True)
            continue
        with tempfile.NamedTemporaryFile(delete=False, suffix="." + c.kind, dir="/tmp") as tmp:
            pass
        try:
            info(f"downloading {c.asset or c.url}")
            download(c.url, tmp.name)
        except Exception as e:
            os.unlink(tmp.name)
            done(c, False)
            warn(f"{c.name}: download failed ({e})")
            continue
        # apt runs as _apt and needs to read the file.
        os.chmod(tmp.name, 0o644)
        try:
            done(c, pm.install_file(tmp.name))
        finally:
            os.unlink(tmp.name)

    aur = [c for c in choices if c.kind == "aur"]
    if aur:
        names = [p for c in aur for p in c.packages if not pm.installed(p)]
        for c in aur:
            if all(pm.installed(p) for p in c.packages):
                done(c, True, already=True)
        if names:
            ok = ctx.run.run([s.aur_helper, "-S", "--needed", "--noconfirm", *names]).code == 0
            for c in aur:
                if any(p in names for p in c.packages):
                    done(c, ok)

    profile_dirs = []
    for c in [c for c in choices if c.kind == "script"]:
        sdef = cat.scripts[c.method["script"]]
        extend_path(sdef.get("path", []))
        # check is a program name, or a shell test when it has spaces.
        chk = ctx.fmt(sdef.get("check") or "", c.vars)
        if chk and (ctx.run.query(chk).code == 0 if " " in chk else ctx.tool(chk)):
            done(c, True, already=True)
            continue
        for need in sdef.get("needs", []):
            if not ctx.tool(need):
                pm.install([need])
        ok = ctx.run.run(ctx.fmt(sdef["run"], c.vars), root=bool(sdef.get("root"))).code == 0
        done(c, ok)
        if sdef.get("profile"):
            profile_dirs += sdef.get("path", [])
        extend_path(sdef.get("path", []))
    if profile_dirs:
        add_profile_paths(ctx, profile_dirs)

    portable = [c for c in choices if c.kind in ("appimage", "tarball")]
    if any(c.kind == "appimage" for c in portable):
        fuse = names_of(pick(cat.fuse2, s))
        if fuse:
            pick_name = (
                next((n for n in fuse[1] if pm.available(n) is not False), None)
                if fuse[0] == "any"
                else None
            )
            fnames = [pick_name] if pick_name else (fuse[1] if fuse[0] == "all" else fuse[1][:1])
            if not all(pm.installed(n) for n in fnames):
                pm.install(fnames)
    for c in portable:
        try:
            done(c, install_appimage(ctx, c) if c.kind == "appimage" else install_tarball(ctx, c))
        except Exception as e:
            warn(f"{c.name}: {e}")
            done(c, False)

    flat = [c for c in choices if c.kind == "flatpak"]
    if flat:
        if not ctx.tool("flatpak"):
            pm.install([pick(cat.flatpak, s) or "flatpak"])
        ctx.run.run(
            ["flatpak", "remote-add", "--if-not-exists", "flathub", cat.flatpak["remote"]],
            root=True,
        )
        for c in flat:
            if ctx.run.query(["flatpak", "info", c.packages[0]]).code == 0:
                done(c, True, already=True)
            else:
                done(
                    c,
                    ctx.run.run(
                        ["flatpak", "install", "-y", "--noninteractive", "flathub", c.packages[0]],
                        root=True,
                    ).code
                    == 0,
                )

    for c in choices:
        for post in c.method.get("post") or cat.packages.get(c.key, {}).get("post") or []:
            if post.get("needs") == "systemd" and not s.systemd:
                ctx.todo(f"{c.name}: run '{ctx.fmt(post['cmd'])}' once systemd is running")
                continue
            if post.get("needs") == "user" and s.user == "root":
                continue
            ctx.run.run(ctx.fmt(post["cmd"]), root=bool(post.get("root")))

    r = ctx.report
    return (
        f"{len(r['installed'])} installed, {len(r['present'])} already there, {len(r['failed'])} failed, "
        f"{len(r['none'])} with no Linux version, {len(r['windows_only'])} Windows-only, {len(r['unmapped'])} not in the catalog"
    )


def describe(c, family):
    if c.kind == "repo":
        return f"{c.method['repo']} repo: {' '.join(c.packages)}"
    if c.kind == "distro":
        return f"{family}: {' '.join(c.packages)}"
    if c.kind in ("deb", "rpm", "appimage", "tarball"):
        return f"{c.kind} {c.asset or c.url}"
    if c.kind == "script":
        return f"installer {c.method['script']}"
    if c.kind == "aur":
        return f"AUR {' '.join(c.packages)}"
    return f"{c.kind} {' '.join(c.packages)}"


# ---------------------------------------------------------------------------
# Step: dev packages
# ---------------------------------------------------------------------------
def step_dev_packages(ctx):
    p = load_json(ctx.settings / "dev" / "packages.json")
    if not p:
        return "skipped: no settings/dev/packages.json"
    extend_path(
        [
            "~/.local/bin",
            "~/.cargo/bin",
            "/usr/local/go/bin",
            "~/go/bin",
            "~/.dotnet/tools",
            "~/.deno/bin",
            "~/.bun/bin",
        ]
    )
    run, q = ctx.run.run, ctx.run.query
    done, waiting = [], []

    def wanted(group, items):
        return [i for i in (items or []) if i and ctx.planned(group, i)]

    npm = wanted("npm", p.get("Npm"))
    if npm:
        if ctx.tool("npm"):
            try:
                have = set(
                    json.loads(q(["npm", "ls", "-g", "--depth=0", "--json"]).out or "{}").get(
                        "dependencies", {}
                    )
                )
            except ValueError:
                have = set()
            todo = [n for n in npm if n not in have]
            prefix = q(["npm", "config", "get", "prefix"]).out.strip()
            need_root = bool(prefix) and not os.access(prefix, os.W_OK)
            if todo:
                run(["npm", "install", "-g", *todo], root=need_root)
            done.append(f"npm {len(todo)} new")
        else:
            waiting.append("Node.js (npm)")
    dotnet = wanted("dotnet", p.get("Dotnet"))
    if dotnet:
        if ctx.tool("dotnet"):
            have = {
                line.split()[0].lower()
                for line in q(["dotnet", "tool", "list", "-g"]).out.splitlines()[2:]
                if line.strip()
            }
            todo = [t for t in dotnet if t.lower() not in have]
            for t in todo:
                run(["dotnet", "tool", "install", "-g", t])
            done.append(f"dotnet {len(todo)} new")
        else:
            waiting.append(".NET SDK")
    go = wanted("go", p.get("Go"))
    if go:
        if ctx.tool("go"):
            gobin = Path(q(["go", "env", "GOPATH"]).out.strip() or str(ctx.sys.home / "go")) / "bin"
            todo = [m for m in go if not (gobin / m.rstrip("/").rsplit("/", 1)[-1]).exists()]
            for m in todo:
                run(["go", "install", f"{m}@latest"])
            done.append(f"go {len(todo)} new")
        else:
            waiting.append("Go")
    cargo = wanted("cargo", p.get("Cargo"))
    if cargo:
        if ctx.tool("cargo"):
            have = {
                line.split()[0]
                for line in q(["cargo", "install", "--list"]).out.splitlines()
                if re.match(r"^\S+ v", line)
            }
            todo = [c for c in cargo if c not in have]
            if todo:
                run(["cargo", "install", *todo])
            done.append(f"cargo {len(todo)} new")
        else:
            waiting.append("Rust (cargo)")
    uv = wanted("uv", p.get("Uv"))
    if uv:
        if ctx.tool("uv"):
            have = {
                line.split()[0]
                for line in q(["uv", "tool", "list"]).out.splitlines()
                if line and not line.startswith("-")
            }
            todo = [t for t in uv if t not in have]
            for t in todo:
                run(["uv", "tool", "install", t])
            done.append(f"uv {len(todo)} new")
        else:
            waiting.append("uv")
    psm = wanted("psmodules", p.get("PowerShell"))
    if psm:
        if ctx.tool("pwsh"):
            for m in psm:
                run(
                    [
                        "pwsh",
                        "-NoProfile",
                        "-Command",
                        f"if (-not (Get-Module -ListAvailable -Name '{m}')) {{ Install-Module '{m}' -Scope CurrentUser -Force }}",
                    ]
                )
            done.append(f"{len(psm)} PowerShell module(s)")
        else:
            waiting.append("PowerShell")
    if waiting:
        ctx.todo(
            f"Dev packages: install {', '.join(waiting)}, then rerun with --steps dev-packages"
        )
    parts = done + ([f"waiting on {', '.join(waiting)}"] if waiting else [])
    return "; ".join(parts) if parts else "nothing to install"


# ---------------------------------------------------------------------------
# Config files
# ---------------------------------------------------------------------------
def copy_config(ctx, rel, dst, data=None, quiet=False):
    """Copy settings/<rel> to dst: same -> nothing; existing -> backed up, then replaced."""
    src = ctx.settings / rel
    if data is None:
        if not src.is_file():
            return "missing"
        data = src.read_bytes()
    if not ctx.planned("files", rel.replace("\\", "/")):
        return "skipped by plan"
    dst = Path(dst)
    if dst.exists():
        if dst.read_bytes() == data:
            return "same"
        if ctx.args.no_overwrite:
            return "kept existing"
        if ctx.dry:
            if not quiet:
                print(color("36", f"  would: back up {dst} and replace it"))
            return "would replace"
        shutil.copy2(dst, dst.with_name(f"{dst.name}.pre-restore-{STAMP}"))
    elif ctx.dry:
        if not quiet:
            print(color("36", f"  would: copy {rel} -> {dst}"))
        return "would copy"
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(data)
    return "copied"


def looks_windows(data):
    try:
        return bool(WINDOWS_ISMS.search(data.decode("utf-8", errors="replace")))
    except Exception:
        return False


def copy_dir(ctx, rel, dst_dir, skip_windows=True):
    src_dir = ctx.settings / rel
    n, skipped = 0, []
    if not src_dir.is_dir():
        return 0, skipped
    for f in sorted(p for p in src_dir.rglob("*") if p.is_file()):
        sub = f.relative_to(src_dir)
        if skip_windows and f.suffix.lower() in (".ps1", ".cmd", ".bat", ".exe"):
            skipped.append(str(sub))
            continue
        if copy_config(ctx, f"{rel}/{sub.as_posix()}", Path(dst_dir) / sub, quiet=True) in (
            "copied",
            "would copy",
            "would replace",
        ):
            n += 1
    if n:
        print(
            color(
                "36" if ctx.dry else "0",
                f"  {'would: copy' if ctx.dry else 'copied'} {n} file(s) from {rel} -> {dst_dir}",
            )
        )
    return n, skipped


# ---------------------------------------------------------------------------
# Step: git config
# ---------------------------------------------------------------------------
DROP_GIT_KEYS = {
    "core.fscache",
    "core.symlinks",
    "core.longpaths",
    "core.filemode",
    "http.sslbackend",
    "http.schannelcheckrevoke",
    "credential.helper",
    "credential.credentialstore",
    "core.useBuiltinFSMonitor".lower(),
    "core.fsmonitor",
}


def translate_gitconfig(text):
    out, notes, section, drop_section = [], [], "", False
    for line in text.replace("\r\n", "\n").split("\n"):
        stripped = line.strip()
        m = re.match(r"^\[([^\]\s\"]+)(?:\s+\"(.*)\")?\]", stripped)
        if m:
            section = m.group(1).lower()
            sub = m.group(2) or ""
            drop_section = (section == "includeif" and WINDOWS_ISMS.search(sub)) or (
                section == "credential" and sub
            )
            if drop_section:
                notes.append(f'dropped [{m.group(1)} "{sub}"] (Windows path or credential helper)')
                continue
            out.append(line)
            continue
        if drop_section:
            continue
        kv = re.match(r"^\s*([A-Za-z0-9.-]+)\s*=\s*(.*)$", line)
        if not kv:
            out.append(line)
            continue
        key, value = f"{section}.{kv.group(1).lower()}", kv.group(2)
        if key in DROP_GIT_KEYS:
            if key == "credential.helper":
                notes.append(
                    "dropped the Windows credential helper; run 'gh auth setup-git' (or set credential.helper=libsecret)"
                )
            continue
        if key == "core.autocrlf":
            out.append(re.sub(r"=.*", "= input", line))
            continue
        if key == "core.excludesfile":
            out.append(re.sub(r"=.*", "= ~/.gitignore_global", line))
            continue
        if key == "safe.directory" and value.strip() != "*" and WINDOWS_ISMS.search(value):
            continue
        if WINDOWS_ISMS.search(value):
            notes.append(f"dropped {key} = {value.strip()} (Windows path)")
            continue
        out.append(line)
    return "\n".join(out).rstrip("\n") + "\n", notes


def step_git_config(ctx):
    src = ctx.settings / "dev" / "gitconfig"
    if not src.is_file():
        return "skipped: no settings/dev/gitconfig"
    text, notes = translate_gitconfig(src.read_text(encoding="utf-8-sig", errors="replace"))
    r1 = copy_config(ctx, "dev/gitconfig", ctx.sys.home / ".gitconfig", data=text.encode())
    r2 = copy_config(ctx, "dev/gitignore_global", ctx.sys.home / ".gitignore_global")
    for n in notes:
        info(n)
    if (ctx.settings / "dev" / "npmrc").is_file():
        ctx.todo("npm: run 'npm login' (the auth token wasn't exported).")
    if ctx.tool("gh") and ctx.run.query(["gh", "auth", "status"]).code != 0:
        ctx.todo(
            "GitHub: run 'gh auth login' and 'gh auth setup-git' (before the repos step if cloning asks for credentials)."
        )
    return f"gitconfig {r1}; gitignore_global {r2}" + (
        f"; {len(notes)} Windows-only setting(s) dropped" if notes else ""
    )


# ---------------------------------------------------------------------------
# Step: repos
# ---------------------------------------------------------------------------
def step_repos(ctx):
    repos = load_json(ctx.settings / "dev" / "repos.json")
    if repos is None:
        return "skipped: no settings/dev/repos.json"
    if isinstance(repos, dict):
        repos = [repos]
    if not ctx.tool("git") and not ctx.dry:
        return "FAILED: git missing (the packages step installs it)"
    cloned, there, notes = 0, 0, []
    for r in repos:
        path = r.get("Path", "").replace("\\", "/")
        if not path or not ctx.planned("repos", r.get("Path", "")):
            continue
        if not r.get("Url"):
            notes.append(f"{path}: no remote")
            continue
        target = ctx.dev_root / path
        if (target / ".git").exists():
            there += 1
            continue
        if ctx.dry:
            print(color("36", f"  would: git clone {r['Url']} {target}"))
            cloned += 1
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        if ctx.run.run(["git", "clone", r["Url"], str(target)]).code == 0:
            cloned += 1
            branch = r.get("Branch")
            if (
                branch
                and ctx.run.query(
                    ["git", "-C", str(target), "branch", "--show-current"]
                ).out.strip()
                != branch
            ):
                if (
                    ctx.run.run(["git", "-C", str(target), "checkout", branch], show=False).code
                    != 0
                ):
                    notes.append(f"{path}: was on {branch}, which isn't on the remote")
        else:
            notes.append(f"{path}: clone failed")
    ctx.todo(
        "Repos: put back gitignored local files with --steps dev-extras (listed in settings/dev/repos.md)."
    )
    return f"cloned {cloned}, already there {there}" + (f"; {'; '.join(notes)}" if notes else "")


# ---------------------------------------------------------------------------
# Extras archive (zip files written by Backup-Extras.ps1 on Windows)
# ---------------------------------------------------------------------------
def find_extras(ctx):
    if ctx.args.extras:
        p = expand(ctx.args.extras)
        for c in (p, p / "extras"):
            if (c / "manifest.json").exists():
                return c
        return None
    name = (
        (ctx.config.get("migrationRoot") or "Hopover")
        .replace("\\", "/")
        .rstrip("/")
        .rsplit("/", 1)[-1]
    )
    user = ctx.sys.user
    for pattern in (
        f"/media/{user}/*/{name}/extras",
        f"/run/media/{user}/*/{name}/extras",
        f"/media/*/{name}/extras",
        f"/mnt/*/{name}/extras",
        f"/mnt/{name}/extras",
    ):
        for hit in sorted(Path("/").glob(pattern.lstrip("/"))):
            if (hit / "manifest.json").exists():
                return hit
    return None


def extras_items(ctx, prefix):
    root = find_extras(ctx)
    if not root:
        return None, []
    m = load_json(root / "manifest.json", {}) or {}
    items = [
        i
        for i in m.get("Items", [])
        if i.get("File")
        and i.get("Status") in ("ok", "PARTIAL")
        and any(i["Name"].startswith(p) for p in prefix)
    ]
    return root, items


def extract_zip(ctx, zpath, into):
    """Extract without overwriting existing files. Returns the number of files written."""
    n = 0
    into = Path(into).resolve()
    with zipfile.ZipFile(zpath) as z:
        for member in z.infolist():
            name = member.filename.replace("\\", "/")
            if member.is_dir() or not name or name.startswith("/") or ".." in Path(name).parts:
                continue
            target = (into / name).resolve()
            if not str(target).startswith(str(into) + os.sep) or target.exists():
                continue
            if ctx.dry:
                n += 1
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with z.open(member) as src, open(target, "wb") as dst:
                shutil.copyfileobj(src, dst)
            n += 1
    return n


def step_dev_extras(ctx):
    root, items = extras_items(ctx, ["dev-"])
    if root is None:
        return "skipped: extras archive not found (plug in the migration drive, or pass --extras <folder>)"
    items = [i for i in items if ctx.planned("extras", i["Name"])]
    total = 0
    for i in items:
        into = (
            ctx.dev_root / "_restored-patches" if i["Name"] == "dev-uncommitted" else ctx.dev_root
        )
        n = extract_zip(ctx, root / i["File"], into)
        info(f"{i['Name']}: {n} file(s){' would be' if ctx.dry else ''} restored")
        total += n
        if i["Name"] == "dev-uncommitted":
            ctx.todo(
                f"Uncommitted changes from Windows are in {into}; apply with: git -C <repo> apply <file>.patch"
            )
    others = [i["Name"] for i in extras_items(ctx, ["app-"])[1]]
    if others:
        ctx.todo(
            f"Windows app data in the extras archive ({', '.join(others)}): copy what you need into the Linux app's folder (World of Warcraft: into the Wine/Lutris prefix's WoW folder)."
        )
    return f"{total} file(s) from {len(items)} archive(s)"


def step_docker_volumes(ctx):
    root = find_extras(ctx)
    if not root:
        return "skipped: extras archive not found"
    vol_dir = root / "docker-volumes"
    tgz = sorted(vol_dir.glob("*.tgz")) if vol_dir.is_dir() else []
    if not tgz:
        return "skipped: no volume archives"
    if not ctx.tool("docker") or ctx.run.query(["docker", "info"]).code != 0:
        return "skipped: Docker isn't running (start it, or log out and in after joining the docker group), then rerun --steps docker-volumes"
    have = set(ctx.run.query(["docker", "volume", "ls", "--format", "{{.Name}}"]).out.split())
    n = 0
    for t in tgz:
        v = t.name[:-4]
        if not ctx.planned("docker-volumes", v) or v in have:
            continue
        ctx.run.run(["docker", "volume", "create", v])
        if (
            ctx.run.run(
                [
                    "docker",
                    "run",
                    "--rm",
                    "-v",
                    f"{v}:/data",
                    "-v",
                    f"{vol_dir}:/backup:ro",
                    "alpine",
                    "tar",
                    "xzf",
                    f"/backup/{t.name}",
                    "-C",
                    "/data",
                ]
            ).code
            == 0
        ):
            n += 1
    return f"restored {n} of {len(tgz)}"


# ---------------------------------------------------------------------------
# Step: VS Code
# ---------------------------------------------------------------------------
def step_vscode(ctx):
    variants = [
        ("code", ".config/Code/User"),
        ("code-insiders", ".config/Code - Insiders/User"),
        ("codium", ".config/VSCodium/User"),
        ("code-oss", ".config/Code - OSS/User"),
    ]
    cli, user_dir = next(
        ((c, d) for c, d in variants if ctx.tool(c)), ("code", ".config/Code/User")
    )
    user = ctx.sys.home / user_dir
    res = []
    for f in ("settings.json", "keybindings.json", "mcp.json", "tasks.json"):
        r = copy_config(ctx, f"vscode/{f}", user / f)
        if r != "missing":
            res.append(f"{f} {r}")
    sn, _ = copy_dir(ctx, "vscode/snippets", user / "snippets")
    pr, _ = copy_dir(ctx, "vscode/prompts", user / "prompts")
    if not ctx.tool(cli):
        return "; ".join(res) + "; extensions waiting on VS Code (the packages step installs it)"
    want_file = ctx.settings / "vscode" / "extensions.txt"
    want = (
        [line.strip() for line in want_file.read_text(encoding="utf-8-sig").splitlines()]
        if want_file.exists()
        else []
    )
    want = [w for w in want if w and ctx.planned("vscode-extensions", w)]
    # VS Code refuses to run as root without its own data folder (only matters in containers).
    extra = (
        ["--no-sandbox", "--user-data-dir", str(ctx.sys.home / ".vscode-root")]
        if ctx.sys.is_root
        else []
    )

    def listing():
        return {
            line.strip().lower()
            for line in ctx.run.query([cli, *extra, "--list-extensions"]).out.splitlines()
        }

    todo = [w for w in want if w.lower() not in listing()]
    if todo:
        # One call installs them all and carries on past any that fail.
        args = [cli, *extra] + [a for e in todo for a in ("--install-extension", e)] + ["--force"]
        out = ctx.run.run(args, capture=True, show=False)
        if not ctx.dry:
            info(f"code --install-extension x{len(todo)}")
    failed = [] if ctx.dry else [e for e in todo if e.lower() not in listing()]
    if failed and out.out.strip():
        for line in out.out.strip().splitlines()[-5:]:
            warn(f"code: {line}")
    if failed:
        ctx.todo(
            f"VS Code: these extensions didn't install (some are Windows-only): {', '.join(failed)}"
        )
    return (
        "; ".join(res)
        + f"; {sn} snippet(s), {pr} prompt(s); {len(todo) - len(failed)} extension(s) installed"
    )


# ---------------------------------------------------------------------------
# Step: Claude Code and Codex
# ---------------------------------------------------------------------------
def claude_dir_name(path):
    return re.sub(r"[^A-Za-z0-9]", "-", str(path))


def copy_or_park(ctx, rel, dst):
    """Copy a config file, or park it beside the target as *.windows.* when it's written for Windows."""
    src = ctx.settings / rel
    if not src.is_file():
        return "missing"
    data = src.read_bytes()
    if looks_windows(data) and Path(dst).suffix.lower() in (".md", ".txt"):
        # Instructions are prose: a mention of a Windows path doesn't break anything, so copy and flag it.
        r = copy_config(ctx, rel, dst)
        ctx.todo(
            f"{rel} mentions Windows paths or programs; review {dst} for anything that only applied on Windows."
        )
        return r
    if looks_windows(data):
        parked = Path(dst).with_name(Path(dst).stem + ".windows" + Path(dst).suffix)
        r = copy_config(ctx, rel, parked)
        ctx.todo(
            f"{rel} refers to Windows paths or programs; it was saved as {parked} for you to merge by hand."
        )
        return f"saved as {parked.name} (Windows paths)" if r != "skipped by plan" else r
    return copy_config(ctx, rel, dst)


def step_claude(ctx):
    src = ctx.settings / "claude"
    if not src.is_dir():
        return "skipped: no settings/claude"
    c = ctx.sys.home / ".claude"
    res = []
    for f in ("CLAUDE.md", "settings.json", "keybindings.json"):
        r = copy_or_park(ctx, f"claude/{f}", c / f)
        if r != "missing":
            res.append(f"{f} {r}")
    n, skipped = 0, []
    for d in ("agents", "commands", "themes", "hooks"):
        k, s = copy_dir(ctx, f"claude/{d}", c / d)
        n += k
        skipped += [f"{d}/{x}" for x in s]
    if skipped:
        ctx.todo(
            f"Claude Code: Windows scripts not copied ({', '.join(skipped)}); rewrite any hooks that used them."
        )
    # Memory folders are named after the project path; map the Windows dev root to the Linux one.
    win = claude_dir_name(ctx.win_dev_root)
    lin = claude_dir_name(ctx.dev_root)
    mem = 0
    mem_src = src / "memory"
    if mem_src.is_dir():
        for proj in sorted(p for p in mem_src.iterdir() if p.is_dir()):
            name = proj.name
            if name == win or name.startswith(win + "-"):
                name = lin + name[len(win) :]
            k, _ = copy_dir(
                ctx,
                f"claude/memory/{proj.name}",
                c / "projects" / name / "memory",
                skip_windows=False,
            )
            mem += k
    mcp = load_json(src / "mcp-servers.json", {}) or {}
    added = 0
    if mcp.get("user") and ctx.tool("claude"):
        existing = ctx.run.query(["claude", "mcp", "list"]).out
        for name, cfg in mcp["user"].items():
            if (
                name in existing
                or not cfg.get("url")
                or cfg.get("headers")
                or cfg.get("env")
                or not ctx.planned("mcp", name)
            ):
                continue
            if (
                ctx.run.run(
                    [
                        "claude",
                        "mcp",
                        "add",
                        "--transport",
                        cfg.get("type", "http"),
                        name,
                        cfg["url"],
                        "--scope",
                        "user",
                    ]
                ).code
                == 0
            ):
                added += 1
    elif mcp.get("user"):
        ctx.todo(
            "Claude Code: install it (the packages step does), then rerun --steps claude to add your MCP servers."
        )
    ctx.todo(
        "Claude Code: sign in, and reinstall skills (settings/claude/skills.md) and plugins (settings/claude/plugins)."
    )
    return (
        "; ".join(res)
        + f"; {n} agent/command/theme/hook file(s); {mem} memory file(s); {added} MCP server(s) added"
    )


def step_codex(ctx):
    src = ctx.settings / "codex"
    if not src.is_dir():
        return "skipped: no settings/codex"
    c = ctx.sys.home / ".codex"
    res = []
    for f in sorted(p.name for p in src.iterdir() if p.is_file()):
        if f == "skills.md":
            continue
        if Path(f).suffix.lower() in (".ps1", ".cmd", ".bat"):
            ctx.todo(
                f"Codex: {f} is a Windows script and wasn't copied; recreate it for Linux if your config uses it."
            )
            continue
        res.append(f"{f} {copy_or_park(ctx, f'codex/{f}', c / f)}")
    n, _ = copy_dir(ctx, "codex/rules", c / "rules")
    ctx.todo(
        "Codex: sign in (auth.json wasn't exported) and reinstall skills listed in settings/codex/skills.md."
    )
    return "; ".join(res) + f"; {n} rule file(s)"


STEP_FUNCS = {
    "packages": step_packages,
    "dev-packages": step_dev_packages,
    "git-config": step_git_config,
    "repos": step_repos,
    "dev-extras": step_dev_extras,
    "vscode": step_vscode,
    "claude": step_claude,
    "codex": step_codex,
    "docker-volumes": step_docker_volumes,
}


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
def write_report(ctx, path):
    r = ctx.report
    lines = [
        "# Linux restore report",
        "",
        f"{time.strftime('%Y-%m-%d %H:%M')} on {ctx.sys.describe()}{' (dry run)' if ctx.dry else ''}.",
        "",
    ]

    def section(title, items):
        if items:
            lines.extend([f"## {title}", ""] + [f"- {i}" for i in items] + [""])

    section("Installed" if not ctx.dry else "Would install", r["installed"])
    section("Already installed", r["present"])
    section("Failed", [f"{n}: {why}" for n, why in r["failed"]])
    section(
        "No Linux version",
        [
            f"{n}: {why}" + (f" Alternatives: {', '.join(alts)}." if alts else "")
            for n, why, alts in r["none"]
        ],
    )
    section("Not in the catalog (add them to catalog/linux-packages.json)", r["unmapped"])
    section("Skipped by your plan or config", r["planned"])
    section("Notes", r["notes"])
    section("Still to do by hand", ctx.manual)
    if r["windows_only"]:
        lines += ["## Windows-only (nothing to install)", "", ", ".join(r["windows_only"]), ""]
    lines += ["## Steps", "", "| Step | Result |", "| --- | --- |"] + [
        f"| {s} | {res} |" for s, res in ctx.results
    ]
    try:
        Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")
        return True
    except OSError:
        return False


def main():
    default_data = os.environ.get("HOPOVER_DATA") or str(TOOL / "data")
    ap = argparse.ArgumentParser(
        description="Set up Linux from a Windows PC's exports (see the tool's README)."
    )
    ap.add_argument(
        "--data",
        default=default_data,
        help="data folder (default: $HOPOVER_DATA, else <tool>/data)",
    )
    ap.add_argument(
        "--extras",
        help="folder holding the extras archive (default: look for <migrationRoot name>/extras on mounted drives)",
    )
    ap.add_argument(
        "--dev-root", help="where to clone repos (default: the linux.devRoot option, ~/dev)"
    )
    ap.add_argument("--steps", help="comma-separated steps to run (default: all; see --list)")
    ap.add_argument(
        "--only",
        help="comma-separated app ids (winget ids or catalog keys) to limit the packages step to",
    )
    ap.add_argument("--dry-run", action="store_true", help="show what would happen; change nothing")
    ap.add_argument(
        "--refresh",
        action="store_true",
        help="with --dry-run: refresh package metadata (needs sudo) so package names are checked",
    )
    ap.add_argument(
        "--prefer",
        help="install source order, e.g. vendor,distro,portable,flatpak (default: the linux.prefer option)",
    )
    ap.add_argument("--no-flatpak", action="store_true", help="never use Flathub")
    ap.add_argument(
        "--aur",
        choices=["auto", "never"],
        help="use an AUR helper (yay/paru) if one is installed (default: the linux.aur option)",
    )
    ap.add_argument("--no-overwrite", action="store_true", help="leave existing config files alone")
    ap.add_argument(
        "--ignore-plan", action="store_true", help="restore everything, ignoring restore-plan.json"
    )
    ap.add_argument(
        "--report", help="where to write the report (default: ~/hopover-linux-<timestamp>.md)"
    )
    ap.add_argument("--list", action="store_true", help="list the steps and exit")
    args = ap.parse_args()

    if args.list:
        for name, text in STEPS:
            print(f"{name:16} {text}")
        return 0
    if os.geteuid() == 0 and os.environ.get("SUDO_USER"):
        print(
            "Run this as your normal user (not with sudo); it asks for sudo when it needs it.",
            file=sys.stderr,
        )
        return 1

    ctx = Ctx(args)
    if not (ctx.data / "settings").is_dir() and not (ctx.data / "winget-packages.json").exists():
        print(
            f"No exports in {ctx.data}. Pass --data <your data folder> (the folder with settings/ and winget-packages.json).",
            file=sys.stderr,
        )
        return 1
    if not ctx.sys.family:
        print("This distro isn't supported: no apt-get, dnf or pacman found.", file=sys.stderr)
        return 1

    print(color("36;1", f"Linux restore{' (DRY RUN)' if ctx.dry else ''}"))
    info(f"system: {ctx.sys.describe()}")
    info(f"data:   {ctx.data}")
    info(f"plan:   {ctx.plan_file or 'none (restoring everything)'}")
    info(
        f"order:  {' > '.join(ctx.linux['prefer'])}; AUR {ctx.linux.get('aur')}; Flathub {'on' if ctx.linux.get('flatpak', True) else 'off'}"
    )
    if ctx.dry and not args.refresh:
        info(
            "package names aren't checked against the repos in a dry run (add --refresh to check them; needs sudo)"
        )
    if not ctx.sys.is_root and not ctx.dry and shutil.which("sudo"):
        subprocess.run(["sudo", "-v"])

    wanted = [s.strip() for s in (args.steps or "").split(",") if s.strip()]
    unknown = [s for s in wanted if s not in STEP_FUNCS]
    if unknown:
        print(f"Unknown step(s): {', '.join(unknown)}. Run with --list.", file=sys.stderr)
        return 1
    for name, text in STEPS:
        if wanted and name not in wanted:
            continue
        if not wanted and name in ctx.skip_steps:
            ctx.results.append((name, "skipped by plan"))
            continue
        head(f"{name}: {text}")
        ctx.plan_hits = 0
        try:
            status = STEP_FUNCS[name](ctx) or "done"
        except Exception as e:  # keep going; one broken step shouldn't stop the rest
            status = f"FAILED: {e}"
        if ctx.plan_hits:
            status += f"; {ctx.plan_hits} item(s) skipped by plan"
        ctx.results.append((name, status))
        (warn if status.startswith(("FAILED", "skipped")) else good)(f"-> {status}")

    r = ctx.report
    head("Summary")
    for name, status in ctx.results:
        info(f"{name:16} {status}")
    if r["failed"]:
        head("Failed")
        for n, why in r["failed"]:
            warn(f"{n}: {why}")
    if r["none"]:
        head("No Linux version")
        for n, why, alts in r["none"]:
            info(f"{n}: {why}" + (f" Try: {', '.join(alts)}." if alts else ""))
    if r["unmapped"]:
        head("Not in the catalog")
        info(", ".join(r["unmapped"]))
        info("Add them to catalog/linux-packages.json (or install them by hand).")
    if r["notes"] or ctx.manual:
        head("Still to do by hand")
        for m in r["notes"] + ctx.manual:
            print(f"  [ ] {m}")
    report = args.report or str(ctx.sys.home / f"hopover-linux-{STAMP}.md")
    if write_report(ctx, report):
        print()
        info(f"Report: {report}")
    return 1 if any(s.startswith("FAILED") for _, s in ctx.results) else 0


if __name__ == "__main__":
    sys.exit(main())
