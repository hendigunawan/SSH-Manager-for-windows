[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
# RDP model/migration, mstsc arguments, copy naming, non-blocking TCP probe, VPN runspace and Credential Manager.
# No RDP login is performed and mstsc.exe is never started.
$applicationRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $applicationRoot 'Modules/SSHManager.Core.psm1') -Force -DisableNameChecking
function Assert-Rdp { param([bool]$Value, [string]$Message) if (-not $Value) { throw $Message } }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('psm-rdp-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$credentialHost = 'psm-test-{0}.invalid' -f [guid]::NewGuid().ToString('N')
try {
    # 1. Legacy configuration is migrated in place without user action.
    $paths = Get-SSHManagerPaths -ApplicationRoot $applicationRoot
    $paths.DataRoot = $testRoot; $paths.ConfigFile = Join-Path $testRoot 'config.json'
    $paths.SecretsRoot = Join-Path $testRoot 'secrets'; $paths.BackupsRoot = Join-Path $testRoot 'backups'
    $paths.LogsRoot = Join-Path $testRoot 'logs'; $paths.ScpStatusRoot = Join-Path $testRoot 'scp-status'
    Set-Content -LiteralPath $paths.ConfigFile -Encoding UTF8 -Value @'
{ "Version": 1, "App": {}, "VpnProfiles": [],
  "Hosts": [
    { "name": "Server01", "host": "10.10.10.1", "port": 22 },
    { "Id": "v19", "Name": "Server02", "HostName": "10.10.10.2", "Port": 2222, "Username": "ops", "AuthType": "Agent" }
  ] }
'@
    $config = Read-SSHManagerConfig -Paths $paths
    $legacy = $config.Hosts[0]
    Assert-Rdp ($legacy.Name -eq 'Server01' -and $legacy.HostName -eq '10.10.10.1' -and $legacy.Port -eq 22) 'Legacy name/host/port not read.'
    Assert-Rdp ($legacy.SshEnabled -eq $true -and $legacy.RdpEnabled -eq $false -and $legacy.RdpPort -eq 3389 -and $legacy.RdpCredentialSaved -eq $false) 'Legacy host did not receive SSH/RDP defaults.'
    Assert-Rdp ($config.Hosts[1].Port -eq 2222 -and $config.Hosts[1].Username -eq 'ops' -and (Test-SSHManagerSshEnabled $config.Hosts[1])) 'v1.9 host lost SSH settings.'
    Save-SSHManagerConfig -Config $config -Paths $paths
    $reloaded = Read-SSHManagerConfig -Paths $paths
    Assert-Rdp (@($reloaded.Hosts).Count -eq 2 -and $null -ne $reloaded.Hosts[0].PSObject.Properties['RdpPort']) 'Migrated config did not round-trip.'
    $raw = Get-Content -LiteralPath $paths.ConfigFile -Raw
    Assert-Rdp ($raw -notmatch '(?i)"password"\s*:') 'Config file contains a password field.'
    $partial = [pscustomobject]@{ Name = 'x' }
    Assert-Rdp ((Test-SSHManagerSshEnabled $partial) -and -not (Test-SSHManagerRdpEnabled $partial) -and (Get-SSHManagerRdpPort $partial) -eq 3389) 'Missing fields are not treated as SSH-only defaults.'
    Assert-Rdp ((Get-SSHManagerHostValue $partial 'Group' 'Default') -eq 'Default') 'Safe field read failed.'

    # 2. mstsc command line.
    $plan = New-SSHManagerRdpLaunchPlan -HostName '10.10.10.10' -Port 3389
    Assert-Rdp (($plan.Arguments -join ' ') -eq '/v:10.10.10.10:3389' -and -not $plan.RdpFileContent) 'Minimal mstsc /v:HOST:PORT plan wrong.'
    $plan = New-SSHManagerRdpLaunchPlan -HostName '10.10.10.10' -Port 3390 -Fullscreen $true -Admin $true -MultiMonitor $true
    Assert-Rdp (($plan.Arguments -join ' ') -eq '/v:10.10.10.10:3390 /admin /f /multimon') 'Fullscreen/admin/multimon plan wrong.'
    $plan = New-SSHManagerRdpLaunchPlan -HostName 'win01' -Width 1600 -Height 900
    Assert-Rdp (($plan.Arguments -join ' ') -eq '/v:win01:3389 /w:1600 /h:900') 'Custom resolution plan wrong.'
    $plan = New-SSHManagerRdpLaunchPlan -HostName 'fe80::10' -Port 3389
    Assert-Rdp ($plan.Endpoint -eq '[fe80::10]:3389') 'IPv6 endpoint not bracketed.'
    $rdpFile = Join-Path $testRoot 'win.rdp'
    $plan = New-SSHManagerRdpLaunchPlan -HostName 'win01' -Username 'CORP\ops' -RdpFilePath $rdpFile
    Assert-Rdp ($plan.Arguments[0] -eq $rdpFile -and $plan.Arguments[1] -eq '/v:win01:3389') 'Username plan does not pass the .rdp file first.'
    Assert-Rdp ($plan.RdpFileContent -match 'username:s:CORP\\ops' -and $plan.RdpFileContent -match 'full address:s:win01:3389' -and $plan.RdpFileContent -notmatch '(?i)password') '.rdp file content wrong or contains a password.'
    $failed = $false; try { [void](New-SSHManagerRdpLaunchPlan -HostName 'bad host' -Port 3389) } catch { $failed = $true }
    Assert-Rdp $failed 'Host with whitespace accepted.'
    $failed = $false; try { [void](New-SSHManagerRdpLaunchPlan -HostName 'h' -Port 70000) } catch { $failed = $true }
    Assert-Rdp $failed 'Invalid port accepted.'

    # 3. Duplicate naming.
    Assert-Rdp ((Get-SSHManagerCopyName 'Server01' @('Server01')) -eq 'Server01 - Copy') 'First copy name wrong.'
    Assert-Rdp ((Get-SSHManagerCopyName 'Server01' @('Server01', 'Server01 - Copy')) -eq 'Server01 - Copy 2') 'Second copy name wrong.'
    Assert-Rdp ((Get-SSHManagerCopyName 'Server01 - Copy 2' @('Server01', 'Server01 - Copy', 'Server01 - Copy 2')) -eq 'Server01 - Copy 3') 'Copy of a copy did not continue the sequence.'

    # 4. VPN selection for RDP.
    $vpnHost = [pscustomobject]@{ VpnProfileId = 'harita' }
    Assert-Rdp ((Resolve-SSHManagerVpnId $vpnHost '__HOST__') -eq 'harita' -and (Resolve-SSHManagerVpnId $vpnHost '__NONE__') -eq '' -and (Resolve-SSHManagerVpnId $vpnHost 'forced') -eq 'forced') 'VPN override resolution wrong.'

    # 5. Non-blocking TCP probe: open port, closed port.
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        $openPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $probe = Start-SSHManagerTcpProbe -HostName '127.0.0.1' -Port $openPort -TimeoutSeconds 5
        Assert-Rdp ($watch.ElapsedMilliseconds -lt 1000) 'Starting a probe blocked the caller.'
        $result = $null
        while ($null -eq ($result = Get-SSHManagerTcpProbeResult -Probe $probe)) { Start-Sleep -Milliseconds 20 }
        Assert-Rdp ($result.Success -and $result.Message -eq 'Connected' -and $result.Milliseconds -ge 0) 'Open port not reported as Connected.'
        $closedPort = $openPort
    }
    finally { $listener.Stop() }
    $probe = Start-SSHManagerTcpProbe -HostName '127.0.0.1' -Port $closedPort -TimeoutSeconds 3
    $result = $null
    while ($null -eq ($result = Get-SSHManagerTcpProbeResult -Probe $probe)) { Start-Sleep -Milliseconds 20 }
    Assert-Rdp (-not $result.Success -and $result.Message) 'Closed port reported as reachable.'
    $probe = Start-SSHManagerTcpProbe -HostName '10.255.255.1' -Port 3389 -TimeoutSeconds 1
    $result = $null
    while ($null -eq ($result = Get-SSHManagerTcpProbeResult -Probe $probe)) { Start-Sleep -Milliseconds 50 }
    Assert-Rdp (-not $result.Success -and $result.Milliseconds -le 2500) 'Timeout probe did not fail within its deadline.'

    # 6. Background VPN job (runspace): success and failure results are returned, not thrown.
    $okProfile = [pscustomobject]@{ Id = 'v1'; Name = 'Fixture'; Type = 'CustomCommand'; ConnectionName = ''; Username = ''; ConnectCommand = 'exit 0'; CheckCommand = ''; DisconnectCommand = ''; RunAsAdministrator = $false; WaitSeconds = 1; Notes = '' }
    $job = Start-SSHManagerVpnJob -Profile $okProfile -Paths $paths -TimeoutSeconds 5
    $vpn = $null; $deadline = (Get-Date).AddSeconds(60)
    while ($null -eq ($vpn = Receive-SSHManagerVpnJob -Job $job)) { if ((Get-Date) -gt $deadline) { throw 'VPN job did not finish.' }; Start-Sleep -Milliseconds 100 }
    Assert-Rdp ([bool]$vpn.Success) ('VPN job failed: ' + $vpn.Message)
    $badProfile = [pscustomobject]@{ Id = 'v2'; Name = 'Broken'; Type = 'WindowsRas'; ConnectionName = ''; Username = ''; ConnectCommand = ''; CheckCommand = ''; DisconnectCommand = ''; RunAsAdministrator = $false; WaitSeconds = 1; Notes = '' }
    $job = Start-SSHManagerVpnJob -Profile $badProfile -Paths $paths -TimeoutSeconds 2
    $vpn = $null; $deadline = (Get-Date).AddSeconds(60)
    while ($null -eq ($vpn = Receive-SSHManagerVpnJob -Job $job)) { if ((Get-Date) -gt $deadline) { throw 'VPN failure job did not finish.' }; Start-Sleep -Milliseconds 100 }
    Assert-Rdp (-not [bool]$vpn.Success -and $vpn.Message) 'Broken VPN profile reported success.'

    # 6b. Abandoning a hung job kills the native process tree it started (disconnect and check command).
    foreach ($operation in 'Disconnect', 'Connect') {
        $marker = 'psm-hung-' + [guid]::NewGuid().ToString('N')
        # The grandchild powershell.exe proves the whole tree is killed, not only the direct child.
        $hungCommand = "Start-Process powershell.exe -ArgumentList '-NoProfile -Command Start-Sleep -Seconds 120 # $marker' -WindowStyle Hidden; Start-Sleep -Seconds 120 # $marker"
        $hungProfile = [pscustomobject]@{ Id = 'v3'; Name = 'Hung'; Type = 'CustomCommand'; ConnectionName = ''; Username = ''; ConnectCommand = ''; CheckCommand = ''; DisconnectCommand = ''; RunAsAdministrator = $false; WaitSeconds = 1; Notes = '' }
        if ($operation -eq 'Disconnect') { $hungProfile.DisconnectCommand = $hungCommand } else { $hungProfile.CheckCommand = $hungCommand }
        $job = Start-SSHManagerVpnJob -Profile $hungProfile -Paths $paths -TimeoutSeconds 5 -Operation $operation
        # Direct child: encoded command, so found by parent PID. Grandchild: plain command line with the marker.
        $findHung = { @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.ParentProcessId -eq $PID -or [string]$_.CommandLine -match $marker }) }
        $deadline = (Get-Date).AddSeconds(30)
        while (@(& $findHung).Count -lt 2) { if ((Get-Date) -gt $deadline) { throw "$operation fixture never started its process tree." }; Start-Sleep -Milliseconds 200 }
        $stopped = Stop-SSHManagerVpnJob -Job $job -Message 'fixture timeout'
        Assert-Rdp (-not $stopped.Success -and $stopped.Message -eq 'fixture timeout') "Stopped $operation job returned the wrong result."
        $deadline = (Get-Date).AddSeconds(10)
        while (@(& $findHung).Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        $left = @(& $findHung)
        foreach ($process in $left) { try { Stop-Process -Id $process.ProcessId -Force } catch { } }
        Assert-Rdp ($left.Count -eq 0) ("Abandoned {0} job left {1} native process(es) running." -f $operation, $left.Count)
    }

    # 7. Windows Credential Manager round trip (dummy target, removed afterwards).
    $secure = New-Object Security.SecureString; foreach ($ch in 'fixture'.ToCharArray()) { $secure.AppendChar($ch) }
    Save-RdpCredential -HostName $credentialHost -Username 'demo' -Password $secure
    $stored = Get-RdpCredential -HostName $credentialHost
    Assert-Rdp ($stored.Exists -and $stored.Username -eq 'demo' -and $stored.Target -eq "TERMSRV/$credentialHost") 'Credential not stored in Credential Manager.'
    Assert-Rdp ($null -eq $stored.PSObject.Properties['Password']) 'Get-RdpCredential exposed a password.'
    Assert-Rdp (Remove-RdpCredential -HostName $credentialHost) 'Credential delete failed.'
    Assert-Rdp (-not (Get-RdpCredential -HostName $credentialHost).Exists) 'Credential still present after delete.'

    # 8. Log file contains the required fields and never the secret.
    [void](Initialize-SSHManagerLog -Paths $paths)
    Write-SSHManagerLog -Level ERROR -Component 'RDP' -Action 'Test' -HostName '10.10.10.10:3389' -Message 'fixture' -ErrorRecord ([Exception]::new('boom'))
    $logLine = @(Get-Content -LiteralPath (Get-SSHManagerLogFile))[-1]
    Assert-Rdp ($logLine -match '^\d{4}-\d{2}-\d{2} .+\| ERROR \| RDP \| Test \| host=10\.10\.10\.10:3389 \| fixture \| exception=System\.Exception: boom') "Log line format wrong: $logLine"
}
finally {
    try { [void](Remove-RdpCredential -HostName $credentialHost) } catch { }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'PASS RDP: legacy migration, mstsc /v /f /multimon /admin /w /h, IPv6, .rdp without password, copy names, VPN override, async TCP probe (open/closed/timeout), VPN runspace, Credential Manager round trip, log format.'
