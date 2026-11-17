# WSL-Distro (Intune Win32 app, one app per distribution)

Registers a WSL distribution for the signed-in user. Distributions are per user
(`HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss`, disk in the user profile), so these
apps run in **user context**. Same `install.ps1` / `uninstall.ps1` for every distribution,
the name is passed as parameter. Detection is one file per distribution (Intune detection
scripts take no parameters).

## How it works

- install.ps1: checks WSL-Core is present, skips if already registered, returns `1618`
  (Intune default: Retry) while a reboot is pending, then runs
  `wsl.exe --install --distribution <Name> --name <Name> --no-launch --web-download`.
  Success = distribution registered in HKCU.
- First start: user opens the distribution from Start menu / Windows Terminal and creates
  the Linux user (OOBE). No credentials in the package.
- uninstall.ps1: `wsl --terminate`, `wsl --export` to `%USERPROFILE%\WSL-Backup\<Name>-<timestamp>.tar`,
  then `wsl --unregister`. **Unregister deletes all data in the distribution.** If the
  export fails, removal is aborted. Disable backup via `$createBackupBeforeRemoval = $false`.
- Logs: `%LOCALAPPDATA%\IntuneLogs\Applications\<USERNAME>\WSL-Distro-<Name>\` (`yyyyMMdd-install.log`, ...; max 14 per kind).

## Prepared distributions

Names from the official WSL manifest (`microsoft/WSL/distributions/DistributionInfo.json`).
Pin versioned names: plain `Ubuntu` floats to the newest LTS.

| Intune app | `-DistributionName` | Detection file | arm64 |
|---|---|---|---|
| WSL - Ubuntu 24.04 LTS | `Ubuntu-24.04` | `detection/detection-Ubuntu-24.04.ps1` | yes |
| WSL - Ubuntu 26.04 LTS | `Ubuntu-26.04` | `detection/detection-Ubuntu-26.04.ps1` | yes |
| WSL - Debian | `Debian` | `detection/detection-Debian.ps1` | yes |
| WSL - Azure Linux 4 | `AzureLinux-4` | `detection/detection-AzureLinux-4.ps1` | yes |
| WSL - Fedora Linux 45 | `FedoraLinux-45` | `detection/detection-FedoraLinux-45.ps1` | yes |
| WSL - Arch Linux | `archlinux` | `detection/detection-archlinux.ps1` | **no** - set Intune requirement architecture to x64 only |

Notes:
- Fedora: ~13 month support per release. Plan a new app (`FedoraLinux-46`, ...) per release;
  existing user installs are not upgraded in place (`dnf system-upgrade` inside the distro).
- Arch: rolling release, no versioned name. Updates happen inside the distro (`pacman -Syu`).

Add another one: copy `detection/detection-TEMPLATE.ps1`, replace `__DISTRIBUTION_NAME__`.
List available names on a client: `wsl --list --online`.

## Intune app settings (per distribution)

| Setting | Value |
|---|---|
| Install command | `%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File .\install.ps1 -DistributionName Ubuntu-24.04` |
| Uninstall command | `%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File .\uninstall.ps1 -DistributionName Ubuntu-24.04` |
| Install behavior | **User** |
| Return code 1618 | Retry (default mapping) |
| Detection script | `detection-<Name>.ps1`, 32-bit: **No** |
| Dependency | WSL-Core, auto-install: Yes |
| Assignment | User groups (Available in Company Portal recommended) |

Uninstall can take a while (export of a large disk): raise the install/uninstall timeout
if users keep big distributions.

## Test checklist (pilot)

- [ ] Install as standard user (no admin) after WSL-Core + reboot: registered, Start menu entry exists.
- [ ] Install directly after WSL-Core without reboot: exit 1618, succeeds on retry after reboot.
- [ ] `--name` works for each distribution (registered name equals `-DistributionName`).
- [ ] First launch shows OOBE (user creation).
- [ ] Detection runs in user context and finds the HKCU entry.
- [ ] Uninstall: backup tar written, distribution removed; export failure aborts removal.
- [ ] Network: distribution download URLs (vendor CDNs, see manifest) reachable via user proxy.
