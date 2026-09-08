[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ApplicationRoot,
    [Parameter(Mandatory = $true)][string]$HostId,
    [Parameter(Mandatory = $true)][ValidateSet('Upload', 'Download')][string]$Direction,
    [Parameter(Mandatory = $true)][string]$LocalPathsBase64,
    [Parameter(Mandatory = $true)][string]$RemotePathsBase64,
    [int]$ManagerProcessId = 0,
    [long]$ManagerWindowHandle = 0,
    [string]$StatusFile = '',
    [int]$SourceFileCount = 0,
    [int]$SourceFolderCount = 0,
    [switch]$ReturnToManager,
    [switch]$Recursive,
    [switch]$PreserveTimes,
    [switch]$Compression
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$transferSucceeded = $false
$transferErrorMessage = ''
$resultHostName = $HostId
$sourceItemCount = [Math]::Max(0, $SourceFileCount) + [Math]::Max(0, $SourceFolderCount)

function Write-ScpStatusResult {
    if ([string]::IsNullOrWhiteSpace($StatusFile)) { return }

    try {
        $statusDirectory = Split-Path -Parent $StatusFile
        if (-not [string]::IsNullOrWhiteSpace($statusDirectory) -and -not (Test-Path -LiteralPath $statusDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $statusDirectory -Force | Out-Null
        }

        $payload = [pscustomobject]@{
            Succeeded   = [bool]$transferSucceeded
            Direction   = [string]$Direction
            HostName    = [string]$resultHostName
            FileCount   = [Math]::Max(0, [int]$SourceFileCount)
            FolderCount = [Math]::Max(0, [int]$SourceFolderCount)
            ItemCount   = [Math]::Max(0, [int]$sourceItemCount)
            Message     = [string]$transferErrorMessage
            FinishedAt  = (Get-Date).ToString('o')
        }
        $temporaryStatusFile = '{0}.{1}.tmp' -f $StatusFile, $PID
        $payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporaryStatusFile -Encoding UTF8
        Move-Item -LiteralPath $temporaryStatusFile -Destination $StatusFile -Force
    }
    catch {
        Write-Host ('Status manager tidak dapat diperbarui: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Show-SSHManagerWindow {
    param(
        [long]$WindowHandle,
        [int]$ProcessId
    )

    try {
        $nativeHandle = [IntPtr]$WindowHandle
        if ($nativeHandle -eq [IntPtr]::Zero -and $ProcessId -gt 0) {
            $managerProcess = Get-Process -Id $ProcessId -ErrorAction Stop
            $managerProcess.Refresh()
            $nativeHandle = $managerProcess.MainWindowHandle
        }
        if ($nativeHandle -eq [IntPtr]::Zero) { return $false }

        if (-not ('SSHManagerWindowActivation' -as [type])) {
            $originalCompilerLib = [Environment]::GetEnvironmentVariable('LIB', [EnvironmentVariableTarget]::Process)
            try {
                [Environment]::SetEnvironmentVariable('LIB', $null, [EnvironmentVariableTarget]::Process)
                Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SSHManagerWindowActivation
{
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
'@
            }
            finally {
                [Environment]::SetEnvironmentVariable('LIB', $originalCompilerLib, [EnvironmentVariableTarget]::Process)
            }
        }
        $windowShown = [SSHManagerWindowActivation]::ShowWindowAsync($nativeHandle, 9)
        Start-Sleep -Milliseconds 150
        [void][SSHManagerWindowActivation]::SetForegroundWindow($nativeHandle)
        return $windowShown
    }
    catch {
        return $false
    }
}

function Open-SSHManagerFallback {
    try {
        $wtCommand = Get-Command wt.exe -ErrorAction Stop
        $arguments = @('--window', '0', 'new-tab', '--profile', '{ab5b9b8b-03f3-518a-a9dc-240db7890dbb}')
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $wtCommand.Source
        $startInfo.Arguments = Join-WindowsCommandLine -Arguments $arguments
        $startInfo.UseShellExecute = $true
        return $null -ne [Diagnostics.Process]::Start($startInfo)
    }
    catch {
        return $false
    }
}

function ConvertFrom-EncodedPathList {
    param(
        [Parameter(Mandatory = $true)][string]$EncodedValue,
        [Parameter(Mandatory = $true)][string]$Label
    )

    try {
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EncodedValue))
        $values = @($json | ConvertFrom-Json)
        return @($values | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    catch {
        throw "Daftar $Label tidak valid: $($_.Exception.Message)"
    }
}

function Expand-JoinedRemotePathList {
    param([string[]]$Paths)

    if ($Paths.Count -ne 1) { return @($Paths) }
    $singlePath = [string]$Paths[0]
    if ($singlePath -notmatch '\s+(?=(?:/|~/))') { return @($singlePath) }

    $splitPaths = @(
        [regex]::Split($singlePath.Trim(), '\s+(?=(?:/|~/))') |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($splitPaths.Count -gt 1) { return @($splitPaths) }
    return @($singlePath)
}

try {
    $module = Join-Path $ApplicationRoot 'Modules\SSHManager.Core.psm1'
    Import-Module $module -Force
    $paths = Get-SSHManagerPaths -ApplicationRoot $ApplicationRoot
    $config = Read-SSHManagerConfig -Paths $paths
    $hostMatches = @($config.Hosts | Where-Object { $_.Id -eq $HostId } | Select-Object -First 1)
    if ($hostMatches.Count -eq 0) { throw "Host dengan ID '$HostId' tidak ditemukan." }
    $hostEntry = $hostMatches[0]
    $resultHostName = [string]$hostEntry.Name

    $scpCommand = Get-Command scp.exe -ErrorAction SilentlyContinue
    if ($null -eq $scpCommand) {
        throw 'scp.exe tidak ditemukan. Install Windows OpenSSH Client terlebih dahulu.'
    }

    $localPaths = @(ConvertFrom-EncodedPathList -EncodedValue $LocalPathsBase64 -Label 'path lokal')
    $remotePaths = @(ConvertFrom-EncodedPathList -EncodedValue $RemotePathsBase64 -Label 'path remote')
    if ($Direction -eq 'Download') {
        $remotePaths = @(Expand-JoinedRemotePathList -Paths ([string[]]$remotePaths))
    }
    if ($localPaths.Count -eq 0) { throw 'Path lokal wajib diisi.' }
    if ($remotePaths.Count -eq 0) { throw 'Path remote wajib diisi.' }

    if ($Direction -eq 'Upload') {
        if ($remotePaths.Count -ne 1) {
            throw 'Upload membutuhkan tepat satu folder tujuan remote.'
        }
        $SourceFileCount = 0
        $SourceFolderCount = 0
        $expandedLocalPaths = @(
            foreach ($localPathValue in $localPaths) {
                $expandedPath = [Environment]::ExpandEnvironmentVariables($localPathValue.Trim())
                if (-not (Test-Path -LiteralPath $expandedPath)) {
                    throw "File atau folder lokal tidak ditemukan: $expandedPath"
                }
                $localItem = Get-Item -LiteralPath $expandedPath -Force
                if ($localItem.PSIsContainer -and -not $Recursive) {
                    throw "Sumber lokal '$($localItem.FullName)' adalah folder. Aktifkan opsi Recursive untuk mengirim folder."
                }
                if ($localItem.PSIsContainer) { $SourceFolderCount++ }
                else { $SourceFileCount++ }
                $localItem.FullName
            }
        )
        $sourceItemCount = $SourceFileCount + $SourceFolderCount
        $cleanRemotePaths = @($remotePaths[0].Trim())
    }
    else {
        if ($localPaths.Count -ne 1) {
            throw 'Download membutuhkan tepat satu folder tujuan lokal.'
        }
        $expandedLocalPath = [Environment]::ExpandEnvironmentVariables($localPaths[0].Trim())
        if (-not (Test-Path -LiteralPath $expandedLocalPath -PathType Container)) {
            New-Item -ItemType Directory -Path $expandedLocalPath -Force | Out-Null
        }
        $expandedLocalPaths = @((Get-Item -LiteralPath $expandedLocalPath).FullName)
        $cleanRemotePaths = @($remotePaths | ForEach-Object { $_.Trim() })
        if (($SourceFileCount + $SourceFolderCount) -ne $cleanRemotePaths.Count) {
            if ($Recursive) { $SourceFolderCount = $cleanRemotePaths.Count }
            else { $SourceFileCount = $cleanRemotePaths.Count }
            if ($Recursive) { $SourceFileCount = 0 }
            else { $SourceFolderCount = 0 }
        }
        $sourceItemCount = $SourceFileCount + $SourceFolderCount
    }

    $remoteHost = [string]$hostEntry.HostName
    if ($remoteHost.Contains(':') -and -not $remoteHost.StartsWith('[')) {
        $remoteHost = "[$remoteHost]"
    }
    $remoteSpecs = @(
        foreach ($cleanRemotePath in $cleanRemotePaths) {
            '{0}@{1}:{2}' -f [string]$hostEntry.Username, $remoteHost, $cleanRemotePath
        }
    )

    $versionPath = Join-Path $ApplicationRoot 'VERSION'
    $applicationVersion = if (Test-Path -LiteralPath $versionPath -PathType Leaf) { (Get-Content -LiteralPath $versionPath -Raw).Trim() } else { 'unknown' }

    $Host.UI.RawUI.WindowTitle = "SCP - $($hostEntry.Name)"
    Write-Host ''
    Write-Host ('  Proper SSH Manager {0}  |  SCP {1}' -f $applicationVersion, $Direction) -ForegroundColor Cyan
    Write-Host ('  Host   : {0}@{1}:{2}' -f $hostEntry.Username, $hostEntry.HostName, $hostEntry.Port) -ForegroundColor DarkGray
    if ($Direction -eq 'Upload') {
        Write-Host ('  Sumber : {0} item lokal' -f $expandedLocalPaths.Count) -ForegroundColor DarkGray
        foreach ($sourcePath in $expandedLocalPaths) { Write-Host ('           {0}' -f $sourcePath) -ForegroundColor DarkGray }
        Write-Host ('  Ke     : {0}' -f $remoteSpecs[0]) -ForegroundColor DarkGray
    }
    else {
        Write-Host ('  Sumber : {0} item remote' -f $remoteSpecs.Count) -ForegroundColor DarkGray
        foreach ($sourceSpec in $remoteSpecs) { Write-Host ('           {0}' -f $sourceSpec) -ForegroundColor DarkGray }
        Write-Host ('  Ke     : {0}' -f $expandedLocalPaths[0]) -ForegroundColor DarkGray
    }
    Write-Host ''

    $scpArgs = New-Object 'Collections.Generic.List[string]'
    $scpArgs.Add('-P')
    $scpArgs.Add([string][int]$hostEntry.Port)
    $scpArgs.Add('-o')
    $scpArgs.Add("ServerAliveInterval=$([Math]::Max(0, [int]$hostEntry.KeepAliveInterval))")
    $scpArgs.Add('-o')
    $scpArgs.Add("ServerAliveCountMax=$([Math]::Max(1, [int]$hostEntry.KeepAliveCountMax))")
    $scpArgs.Add('-o')
    $scpArgs.Add('TCPKeepAlive=yes')

    switch ([string]$hostEntry.HostKeyPolicy) {
        'Strict' {
            $scpArgs.Add('-o')
            $scpArgs.Add('StrictHostKeyChecking=yes')
        }
        'AcceptNew' {
            $scpArgs.Add('-o')
            $scpArgs.Add('StrictHostKeyChecking=accept-new')
        }
        default {
            $scpArgs.Add('-o')
            $scpArgs.Add('StrictHostKeyChecking=ask')
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$hostEntry.JumpHost)) {
        $scpArgs.Add('-J')
        $scpArgs.Add([string]$hostEntry.JumpHost)
    }

    switch ([string]$hostEntry.AuthType) {
        'PrivateKey' {
            $keyPath = [Environment]::ExpandEnvironmentVariables([string]$hostEntry.KeyPath)
            if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) {
                throw "Private key tidak ditemukan: $($hostEntry.KeyPath)"
            }
            $scpArgs.Add('-i')
            $scpArgs.Add($keyPath)
            $scpArgs.Add('-o')
            $scpArgs.Add('BatchMode=no')
        }
        'Agent' {
            $scpArgs.Add('-o')
            $scpArgs.Add('BatchMode=no')
        }
        default {
            $secretFile = Get-SecretFilePath -Paths $paths -Kind host -Id $hostEntry.Id
            if (-not (Test-Path -LiteralPath $secretFile -PathType Leaf)) {
                throw 'Password belum disimpan. Edit host dan masukkan password terlebih dahulu.'
            }
            $askPass = Initialize-SSHManagerAskPass -Paths $paths
            $env:SSH_MANAGER_SECRET_FILE = $secretFile
            $env:SSH_ASKPASS = $askPass
            $env:SSH_ASKPASS_REQUIRE = 'force'
            $env:DISPLAY = 'proper-ssh-manager:0'
            $scpArgs.Add('-o')
            $scpArgs.Add('BatchMode=no')
            $scpArgs.Add('-o')
            $scpArgs.Add('PreferredAuthentications=password,keyboard-interactive')
            $scpArgs.Add('-o')
            $scpArgs.Add('PubkeyAuthentication=no')
        }
    }

    if ($Recursive) { $scpArgs.Add('-r') }
    if ($PreserveTimes) { $scpArgs.Add('-p') }
    if ($Compression) { $scpArgs.Add('-C') }

    if ($Direction -eq 'Upload') {
        foreach ($sourcePath in $expandedLocalPaths) { $scpArgs.Add($sourcePath) }
        $scpArgs.Add($remoteSpecs[0])
    }
    else {
        foreach ($sourceSpec in $remoteSpecs) { $scpArgs.Add($sourceSpec) }
        $scpArgs.Add($expandedLocalPaths[0])
    }

    & $scpCommand.Source @($scpArgs.ToArray())
    $exitCode = $LASTEXITCODE
    Write-Host ''
    if ($exitCode -eq 0) {
        Write-Host 'Transfer SCP selesai.' -ForegroundColor Green
        $transferSucceeded = $true
    }
    else {
        throw "SCP berhenti dengan exit code $exitCode."
    }
}
catch {
    $transferErrorMessage = $_.Exception.Message
    Write-Host ''
    Write-Host 'Transfer SCP gagal:' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
}
finally {
    Remove-Item Env:\SSH_MANAGER_SECRET_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\SSH_ASKPASS -ErrorAction SilentlyContinue
    Remove-Item Env:\SSH_ASKPASS_REQUIRE -ErrorAction SilentlyContinue
    Remove-Item Env:\DISPLAY -ErrorAction SilentlyContinue
    Write-ScpStatusResult
    Write-Host ''
    if ($ReturnToManager) {
        if (-not $transferSucceeded) {
            [void](Read-Host 'Transfer gagal. Tekan Enter untuk kembali ke Proper SSH Manager')
        }
        Write-Host 'Kembali ke Proper SSH Manager...' -ForegroundColor Cyan
        $managerActivated = Show-SSHManagerWindow -WindowHandle $ManagerWindowHandle -ProcessId $ManagerProcessId
        if (-not $managerActivated) { $managerActivated = Open-SSHManagerFallback }
        if ($managerActivated) {
            Start-Sleep -Milliseconds 700
            if ($transferSucceeded) { exit 0 }
            exit 1
        }
        Write-Host 'Manager tidak dapat diaktifkan otomatis. Gunakan Ctrl+Alt+S untuk membukanya.' -ForegroundColor Yellow
        [void](Read-Host 'Tekan Enter untuk menutup tab SCP')
        if ($transferSucceeded) { exit 0 }
        exit 1
    }
    Write-Host 'Tab ini dapat ditutup setelah hasil transfer diperiksa.' -ForegroundColor DarkGray
}
