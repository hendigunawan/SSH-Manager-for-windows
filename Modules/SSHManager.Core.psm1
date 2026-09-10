Set-StrictMode -Version 2.0

$script:ApplicationName = 'Proper SSH Manager'
$script:DataFolderName = 'ProperSSHManager'
$script:ConfigVersion = 1

. (Join-Path $PSScriptRoot 'SSHManager.ScpBatch.ps1')
. (Join-Path $PSScriptRoot 'SSHManager.RemoteEditor.ps1')

function Get-SSHManagerPaths {
    param([string]$ApplicationRoot)

    if ([string]::IsNullOrWhiteSpace($ApplicationRoot)) {
        $ApplicationRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }

    $dataRoot = $env:PROPER_SSH_MANAGER_DATA
    if ([string]::IsNullOrWhiteSpace($dataRoot)) {
        $dataRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) $script:DataFolderName
    }

    [pscustomobject]@{
        ApplicationRoot = [IO.Path]::GetFullPath($ApplicationRoot)
        DataRoot        = $dataRoot
        ConfigFile      = Join-Path $dataRoot 'config.json'
        SecretsRoot     = Join-Path $dataRoot 'secrets'
        BackupsRoot     = Join-Path $dataRoot 'backups'
        LogsRoot        = Join-Path $dataRoot 'logs'
        ScpStatusRoot   = Join-Path $dataRoot 'scp-status'
        RuntimeRoot     = Join-Path $ApplicationRoot 'Runtime'
    }
}

function New-SSHManagerDefaultConfig {
    [pscustomobject]@{
        Version     = $script:ConfigVersion
        App         = [pscustomobject]@{
            DefaultLayout            = 'Single'
            TerminalProfile          = ''
            StartMaximized            = $true
            CloseManagerAfterLaunch   = $false
            ReturnToManagerAfterScp   = $true
            ConfirmBeforeDelete       = $true
            TestConnectionBeforeOpen  = $true
            ConnectTimeoutSeconds     = 8
            VpnConnectTimeoutSeconds  = 30
            SearchIncludesNotes       = $true
        }
        Hosts       = @()
        VpnProfiles = @()
    }
}

function Add-MissingProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Repair-SSHManagerConfig {
    param([Parameter(Mandatory = $true)]$Config)

    Add-MissingProperty $Config 'Version' $script:ConfigVersion
    Add-MissingProperty $Config 'App' ([pscustomobject]@{})
    Add-MissingProperty $Config 'Hosts' @()
    Add-MissingProperty $Config 'VpnProfiles' @()

    $defaults = (New-SSHManagerDefaultConfig).App
    foreach ($property in $defaults.PSObject.Properties) {
        Add-MissingProperty $Config.App $property.Name $property.Value
    }

    foreach ($hostItem in @($Config.Hosts)) {
        Add-MissingProperty $hostItem 'Id' ([guid]::NewGuid().ToString('N'))
        Add-MissingProperty $hostItem 'Name' ''
        Add-MissingProperty $hostItem 'Group' 'Default'
        Add-MissingProperty $hostItem 'HostName' ''
        Add-MissingProperty $hostItem 'Port' 22
        Add-MissingProperty $hostItem 'Username' ''
        Add-MissingProperty $hostItem 'AuthType' 'Password'
        Add-MissingProperty $hostItem 'KeyPath' ''
        Add-MissingProperty $hostItem 'VpnProfileId' ''
        Add-MissingProperty $hostItem 'JumpHost' ''
        Add-MissingProperty $hostItem 'KeepAliveInterval' 15
        Add-MissingProperty $hostItem 'KeepAliveCountMax' 4
        Add-MissingProperty $hostItem 'HostKeyPolicy' 'AcceptNew'
        Add-MissingProperty $hostItem 'Tags' ''
        Add-MissingProperty $hostItem 'Notes' ''
        Add-MissingProperty $hostItem 'Favorite' $false
        Add-MissingProperty $hostItem 'LastConnectedAt' ''
    }

    foreach ($vpn in @($Config.VpnProfiles)) {
        Add-MissingProperty $vpn 'Id' ([guid]::NewGuid().ToString('N'))
        Add-MissingProperty $vpn 'Name' ''
        Add-MissingProperty $vpn 'Type' 'WindowsRas'
        Add-MissingProperty $vpn 'ConnectionName' ''
        Add-MissingProperty $vpn 'Username' ''
        Add-MissingProperty $vpn 'ConnectCommand' ''
        Add-MissingProperty $vpn 'CheckCommand' ''
        Add-MissingProperty $vpn 'DisconnectCommand' ''
        Add-MissingProperty $vpn 'RunAsAdministrator' $false
        Add-MissingProperty $vpn 'WaitSeconds' 3
        Add-MissingProperty $vpn 'Notes' ''
    }

    $Config.Hosts = @($Config.Hosts)
    $Config.VpnProfiles = @($Config.VpnProfiles)
    $Config.Version = $script:ConfigVersion
    return $Config
}

function Initialize-SSHManagerData {
    param([Parameter(Mandatory = $true)]$Paths)

    foreach ($directory in @($Paths.DataRoot, $Paths.SecretsRoot, $Paths.BackupsRoot, $Paths.LogsRoot, $Paths.ScpStatusRoot)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
    }

    if (-not (Test-Path -LiteralPath $Paths.ConfigFile -PathType Leaf)) {
        Save-SSHManagerConfig -Config (New-SSHManagerDefaultConfig) -Paths $Paths -SkipBackup
    }
}

