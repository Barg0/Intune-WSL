#Requires -Version 5.1
# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Configuration ]---------------------------
$applicationName     = "Windows Subsystem for Linux"
$githubRepository    = "microsoft/WSL"
$installerArguments  = '/qn /norestart'
$requiredFeatureName = "VirtualMachinePlatform"
$installedWslPath    = "$env:ProgramFiles\WSL\wsl.exe"

# wsl.exe --install is not used: the inbox stub requests UAC elevation, which fails as
# SYSTEM ("The requested operation requires elevation" / "The handle is invalid").
# The same GitHub release is installed directly via msiexec instead.

# Fallback when GitHub is unreachable or the download fails verification.
# Optional: place e.g. wsl.3.0.5.0.x64.msi / wsl.3.0.5.0.arm64.msi next to this script.
$bundledInstallerPattern = "wsl.*.{0}.msi"

# Downloaded MSI must be Authenticode-signed by Microsoft and chain to a Microsoft root.
$expectedSignerPattern = "CN=Microsoft Corporation,*"
$expectedRootPattern   = "CN=Microsoft*Root*"

$userAgent             = "Intune-WSL-Installer"
$requestTimeoutSeconds = 300
$downloadDirectory     = "$env:ProgramData\IntuneLogs\Applications\WSL-Core\Download"

$msiSuccessCodes = @(0)
$msiRebootCodes  = @(3010, 1641)
$exitCodeSuccess = 0
$exitCodeFailure = 1
$exitCodeReboot  = 3010

# ---------------------------[ Script Name ]---------------------------
$scriptName  = "WSL-Core"
$logKind     = "install"
$logFileName = "{0}-{1}.log" -f (Get-Date -Format "yyyyMMdd"), $logKind
$msiLogKind  = "msiexec-install"

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

# ---------------------------[ Architecture & Version ]---------------------------
function Get-SystemArchitecture {
    $processorArchitectureArm64 = 12
    $processor = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1

    if ($processor.Architecture -eq $processorArchitectureArm64) { return "arm64" }
    return "x64"
}

function Get-InstalledWslVersion {
    if (-not (Test-Path -Path $installedWslPath)) { return $null }

    $fileVersionInfo = (Get-Item -Path $installedWslPath).VersionInfo
    return [version]("{0}.{1}.{2}" -f $fileVersionInfo.FileMajorPart, $fileVersionInfo.FileMinorPart, $fileVersionInfo.FileBuildPart)
}

function ConvertTo-ReleaseVersion {
    param([string]$TagName)

    return [version]($TagName.TrimStart('v', 'V'))
}

# ---------------------------[ GitHub Release Lookup ]---------------------------
function Get-LatestReleaseFromApi {
    param([string]$Architecture)

    $apiUrl  = "https://api.github.com/repos/$githubRepository/releases/latest"
    $headers = @{ "User-Agent" = $userAgent; "Accept" = "application/vnd.github+json" }

    $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -UseBasicParsing -TimeoutSec $requestTimeoutSeconds -ErrorAction Stop
    $asset   = $release.assets | Where-Object { $_.name -match "^wsl\.[\d\.]+\.$Architecture\.msi$" } | Select-Object -First 1

    if ($null -eq $asset) {
        throw "Release $($release.tag_name) has no MSI asset for $Architecture"
    }

    $expectedSha256 = $null
    if ($asset.digest -match '^sha256:([0-9a-fA-F]{64})$') { $expectedSha256 = $Matches[1] }

    return [pscustomobject]@{
        Version        = ConvertTo-ReleaseVersion -TagName $release.tag_name
        Url            = $asset.browser_download_url
        FileName       = $asset.name
        ExpectedSha256 = $expectedSha256
    }
}

# The GitHub API allows 60 unauthenticated requests per hour per public IP. Many clients
# behind one NAT exhaust that quickly, so the release page redirect is used as fallback.
# It carries no hash, which leaves the Authenticode check as the only integrity control.
function Get-LatestReleaseFromRedirect {
    param([string]$Architecture)

    $request = [System.Net.HttpWebRequest]::Create("https://github.com/$githubRepository/releases/latest")
    $request.AllowAutoRedirect = $false
    $request.UserAgent         = $userAgent
    $request.Timeout           = $requestTimeoutSeconds * 1000

    $response = $request.GetResponse()
    try {
        $redirectLocation = $response.Headers["Location"]
    }
    finally {
        $response.Close()
    }

    if ([string]::IsNullOrWhiteSpace($redirectLocation)) {
        throw "Release page returned no redirect location"
    }

    $tagName  = ($redirectLocation.TrimEnd('/') -split '/')[-1]
    $fileName = "wsl.$($tagName.TrimStart('v', 'V')).0.$Architecture.msi"

    return [pscustomobject]@{
        Version        = ConvertTo-ReleaseVersion -TagName $tagName
        Url            = "https://github.com/$githubRepository/releases/download/$tagName/$fileName"
        FileName       = $fileName
        ExpectedSha256 = $null
    }
}

