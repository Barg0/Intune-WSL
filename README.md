# WSL for Microsoft Intune

Deploys Windows Subsystem for Linux (WSL) and Linux distributions as Intune Win32 apps.

| Package | Context | What it does |
|---|---|---|
| [`WSL-Core`](WSL-Core/README.md) | **System** | Enables `VirtualMachinePlatform`, installs or updates WSL from the latest GitHub release MSI (hash + signature checked) |
| [`WSL-Distro`](WSL-Distro/README.md) | **User** | Registers one Linux distribution for the signed-in user. One Intune app per distribution, same package |

Why two contexts: WSL itself is a machine component (admin rights). Distributions are
registered per user (`HKCU\...\Lxss`) and their disk lives in the user profile, so they
must be installed as the user.

```
intune-wsl/
+-- WSL-Core/
|   +-- install.ps1        packaged
|   +-- uninstall.ps1      packaged
|   +-- detection.ps1      upload as detection script
|   +-- requirement.ps1    upload as requirement script
+-- WSL-Distro/
|   +-- install.ps1        packaged, -DistributionName <Name>
|   +-- uninstall.ps1      packaged, -DistributionName <Name>
|   +-- detection/
|       +-- detection-<Name>.ps1     one per distribution, upload as detection script
|       +-- detection-TEMPLATE.ps1   copy for new distributions
+-- POWERSHELL_GUIDELINES.md
```

---

## 1. Packaging

Only `install.ps1` and `uninstall.ps1` go into the `.intunewin`. Detection and
requirement scripts are uploaded separately in the Intune portal.

```powershell
# Staging folders keep detection scripts out of the packages
New-Item -ItemType Directory .\pkg\WSL-Core, .\pkg\WSL-Distro, .\out -Force | Out-Null
Copy-Item .\WSL-Core\install.ps1, .\WSL-Core\uninstall.ps1 .\pkg\WSL-Core\
Copy-Item .\WSL-Distro\install.ps1, .\WSL-Distro\uninstall.ps1 .\pkg\WSL-Distro\

.\IntuneWinAppUtil.exe -c .\pkg\WSL-Core   -s install.ps1 -o .\out -q
.\IntuneWinAppUtil.exe -c .\pkg\WSL-Distro -s install.ps1 -o .\out -q
```

The single `WSL-Distro` `.intunewin` is uploaded once per distribution app. Only the
command line and the detection script differ.

---

## 2. WSL-Core (System)

| Setting | Value |
|---|---|
| Install command | `%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\install.ps1` |
| Uninstall command | `%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\uninstall.ps1` |
| Install behavior | System |
| Device restart behavior | Determine behavior based on return codes |
| Return codes | `0` Success, `3010` Soft reboot, `1641` Hard reboot (defaults) |
| Requirements | Windows 10 22H2 or later, x64 and arm64 |
| Requirement script | `WSL-Core\requirement.ps1`, output type String, Equals `Supported`, run as 32-bit: **No** |
| Detection | Custom script `WSL-Core\detection.ps1`, run as 32-bit: **No**, enforce signature: No |
| Assignment | Required (devices) or Available (users) |

System context runs in session 0, no window is visible to the user.

---

## 3. Distributions (User)

### Common settings for every distribution app

| Setting | Value |
|---|---|
| Install behavior | **User** |
| Device restart behavior | No specific action |
| Return codes | `0` Success, `1618` **Retry** (default, returned while a reboot is pending) |
| Detection | Custom script `WSL-Distro\detection\detection-<Name>.ps1`, run as 32-bit: **No** |
| Dependency | `WSL-Core`, automatically install: **Yes** |
| Assignment | Users, Available (Company Portal) recommended |

### Hidden window

User-context installs run in the user's session, so a plain `powershell.exe` call shows a
console window. All commands below use `-WindowStyle Hidden`. Windows still creates the
console before PowerShell hides it, so a very short flash can remain; that is a
PowerShell limitation, not a script issue.

<details>
<summary>Optional: no flash at all (test first)</summary>

`conhost.exe --headless` starts PowerShell without any visible console:

```
%WINDIR%\sysnative\conhost.exe --headless %WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\install.ps1 -DistributionName Ubuntu-24.04
```

Not verified: whether conhost passes the script exit code (`1618`, errors) back to Intune.
Only switch to this after a pilot test shows correct success/retry/failure states in Intune.
</details>

### Install and uninstall commands

**Ubuntu 24.04 LTS** - detection: `detection-Ubuntu-24.04.ps1`
```
%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File .\install.ps1 -DistributionName Ubuntu-24.04
%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File .\uninstall.ps1 -DistributionName Ubuntu-24.04
```

**Ubuntu 26.04 LTS** - detection: `detection-Ubuntu-26.04.ps1`
```
%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File .\install.ps1 -DistributionName Ubuntu-26.04
%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File .\uninstall.ps1 -DistributionName Ubuntu-26.04
```