function Read-SSHManagerConfig {
    param([Parameter(Mandatory = $true)]$Paths)

    Initialize-SSHManagerData -Paths $Paths
    try {
        $raw = Get-Content -LiteralPath $Paths.ConfigFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            throw 'File konfigurasi kosong.'
        }
        return Repair-SSHManagerConfig -Config ($raw | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $broken = Join-Path $Paths.BackupsRoot ("config-broken-{0}.json" -f $stamp)
        if (Test-Path -LiteralPath $Paths.ConfigFile) {
            Copy-Item -LiteralPath $Paths.ConfigFile -Destination $broken -Force -ErrorAction SilentlyContinue
        }
        $config = New-SSHManagerDefaultConfig
        Save-SSHManagerConfig -Config $config -Paths $Paths -SkipBackup
        return $config
    }
}

function Save-SSHManagerConfig {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Paths,
        [switch]$SkipBackup
    )

    foreach ($directory in @($Paths.DataRoot, $Paths.BackupsRoot)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
    }

    $Config = Repair-SSHManagerConfig -Config $Config
    if (-not $SkipBackup -and (Test-Path -LiteralPath $Paths.ConfigFile -PathType Leaf)) {
        $backup = Join-Path $Paths.BackupsRoot ("config-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
        Copy-Item -LiteralPath $Paths.ConfigFile -Destination $backup -Force
        Get-ChildItem -LiteralPath $Paths.BackupsRoot -Filter 'config-*.json' -File |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 20 |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    $temporary = Join-Path $Paths.DataRoot ("config.{0}.tmp" -f [guid]::NewGuid().ToString('N'))
    try {
        $Config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $Paths.ConfigFile -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-SecretFilePath {
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [ValidateSet('host', 'vpn')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Id
    )

    if ($Id -notmatch '^[a-zA-Z0-9_-]+$') {
        throw 'ID secret tidak valid.'
    }
    Join-Path $Paths.SecretsRoot ("{0}-{1}.secret" -f $Kind, $Id)
}

function Set-SSHManagerSecret {
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [ValidateSet('host', 'vpn')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][Security.SecureString]$Secret
    )

    if (-not (Test-Path -LiteralPath $Paths.SecretsRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $Paths.SecretsRoot -Force | Out-Null
    }

    $path = Get-SecretFilePath -Paths $Paths -Kind $Kind -Id $Id
    $Secret | ConvertFrom-SecureString | Set-Content -LiteralPath $path -Encoding UTF8

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $acl = New-Object Security.AccessControl.FileSecurity
        $acl.SetOwner($identity.User)
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $identity.User,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
        [IO.File]::SetAccessControl($path, $acl)
    }
    catch {
        # DPAPI tetap melindungi isi file walaupun penguatan ACL tidak tersedia.
    }

    return $path
}

function Remove-SSHManagerSecret {
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [ValidateSet('host', 'vpn')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Id
    )

    $path = Get-SecretFilePath -Paths $Paths -Kind $Kind -Id $Id
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Test-SSHManagerSecret {
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [ValidateSet('host', 'vpn')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Id
    )

    Test-Path -LiteralPath (Get-SecretFilePath -Paths $Paths -Kind $Kind -Id $Id) -PathType Leaf
}

function Get-SSHManagerPlainSecret {
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [ValidateSet('host', 'vpn')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Id
    )

    $path = Get-SecretFilePath -Paths $Paths -Kind $Kind -Id $Id
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Password tersimpan tidak ditemukan.'
    }

    $secure = (Get-Content -LiteralPath $path -Raw).Trim() | ConvertTo-SecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Get-SSHManagerDependencyStatus {
    $items = @(
        [pscustomobject]@{ Name = 'OpenSSH Client'; Command = 'ssh.exe'; Required = $true; Description = 'Mesin koneksi SSH' },
        [pscustomobject]@{ Name = 'OpenSSH SCP'; Command = 'scp.exe'; Required = $false; Description = 'Upload/download file dan folder' },
        [pscustomobject]@{ Name = 'Windows Terminal'; Command = 'wt.exe'; Required = $true; Description = 'Layout multi-pane' },
        [pscustomobject]@{ Name = 'PowerShell'; Command = 'powershell.exe'; Required = $true; Description = 'Runtime aplikasi' },
        [pscustomobject]@{ Name = 'Windows VPN/RAS'; Command = 'rasdial.exe'; Required = $false; Description = 'Hanya untuk profil Windows VPN' }
    )

    foreach ($item in $items) {
        $resolved = Get-Command $item.Command -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Name        = $item.Name
            Available   = ($null -ne $resolved)
            Required    = $item.Required
            Path        = if ($resolved) { $resolved.Source } else { '' }
            Description = $item.Description
        }
    }
}

function Test-SSHManagerHost {
    param(
        [Parameter(Mandatory = $true)]$HostEntry,
        [int]$TimeoutSeconds = 8,
        [scriptblock]$ProgressAction = $null
    )

    $client = New-Object Net.Sockets.TcpClient
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $effectiveTimeoutSeconds = [Math]::Max(1, $TimeoutSeconds)
        if ($ProgressAction) {
            try { & $ProgressAction 0 $effectiveTimeoutSeconds } catch { }
        }
        $task = $client.ConnectAsync([string]$HostEntry.HostName, [int]$HostEntry.Port)
        while (-not $task.IsCompleted) {
            $elapsedMilliseconds = $watch.ElapsedMilliseconds
            if ($elapsedMilliseconds -ge ($effectiveTimeoutSeconds * 1000)) {
                throw "Timeout setelah $effectiveTimeoutSeconds detik"
            }
            if ($ProgressAction) {
                try { & $ProgressAction $elapsedMilliseconds $effectiveTimeoutSeconds } catch { }
            }
            Start-Sleep -Milliseconds 100
        }
        if ($task.IsFaulted) {
            throw $task.Exception.GetBaseException().Message
        }
        $watch.Stop()
        if ($ProgressAction) {
            try { & $ProgressAction $watch.ElapsedMilliseconds $effectiveTimeoutSeconds } catch { }
        }
        [pscustomobject]@{ Success = $true; Milliseconds = $watch.ElapsedMilliseconds; Message = 'Port SSH dapat dijangkau.' }
    }
    catch {
        $watch.Stop()
        [pscustomobject]@{ Success = $false; Milliseconds = $watch.ElapsedMilliseconds; Message = $_.Exception.Message }
    }
    finally {
        $client.Dispose()
    }
}

function Test-SSHManagerVpnConnected {
    param([Parameter(Mandatory = $true)]$Profile)

    if ($Profile.Type -eq 'WindowsRas') {
        try {
            $text = (& rasdial.exe 2>&1 | Out-String)
            return $text -match [regex]::Escape([string]$Profile.ConnectionName)
        }
        catch { return $false }
    }

    if ([string]::IsNullOrWhiteSpace([string]$Profile.CheckCommand)) {
        return $false
    }

    try {
        $result = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ([string]$Profile.CheckCommand) 2>$null
        return ($LASTEXITCODE -eq 0 -and (($result | Out-String).Trim() -notmatch '^(false|0)$'))
    }
    catch { return $false }
}

function Connect-SSHManagerVpn {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)]$Paths,
        [int]$TimeoutSeconds = 30,
        [scriptblock]$ProgressAction = $null
    )

    $effectiveTimeoutSeconds = [Math]::Max(1, $TimeoutSeconds)
    if ($ProgressAction) {
        try { & $ProgressAction 0 $effectiveTimeoutSeconds } catch { }
    }
    if (Test-SSHManagerVpnConnected -Profile $Profile) {
        return [pscustomobject]@{ Success = $true; AlreadyConnected = $true; Message = "VPN '$($Profile.Name)' sudah terhubung." }
    }

    try {
        if ($Profile.Type -eq 'WindowsRas') {
            if ([string]::IsNullOrWhiteSpace([string]$Profile.ConnectionName)) {
                throw 'Nama koneksi Windows VPN belum diisi.'
            }

            $arguments = @([string]$Profile.ConnectionName)
            if (-not [string]::IsNullOrWhiteSpace([string]$Profile.Username)) {
                $password = Get-SSHManagerPlainSecret -Paths $Paths -Kind vpn -Id $Profile.Id
                $arguments += [string]$Profile.Username
                $arguments += $password
            }
            try {
                $output = (& rasdial.exe @arguments 2>&1 | Out-String)
            }
            finally {
                $password = $null
            }
            if ($LASTEXITCODE -ne 0 -and $output -notmatch 'already connected') {
                throw $output.Trim()
            }
        }
        else {
            if ([string]::IsNullOrWhiteSpace([string]$Profile.ConnectCommand)) {
                throw 'Perintah connect VPN belum diisi.'
            }
            $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([string]$Profile.ConnectCommand))
            $startInfo = New-Object Diagnostics.ProcessStartInfo
            $startInfo.FileName = 'powershell.exe'
            $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
            $startInfo.UseShellExecute = [bool]$Profile.RunAsAdministrator
            if ($Profile.RunAsAdministrator) {
                $startInfo.Verb = 'runas'
            }
            else {
                $startInfo.CreateNoWindow = $true
                $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
            }
            $process = [Diagnostics.Process]::Start($startInfo)
            if ($process -and -not $Profile.RunAsAdministrator) {
                $process.WaitForExit([Math]::Max(1, [int]$Profile.WaitSeconds) * 1000) | Out-Null
            }
        }

        $waitWatch = [Diagnostics.Stopwatch]::StartNew()
        $deadline = (Get-Date).AddSeconds($effectiveTimeoutSeconds)
        do {
            if ($ProgressAction) {
                try { & $ProgressAction $waitWatch.ElapsedMilliseconds $effectiveTimeoutSeconds } catch { }
            }
            if (Test-SSHManagerVpnConnected -Profile $Profile) {
                $waitWatch.Stop()
                return [pscustomobject]@{ Success = $true; AlreadyConnected = $false; Message = "VPN '$($Profile.Name)' terhubung." }
            }
            if ($Profile.Type -ne 'WindowsRas' -and [string]::IsNullOrWhiteSpace([string]$Profile.CheckCommand)) {
                return [pscustomobject]@{ Success = $true; AlreadyConnected = $false; Message = "Perintah VPN '$($Profile.Name)' sudah dijalankan; status tidak dapat diverifikasi." }
            }
            Start-Sleep -Milliseconds 250
        } while ((Get-Date) -lt $deadline)

        $waitWatch.Stop()
        throw "VPN tidak terdeteksi terhubung dalam $effectiveTimeoutSeconds detik."
    }
    catch {
        return [pscustomobject]@{ Success = $false; AlreadyConnected = $false; Message = $_.Exception.Message }
    }
}