function Get-LatestWslRelease {
    param([string]$Architecture)

    try {
        Write-Log "Query GitHub API for latest release" -Tag "Get"
        return Get-LatestReleaseFromApi -Architecture $Architecture
    }
    catch {
        Write-Log "GitHub API failed: $($_.Exception.Message)" -Tag "Warn"
    }

    Write-Log "Resolve latest release via release page redirect" -Tag "Get"
    return Get-LatestReleaseFromRedirect -Architecture $Architecture
}

# ---------------------------[ Download & Verification ]---------------------------
# SYSTEM downloads and installs; users must not be able to swap the MSI in between.
function New-ProtectedDirectory {
    param([string]$Path)

    if (Test-Path -Path $Path) { Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop }
    New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null

    $icaclsOutput = & icacls.exe $Path /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "icacls failed on $Path : $icaclsOutput"
    }
}

function Save-ReleaseInstaller {
    param([pscustomobject]$Release)

    New-ProtectedDirectory -Path $downloadDirectory
    $installerPath = Join-Path -Path $downloadDirectory -ChildPath $Release.FileName

    Write-Log "Download $($Release.Url)" -Tag "Run"
    Invoke-WebRequest -Uri $Release.Url -OutFile $installerPath -UserAgent $userAgent -UseBasicParsing -TimeoutSec $requestTimeoutSeconds -ErrorAction Stop

    return $installerPath
}

function Test-InstallerHash {
    param(
        [string]$InstallerPath,
        [string]$ExpectedSha256
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        Write-Log "No published SHA256, hash check skipped" -Tag "Warn"
        return $true
    }

    $actualSha256 = (Get-FileHash -Path $InstallerPath -Algorithm SHA256).Hash
    $isMatch = $actualSha256 -eq $ExpectedSha256.ToUpperInvariant()

    if ($isMatch) { Write-Log "SHA256 match $actualSha256" -Tag "Ok" }
    else { Write-Log "SHA256 mismatch: expected $ExpectedSha256, got $actualSha256" -Tag "Error" }

    return $isMatch
}

function Test-InstallerSignature {
    param([string]$InstallerPath)

    $signature = Get-AuthenticodeSignature -FilePath $InstallerPath

    if ($signature.Status -ne 'Valid') {
        Write-Log "Signature status $($signature.Status) on $InstallerPath" -Tag "Error"
        return $false
    }

    $signerSubject = $signature.SignerCertificate.Subject
    if ($signerSubject -notlike $expectedSignerPattern) {
        Write-Log "Unexpected signer: $signerSubject" -Tag "Error"
        return $false
    }

    $certificateChain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $null = $certificateChain.Build($signature.SignerCertificate)
    $rootSubject = $certificateChain.ChainElements[$certificateChain.ChainElements.Count - 1].Certificate.Subject

    if ($rootSubject -notlike $expectedRootPattern) {
        Write-Log "Unexpected root CA: $rootSubject" -Tag "Error"
        return $false
    }

    Write-Log "Signature valid: $signerSubject" -Tag "Ok"
    return $true
}

function Get-OnlineInstaller {
    param([string]$Architecture)

    $release = Get-LatestWslRelease -Architecture $Architecture
    Write-Log "Latest release $($release.Version) ($($release.FileName))" -Tag "Info"

    $installerPath = Save-ReleaseInstaller -Release $release

    $isHashValid      = Test-InstallerHash -InstallerPath $installerPath -ExpectedSha256 $release.ExpectedSha256
    $isSignatureValid = Test-InstallerSignature -InstallerPath $installerPath

    if (-not ($isHashValid -and $isSignatureValid)) {
        throw "Downloaded installer failed verification"
    }

    return [pscustomobject]@{ Path = $installerPath; Version = $release.Version }
}

