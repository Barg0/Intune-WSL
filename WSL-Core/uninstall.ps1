#Requires -Version 5.1
# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Configuration ]---------------------------
$applicationName       = "Windows Subsystem for Linux"
$uninstallerArguments  = '/qn /norestart'
$requiredFeatureName   = "VirtualMachinePlatform"

# VirtualMachinePlatform is shared with other software (e.g. Docker Desktop, Android tooling).
# Leave it enabled unless no other workload on the device depends on it.
$disableRequiredFeature = $false

$registrySearchPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)

$msiSuccessCodes = @(0, 1605)   # 1605 = product not installed
$msiRebootCodes  = @(3010, 1641)
$exitCodeSuccess = 0
$exitCodeFailure = 1
$exitCodeReboot  = 3010

# ---------------------------[ Script Name ]---------------------------
$scriptName  = "WSL-Core"
$logKind     = "uninstall"
$logFileName = "{0}-{1}.log" -f (Get-Date -Format "yyyyMMdd"), $logKind
$msiLogKind  = "msiexec-uninstall"

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

# ---------------------------[ Uninstall Functions ]---------------------------
# Only MSI rows qualify: the product code is the registry key name.
function Get-WslProductCode {
    $productCodes = @()

    foreach ($registryPath in $registrySearchPaths) {
        if (-not (Test-Path -Path $registryPath)) { continue }

        foreach ($subKey in Get-ChildItem -Path $registryPath -ErrorAction SilentlyContinue) {
            $properties = Get-ItemProperty -Path $subKey.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $properties) { continue }

            $isWslMsi = ($properties.DisplayName -eq $applicationName) -and ($properties.WindowsInstaller -eq 1)
            if ($isWslMsi) {
                Write-Log "Found $($properties.DisplayName) $($properties.DisplayVersion) $($subKey.PSChildName)" -Tag "Get"
                $productCodes += $subKey.PSChildName
            }
        }
    }

    return $productCodes
}

function Uninstall-WslMsi {
    param([string]$ProductCode)

    $msiLogPath  = Join-Path -Path $logFileDirectory -ChildPath ("{0}-{1}.log" -f (Get-Date -Format "yyyyMMdd"), $msiLogKind)
    $msiArgument = "/x $ProductCode $uninstallerArguments /l*v `"$msiLogPath`""

    Write-Log "msiexec.exe $msiArgument" -Tag "Run"
    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgument -Wait -PassThru -ErrorAction Stop

    return $process.ExitCode
}

function Disable-RequiredFeature {
    $feature = Get-WindowsOptionalFeature -Online -FeatureName $requiredFeatureName -ErrorAction Stop
    if ($feature.State -eq 'Disabled') { return $false }

    Write-Log "Disable feature $requiredFeatureName" -Tag "Run"
    $result = Disable-WindowsOptionalFeature -Online -FeatureName $requiredFeatureName -NoRestart -ErrorAction Stop
    Write-Log "Feature $requiredFeatureName disabled, restart needed: $($result.RestartNeeded)" -Tag "Ok"

    return [bool]$result.RestartNeeded
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
Remove-ExpiredLogFile -LogKind $msiLogKind
Write-Log "$env:COMPUTERNAME | $env:USERNAME | $applicationName" -Tag "Info"
Write-Log "User distributions (ext4.vhdx in user profiles) are not removed" -Tag "Info"

$isRestartRequired = $false
$productCodes      = Get-WslProductCode

if ($productCodes.Count -eq 0) {
    Write-Log "No MSI installation of $applicationName found" -Tag "Info"
}

foreach ($productCode in $productCodes) {
    try {
        $msiExitCode = Uninstall-WslMsi -ProductCode $productCode
    }
    catch {
        Write-Log "msiexec start failed: $($_.Exception.Message)" -Tag "Error"
        Complete-Script -ExitCode $exitCodeFailure
    }

    if ($msiRebootCodes -contains $msiExitCode) {
        Write-Log "Removed $productCode, restart required ($msiExitCode)" -Tag "Ok"
        $isRestartRequired = $true
    }
    elseif ($msiSuccessCodes -contains $msiExitCode) {
        Write-Log "Removed $productCode" -Tag "Ok"
    }
    else {
        Write-Log "Uninstall of $productCode failed with exit code $msiExitCode" -Tag "Error"
        Complete-Script -ExitCode $msiExitCode
    }
}

if ($disableRequiredFeature) {
    try {
        if (Disable-RequiredFeature) { $isRestartRequired = $true }
    }
    catch {
        Write-Log "Disable feature $requiredFeatureName failed: $($_.Exception.Message)" -Tag "Error"
        Complete-Script -ExitCode $exitCodeFailure
    }
}

if ((Get-WslProductCode).Count -gt 0) {
    Write-Log "$applicationName still registered after uninstall" -Tag "Error"
    Complete-Script -ExitCode $exitCodeFailure
}

if ($isRestartRequired) {
    Complete-Script -ExitCode $exitCodeReboot
}

Complete-Script -ExitCode $exitCodeSuccess