function Disconnect-SSHManagerVpn {
    param([Parameter(Mandatory = $true)]$Profile)

    try {
        if ($Profile.Type -eq 'WindowsRas') {
            $output = (& rasdial.exe ([string]$Profile.ConnectionName) /disconnect 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) { throw $output.Trim() }
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$Profile.DisconnectCommand)) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ([string]$Profile.DisconnectCommand) | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Perintah disconnect VPN gagal.' }
        }
        else {
            throw 'Perintah disconnect belum dikonfigurasi.'
        }
        [pscustomobject]@{ Success = $true; Message = "VPN '$($Profile.Name)' diputus." }
    }
    catch {
        [pscustomobject]@{ Success = $false; Message = $_.Exception.Message }
    }
}

function Join-WindowsCommandLine {
    param([string[]]$Arguments)

    $quoted = foreach ($argument in $Arguments) {
        if ($null -eq $argument) { '""'; continue }
        if ($argument -notmatch '[\s"]') { $argument; continue }

        $builder = New-Object Text.StringBuilder
        [void]$builder.Append('"')
        $slashes = 0
        foreach ($character in $argument.ToCharArray()) {
            if ($character -eq '\') {
                $slashes++
                continue
            }
            if ($character -eq '"') {
                [void]$builder.Append(('\' * ($slashes * 2 + 1)))
                [void]$builder.Append('"')
                $slashes = 0
                continue
            }
            if ($slashes -gt 0) {
                [void]$builder.Append(('\' * $slashes))
                $slashes = 0
            }
            [void]$builder.Append($character)
        }
        if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
        [void]$builder.Append('"')
        $builder.ToString()
    }
    return ($quoted -join ' ')
}

function Initialize-SSHManagerAskPass {
    param([Parameter(Mandatory = $true)]$Paths)

    $source = Join-Path $Paths.RuntimeRoot 'AskPass.cs'
    $target = Join-Path $Paths.RuntimeRoot 'ssh-askpass.exe'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Source helper AskPass tidak ditemukan: $source"
    }
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        if ((Get-Item -LiteralPath $target).LastWriteTimeUtc -ge (Get-Item -LiteralPath $source).LastWriteTimeUtc) {
            return $target
        }
        Remove-Item -LiteralPath $target -Force
    }

    # Add-Type/csc membaca LIB milik proses. Environment Visual Studio/C++ yang
    # berisi path lama dapat mengubah warning pencarian library menjadi error,
    # padahal helper ini hanya membutuhkan assembly .NET. Kosongkan hanya untuk
    # proses kompilasi ini, lalu pulihkan nilai aslinya tanpa mengubah env user.
    $originalCompilerLib = [Environment]::GetEnvironmentVariable('LIB', [EnvironmentVariableTarget]::Process)
    try {
        [Environment]::SetEnvironmentVariable('LIB', $null, [EnvironmentVariableTarget]::Process)
        Add-Type -Path $source -OutputAssembly $target -OutputType ConsoleApplication -ReferencedAssemblies @(
            'System.dll',
            'System.Core.dll',
            'System.Security.dll'
        ) -ErrorAction Stop
    }
    catch {
        throw "Gagal membuat helper password: $($_.Exception.Message)"
    }
    finally {
        [Environment]::SetEnvironmentVariable('LIB', $originalCompilerLib, [EnvironmentVariableTarget]::Process)
    }
    return $target
}

function ConvertTo-SSHManagerPosixLiteral {
    param([AllowEmptyString()][string]$Value)

    $apostrophe = [string][char]39
    $doubleQuote = [string][char]34
    $escapedApostrophe = $apostrophe + $doubleQuote + $apostrophe + $doubleQuote + $apostrophe
    return $apostrophe + $Value.Replace($apostrophe, $escapedApostrophe) + $apostrophe
}

function New-SSHManagerRemoteProcessStartInfo {
    param(
        [Parameter(Mandatory = $true)]$HostEntry,
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$RemoteCommand,
        [ValidateRange(3,120)][int]$TimeoutSeconds = 30
    )
    $sshCommand = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($null -eq $sshCommand) { throw 'ssh.exe tidak ditemukan. Install Windows OpenSSH Client terlebih dahulu.' }
    $sshArgs = New-Object 'Collections.Generic.List[string]'
    $sshArgs.Add('-T')
    $sshArgs.Add('-p')
    $sshArgs.Add([string][int]$HostEntry.Port)
    $sshArgs.Add('-o')
    $sshArgs.Add("ConnectTimeout=$TimeoutSeconds")
    $sshArgs.Add('-o')
    $sshArgs.Add("ServerAliveInterval=$([Math]::Max(0, [int]$HostEntry.KeepAliveInterval))")
    $sshArgs.Add('-o')
    $sshArgs.Add("ServerAliveCountMax=$([Math]::Max(1, [int]$HostEntry.KeepAliveCountMax))")
    $sshArgs.Add('-o')
    $sshArgs.Add('TCPKeepAlive=yes')
    $sshArgs.Add('-o')
    $sshArgs.Add('LogLevel=ERROR')

    switch ([string]$HostEntry.HostKeyPolicy) {
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

    if (-not [string]::IsNullOrWhiteSpace([string]$HostEntry.JumpHost)) {
        $sshArgs.Add('-J')
        $sshArgs.Add([string]$HostEntry.JumpHost)
    }

    $secretFile = $null
    $askPass = $null
    switch ([string]$HostEntry.AuthType) {
        'PrivateKey' {
            $keyPath = [Environment]::ExpandEnvironmentVariables([string]$HostEntry.KeyPath)
            if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) {
                throw "Private key tidak ditemukan: $($HostEntry.KeyPath)"
            }
            $sshArgs.Add('-i')
            $sshArgs.Add($keyPath)
            $sshArgs.Add('-o')
            $sshArgs.Add('BatchMode=no')
        }
        'Agent' {
            $sshArgs.Add('-o')
            $sshArgs.Add('BatchMode=no')
        }
        default {
            $secretFile = Get-SecretFilePath -Paths $Paths -Kind host -Id $HostEntry.Id
            if (-not (Test-Path -LiteralPath $secretFile -PathType Leaf)) {
                throw 'Password belum disimpan. Edit host dan masukkan password terlebih dahulu.'
            }
            $askPass = Initialize-SSHManagerAskPass -Paths $Paths
            $sshArgs.Add('-o')
            $sshArgs.Add('BatchMode=no')
            $sshArgs.Add('-o')
            $sshArgs.Add('PreferredAuthentications=password,keyboard-interactive')
            $sshArgs.Add('-o')
            $sshArgs.Add('PubkeyAuthentication=no')
        }
    }

    $sshArgs.Add(('{0}@{1}' -f [string]$HostEntry.Username, [string]$HostEntry.HostName))
    $sshArgs.Add($remoteCommand)

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $sshCommand.Source
    $startInfo.Arguments = Join-WindowsCommandLine -Arguments $sshArgs.ToArray()
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    if ($secretFile) {
        $startInfo.EnvironmentVariables['SSH_MANAGER_SECRET_FILE'] = $secretFile
        $startInfo.EnvironmentVariables['SSH_ASKPASS'] = $askPass
        $startInfo.EnvironmentVariables['SSH_ASKPASS_REQUIRE'] = 'force'
        $startInfo.EnvironmentVariables['DISPLAY'] = 'proper-ssh-manager:0'
    }

    return $startInfo
}

function Invoke-SSHManagerRemoteDirectoryList {
    param(
        [Parameter(Mandatory = $true)]$HostEntry,
        [Parameter(Mandatory = $true)]$Paths,
        [string]$RemotePath = '~/',
        [ValidateRange(3, 120)][int]$TimeoutSeconds = 20
    )

    $sshCommand = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($null -eq $sshCommand) {
        throw 'ssh.exe tidak ditemukan. Install Windows OpenSSH Client terlebih dahulu.'
    }

    $requestedPath = $RemotePath.Trim()
    if ([string]::IsNullOrWhiteSpace($requestedPath)) { $requestedPath = '~/' }
    if ($requestedPath.Contains("`r") -or $requestedPath.Contains("`n")) {
        throw 'Path remote tidak boleh mengandung baris baru.'
    }

    $pathLiteral = ConvertTo-SSHManagerPosixLiteral -Value $requestedPath
    $remoteScript = @'
path=__PSM_PATH_LITERAL__
case "$path" in
  "~") path="$HOME" ;;
  "~/"*) path="$HOME/${path#??}" ;;
esac
if ! cd -- "$path" 2>/dev/null; then
  printf 'Folder remote tidak dapat dibuka: %s\n' "$path" >&2
  exit 21
fi
printf '__PSM_PATH__\t%s\n' "$PWD"
for item in ./* ./.[!.]* ./..?*; do
  if [ ! -e "$item" ] && [ ! -L "$item" ]; then
    continue
  fi
  name=${item#./}
  if [ -d "$item" ]; then
    kind=D
  else
    kind=F
  fi
  printf '__PSM_ITEM__\t%s\t%s\n' "$kind" "$name"
done
'@
    $remoteScript = $remoteScript.Replace('__PSM_PATH_LITERAL__', $pathLiteral)
    $remoteCommand = 'sh -c ' + (ConvertTo-SSHManagerPosixLiteral -Value $remoteScript)

    $startInfo = New-SSHManagerRemoteProcessStartInfo -HostEntry $HostEntry -Paths $Paths -RemoteCommand $remoteCommand -TimeoutSeconds $TimeoutSeconds

    $process = $null
    try {
        $process = [Diagnostics.Process]::Start($startInfo)
        if ($null -eq $process) { throw 'Proses SSH untuk membaca folder remote gagal dimulai.' }
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            [void]$process.WaitForExit(2000)
            throw "Timeout saat membaca folder remote setelah $TimeoutSeconds detik."
        }
        $output = $outputTask.Result
        $errorOutput = $errorTask.Result
        $exitCode = $process.ExitCode
    }
    finally {
        if ($process) { $process.Dispose() }
    }

    if ($exitCode -ne 0) {
        $message = ($errorOutput | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($message)) { $message = "SSH berhenti dengan exit code $exitCode." }
        throw $message
    }

    $resolvedPath = ''
    $items = New-Object 'Collections.Generic.List[object]'
    $pathPrefix = "__PSM_PATH__`t"
    $itemPrefix = "__PSM_ITEM__`t"
    foreach ($line in @($output -split "`r?`n")) {
        if ($line.StartsWith($pathPrefix, [StringComparison]::Ordinal)) {
            $resolvedPath = $line.Substring($pathPrefix.Length)
            continue
        }
        if (-not $line.StartsWith($itemPrefix, [StringComparison]::Ordinal)) { continue }
        $parts = @($line.Substring($itemPrefix.Length) -split "`t", 2)
        if ($parts.Count -ne 2) { continue }
        $isDirectory = ($parts[0] -eq 'D')
        $name = $parts[1]
        $fullPath = if ($resolvedPath -eq '/') { "/$name" } else { '{0}/{1}' -f $resolvedPath.TrimEnd('/'), $name }
        $items.Add([pscustomobject]@{
            Name        = $name
            FullPath    = $fullPath
            IsDirectory = $isDirectory
            TypeLabel   = if ($isDirectory) { 'Folder' } else { 'File' }
        })
    }

    if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
        throw 'Server tidak mengembalikan path folder remote yang valid.'
    }

    [pscustomobject]@{
        Path  = $resolvedPath
        Items = @($items | Sort-Object -Property @{ Expression = 'IsDirectory'; Descending = $true }, Name)
    }
}

function Get-PaneCommandArguments {
    param(
        [Parameter(Mandatory = $true)]$HostEntry,
        [Parameter(Mandatory = $true)]$Paths
    )

    @(
        'powershell.exe',
        '-NoExit',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $Paths.RuntimeRoot 'Connect-SSH.ps1'),
        '-ApplicationRoot', $Paths.ApplicationRoot,
        '-HostId', [string]$HostEntry.Id
    )
}

function Add-WtPaneCommand {
    param(
        [Collections.Generic.List[string]]$Arguments,
        [string]$Command,
        [string]$Split,
        $HostEntry,
        $Paths,
        [string]$TerminalProfile
    )

    $Arguments.Add($Command)
    if (-not [string]::IsNullOrWhiteSpace($Split)) { $Arguments.Add($Split) }
    if (-not [string]::IsNullOrWhiteSpace($TerminalProfile)) {
        $Arguments.Add('--profile')
        $Arguments.Add($TerminalProfile)
    }
    $Arguments.Add('--title')
    $Arguments.Add([string]$HostEntry.Name)
    $Arguments.Add('--suppressApplicationTitle')
    foreach ($part in (Get-PaneCommandArguments -HostEntry $HostEntry -Paths $Paths)) {
        $Arguments.Add([string]$part)
    }
}

function Get-SSHManagerLayoutCapacity {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Single', 'TwoColumns', 'TwoRows', 'TopOneBottomTwo', 'TopTwoBottomOne', 'FourGrid')]
        [string]$Layout
    )

    return @{
        Single          = 1
        TwoColumns      = 2
        TwoRows         = 2
        TopOneBottomTwo = 3
        TopTwoBottomOne = 3
        FourGrid        = 4
    }[$Layout]
}

function Resolve-SSHManagerPartialLayout {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Single', 'TwoColumns', 'TwoRows', 'TopOneBottomTwo', 'TopTwoBottomOne', 'FourGrid')]
        [string]$RequestedLayout,
        [Parameter(Mandatory = $true)][ValidateRange(1, 4)][int]$HostCount
    )

    switch ($HostCount) {
        1 { return 'Single' }
        2 {
            if ($RequestedLayout -eq 'TwoRows') { return 'TwoRows' }
            return 'TwoColumns'
        }
        3 {
            if ($RequestedLayout -eq 'TopTwoBottomOne') { return 'TopTwoBottomOne' }
            return 'TopOneBottomTwo'
        }
        4 { return 'FourGrid' }
    }
}

function Add-WtLayoutTab {
    param(
        [Parameter(Mandatory = $true)][Collections.Generic.List[string]]$Arguments,
        [Parameter(Mandatory = $true)][object[]]$Hosts,
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Single', 'TwoColumns', 'TwoRows', 'TopOneBottomTwo', 'TopTwoBottomOne', 'FourGrid')]
        [string]$Layout,
        [string]$TerminalProfile = ''
    )

    $hostList = @($Hosts)
    $expected = Get-SSHManagerLayoutCapacity -Layout $Layout
    if ($hostList.Count -ne $expected) {
        throw "Layout tab $Layout memerlukan $expected host, menerima $($hostList.Count)."
    }

    Add-WtPaneCommand -Arguments $Arguments -Command 'new-tab' -Split '' -HostEntry $hostList[0] -Paths $Paths -TerminalProfile $TerminalProfile

    switch ($Layout) {
        'TwoColumns' {
            $Arguments.Add(';')
            Add-WtPaneCommand -Arguments $Arguments -Command 'split-pane' -Split '-V' -HostEntry $hostList[1] -Paths $Paths -TerminalProfile $TerminalProfile
        }
        'TwoRows' {
            $Arguments.Add(';')
            Add-WtPaneCommand -Arguments $Arguments -Command 'split-pane' -Split '-H' -HostEntry $hostList[1] -Paths $Paths -TerminalProfile $TerminalProfile
        }
        'TopOneBottomTwo' {
            $Arguments.Add(';')
            Add-WtPaneCommand -Arguments $Arguments -Command 'split-pane' -Split '-H' -HostEntry $hostList[1] -Paths $Paths -TerminalProfile $TerminalProfile
            $Arguments.Add(';')
            Add-WtPaneCommand -Arguments $Arguments -Command 'split-pane' -Split '-V' -HostEntry $hostList[2] -Paths $Paths -TerminalProfile $TerminalProfile
        }
        'TopTwoBottomOne' {
            $Arguments.Add(';')
            Add-WtPaneCommand -Arguments $Arguments -Command 'split-pane' -Split '-H' -HostEntry $hostList[2] -Paths $Paths -TerminalProfile $TerminalProfile
            $Arguments.Add(';')
            $Arguments.Add('move-focus')
            $Arguments.Add('first')
            $Arguments.Add(';')
            Add-WtPaneCommand -Arguments $Arguments -Command 'split-pane' -Split '-V' -HostEntry $hostList[1] -Paths $Paths -TerminalProfile $TerminalProfile
        }
        'FourGrid' {
            $Arguments.Add(';')
            Add-WtPaneCommand -Arguments $Arguments -Command 'split-pane' -Split '-V' -HostEntry $hostList[1] -Paths $Paths -TerminalProfile $TerminalProfile
            $Arguments.Add(';')
            Add-WtPaneCommand -Arguments $Arguments -Command 'split-pane' -Split '-H' -HostEntry $hostList[3] -Paths $Paths -TerminalProfile $TerminalProfile
            $Arguments.Add(';')
            $Arguments.Add('move-focus')
            $Arguments.Add('first')
            $Arguments.Add(';')
            Add-WtPaneCommand -Arguments $Arguments -Command 'split-pane' -Split '-H' -HostEntry $hostList[2] -Paths $Paths -TerminalProfile $TerminalProfile
        }
    }
}

function Start-SSHManagerLayout {
    param(
        [Parameter(Mandatory = $true)][object[]]$Hosts,
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][ValidateSet('Single', 'TwoColumns', 'TwoRows', 'TopOneBottomTwo', 'TopTwoBottomOne', 'FourGrid')][string]$Layout,
        [string]$TerminalProfile = '',
        [bool]$StartMaximized = $true
    )

    $hostList = @($Hosts)
    if ($hostList.Count -eq 0) { throw 'Pilih minimal satu host.' }
    $capacity = Get-SSHManagerLayoutCapacity -Layout $Layout

    # Jika hanya satu host dipilih, isi semua panel layout dengan host yang sama.
    if ($hostList.Count -eq 1 -and $capacity -gt 1) {
        $singleHost = $hostList[0]
        $hostList = @()
        for ($index = 0; $index -lt $capacity; $index++) {
            $hostList += $singleHost
        }
    }

    $arguments = New-Object 'Collections.Generic.List[string]'
    $arguments.Add('--window')
    # Window ID 0 berarti jendela Windows Terminal yang terakhir digunakan.
    # Jika belum ada jendela Terminal, wt.exe akan membuat satu secara otomatis.
    $arguments.Add('0')
    if ($StartMaximized) { $arguments.Add('--maximized') }

    $offset = 0
    $tabIndex = 0
    while ($offset -lt $hostList.Count) {
        $tabHostCount = [Math]::Min($capacity, $hostList.Count - $offset)
        $tabHosts = @()
        for ($index = 0; $index -lt $tabHostCount; $index++) {
            $tabHosts += $hostList[$offset + $index]
        }

        if ($tabIndex -gt 0) { $arguments.Add(';') }
        $tabLayout = Resolve-SSHManagerPartialLayout -RequestedLayout $Layout -HostCount $tabHostCount
        Add-WtLayoutTab -Arguments $arguments -Hosts $tabHosts -Paths $Paths -Layout $tabLayout -TerminalProfile $TerminalProfile

        $offset += $tabHostCount
        $tabIndex++
    }

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'wt.exe'
    $startInfo.Arguments = Join-WindowsCommandLine -Arguments $arguments.ToArray()
    $startInfo.UseShellExecute = $true
    $terminalProcess = [Diagnostics.Process]::Start($startInfo)
    if ($null -eq $terminalProcess) {
        throw 'Windows Terminal gagal menerima perintah untuk membuka sesi SSH.'
    }

    # Beri waktu singkat agar perintah tab/pane diterima sebelum tab manager
    # boleh ditutup oleh opsi CloseManagerAfterLaunch.
    [void]$terminalProcess.WaitForExit(1000)
    if ($terminalProcess.HasExited -and $terminalProcess.ExitCode -ne 0) {
        throw "Windows Terminal berhenti dengan exit code $($terminalProcess.ExitCode)."
    }
}

function Start-SSHManagerScp {
    param(
        [Parameter(Mandatory = $true)]$HostEntry,
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][ValidateSet('Upload', 'Download')][string]$Direction,
        [Parameter(Mandatory = $true)][string[]]$LocalPaths,
        [Parameter(Mandatory = $true)][string[]]$RemotePaths,
        [string]$TerminalProfile = '',
        [bool]$Recursive = $false,
        [bool]$PreserveTimes = $false,
        [bool]$Compression = $false,
        [bool]$StartMaximized = $true,
        [bool]$ReturnToManager = $true,
        [int]$ManagerProcessId = 0,
        [long]$ManagerWindowHandle = 0,
        [string]$StatusFile = '',
        [int]$SourceFileCount = 0,
        [int]$SourceFolderCount = 0
    )

    $cleanLocalPaths = @($LocalPaths | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $cleanRemotePaths = @($RemotePaths | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($cleanLocalPaths.Count -eq 0) { throw 'Path lokal wajib diisi.' }
    if ($cleanRemotePaths.Count -eq 0) { throw 'Path remote wajib diisi.' }

    $localPathsJson = ConvertTo-Json -InputObject @($cleanLocalPaths) -Compress
    $remotePathsJson = ConvertTo-Json -InputObject @($cleanRemotePaths) -Compress
    $localPathsBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($localPathsJson))
    $remotePathsBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remotePathsJson))

    $runtimeScript = Join-Path $Paths.RuntimeRoot 'Connect-SCP.ps1'
    if (-not (Test-Path -LiteralPath $runtimeScript -PathType Leaf)) {
        throw "Runtime SCP tidak ditemukan: $runtimeScript"
    }

    $arguments = New-Object 'Collections.Generic.List[string]'
    $arguments.Add('--window')
    $arguments.Add('0')
    if ($StartMaximized) { $arguments.Add('--maximized') }
    $arguments.Add('new-tab')
    if (-not [string]::IsNullOrWhiteSpace($TerminalProfile)) {
        $arguments.Add('--profile')
        $arguments.Add($TerminalProfile)
    }
    $arguments.Add('--title')
    $arguments.Add(('SCP - {0}' -f [string]$HostEntry.Name))
    $arguments.Add('--suppressApplicationTitle')

    $arguments.Add('powershell.exe')
    if (-not $ReturnToManager) { $arguments.Add('-NoExit') }
    foreach ($part in @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $runtimeScript,
        '-ApplicationRoot', $Paths.ApplicationRoot,
        '-HostId', [string]$HostEntry.Id,
        '-Direction', $Direction,
        '-LocalPathsBase64', $localPathsBase64,
        '-RemotePathsBase64', $remotePathsBase64,
        '-ManagerProcessId', [string]$ManagerProcessId,
        '-ManagerWindowHandle', [string]$ManagerWindowHandle,
        '-StatusFile', $StatusFile,
        '-SourceFileCount', [string][Math]::Max(0, $SourceFileCount),
        '-SourceFolderCount', [string][Math]::Max(0, $SourceFolderCount)
    )) {
        $arguments.Add([string]$part)
    }
    if ($Recursive) { $arguments.Add('-Recursive') }
    if ($PreserveTimes) { $arguments.Add('-PreserveTimes') }
    if ($Compression) { $arguments.Add('-Compression') }
    if ($ReturnToManager) { $arguments.Add('-ReturnToManager') }

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'wt.exe'
    $startInfo.Arguments = Join-WindowsCommandLine -Arguments $arguments.ToArray()
    $startInfo.UseShellExecute = $true
    $terminalProcess = [Diagnostics.Process]::Start($startInfo)
    if ($null -eq $terminalProcess) {
        throw 'Windows Terminal gagal menerima perintah transfer SCP.'
    }
    [void]$terminalProcess.WaitForExit(1000)
    if ($terminalProcess.HasExited -and $terminalProcess.ExitCode -ne 0) {
        throw "Windows Terminal berhenti dengan exit code $($terminalProcess.ExitCode)."
    }
}

function Export-SSHManagerConfig {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $clean = $Config | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $clean | Add-Member -MemberType NoteProperty -Name ExportedAt -Value (Get-Date).ToString('o') -Force
    $clean | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Destination -Encoding UTF8
}

function Import-SSHManagerConfig {
    param([Parameter(Mandatory = $true)][string]$Source)

    $raw = Get-Content -LiteralPath $Source -Raw -ErrorAction Stop
    $incoming = $raw | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $incoming.Hosts -or $null -eq $incoming.VpnProfiles) {
        throw 'File bukan konfigurasi Proper SSH Manager yang valid.'
    }
    Repair-SSHManagerConfig -Config $incoming
}

Export-ModuleMember -Function @(
    'ConvertFrom-SSHManagerTextBytes',
    'ConvertTo-SSHManagerTextBytes',
    'Find-SSHManagerEditorText',
    'Invoke-SSHManagerRemoteTextFile',
    'New-SSHManagerScpBatchPlan',
    'New-SSHManagerScpBatchStatus',
    'Write-SSHManagerScpBatchStatus',
    'Invoke-SSHManagerScpBatch',
    'Get-SSHManagerScpBatchStatusText',
    'Start-SSHManagerScpBatch',
    'Get-SSHManagerPaths',
    'New-SSHManagerDefaultConfig',
    'Initialize-SSHManagerData',
    'Read-SSHManagerConfig',
    'Save-SSHManagerConfig',
    'Get-SecretFilePath',
    'Set-SSHManagerSecret',
    'Remove-SSHManagerSecret',
    'Test-SSHManagerSecret',
    'Get-SSHManagerPlainSecret',
    'Get-SSHManagerDependencyStatus',
    'Test-SSHManagerHost',
    'Test-SSHManagerVpnConnected',
    'Connect-SSHManagerVpn',
    'Disconnect-SSHManagerVpn',
    'Join-WindowsCommandLine',
    'Initialize-SSHManagerAskPass',
    'Invoke-SSHManagerRemoteDirectoryList',
    'Start-SSHManagerLayout',
    'Start-SSHManagerScp',
    'Export-SSHManagerConfig',
    'Import-SSHManagerConfig'
)
