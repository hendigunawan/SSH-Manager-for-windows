# RDP model helpers, mstsc launcher, non-blocking TCP probe and background VPN job.
# Nothing in this file blocks the WPF dispatcher; callers poll the probe/job from a DispatcherTimer.

function Get-SSHManagerHostValue {
    param($HostEntry, [Parameter(Mandatory = $true)][string]$Name, $Default = '')
    # Strict-mode safe read for host fields that may be missing from partial or legacy objects.
    if ($null -eq $HostEntry) { return $Default }
    $property = $HostEntry.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Test-SSHManagerSshEnabled {
    param($HostEntry)
    if ($null -eq $HostEntry) { return $false }
    $property = $HostEntry.PSObject.Properties['SshEnabled']
    if ($null -eq $property) { return $true }
    return [bool]$property.Value
}

function Test-SSHManagerRdpEnabled {
    param($HostEntry)
    if ($null -eq $HostEntry) { return $false }
    $property = $HostEntry.PSObject.Properties['RdpEnabled']
    if ($null -eq $property) { return $false }
    return [bool]$property.Value
}

function Get-SSHManagerRdpPort {
    param($HostEntry)
    $port = 0
    $property = if ($null -ne $HostEntry) { $HostEntry.PSObject.Properties['RdpPort'] } else { $null }
    if ($null -ne $property -and [int]::TryParse([string]$property.Value, [ref]$port) -and $port -ge 1 -and $port -le 65535) { return $port }
    return 3389
}

function Get-SSHManagerRdpEndpoint {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [int]$Port = 3389
    )
    $address = $HostName.Trim()
    # IPv6 literals need brackets before the port separator.
    if ($address.Contains(':') -and -not $address.StartsWith('[')) { $address = '[{0}]' -f $address }
    return '{0}:{1}' -f $address, $Port
}

function Resolve-SSHManagerVpnId {
    param($HostEntry, [string]$Override = '__HOST__')
    if ($Override -eq '__NONE__') { return '' }
    if ([string]::IsNullOrWhiteSpace($Override) -or $Override -eq '__HOST__') {
        if ($null -eq $HostEntry -or $null -eq $HostEntry.PSObject.Properties['VpnProfileId']) { return '' }
        return [string]$HostEntry.VpnProfileId
    }
    return $Override
}

function Get-SSHManagerCopyName {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowEmptyCollection()][string[]]$ExistingNames = @()
    )
    $base = $Name.Trim()
    # Duplicating a copy continues the original sequence instead of producing "X - Copy - Copy".
    $match = [regex]::Match($base, '^(?<base>.+?) - Copy(?: (?<n>\d+))?$')
    if ($match.Success) { $base = $match.Groups['base'].Value }
    $taken = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($existing in $ExistingNames) { if ($null -ne $existing) { [void]$taken.Add($existing.Trim()) } }
    $candidate = '{0} - Copy' -f $base
    $number = 2
    while ($taken.Contains($candidate)) { $candidate = '{0} - Copy {1}' -f $base, $number; $number++ }
    return $candidate
}

function New-SSHManagerRdpLaunchPlan {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [int]$Port = 3389,
        [string]$Username = '',
        [int]$Width = 0,
        [int]$Height = 0,
        [bool]$Fullscreen = $false,
        [bool]$Admin = $false,
        [bool]$MultiMonitor = $false,
        [string]$RdpFilePath = ''
    )

    if ([string]::IsNullOrWhiteSpace($HostName) -or $HostName -match '\s') { throw 'Host/IP RDP tidak valid.' }
    if ($Port -lt 1 -or $Port -gt 65535) { throw 'Port RDP harus 1–65535.' }
    $endpoint = Get-SSHManagerRdpEndpoint -HostName $HostName -Port $Port
    $arguments = New-Object 'Collections.Generic.List[string]'
    $fileContent = ''
    if (-not [string]::IsNullOrWhiteSpace($Username)) {
        if ([string]::IsNullOrWhiteSpace($RdpFilePath)) { throw 'Path file .rdp wajib diisi bila username RDP digunakan.' }
        # mstsc has no username switch; the .rdp file carries only non-secret connection settings.
        $lines = @(
            ('full address:s:{0}' -f $endpoint),
            ('username:s:{0}' -f $Username.Trim()),
            'prompt for credentials:i:0'
        )
        $fileContent = ($lines -join "`r`n") + "`r`n"
        $arguments.Add($RdpFilePath)
    }
    $arguments.Add(('/v:{0}' -f $endpoint))
    if ($Admin) { $arguments.Add('/admin') }
    if ($Fullscreen) { $arguments.Add('/f') }
    elseif ($Width -gt 0 -and $Height -gt 0) { $arguments.Add(('/w:{0}' -f $Width)); $arguments.Add(('/h:{0}' -f $Height)) }
    if ($MultiMonitor) { $arguments.Add('/multimon') }
    return [pscustomobject]@{
        Endpoint       = $endpoint
        Arguments      = [string[]]$arguments.ToArray()
        RdpFilePath    = $(if ($fileContent) { $RdpFilePath } else { '' })
        RdpFileContent = $fileContent
    }
}

