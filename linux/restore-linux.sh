#!/usr/bin/env bash
# restore-linux.sh: set up a Linux install from a Windows PC's Backup (or the exports in a data
# folder). Makes sure python3 and curl exist, and 7-Zip for a Backup, then runs restore_linux.py.
#
#   linux/restore-linux.sh --backup "/media/me/USB/Laptop 2026-11-27.hopover.7z" --dry-run
#                                           # open the Backup and show what would happen
#   linux/restore-linux.sh --backup <file>  # do it (asks for the password, and for sudo when needed)
#   linux/restore-linux.sh --list           # list the steps
#   linux/restore-linux.sh --help           # all options
#
# The password is asked for once, or read from standard input when a program pipes it in.
# Run it as your normal user, not with sudo. Works on apt (Debian, Ubuntu, Linux Mint, Pop!_OS...),
# dnf (Fedora) and pacman (Arch, CachyOS, EndeavourOS, Manjaro) systems. Note: if python3 or curl
# is missing, or 7-Zip when --backup is given, this installs it first, even with --dry-run. It stops
# if python3 is older than 3.10.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    echo "Run this as your normal user (not with sudo); it asks for sudo when it needs it." >&2
    exit 1
fi

family=""
if command -v apt-get >/dev/null 2>&1; then
    family=apt
elif command -v dnf >/dev/null 2>&1; then
    family=dnf
elif command -v pacman >/dev/null 2>&1; then
    family=pacman
fi
sudo=""
if [ "$(id -u)" -ne 0 ]; then sudo="sudo"; fi

# Installs packages with the distro's package manager; fails when one isn't there.
apt_updated=""
install_packages() {
    case "$family" in
        apt)
            if [ -z "$apt_updated" ]; then
                $sudo apt-get update || return 1
                apt_updated=1
            fi
            $sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
            ;;
        dnf) $sudo dnf install -y "$@" ;;
        # Arch doesn't support partial upgrades, so sync and upgrade together.
        pacman) $sudo pacman -Syu --needed --noconfirm "$@" ;;
        *) return 1 ;;
    esac
}

# 7-Zip opens Backups: the 7zip package's 7z (7zz on Ubuntu 22.04 and Debian 12), or p7zip's 7za.
have_7zip() {
    command -v 7z >/dev/null 2>&1 || command -v 7zz >/dev/null 2>&1 || command -v 7za >/dev/null 2>&1
}

missing=()
command -v python3 >/dev/null 2>&1 || missing+=(python3)
command -v curl    >/dev/null 2>&1 || missing+=(curl)

if [ "${#missing[@]}" -gt 0 ]; then
    if [ -z "$family" ]; then
        echo "No apt-get, dnf or pacman found. Install python3 and curl yourself, then rerun." >&2
        exit 1
    fi
    echo "Installing ${missing[*]} first..."
    if [ "$family" = pacman ]; then
        install_packages python curl ca-certificates
    else
        install_packages python3 curl ca-certificates
    fi
fi

# Only a restore from a Backup needs 7-Zip, so --list, --help and a data folder never install it
# (on Arch an install upgrades the whole system).
from_backup=""
for a in "$@"; do
    case "$a" in --backup|--backup=*) from_backup=1 ;; esac
done
if [ -n "$from_backup" ] && ! have_7zip && [ -n "$family" ]; then
    echo "Installing 7-Zip, which opens Backups..."
    # The 7zip package where the release has one; p7zip where it doesn't (Fedora 41 and 42).
    case "$family" in
        apt) install_packages 7zip || install_packages p7zip-full || true ;;
        *) install_packages 7zip || install_packages p7zip || true ;;
    esac
fi
if [ -n "$from_backup" ] && ! have_7zip; then
    echo "No 7-Zip (7z, 7zz or 7za): restoring a Backup needs the distro's 7zip or p7zip package." >&2
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
