[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
# Native WPF: SSH connect/test VPN + TCP checks must not block the UI thread.
# A DispatcherTimer counts ticks while the real Connect-SelectedHosts waits; launch/terminal are replaced.
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Jalankan powershell.exe -STA -File Tests\SshAsync-Test.ps1.' }
Add-Type -AssemblyName @('PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml', 'System.Windows.Forms')
$script:ApplicationRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:ApplicationRoot 'Modules/SSHManager.Core.psm1') -Force -DisableNameChecking
. (Join-Path $script:ApplicationRoot 'UI/WorkspaceModel.ps1')
. (Join-Path $script:ApplicationRoot 'UI/Workspace.ps1')
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:ApplicationRoot 'SSHManager.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Read-XamlWindow', 'Get-NamedControl', 'Apply-DarkComboBoxTheme', 'Set-Status', 'New-ConnectionProgressWindow', 'Update-ConnectionProgressWindow', 'Close-ConnectionProgressWindow', 'Get-VpnById', 'Invoke-SSHManagerVpnConnectAsync', 'Invoke-SSHManagerVpnDisconnectAsync', 'Invoke-SSHManagerPortChecks', 'Ensure-SSHManagerVpnForHost', 'Test-ManagerStillOpen', 'Connect-SelectedHosts')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if ($null -eq $definition) { throw "Function $name not found." }
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Assert-Async { param([bool]$Value, [string]$Message) if (-not $Value) { throw $Message } }