function Start-RdpConnection {
    param(
        [Parameter(Mandatory = $true)][Alias('Host')][string]$HostName,
        [int]$Port = 3389,
        [string]$Username = '',
        [int]$Width = 0,
        [int]$Height = 0,
        [switch]$Fullscreen,
        [switch]$Admin,
        [switch]$MultiMonitor,
        [string]$RdpFileRoot = '',
        [string]$SessionName = 'session'
    )

    $mstsc = Get-Command mstsc.exe -ErrorAction SilentlyContinue
    if ($null -eq $mstsc) { throw 'mstsc.exe (Remote Desktop Connection) tidak ditemukan di Windows ini.' }
    $rdpFile = ''
    if (-not [string]::IsNullOrWhiteSpace($Username)) {
        if ([string]::IsNullOrWhiteSpace($RdpFileRoot)) { $RdpFileRoot = Join-Path ([IO.Path]::GetTempPath()) 'ProperSSHManager-rdp' }
        if (-not (Test-Path -LiteralPath $RdpFileRoot -PathType Container)) { New-Item -ItemType Directory -Path $RdpFileRoot -Force | Out-Null }
        $safeName = ($SessionName -replace '[^A-Za-z0-9_.-]', '_')
        $rdpFile = Join-Path $RdpFileRoot ('{0}.rdp' -f $safeName)
    }
    $plan = New-SSHManagerRdpLaunchPlan -HostName $HostName -Port $Port -Username $Username -Width $Width -Height $Height -Fullscreen ([bool]$Fullscreen) -Admin ([bool]$Admin) -MultiMonitor ([bool]$MultiMonitor) -RdpFilePath $rdpFile
    if ($plan.RdpFileContent) { [IO.File]::WriteAllText($plan.RdpFilePath, $plan.RdpFileContent, [Text.Encoding]::Unicode) }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $mstsc.Source
    $startInfo.Arguments = Join-WindowsCommandLine -Arguments $plan.Arguments
    $startInfo.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($startInfo)
    return [pscustomobject]@{ Endpoint = $plan.Endpoint; ProcessId = $(if ($process) { $process.Id } else { 0 }); Arguments = $plan.Arguments }
}

function Start-SSHManagerTcpProbe {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutSeconds = 8
    )
    $client = New-Object Net.Sockets.TcpClient
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $task = $null
    $startError = ''
    try { $task = $client.ConnectAsync($HostName.Trim('[', ']'), $Port) }
    catch { $startError = $_.Exception.GetBaseException().Message }
    return [pscustomobject]@{
        HostName = $HostName; Port = $Port; Client = $client; Task = $task; Watch = $watch
        TimeoutMilliseconds = [Math]::Max(1, $TimeoutSeconds) * 1000; StartError = $startError; Result = $null
    }
}

function Get-SSHManagerTcpProbeResult {
    param([Parameter(Mandatory = $true)]$Probe)
    if ($null -ne $Probe.Result) { return $Probe.Result }
    $result = $null
    if ($Probe.StartError) {
        $result = [pscustomobject]@{ Success = $false; Milliseconds = 0; Message = $Probe.StartError }
    }
    elseif ($Probe.Task.IsCompleted) {
        $Probe.Watch.Stop()
        if ($Probe.Task.IsFaulted -or $Probe.Task.IsCanceled -or -not $Probe.Client.Connected) {
            $message = if ($Probe.Task.Exception) { $Probe.Task.Exception.GetBaseException().Message } else { 'Connection failed' }
            $result = [pscustomobject]@{ Success = $false; Milliseconds = $Probe.Watch.ElapsedMilliseconds; Message = $message }
        }
        else { $result = [pscustomobject]@{ Success = $true; Milliseconds = $Probe.Watch.ElapsedMilliseconds; Message = 'Connected' } }
    }
    elseif ($Probe.Watch.ElapsedMilliseconds -ge $Probe.TimeoutMilliseconds) {
        $Probe.Watch.Stop()
        $result = [pscustomobject]@{ Success = $false; Milliseconds = $Probe.Watch.ElapsedMilliseconds; Message = 'Timeout' }
    }
    if ($null -ne $result) {
        try { $Probe.Client.Dispose() } catch { }
        $Probe.Result = $result
    }
    return $result
}