**Debian** - detection: `detection-Debian.ps1`
```
%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File .\install.ps1 -DistributionName Debian
%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File .\uninstall.ps1 -DistributionName Debian
```

**Azure Linux 4** - detection: `detection-AzureLinux-4.ps1`
```
%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File .\install.ps1 -DistributionName AzureLinux-4
%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File .\uninstall.ps1 -DistributionName AzureLinux-4
```

**Fedora Linux 45** - detection: `detection-FedoraLinux-45.ps1`
```
%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File .\install.ps1 -DistributionName FedoraLinux-45
%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File .\uninstall.ps1 -DistributionName FedoraLinux-45
```

**Arch Linux** - detection: `detection-archlinux.ps1` - requirement: architecture **x64 only** (no arm64 image)
```
%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File .\install.ps1 -DistributionName archlinux
%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File .\uninstall.ps1 -DistributionName archlinux
```

### Adding another distribution

1. `wsl --list --online` on a client shows the valid names (case-sensitive in detection).
2. Copy `detection-TEMPLATE.ps1` to `detection-<Name>.ps1`, replace `__DISTRIBUTION_NAME__`.
3. Create a new Intune app with the `WSL-Distro` package and `-DistributionName <Name>`.

### What the user sees

1. Installs the distribution from Company Portal (WSL-Core is pulled in automatically).
2. If WSL-Core enabled `VirtualMachinePlatform`: reboot, Intune retries the distribution.
3. Opens the distribution from the Start menu or Windows Terminal and creates the Linux
   user name and password (first-run setup). No credentials are stored in Intune.

> **Warning:** Uninstalling a distribution runs `wsl --unregister`, which permanently
> deletes everything inside it. `uninstall.ps1` exports a backup to
> `%USERPROFILE%\WSL-Backup\<Name>-<timestamp>.tar` first and aborts if the export fails.
> Restore with `wsl --import <Name> <InstallFolder> <BackupFile>`.

---

## 4. Logging

Rule for the whole project (see `POWERSHELL_GUIDELINES.md`, section 4):

| | Path |
|---|---|
| System context (WSL-Core) | `C:\ProgramData\IntuneLogs\Applications\WSL-Core\` |
| User context (distributions) | `%LOCALAPPDATA%\IntuneLogs\Applications\<USERNAME>\WSL-Distro-<Name>\` |

- File name: `yyyyMMdd-<kind>.log`, e.g. `20261117-install.log`, `20261117-detection.log`,
  `20261117-uninstall.log`, `20261117-requirement.log`, `20261117-msiexec-install.log`, `20261117-msiexec-uninstall.log`.
- Max **14 files per kind**; older ones are removed at script start.
- `wsl.exe` output is written to the log as `wsl: ...` lines.

---

## 5. Recommended Intune configuration (outside these packages)

Settings catalog, category "Windows Subsystem for Linux" (Microsoft recommendations):

| Setting | Value |
|---|---|
| Allow the Inbox version of the Windows Subsystem for Linux | Disabled |
| Allow WSL1 | Disabled |
| Allow the debug shell | Disabled |
| Allow custom kernel configuration | Disabled |
| Allow kernel command line configuration | Disabled |
| Allow custom system distribution configuration | Disabled |
| Allow custom networking configuration | Disabled |
| Allow user setting firewall configuration | Disabled |
| Allow nested virtualization | Disabled |
| Allow kernel debugging | Disabled |

Also consider the Microsoft Defender for Endpoint plug-in for WSL. Patching inside the
distributions is not handled by Windows tools; that stays with the user or a Linux
configuration management tool.

---

## 6. Pilot test checklist

WSL-Core (test as SYSTEM: `psexec -s -i %WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe`)
- [ ] Clean device: exit `3010`, detection succeeds before reboot (`EnablePending`).
- [ ] After reboot: `wsl --version` works for a standard user.
- [ ] WSL already installed: update path runs, exit `0`.
- [ ] `wsl:` lines in the log are readable (no broken characters).
- [ ] Uninstall finds the MSI (`DisplayName` = `Windows Subsystem for Linux`).
- [ ] `github.com` / `release-assets.githubusercontent.com` reachable as SYSTEM (proxy).

Distributions (test as standard user)
- [ ] No visible console window (or only a short flash) during install/uninstall.
- [ ] Install before reboot: exit `1618`, Intune shows retry, succeeds after reboot.
- [ ] Registered name equals `-DistributionName` (detection depends on it).
- [ ] First launch starts user creation.
- [ ] Uninstall: backup tar exists, distribution removed.
- [ ] arm64 device: Arch app not applicable, others install.

## Sources

- WSL enterprise setup: https://learn.microsoft.com/windows/wsl/enterprise
- WSL Intune settings: https://learn.microsoft.com/windows/wsl/intune
- WSL commands: https://learn.microsoft.com/windows/wsl/basic-commands
- Distribution list: https://github.com/microsoft/WSL/blob/master/distributions/DistributionInfo.json
- WSL releases: https://github.com/microsoft/WSL/releases
