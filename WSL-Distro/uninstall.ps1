#Requires -Version 5.1
# Runs in USER context. Usage: uninstall.ps1 -DistributionName Ubuntu-24.04
#
# WARNING: wsl --unregister permanently deletes the distribution disk (ext4.vhdx) with all
# user data inside. With $createBackupBeforeRemoval the distribution is exported first and
# the removal is aborted if the export fails.
param(
    [Parameter(Mandatory = $true)]
    [string]$DistributionName
)

# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Configuration ]---------------------------
$applicationName  = "WSL Distribution $DistributionName"
$installedWslPath = "$env:ProgramFiles\WSL\wsl.exe"
$lxssRegistryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"

$createBackupBeforeRemoval = $true
$backupDirectory           = "$env:USERPROFILE\WSL-Backup"

$exitCodeSuccess = 0
$exitCodeFailure = 1

# ---------------------------[ Script Name ]---------------------------
$scriptName  = "WSL-Distro-$DistributionName"
$logKind     = "uninstall"
$logFileName = "{0}-{1}.log" -f (Get-Date -Format "yyyyMMdd"), $logKind

# ---------------------------[ Logging Setup ]---------------------------
# Logging configuration
$log           = $true
$logDebug      = $false   # Set to $true for verbose DEBUG logging
$logGet        = $true    # enable/disable all [Get] logs
$logRun        = $true    # enable/disable all [Run] logs
$enableLogFile = $true
$logRetentionCount = 14   # newest log files kept per kind

# User context: logs go to the user profile.
$logFileDirectory = "$env:LOCALAPPDATA\IntuneLogs\Applications\$($env:USERNAME)\$scriptName"
$logFile          = "$logFileDirectory\$logFileName"

if ($enableLogFile -and -not (Test-Path -Path $logFileDirectory)) {
    New-Item -ItemType Directory -Path $logFileDirectory -Force | Out-Null
}

# ---------------------------[ Logging Function ]---------------------------
function Write-Log {
    [CmdletBinding()]
    param (
        [string]$Message,
        [string]$Tag = "Info"
    )

    if (-not $log) { return }

    if (($Tag -eq "Debug") -and (-not $logDebug)) { return }
    if (($Tag -eq "Get")   -and (-not $logGet))   { return }
    if (($Tag -eq "Run")   -and (-not $logRun))   { return }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $tagMap = @{
        "start"   = "start"
        "get"     = "get"
        "run"     = "run"
        "info"    = "info"
        "warn"    = "warn"
        "warning" = "warn"
        "ok"      = "o.k."
        "success" = "o.k."
        "error"   = "error"
        "debug"   = "debug"
        "end"     = "end"
    }

    $key = $Tag.Trim().ToLowerInvariant()
    $shown = $tagMap[$key]
    if ([string]::IsNullOrWhiteSpace($shown)) { $shown = "error" }
    $rawTag = $shown.PadRight(5)

    $color = switch ($shown) {
        "start" { "Cyan" }
        "get"   { "Blue" }
        "run"   { "Magenta" }
        "info"  { "Yellow" }
        "warn"  { "DarkYellow" }
        "o.k."  { "Green" }
        "error" { "Red" }
        "debug" { "DarkGray" }
        "end"   { "Cyan" }
        default { "White" }
    }

    $logMessage = "$timestamp [ $rawTag ] $Message"

    if ($enableLogFile) {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Add-Content -Path $logFile -Value $logMessage -Encoding UTF8 -ErrorAction Stop
                break
            }
            catch {
                if ($attempt -eq 3) { break }
                Start-Sleep -Milliseconds 120
            }
        }
    }

    Write-Host "$timestamp " -NoNewline
    Write-Host "[ " -NoNewline -ForegroundColor White
    Write-Host "$rawTag" -NoNewline -ForegroundColor $color
    Write-Host " ] " -NoNewline -ForegroundColor White
    Write-Host "$Message"
}

# ---------------------------[ Exit Function ]---------------------------
function Complete-Script {
    param([int]$ExitCode)

    $scriptEndTime = Get-Date
    $duration      = $scriptEndTime - $scriptStartTime

    Write-Log "Runtime $($duration.ToString('hh\:mm\:ss\.ff'))" -Tag "Info"
    Write-Log "Exit $ExitCode" -Tag "Info"
    Write-Log "==================== End ====================" -Tag "End"

    exit $ExitCode
}

# ---------------------------[ WSL Functions ]---------------------------
function Test-DistributionRegistered {
    if (-not (Test-Path -Path $lxssRegistryPath)) { return $false }

    foreach ($distributionKey in Get-ChildItem -Path $lxssRegistryPath -ErrorAction SilentlyContinue) {
        $registeredName = (Get-ItemProperty -Path $distributionKey.PSPath -ErrorAction SilentlyContinue).DistributionName
        if ($registeredName -eq $DistributionName) { return $true }
    }

    return $false
}

