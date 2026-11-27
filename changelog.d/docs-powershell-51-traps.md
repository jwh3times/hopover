### Changed

- For contributors, `AGENTS.md` lists two more Windows PowerShell 5.1 traps. A file from
  `Get-ChildItem` turns into its bare name, not its full path, where a string is expected. A
  process started with its input redirected gets a BOM before what's written to it, so start one
  with `Start-InputProcess` in `lib/Backup.ps1`.