function Start-SSHManagerVpnJob {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)]$Paths,
        [int]$TimeoutSeconds = 30,
        [ValidateSet('Connect', 'Disconnect')][string]$Operation = 'Connect'
    )
    # A separate runspace keeps rasdial/custom VPN commands off the WPF dispatcher thread.
    $modulePath = Join-Path $PSScriptRoot 'SSHManager.Core.psm1'
    # Every native process the job starts is registered here (Start-SSHManagerTrackedProcess).
    $tracker = [hashtable]::Synchronized(@{ Stopped = $false; Processes = New-Object Collections.ArrayList })
    $shell = [PowerShell]::Create()
    [void]$shell.AddScript({
        param($ModulePath, $Profile, $Paths, $TimeoutSeconds, $Operation, $Tracker)
        $module = Import-Module $ModulePath -Force -DisableNameChecking -PassThru
        & $module { param($Value) $script:SSHManagerProcessTracker = $Value } $Tracker
        if ($Operation -eq 'Disconnect') { Disconnect-SSHManagerVpn -Profile $Profile }
        else { Connect-SSHManagerVpn -Profile $Profile -Paths $Paths -TimeoutSeconds $TimeoutSeconds }
    }).AddArgument($modulePath).AddArgument($Profile).AddArgument($Paths).AddArgument($TimeoutSeconds).AddArgument($Operation).AddArgument($tracker)
    return [pscustomobject]@{ Shell = $shell; Handle = $shell.BeginInvoke(); Profile = $Profile; Operation = $Operation; Tracker = $tracker; Result = $null }
}

function Stop-SSHManagerProcessTree {
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)
    # The open Process handle keeps the PID from being reused, so taskkill cannot hit an unrelated process.
    try { if ($Process.HasExited) { return } } catch { return }
    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = 'taskkill.exe'
        $startInfo.Arguments = '/PID {0} /T /F' -f $Process.Id
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $taskkill = [Diagnostics.Process]::Start($startInfo)
        [void]$taskkill.WaitForExit(3000)
        $taskkill.Dispose()
    }
    catch { }
    try { if (-not $Process.HasExited) { $Process.Kill() } } catch { }
}

function Stop-SSHManagerVpnJob {
    param([Parameter(Mandatory = $true)]$Job, [string]$Message = 'VPN tidak merespons.')
    # Gives up on a job that exceeded its deadline and kills the native process trees it started.
    # Processes started elevated (RunAsAdministrator) are not tracked and keep running.
    if ($null -ne $Job.Result) { return $Job.Result }
    $processes = @()
    if ($null -ne $Job.PSObject.Properties['Tracker'] -and $null -ne $Job.Tracker) {
        [Threading.Monitor]::Enter($Job.Tracker)
        try { $Job.Tracker.Stopped = $true; $processes = @($Job.Tracker.Processes) }
        finally { [Threading.Monitor]::Exit($Job.Tracker) }
    }
    # Kill trees before stopping the pipeline: stopping kills only the direct child and orphans its descendants.
    foreach ($process in $processes) { Stop-SSHManagerProcessTree -Process $process }
    try { [void]$Job.Shell.BeginStop($null, $null) } catch { }
    $Job.Result = [pscustomobject]@{ Success = $false; Message = $Message }
    return $Job.Result
}

function Receive-SSHManagerVpnJob {
    param([Parameter(Mandatory = $true)]$Job)
    if ($null -ne $Job.Result) { return $Job.Result }
    if (-not $Job.Handle.IsCompleted) { return $null }
    try {
        $output = @($Job.Shell.EndInvoke($Job.Handle))
        $result = $output | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['Success'] } | Select-Object -Last 1
        if ($null -eq $result) {
            $errorText = (@($Job.Shell.Streams.Error) | ForEach-Object { $_.ToString() }) -join '; '
            $result = [pscustomobject]@{ Success = $false; Message = $(if ($errorText) { $errorText } else { 'VPN tidak mengembalikan status.' }) }
        }
    }
    catch { $result = [pscustomobject]@{ Success = $false; Message = $_.Exception.GetBaseException().Message } }
    finally { $Job.Shell.Dispose() }
    $Job.Result = $result
    return $result
}
