#Requires -Version 5.1
# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Configuration ]---------------------------
$applicationName     = "Windows Subsystem for Linux"
$requiredFeatureName = "VirtualMachinePlatform"

# install.ps1 always fetches the latest release, so detection only enforces a floor.
# 2.4.4 is the first release supporting .wsl distribution files (wsl --install --from-file).
$minimumVersion = [version]"2.4.4"

$wslExecutablePath     = "$env:ProgramFiles\WSL\wsl.exe"
$acceptedFeatureStates = @("Enabled", "EnablePending")

# ---------------------------[ Script Name ]---------------------------
$scriptName  = "WSL-Core"
$logKind     = "detection"
$logFileName = "{0}-{1}.log" -f (Get-Date -Format "yyyyMMdd"), $logKind

# ---------------------------[ Logging Setup ]---------------------------
# Logging configuration
$log           = $true
$logDebug      = $false   # Set to $true for verbose DEBUG logging
$logGet        = $true    # enable/disable all [Get] logs
$logRun        = $true    # enable/disable all [Run] logs
$enableLogFile = $true
$logRetentionCount = 14   # newest log files kept per kind

$logFileDirectory = "$env:ProgramData\IntuneLogs\Applications\$scriptName"
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

# ---------------------------[ Detection Functions ]---------------------------
function Test-WslVersion {
    if (-not (Test-Path -Path $wslExecutablePath)) {
        Write-Log "Missing $wslExecutablePath" -Tag "Error"
        return $false
    }

    $fileVersionInfo  = (Get-Item -Path $wslExecutablePath).VersionInfo
    $installedVersion = [version]("{0}.{1}.{2}" -f $fileVersionInfo.FileMajorPart, $fileVersionInfo.FileMinorPart, $fileVersionInfo.FileBuildPart)

    $isSufficient = $installedVersion -ge $minimumVersion
    if ($isSufficient) { Write-Log "WSL $installedVersion >= $minimumVersion" -Tag "Ok" }
    else { Write-Log "WSL $installedVersion < $minimumVersion" -Tag "Error" }

    return $isSufficient
}

# EnablePending is accepted so detection succeeds between install and the soft reboot.
function Test-RequiredFeature {
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $requiredFeatureName -ErrorAction Stop
    }
    catch {
        Write-Log "Query feature $requiredFeatureName failed: $($_.Exception.Message)" -Tag "Error"
        return $false
    }

    $isEnabled = $acceptedFeatureStates -contains [string]$feature.State
    if ($isEnabled) { Write-Log "Feature $requiredFeatureName $($feature.State)" -Tag "Ok" }
    else { Write-Log "Feature $requiredFeatureName $($feature.State)" -Tag "Error" }

    return $isEnabled
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

$isVersionDetected = Test-WslVersion
$isFeatureDetected = Test-RequiredFeature

if ($isVersionDetected -and $isFeatureDetected) {
    Complete-Script -ExitCode 0
}

Complete-Script -ExitCode 1
