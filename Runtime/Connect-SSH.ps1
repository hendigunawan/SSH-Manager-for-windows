[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ApplicationRoot,
    [Parameter(Mandatory = $true)][string]$HostId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

try {
    $module = Join-Path $ApplicationRoot 'Modules\SSHManager.Core.psm1'
    Import-Module $module -Force
    $paths = Get-SSHManagerPaths -ApplicationRoot $ApplicationRoot
    $config = Read-SSHManagerConfig -Paths $paths
    $hostEntry = @($config.Hosts | Where-Object { $_.Id -eq $HostId } | Select-Object -First 1)
    if ($hostEntry.Count -eq 0) {
        throw "Host dengan ID '$HostId' tidak ditemukan."
    }
    $hostEntry = $hostEntry[0]

    $Host.UI.RawUI.WindowTitle = "SSH - $($hostEntry.Name)"
    Write-Host ''
    Write-Host ('  Proper SSH Manager  |  {0}' -f $hostEntry.Name) -ForegroundColor Cyan
    Write-Host ('  {0}@{1}:{2}' -f $hostEntry.Username, $hostEntry.HostName, $hostEntry.Port) -ForegroundColor DarkGray
    Write-Host ''

    $sshArgs = New-Object 'Collections.Generic.List[string]'
    $sshArgs.Add('-p')
    $sshArgs.Add([string][int]$hostEntry.Port)
    $sshArgs.Add('-o')
    $sshArgs.Add("ServerAliveInterval=$([Math]::Max(0, [int]$hostEntry.KeepAliveInterval))")
    $sshArgs.Add('-o')
    $sshArgs.Add("ServerAliveCountMax=$([Math]::Max(1, [int]$hostEntry.KeepAliveCountMax))")
    $sshArgs.Add('-o')
    $sshArgs.Add('TCPKeepAlive=yes')

    switch ([string]$hostEntry.HostKeyPolicy) {
        'Strict' {
            $sshArgs.Add('-o')
            $sshArgs.Add('StrictHostKeyChecking=yes')
        }
        'AcceptNew' {
            $sshArgs.Add('-o')
            $sshArgs.Add('StrictHostKeyChecking=accept-new')
        }
        default {
            $sshArgs.Add('-o')
            $sshArgs.Add('StrictHostKeyChecking=ask')
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$hostEntry.JumpHost)) {
        $sshArgs.Add('-J')
        $sshArgs.Add([string]$hostEntry.JumpHost)
    }

    switch ([string]$hostEntry.AuthType) {
        'PrivateKey' {
            if (-not (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables([string]$hostEntry.KeyPath)) -PathType Leaf)) {
                throw "Private key tidak ditemukan: $($hostEntry.KeyPath)"
            }
            $sshArgs.Add('-i')
            $sshArgs.Add([Environment]::ExpandEnvironmentVariables([string]$hostEntry.KeyPath))
            $sshArgs.Add('-o')
            $sshArgs.Add('BatchMode=no')
        }
        'Agent' {
            $sshArgs.Add('-o')
            $sshArgs.Add('BatchMode=no')
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
            $sshArgs.Add('-o')
            $sshArgs.Add('BatchMode=no')
            $sshArgs.Add('-o')
            $sshArgs.Add('PreferredAuthentications=password,keyboard-interactive')
            $sshArgs.Add('-o')
            $sshArgs.Add('PubkeyAuthentication=no')
        }
    }

    $sshArgs.Add(('{0}@{1}' -f $hostEntry.Username, $hostEntry.HostName))
    & ssh.exe @($sshArgs.ToArray())
    $exitCode = $LASTEXITCODE
    Write-Host ''
    if ($exitCode -eq 0) {
        Write-Host 'Sesi SSH selesai.' -ForegroundColor DarkGray
    }
    else {
        Write-Host ("SSH berhenti dengan exit code {0}." -f $exitCode) -ForegroundColor Yellow
    }
}
catch {
    Write-Host ''
    Write-Host 'Gagal membuka SSH:' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ''
    Write-Host 'Tekan Enter untuk menutup pane ini.' -ForegroundColor DarkGray
    [void](Read-Host)
}
finally {
    Remove-Item Env:\SSH_MANAGER_SECRET_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\SSH_ASKPASS -ErrorAction SilentlyContinue
    Remove-Item Env:\SSH_ASKPASS_REQUIRE -ErrorAction SilentlyContinue
}
