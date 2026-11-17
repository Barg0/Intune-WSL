#Requires -Version 5.1
# Intune requirement script. Configure in Intune:
#   Output data type: String | Operator: Equals | Value: Supported
#
# Deviation from the standard scaffold: Intune compares the complete STDOUT with the
# configured value, so Write-Log writes to the log file only and the single verdict
# is the only console output.

# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Configuration ]---------------------------
$applicationName = "Windows Subsystem for Linux"

# Windows 10 22H2 = build 19045, minimum supported by WSL enterprise guidance.
$minimumOsBuild = 19045

$resultSupported    = "Supported"
$resultNotSupported = "NotSupported"

# ---------------------------[ Script Name ]---------------------------
$scriptName  = "WSL-Core"
$logKind     = "requirement"
$logFileName = "{0}-{1}.log" -f (Get-Date -Format "yyyyMMdd"), $logKind

# ---------------------------[ Logging Setup ]---------------------------
$log           = $true
$logDebug      = $false
$logGet        = $true
$logRun        = $true
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
}

# ---------------------------[ Exit Function ]---------------------------
function Complete-Script {
    param(
        [string]$Result,
        [int]$ExitCode
    )

    $scriptEndTime = Get-Date
    $duration      = $scriptEndTime - $scriptStartTime

    Write-Log "Result $Result" -Tag "Info"
    Write-Log "Runtime $($duration.ToString('hh\:mm\:ss\.ff'))" -Tag "Info"
    Write-Log "Exit $ExitCode" -Tag "Info"
    Write-Log "==================== End ====================" -Tag "End"

    Write-Output $Result
    exit $ExitCode
}

# ---------------------------[ Requirement Functions ]---------------------------
function Test-OsBuild {
    $osBuild = [int](Get-CimInstance -ClassName Win32_OperatingSystem).BuildNumber
    $isSupported = $osBuild -ge $minimumOsBuild

    Write-Log "OS build $osBuild, minimum $minimumOsBuild" -Tag "Get"
    return $isSupported
}

# With VBS/HVCI active the hypervisor already runs and Win32_Processor reports
# VirtualizationFirmwareEnabled = False, so a running hypervisor counts as supported.
function Test-Virtualization {
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
    $processor      = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1

    Write-Log "HypervisorPresent $($computerSystem.HypervisorPresent), VirtualizationFirmwareEnabled $($processor.VirtualizationFirmwareEnabled)" -Tag "Get"
    return [bool]($computerSystem.HypervisorPresent -or $processor.VirtualizationFirmwareEnabled)
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

try {
    $isOsSupported             = Test-OsBuild
    $isVirtualizationAvailable = Test-Virtualization
}
catch {
    Write-Log "Requirement check failed: $($_.Exception.Message)" -Tag "Error"
    Complete-Script -Result $resultNotSupported -ExitCode 0
}

if ($isOsSupported -and $isVirtualizationAvailable) {
    Complete-Script -Result $resultSupported -ExitCode 0
}

Complete-Script -Result $resultNotSupported -ExitCode 0
