# WSL-Core (Intune Win32 app)

Installs or updates Windows Subsystem for Linux from the latest GitHub release MSI and
enables `VirtualMachinePlatform`. Distributions are separate per-user packages (see `../WSL-Distro`).

## How install.ps1 works

1. Enable `VirtualMachinePlatform` explicitly (reboot flagged if newly enabled).
2. Resolve latest release: GitHub API first (gives SHA256 digest), release-page redirect as
   fallback (API limit: 60 unauthenticated requests/hour per public IP).
3. Download MSI (x64 or arm64) to a SYSTEM/Administrators-only folder.
4. Verify SHA256 (when available) and Authenticode signature (`CN=Microsoft Corporation`,
   chain to Microsoft root).
5. Skip if installed version >= latest, else `msiexec /i ... /qn /norestart`.
6. Online failure: use bundled `wsl.<version>.<arch>.msi` next to the script, if present.
7. Exit `3010` when a reboot is required, `0` on success.

### Why not `wsl.exe --install --web-download`

Tested as SYSTEM (pilot, 2026-11-17): the inbox `wsl.exe` stub requests UAC elevation and
fails with `The handle is invalid.` / `The requested operation requires elevation.`
(exit 1). SYSTEM has no interactive desktop for that request. The script installs the
same GitHub release directly with msiexec instead.

Logs: `C:\ProgramData\IntuneLogs\Applications\WSL-Core\` (`yyyyMMdd-install.log`, `yyyyMMdd-detection.log`, ...; max 14 per kind).

## Files

| File | Purpose |
|---|---|
| `install.ps1` | Install/update (packaged) |
| `uninstall.ps1` | MSI removal by product code; `VirtualMachinePlatform` stays on unless `$disableRequiredFeature = $true` (packaged) |
| `detection.ps1` | `wsl.exe` >= `$minimumVersion` and feature `Enabled`/`EnablePending` (upload separately) |
| `requirement.ps1` | OS build >= 19045 and virtualization available (upload separately) |

## Intune app settings

| Setting | Value |
|---|---|
| Install command | `%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\install.ps1` |
| Uninstall command | `%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\uninstall.ps1` |
| Install behavior | System |
| Return code 3010 | Soft reboot |
| Requirement script | `requirement.ps1`, String, Equals, `Supported`, 32-bit: **No** |
| Detection script | `detection.ps1`, 32-bit: **No** |

## Updates

Detection only enforces `$minimumVersion`. Once detected, Intune does not run install.ps1
again. To force an update fleet-wide, raise `$minimumVersion` in `detection.ps1`.

## Test checklist (pilot)

Run as SYSTEM: `psexec -s -i %WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe`

- [ ] Clean device, feature off: install.ps1 exits 3010, detection succeeds before reboot.
- [ ] After reboot: `wsl --version` works for a user.
- [ ] Device with WSL already installed: update path runs, exit 0.
- [ ] Check `install.log` for readable `wsl:` output lines (UTF-8 handling).
- [ ] Record wsl.exe exit codes seen (success / already installed / no network).
- [ ] uninstall.ps1: MSI `DisplayName` is `Windows Subsystem for Linux`, removal exit 0.
- [ ] Network: `github.com` and `release-assets.githubusercontent.com` reachable as SYSTEM
      (machine proxy if needed).