function Get-BundledInstaller {
    param([string]$Architecture)

    $searchPattern = $bundledInstallerPattern -f $Architecture
    $bundledFile   = Get-ChildItem -Path $PSScriptRoot -Filter $searchPattern -File | Sort-Object -Property Name -Descending | Select-Object -First 1

    if ($null -eq $bundledFile) { return $null }

    $versionMatch = [regex]::Match($bundledFile.Name, '^wsl\.(\d+\.\d+\.\d+)')
    return [pscustomobject]@{ Path = $bundledFile.FullName; Version = [version]$versionMatch.Groups[1].Value }
}

function Get-WslInstaller {
    param([string]$Architecture)

    try {
        return Get-OnlineInstaller -Architecture $Architecture
    }
    catch {
        Write-Log "Online installer unavailable: $($_.Exception.Message)" -Tag "Warn"
    }

    $bundledInstaller = Get-BundledInstaller -Architecture $Architecture
    if ($null -ne $bundledInstaller) {
        Write-Log "Use bundled installer $($bundledInstaller.Path)" -Tag "Info"
    }

    return $bundledInstaller
}

# ---------------------------[ Installation ]---------------------------
function Enable-RequiredFeature {
    $feature = Get-WindowsOptionalFeature -Online -FeatureName $requiredFeatureName -ErrorAction Stop
    Write-Log "Feature $requiredFeatureName state $($feature.State)" -Tag "Get"

    if ($feature.State -eq 'Enabled') { return $false }
    if ($feature.State -eq 'EnablePending') { return $true }

    Write-Log "Enable feature $requiredFeatureName" -Tag "Run"
    $result = Enable-WindowsOptionalFeature -Online -FeatureName $requiredFeatureName -All -NoRestart -ErrorAction Stop
    Write-Log "Feature $requiredFeatureName enabled, restart needed: $($result.RestartNeeded)" -Tag "Ok"

    return [bool]$result.RestartNeeded
}

function Install-WslMsi {
    param([string]$InstallerPath)

    $msiLogPath  = Join-Path -Path $logFileDirectory -ChildPath ("{0}-{1}.log" -f (Get-Date -Format "yyyyMMdd"), $msiLogKind)
    $msiArgument = "/i `"$InstallerPath`" $installerArguments /l*v+ `"$msiLogPath`""

    Write-Log "msiexec.exe $msiArgument" -Tag "Run"
    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgument -Wait -PassThru -ErrorAction Stop

    return $process.ExitCode
}

function Remove-DownloadDirectory {
    if (Test-Path -Path $downloadDirectory) {
        try {
            Remove-Item -Path $downloadDirectory -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Log "Cleanup of $downloadDirectory failed: $($_.Exception.Message)" -Tag "Warn"
        }
    }
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

$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$isRestartRequired = $false

try {
    $isRestartRequired = Enable-RequiredFeature
}
catch {
    Write-Log "Enable feature $requiredFeatureName failed: $($_.Exception.Message)" -Tag "Error"
    Complete-Script -ExitCode $exitCodeFailure
}

$architecture     = Get-SystemArchitecture
$installedVersion = Get-InstalledWslVersion
Write-Log "Architecture $architecture, installed WSL version: $installedVersion" -Tag "Get"

$installer = Get-WslInstaller -Architecture $architecture
if ($null -eq $installer) {
    Write-Log "No installer available (online and bundled failed)" -Tag "Error"
    Remove-DownloadDirectory
    Complete-Script -ExitCode $exitCodeFailure
}

$isUpToDate = ($null -ne $installedVersion) -and ($installedVersion -ge $installer.Version)

if ($isUpToDate) {
    Write-Log "Installed $installedVersion >= available $($installer.Version), MSI skipped" -Tag "Ok"
}
else {
    try {
        $msiExitCode = Install-WslMsi -InstallerPath $installer.Path
    }
    catch {
        Write-Log "msiexec start failed: $($_.Exception.Message)" -Tag "Error"
        Remove-DownloadDirectory
        Complete-Script -ExitCode $exitCodeFailure
    }

    if ($msiRebootCodes -contains $msiExitCode) {
        Write-Log "MSI installed $($installer.Version), restart required ($msiExitCode)" -Tag "Ok"
        $isRestartRequired = $true
    }
    elseif ($msiSuccessCodes -contains $msiExitCode) {
        Write-Log "MSI installed $($installer.Version)" -Tag "Ok"
    }
    else {
        Write-Log "MSI failed with exit code $msiExitCode, see $msiLogKind log" -Tag "Error"
        Remove-DownloadDirectory
        Complete-Script -ExitCode $msiExitCode
    }
}

Remove-DownloadDirectory

if ($isRestartRequired) {
    Complete-Script -ExitCode $exitCodeReboot
}

Complete-Script -ExitCode $exitCodeSuccess
