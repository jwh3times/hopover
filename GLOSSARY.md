# Hopover

Hopover moves one PC's apps, settings and files onto a fresh install of Windows or Linux, for anyone from a first-time user to a developer with many repos.

## Language

### The Backup

**Backup**:
The one file Hopover makes of a PC: its apps, settings, app data, drivers and the user's own files, encrypted by default. The user names it and keeps it anywhere, on a drive or in the cloud. Each Backup holds everything a restore needs.
_Avoid_: snapshot, export, archive, capsule, migration drive

**Cloud backup service**:
A third-party service such as Backblaze or OneDrive that keeps copies of files online. It is not a Backup, and Hopover only checks on it.
_Avoid_: backup (without "cloud")

**Companion repo**:
An optional private git repository holding the redacted settings of each Backup, so a developer can see what changed between Backups. It is never needed to restore.
_Avoid_: data repo, private repo, data folder

**Your files**:
The user's own folders (Desktop, Documents, Pictures, Music, Videos, Downloads) as a part of a Backup.
_Avoid_: user data, personal data

**Passwords and keys**:
The secrets a user owns, such as SSH keys, Wi-Fi passwords and tokens in settings files. Only an encrypted Backup carries them. Sign-in sessions and browser cookies are never among them.
_Avoid_: credentials, secrets

**Wiped drive**:
A drive the user will erase when reinstalling. The Windows drive always is one.
_Avoid_: keep drive, target drive

**Ready check**:
The go/no-go test before wiping: that a Backup will survive the wipe, opens with its password, and is recent.
_Avoid_: wipe check, preflight

**Synced folder**:
A folder that a cloud backup service keeps online, which comes back when the user signs in to that service. A Backup lists it but leaves it out unless the user ticks it.
_Avoid_: cloud folder, OneDrive folder

### Choosing what comes back

**Group**:
A plain-language part of a Backup that the user turns on or off: Apps, Your files, Settings, Games, Developer tools. Only groups found on the PC are shown.
_Avoid_: category, section

**Item**:
One thing within a group that can be ticked or unticked: an app, a folder, a settings file, a repo.
_Avoid_: entry, element

**Customize**:
The view that lists every item in every group, for a user who wants to choose item by item.
_Avoid_: advanced mode, plan page

**Plan**:
The user's choices of what not to restore. Anything the plan doesn't leave out is restored.
_Avoid_: restore list, selection

**Step**:
One stage of a restore, such as installing apps or cloning repos, run in a fixed order.
_Avoid_: task, phase

**To-do list**:
What a restore couldn't do by itself (signing in, apps no installer covers), kept until the user ticks each item off.
_Avoid_: manual steps, still to do by hand

**Options**:
How Hopover itself behaves on a PC (where repos go, which drives get wiped, the Linux install order), chosen on the page and carried in each Backup.
_Avoid_: settings, config

**Catalog key**:
Hopover's own name for an app, the same on every OS. A Backup lists apps by it, so a Backup made on one OS can be restored on another.
_Avoid_: app id, package id
