[CmdletBinding()]
param(
    [switch]$NoDesktopShortcut,
    [switch]$Force,
    [switch]$LaunchAfterInstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Installer ini hanya dapat dijalankan di Windows.'
}

$sourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$installRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\ProperSSHManager'
$startMenuRoot = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Windows\Start Menu\Programs'
$startMenuShortcut = Join-Path $startMenuRoot 'Proper SSH Manager.lnk'
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Proper SSH Manager.lnk'
$terminalProfileName = 'Proper SSH Manager'
$terminalProfileGuid = '{ab5b9b8b-03f3-518a-a9dc-240db7890dbb}'
$terminalFragmentRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Microsoft\Windows Terminal\Fragments\ProperSSHManager'
$terminalFragmentPath = Join-Path $terminalFragmentRoot 'proper-ssh-manager.json'
$powerShellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

if ((Test-Path -LiteralPath $installRoot) -and -not $Force) {
    $answer = Read-Host 'Proper SSH Manager sudah terpasang. Update/replace file aplikasi? [Y/n]'
    if ($answer -match '^(n|no|tidak)$') { return }
}

Write-Host 'Memasang Proper SSH Manager...' -ForegroundColor Cyan
New-Item -ItemType Directory -Path $installRoot -Force | Out-Null

$sourceFiles = Get-ChildItem -LiteralPath $sourceRoot -Recurse -File | Where-Object {
    $_.Name -ne 'ssh-askpass.exe' -and $_.Extension -ne '.zip'
}
foreach ($file in $sourceFiles) {
    $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\')
    $destination = Join-Path $installRoot $relative
    $destinationDirectory = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationDirectory)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }
    Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
}

$module = Join-Path $installRoot 'Modules\SSHManager.Core.psm1'
Import-Module $module -Force
$paths = Get-SSHManagerPaths -ApplicationRoot $installRoot
Initialize-SSHManagerData -Paths $paths
Initialize-SSHManagerAskPass -Paths $paths | Out-Null

$wtCommand = Get-Command wt.exe -ErrorAction SilentlyContinue
$wtPath = if ($wtCommand) { $wtCommand.Source } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Microsoft\WindowsApps\wt.exe' }

New-Item -ItemType Directory -Path $terminalFragmentRoot -Force | Out-Null
$managerCommandLine = "`"$powerShellPath`" -NoProfile -ExecutionPolicy Bypass -File `"$installRoot\SSHManager.ps1`""
$terminalFragment = [ordered]@{
    profiles = @(
        [ordered]@{
            guid                     = $terminalProfileGuid
            name                     = $terminalProfileName
            commandline              = $managerCommandLine
            startingDirectory        = $installRoot
            tabTitle                 = $terminalProfileName
            suppressApplicationTitle = $true
            closeOnExit              = 'always'
            hidden                   = $false
        }
    )
    actions = @(
        [ordered]@{
            command = [ordered]@{
                action  = 'newTab'
                profile = $terminalProfileGuid
            }
            keys = 'ctrl+shift+f12'
            name = 'Buka Proper SSH Manager'
        }
    )
}
$terminalFragment | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $terminalFragmentPath -Encoding UTF8

function New-ApplicationShortcut {
    param(
        [string]$Path,
        [switch]$RegisterHotkey
    )
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $wtPath
    $shortcut.Arguments = "-w 0 new-tab --profile `"$terminalProfileName`""
    $shortcut.WorkingDirectory = $installRoot
    $shortcut.Description = 'Kelola SSH, VPN, dan layout Windows Terminal'
    if ($RegisterHotkey) { $shortcut.Hotkey = 'CTRL+ALT+S' }
    $sshCommand = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($sshCommand) { $shortcut.IconLocation = "$($sshCommand.Source),0" }
    $shortcut.Save()
}

New-ApplicationShortcut -Path $startMenuShortcut -RegisterHotkey
if (-not $NoDesktopShortcut) { New-ApplicationShortcut -Path $desktopShortcut }

$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ProperSSHManager'
New-Item -Path $uninstallKey -Force | Out-Null
Set-ItemProperty -Path $uninstallKey -Name DisplayName -Value 'Proper SSH Manager'
Set-ItemProperty -Path $uninstallKey -Name DisplayVersion -Value '1.7.0'
Set-ItemProperty -Path $uninstallKey -Name Publisher -Value 'Local PowerShell Application'
Set-ItemProperty -Path $uninstallKey -Name InstallLocation -Value $installRoot
Set-ItemProperty -Path $uninstallKey -Name NoModify -Value 1 -Type DWord
Set-ItemProperty -Path $uninstallKey -Name UninstallString -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$installRoot\Uninstall.ps1`""

$missing = @(Get-SSHManagerDependencyStatus | Where-Object { $_.Required -and -not $_.Available })
Write-Host ''
Write-Host 'Instalasi selesai.' -ForegroundColor Green
Write-Host 'Versi aplikasi   : 1.7.0'
Write-Host "Lokasi aplikasi : $installRoot"
Write-Host "Lokasi data     : $($paths.DataRoot)"
Write-Host "Profil Terminal : $terminalProfileName"
Write-Host 'Shortcut global : Ctrl+Alt+S'
Write-Host 'Shortcut Terminal: Ctrl+Shift+F12'
if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host ('Dependensi belum tersedia: ' + (($missing.Name) -join ', ')) -ForegroundColor Yellow
    Write-Host 'Lihat bagian Troubleshooting pada README.md.' -ForegroundColor Yellow
}

if ($LaunchAfterInstall) {
    Start-Process -FilePath $wtPath -ArgumentList "-w 0 new-tab --profile `"$terminalProfileName`""
}