# Static guard: UI code must not call the blocking helpers any more.
foreach ($file in @('SSHManager.ps1', 'UI/RemoteEditor.ps1', 'UI/RdpManager.ps1', 'UI/Workspace.ps1')) {
    $code = ((Get-Content (Join-Path $script:ApplicationRoot $file) -Encoding UTF8) | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    Assert-Async ($code -notmatch '\bTest-SSHManagerHost\s+-' -and $code -notmatch '\b(Connect|Disconnect)-SSHManagerVpn\s+-') "$file still calls a blocking network helper."
}

$script:Launched = @(); $script:FailureDialogs = 0; $script:Errors = New-Object 'Collections.Generic.List[string]'
function Get-SelectedHostEntries { return @() }
function Get-SSHManagerDependencyStatus { [pscustomobject]@{ Name = 'fixture'; Required = $true; Available = $true } }
function Start-SSHManagerLayout { param($Hosts, $Paths, $Layout, $TerminalProfile, $StartMaximized) $script:Launched = @($Hosts) }
function Save-CurrentConfig { }
function Show-ErrorMessage { param($Message, $Title) $script:Errors.Add($Message) }
function Show-ConnectionFailureDialog { param([object[]]$Failures) $script:FailureDialogs++; $script:LastFailures = $Failures; return 'Cancel' }

$dataRoot = Join-Path ([IO.Path]::GetTempPath()) ('psm-async-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
$script:Paths = [pscustomobject]@{ DataRoot = $dataRoot; LogsRoot = $dataRoot; SecretsRoot = $dataRoot }
$script:Config = New-SSHManagerDefaultConfig
$script:Config.App.TestConnectionBeforeOpen = $true
$script:Config.App.ConnectTimeoutSeconds = 2
$script:Config.App.VpnConnectTimeoutSeconds = 10
$script:Config.VpnProfiles = @([pscustomobject]@{ Id = 'fixture-vpn'; Name = 'Fixture VPN'; Type = 'CustomCommand'; ConnectionName = ''; Username = ''; ConnectCommand = 'Start-Sleep -Milliseconds 800; exit 0'; CheckCommand = ''; DisconnectCommand = ''; RunAsAdministrator = $false; WaitSeconds = 5; Notes = '' })
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$listener.Start()
$openPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
$reachable = [pscustomobject]@{ Id = 'up'; Name = 'Reachable'; HostName = '127.0.0.1'; Port = $openPort; Username = 'ops'; AuthType = 'Agent'; VpnProfileId = 'fixture-vpn'; LastConnectedAt = ''; SshEnabled = $true }
$blackhole = [pscustomobject]@{ Id = 'down'; Name = 'Blackhole'; HostName = '10.255.255.1'; Port = 22; Username = 'ops'; AuthType = 'Agent'; VpnProfileId = ''; LastConnectedAt = ''; SshEnabled = $true }

$script:MainWindow = New-Object Windows.Window
$script:MainWindow.Width = 300; $script:MainWindow.Height = 200; $script:MainWindow.ShowInTaskbar = $false
$script:StatusText = New-Object Windows.Controls.TextBlock
$script:MainWindow.Content = $script:StatusText
$script:LayoutCombo = [pscustomobject]@{ SelectedValue = 'Single' }
$script:VpnOverride = [pscustomobject]@{ SelectedValue = '__HOST__' }
$script:LockedDuringWait = $false
# A blocked UI thread shows up as one long gap between heartbeats (>= the whole wait); CPU contention only as short ones.
$script:BeatClock = [Diagnostics.Stopwatch]::StartNew(); $script:LastBeat = 0; $script:MaxGap = 0
function Reset-Heartbeat { $script:LastBeat = $script:BeatClock.ElapsedMilliseconds; $script:MaxGap = 0 }
function Assert-NoBlocking { param([string]$Label) Assert-Async ($script:MaxGap -lt 500) ("UI thread was blocked during {0}: {1} ms without a heartbeat." -f $Label, $script:MaxGap) }
$heartbeat = New-Object Windows.Threading.DispatcherTimer
$heartbeat.Interval = [TimeSpan]::FromMilliseconds(25)
$heartbeat.Add_Tick({
    $now = $script:BeatClock.ElapsedMilliseconds
    if ($now - $script:LastBeat -gt $script:MaxGap) { $script:MaxGap = $now - $script:LastBeat }
    $script:LastBeat = $now
    if (-not $script:MainWindow.IsEnabled) { $script:LockedDuringWait = $true }
})
$script:MainWindow.Show()
$heartbeat.Start()
try {
    # 1. Real VPN runspace (0.8 s connect command) + real TCP pre-test, then launch.
    Reset-Heartbeat
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Connect-SelectedHosts -HostEntries @($reachable)
    $watch.Stop()
    Assert-Async ($script:Errors.Count -eq 0) ('Connect failed: ' + ($script:Errors -join '; '))
    Assert-Async ($script:Launched.Count -eq 1 -and $script:Launched[0].Id -eq 'up') 'Reachable host was not launched after VPN + test.'
    Assert-Async ($watch.ElapsedMilliseconds -ge 700) ("VPN fixture finished too fast ({0} ms) to prove anything." -f $watch.ElapsedMilliseconds)
    Assert-NoBlocking 'VPN connect + TCP pre-test'
    Assert-Async ($script:LockedDuringWait -and $script:MainWindow.IsEnabled) 'Main window was not locked during the wait or not restored.'
    Assert-Async ($script:MainWindow.OwnedWindows.Count -eq 0) 'Progress window left open.'

    # 2. Unreachable host: timeout handled without blocking, failure dialog shown, nothing launched.
    $script:Launched = @(); $script:LockedDuringWait = $false; Reset-Heartbeat
    $watch.Restart()
    Connect-SelectedHosts -HostEntries @($blackhole)
    $watch.Stop()
    Assert-Async ($script:FailureDialogs -eq 1 -and $script:LastFailures[0].Host.Id -eq 'down' -and $script:Launched.Count -eq 0) 'Unreachable host was not reported or was launched.'
    Assert-Async ($watch.ElapsedMilliseconds -ge 1500) 'Timeout path finished too fast.'
    Assert-NoBlocking 'TCP timeout'
    Assert-Async ($script:MainWindow.IsEnabled) 'Main window stayed disabled after a failed check.'

    # 3. Parallel checks: two 2-second timeouts finish in about one timeout, not two.
    $watch.Restart()
    $results = @(Invoke-SSHManagerPortChecks -HostEntries @($blackhole, $blackhole, $reachable) -Protocol Ssh)
    $watch.Stop()
    Assert-Async ($results.Count -eq 3 -and -not $results[0].Success -and $results[2].Success) 'Port check results wrong.'
    Assert-Async ($watch.ElapsedMilliseconds -lt 3800) ("Port checks ran sequentially ({0} ms)." -f $watch.ElapsedMilliseconds)

    # 4. VPN disconnect runs in the runspace; a hung disconnect command is abandoned after its deadline.
    $script:Config.VpnProfiles[0].DisconnectCommand = 'Start-Sleep -Milliseconds 800; exit 0'
    Reset-Heartbeat; $watch.Restart()
    $disconnect = Invoke-SSHManagerVpnDisconnectAsync -Profile $script:Config.VpnProfiles[0]
    $watch.Stop()
    Assert-Async ([bool]$disconnect.Success) ('Disconnect failed: ' + $disconnect.Message)
    Assert-Async ($watch.ElapsedMilliseconds -ge 700) 'Disconnect fixture finished too fast.'
    Assert-NoBlocking 'VPN disconnect'
    $script:Config.VpnProfiles[0].DisconnectCommand = 'Start-Sleep -Seconds 60'
    $script:Config.App.VpnConnectTimeoutSeconds = 2
    $watch.Restart()
    $disconnect = Invoke-SSHManagerVpnDisconnectAsync -Profile $script:Config.VpnProfiles[0]
    $watch.Stop()
    Assert-Async (-not $disconnect.Success -and $disconnect.Message -match 'tidak selesai dalam 5 detik' -and $watch.ElapsedMilliseconds -lt 9000) ("Hung disconnect not bounded: {0} ({1} ms)" -f $disconnect.Message, $watch.ElapsedMilliseconds)
    Assert-Async ($script:MainWindow.IsEnabled) 'Main window stayed disabled after a disconnect timeout.'
    $script:Config.App.VpnConnectTimeoutSeconds = 10

    # 5. A failing VPN cancels the SSH launch with a clear message.
    $script:Config.VpnProfiles[0].Type = 'WindowsRas'
    $script:Errors.Clear(); $script:Launched = @()
    Connect-SelectedHosts -HostEntries @($reachable)
    Assert-Async ($script:Launched.Count -eq 0 -and $script:Errors.Count -eq 1 -and $script:Errors[0] -match 'gagal terhubung; SSH dibatalkan') 'VPN failure did not cancel SSH.'
    Assert-Async ($script:MainWindow.IsEnabled) 'Main window stayed disabled after VPN failure.'
}
finally {
    $heartbeat.Stop()
    $listener.Stop()
    $script:MainWindow.Close()
    Remove-Item -LiteralPath $dataRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'PASS SSH async: VPN runspace + TCP pre-test keep the dispatcher responsive, window locked/restored, timeout/failure/VPN-failure paths, parallel port checks, async/bounded VPN disconnect, no blocking calls in UI code.'
