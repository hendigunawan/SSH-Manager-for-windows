[CmdletBinding()]
param([switch]$RemoveUserData)

$ErrorActionPreference = 'Stop'
$installRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\ProperSSHManager'
$dataRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ProperSSHManager'
$startMenuShortcut = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Windows\Start Menu\Programs\Proper SSH Manager.lnk'
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Proper SSH Manager.lnk'
$terminalFragmentRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Microsoft\Windows Terminal\Fragments\ProperSSHManager'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ProperSSHManager'

if ((Split-Path -Leaf $installRoot) -ne 'ProperSSHManager') {
    throw 'Lokasi instalasi tidak valid; uninstall dihentikan.'
}

Remove-Item -LiteralPath $startMenuShortcut -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $desktopShortcut -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $uninstallKey -Recurse -Force -ErrorAction SilentlyContinue
if ((Split-Path -Leaf $terminalFragmentRoot) -ne 'ProperSSHManager') {
    throw 'Lokasi integrasi Windows Terminal tidak valid; uninstall dihentikan.'
}
Remove-Item -LiteralPath $terminalFragmentRoot -Recurse -Force -ErrorAction SilentlyContinue

if ($RemoveUserData) {
    if ((Split-Path -Leaf $dataRoot) -ne 'ProperSSHManager') { throw 'Lokasi data tidak valid.' }
    Remove-Item -LiteralPath $dataRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Konfigurasi dan password tersimpan ikut dihapus.' -ForegroundColor Yellow
}
else {
    Write-Host "Konfigurasi dipertahankan di: $dataRoot"
}

if (Test-Path -LiteralPath $installRoot) {
    Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'Proper SSH Manager sudah dihapus.' -ForegroundColor Green