# wsl.exe writes UTF-16 by default. WSL_UTF8 switches it to UTF-8; null characters are
# stripped as well in case the variable is ignored.
function Invoke-WslCommand {
    param([string[]]$Arguments)

    Write-Log "$installedWslPath $($Arguments -join ' ')" -Tag "Run"

    $previousOutputEncoding   = [Console]::OutputEncoding
    $env:WSL_UTF8             = "1"
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    try {
        $commandOutput = & $installedWslPath @Arguments 2>&1
        $wslExitCode   = $LASTEXITCODE
    }
    finally {
        [Console]::OutputEncoding = $previousOutputEncoding
    }

    foreach ($outputLine in $commandOutput) {
        $cleanLine = ([string]$outputLine) -replace "`0", ""
        if (-not [string]::IsNullOrWhiteSpace($cleanLine)) { Write-Log "wsl: $($cleanLine.Trim())" -Tag "Info" }
    }

    Write-Log "wsl.exe exit code $wslExitCode" -Tag "Info"
    return $wslExitCode
}

function Export-Distribution {
    if (-not (Test-Path -Path $backupDirectory)) {
        New-Item -ItemType Directory -Path $backupDirectory -Force -ErrorAction Stop | Out-Null
    }

    $backupPath  = Join-Path -Path $backupDirectory -ChildPath ("{0}-{1}.tar" -f $DistributionName, (Get-Date -Format "yyyyMMdd-HHmmss"))
    $wslExitCode = Invoke-WslCommand -Arguments @("--export", $DistributionName, $backupPath)

    $isBackupWritten = ($wslExitCode -eq 0) -and (Test-Path -Path $backupPath)
    if (-not $isBackupWritten) {
        throw "Export to $backupPath failed (exit code $wslExitCode)"
    }

    Write-Log "Backup written to $backupPath" -Tag "Ok"
}

# ---------------------------[ Log Retention Function ]---------------------------
# Keeps the newest $logRetentionCount files of one kind (yyyyMMdd-<kind>.log).
# Logging must never block the run, so a failed removal is reported and skipped.
function Remove-ExpiredLogFile {
    param([string]$LogKind)

    if (-not $enableLogFile) { return }

    $logFilePattern  = '^\d{8}-' + [regex]::Escape($LogKind) + '\.log$'
    $expiredLogFiles = Get-ChildItem -Path $logFileDirectory -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $logFilePattern } |
        Sort-Object -Property Name -Descending |
        Select-Object -Skip $logRetentionCount

    foreach ($expiredLogFile in $expiredLogFiles) {
        try {
            Remove-Item -Path $expiredLogFile.FullName -Force -ErrorAction Stop
            Write-Log "Removed old log $($expiredLogFile.Name)" -Tag "Debug"
        }
        catch {
            Write-Log "Remove old log $($expiredLogFile.Name) failed: $($_.Exception.Message)" -Tag "Warn"
        }
    }
}

# ---------------------------[ Script Start ]---------------------------
Write-Log "==================== Start ====================" -Tag "Start"
Remove-ExpiredLogFile -LogKind $logKind
Write-Log "$env:COMPUTERNAME | $env:USERNAME | $applicationName" -Tag "Info"

if (-not (Test-DistributionRegistered)) {
    Write-Log "$DistributionName not registered, nothing to do" -Tag "Ok"
    Complete-Script -ExitCode $exitCodeSuccess
}

if (-not (Test-Path -Path $installedWslPath)) {
    Write-Log "WSL binary missing ($installedWslPath), cannot unregister" -Tag "Error"
    Complete-Script -ExitCode $exitCodeFailure
}

try {
    $null = Invoke-WslCommand -Arguments @("--terminate", $DistributionName)

    if ($createBackupBeforeRemoval) { Export-Distribution }

    $wslExitCode = Invoke-WslCommand -Arguments @("--unregister", $DistributionName)
}
catch {
    Write-Log "Removal aborted, distribution kept: $($_.Exception.Message)" -Tag "Error"
    Complete-Script -ExitCode $exitCodeFailure
}

if (Test-DistributionRegistered) {
    Write-Log "$DistributionName still registered after unregister" -Tag "Error"
    if ($wslExitCode -ne 0) { Complete-Script -ExitCode $wslExitCode }
    Complete-Script -ExitCode $exitCodeFailure
}

Write-Log "$DistributionName unregistered" -Tag "Ok"
Complete-Script -ExitCode $exitCodeSuccess
