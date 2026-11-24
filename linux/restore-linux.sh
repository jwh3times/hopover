#!/usr/bin/env bash
# restore-linux.sh: set up a Linux install from the exports a Windows PC made
# with this tool. Makes sure python3 and curl exist, then runs restore_linux.py.
#
#   linux/restore-linux.sh --dry-run        # show what would happen, change nothing
#   linux/restore-linux.sh                  # do it (asks for sudo when needed)
#   linux/restore-linux.sh --list           # list the steps
#   linux/restore-linux.sh --help           # all options
#
# Run it as your normal user, not with sudo. Works on apt (Debian, Ubuntu,
# Linux Mint, Pop!_OS...), dnf (Fedora) and pacman (Arch, CachyOS, EndeavourOS,
# Manjaro) systems. Note: if python3 or curl is missing, this installs them
# first, even with --dry-run. It stops if python3 is older than 3.10.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    echo "Run this as your normal user (not with sudo); it asks for sudo when it needs it." >&2
    exit 1
fi

missing=()
command -v python3 >/dev/null 2>&1 || missing+=(python3)
command -v curl    >/dev/null 2>&1 || missing+=(curl)

if [ "${#missing[@]}" -gt 0 ]; then
    sudo=""
    if [ "$(id -u)" -ne 0 ]; then sudo="sudo"; fi
    echo "Installing ${missing[*]} first..."
    if command -v apt-get >/dev/null 2>&1; then
        $sudo apt-get update
        $sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y python3 curl ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        $sudo dnf install -y python3 curl ca-certificates
    elif command -v pacman >/dev/null 2>&1; then
        # Arch doesn't support partial upgrades, so sync and upgrade together.
        $sudo pacman -Syu --needed --noconfirm python curl ca-certificates
    else
        echo "No apt-get, dnf or pacman found. Install python3 and curl yourself, then rerun." >&2
        exit 1
    fi
fi

# restore_linux.py needs Python 3.10 or newer. Checked here, in bash, because an older python3
# may fail to parse the script before it could say so itself.
if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
    found="$(python3 -c 'import platform; print(platform.python_version())' 2>/dev/null || echo unknown)"
    echo "restore_linux.py needs Python 3.10 or newer; this system's python3 is ${found}." >&2
    echo "Upgrade the distro, or install a newer python3, then rerun." >&2
    exit 1
fi

exec python3 "$here/restore_linux.py" "$@"
