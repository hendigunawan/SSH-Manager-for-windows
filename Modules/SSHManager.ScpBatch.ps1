function New-SSHManagerScpBatchPlan {
    param(
        [Parameter(Mandatory = $true)][object[]]$HostEntries,
        [Parameter(Mandatory = $true)][ValidateSet('Upload','Download')][string]$Direction,
        [Parameter(Mandatory = $true)][string[]]$LocalPaths,
        [Parameter(Mandatory = $true)][hashtable]$NodeSelections,
        [bool]$Recursive = $false,
        [bool]$PreserveTimes = $false,
        [bool]$Compression = $false,
        [string]$VpnOverride = '__HOST__'
    )
    $uniqueNodes = New-Object 'Collections.Generic.List[object]'
    $seenIds = @{}
    foreach ($node in $HostEntries) {
        $id = [string]$node.Id
        if ([string]::IsNullOrWhiteSpace($id)) { throw 'ID node kosong.' }
        if (-not $seenIds.ContainsKey($id)) { $seenIds[$id] = $true; $uniqueNodes.Add($node) }
    }
    if ($uniqueNodes.Count -eq 0) { throw 'Pilih minimal satu node.' }
    $cleanLocalPaths = @($LocalPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($cleanLocalPaths.Count -eq 0) { throw 'Path lokal wajib diisi.' }
    $localFileCount = 0
    $localFolderCount = 0
    $expandedLocal = @(
        foreach ($value in $cleanLocalPaths) {
            $expanded = [Environment]::ExpandEnvironmentVariables($value.Trim())
            if ($Direction -eq 'Upload') {
                $item = Get-Item -LiteralPath $expanded -Force -ErrorAction Stop
                if ($item.PSIsContainer) { $localFolderCount++ } else { $localFileCount++ }
                $item.FullName
            }
            else {
                if ($cleanLocalPaths.Count -ne 1) { throw 'Download membutuhkan satu folder tujuan lokal.' }
                if (Test-Path -LiteralPath $expanded -PathType Leaf) { throw 'Tujuan download harus berupa folder.' }
                $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($expanded)
            }
        }
    )
    $jobs = New-Object 'Collections.Generic.List[object]'
    $folderNames = @{}
    foreach ($node in $uniqueNodes) {
        $id = [string]$node.Id
        if (-not $NodeSelections.ContainsKey($id)) { throw "Path remote node '$($node.Name)' belum diisi." }
        $selection = $NodeSelections[$id]
        $remote = @($selection.RemotePaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
        if ($remote.Count -eq 0) { throw "Path remote node '$($node.Name)' belum diisi." }
        if ($Direction -eq 'Upload') {
            if ($remote.Count -ne 1) { throw "Upload node '$($node.Name)' membutuhkan satu folder tujuan remote." }
            if (-not $remote[0].EndsWith('/')) { $remote[0] += '/' }
        }
        $destination = [string[]]$expandedLocal
        if ($Direction -eq 'Download' -and $uniqueNodes.Count -gt 1) {
            $safeName = [regex]::Replace([string]$node.Name, '[<>:"/\\|?*\x00-\x1f]', '_').Trim(' ','.')
            if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = 'node' }
            if ($safeName -match '^(CON|PRN|AUX|NUL|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(\.|$)') { $safeName = 'node-' + $safeName }
            if ($safeName.Length -gt 48) { $safeName = $safeName.Substring(0,48) }
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $suffix = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($id)))).Replace('-','').Substring(0,12).ToLowerInvariant() }
            finally { $sha.Dispose() }
            $folder = '{0}-{1}' -f $safeName, $suffix
            $candidate = $folder
            $collision = 1
            while ($folderNames.ContainsKey($candidate)) { $collision++; $candidate = '{0}-{1}' -f $folder, $collision }
            $folderNames[$candidate] = $true
            $destination = @((Join-Path $expandedLocal[0] $candidate))
        }
        $vpnId = if ($VpnOverride -eq '__HOST__') { [string]$node.VpnProfileId } elseif ($VpnOverride -eq '__NONE__') { '' } else { $VpnOverride }
        $fileCount = if ($Direction -eq 'Upload') { $localFileCount } else { [Math]::Max(0,[int]$selection.RemoteFileCount) }
        $folderCount = if ($Direction -eq 'Upload') { $localFolderCount } else { [Math]::Max(0,[int]$selection.RemoteFolderCount) }
        $itemCount = if ($Direction -eq 'Upload') { $expandedLocal.Count } else { $remote.Count }
        if (($fileCount + $folderCount) -ne $itemCount) { $fileCount = 0; $folderCount = 0 }
        $jobRecursive = $Recursive -or ($Direction -eq 'Upload' -and $localFolderCount -gt 0) -or ($Direction -eq 'Download' -and [bool]$selection.RemoteHasDirectory)
        $jobs.Add([pscustomobject]@{
            HostId=$id; HostName=[string]$node.Name; Direction=$Direction
            LocalPaths=[string[]]$destination; RemotePaths=[string[]]$remote
            VpnProfileId=$vpnId; Recursive=[bool]$jobRecursive; PreserveTimes=$PreserveTimes; Compression=$Compression
            SourceFileCount=$fileCount; SourceFolderCount=$folderCount; SourceItemCount=$itemCount
        })
    }
    [pscustomobject]@{ Version=1; BatchId=[guid]::NewGuid().ToString('N'); Direction=$Direction; Jobs=$jobs.ToArray() }
}

function Write-SSHManagerScpBatchStatus {
    param([Parameter(Mandatory = $true)]$Result, [Parameter(Mandatory = $true)][string]$StatusFile)
    $parent = Split-Path -Parent $StatusFile
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporaryStatusFile = '{0}.{1}.tmp' -f $StatusFile, $PID
    try {
        $Result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporaryStatusFile -Encoding UTF8
        for ($attempt = 0; $attempt -lt 4; $attempt++) {
            try { Move-Item -LiteralPath $temporaryStatusFile -Destination $StatusFile -Force -ErrorAction Stop; break }
            catch {
                if ($attempt -eq 3) { throw }
                Start-Sleep -Milliseconds 50
            }
        }
    }
    finally { Remove-Item -LiteralPath $temporaryStatusFile -Force -ErrorAction SilentlyContinue }
}

function New-SSHManagerScpBatchStatus {
    param([Parameter(Mandatory = $true)]$Plan)
    $rows = @(
        foreach ($job in $Plan.Jobs) {
            [pscustomobject]@{
                HostId=[string]$job.HostId; HostName=[string]$job.HostName; State='Pending'; Succeeded=$false
                FileCount=0; FolderCount=0; ItemCount=[int]$job.SourceItemCount; Message=''
                LocalPaths=@($job.LocalPaths); RemotePaths=@($job.RemotePaths)
            }
        }
    )
    [pscustomobject]@{
        Kind='ScpBatch'; BatchId=[string]$Plan.BatchId; Direction=[string]$Plan.Direction
        ProcessId=0; ProcessStartedAt=''; IsComplete=$false; Succeeded=$false
        NodeCount=$rows.Count; NodeIndex=0; SuccessCount=0; FailedCount=0; ActiveHost=''; Stage='Menunggu tab SCP...'
        StartedAt=(Get-Date).ToString('o'); FinishedAt=''; Results=$rows
    }
}

function Invoke-SSHManagerScpBatch {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$StatusFile,
        [Parameter(Mandatory = $true)][scriptblock]$TransferAction
    )
    $jobs = @($Plan.Jobs)
    if ($jobs.Count -eq 0) { throw 'Antrean transfer kosong.' }
    $result = New-SSHManagerScpBatchStatus -Plan $Plan
    $result.ProcessId = $PID
    $processStart = (Get-Process -Id $PID).StartTime
    if ($null -ne $processStart) { $result.ProcessStartedAt = $processStart.ToUniversalTime().ToString('o') }
    Write-SSHManagerScpBatchStatus -Result $result -StatusFile $StatusFile
    try {
        for ($index = 0; $index -lt $jobs.Count; $index++) {
            $job = $jobs[$index]
            $row = $result.Results[$index]
            $result.NodeIndex = $index + 1
            $result.ActiveHost = [string]$job.HostName
            $result.Stage = 'Menghubungkan / transfer'
            $row.State = 'Running'
            try { Write-SSHManagerScpBatchStatus -Result $result -StatusFile $StatusFile }
            catch { Write-Warning ('Progres manager belum dapat diperbarui; antrean dilanjutkan: {0}' -f $_.Exception.Message) }
            Write-Host ('[{0}/{1}] SCP {2} - {3}' -f ($index+1), $jobs.Count, $Plan.Direction, $job.HostName) -ForegroundColor Cyan
            try {
                $outcome = & $TransferAction $job
                if ($null -eq $outcome -or -not ($outcome.PSObject.Properties.Name -contains 'Succeeded')) { throw 'Runtime SCP tidak mengembalikan hasil yang valid.' }
                if (-not [bool]$outcome.Succeeded) { throw [string]$outcome.Message }
                $row.Succeeded = $true
                $row.State = 'Succeeded'
                $row.FileCount = [int]$outcome.FileCount
                $row.FolderCount = [int]$outcome.FolderCount
                $row.ItemCount = [int]$outcome.ItemCount
                $result.SuccessCount++
            }
            catch {
                $row.State = 'Failed'
                $row.Message = $_.Exception.Message
                $result.FailedCount++
                Write-Host ('Gagal {0}: {1}' -f $job.HostName, $row.Message) -ForegroundColor Red
            }
            try { Write-SSHManagerScpBatchStatus -Result $result -StatusFile $StatusFile }
            catch { Write-Warning ('Progres manager belum dapat diperbarui; antrean dilanjutkan: {0}' -f $_.Exception.Message) }
        }
    }
    finally {
        foreach ($row in $result.Results) {
            if ($row.State -in @('Pending','Running')) {
                $row.State='Interrupted'; $row.Message='Antrean dihentikan sebelum hasil transfer diterima.'; $result.FailedCount++
            }
        }
        $result.IsComplete = $true
        $result.Succeeded = ($result.SuccessCount -eq $result.NodeCount)
        $result.ActiveHost = ''
        $result.FinishedAt = (Get-Date).ToString('o')
        try { Write-SSHManagerScpBatchStatus -Result $result -StatusFile $StatusFile }
        catch {
            $result | Add-Member -MemberType NoteProperty -Name StatusWriteFailed -Value $true
            Write-Warning ('Hasil akhir belum dapat dikirim ke manager: {0}' -f $_.Exception.Message)
        }
    }
    return $result
}

function Get-SSHManagerScpBatchStatusText {
    param([Parameter(Mandatory = $true)]$Result)
    $details = New-Object 'Collections.Generic.List[string]'
    $fileTotal = 0; $folderTotal = 0; $unknownTotal = 0
    foreach ($row in $Result.Results) {
        $details.Add(('{0}: {1} ({2} item sumber)' -f $row.HostName, $row.State, $row.ItemCount))
        $details.Add(('  Lokal: {0}' -f (@($row.LocalPaths) -join ', ')))
        $details.Add(('  Remote: {0}' -f (@($row.RemotePaths) -join ', ')))
        if ($row.Message) { $details.Add(('  {0}' -f $row.Message)) }
        if ($row.Succeeded) {
            $fileTotal += [int]$row.FileCount; $folderTotal += [int]$row.FolderCount
            $unknownTotal += [Math]::Max(0, [int]$row.ItemCount - [int]$row.FileCount - [int]$row.FolderCount)
        }
    }
    $totals = New-Object 'Collections.Generic.List[string]'
    if ($fileTotal -gt 0) { $totals.Add(('{0} file' -f $fileTotal)) }
    if ($folderTotal -gt 0) { $totals.Add(('{0} folder' -f $folderTotal)) }
    if ($unknownTotal -gt 0) { $totals.Add(('{0} item' -f $unknownTotal)) }
    $totalText = if ($totals.Count -gt 0) { ' | Berhasil: ' + ($totals -join ', ') } else { '' }
    if (-not $Result.IsComplete) {
        $message = 'SCP {0} [{1}/{2}]: {3} {4} | {5} berhasil, {6} gagal.' -f $Result.Direction, $Result.NodeIndex, $Result.NodeCount, $Result.Stage, $Result.ActiveHost, $Result.SuccessCount, $Result.FailedCount
        $color = '#38BDF8'
    }
    else {
        $label = if ($Result.Succeeded) { 'Selesai' } else { 'Selesai dengan kegagalan' }
        $message = '{0} SCP {1}: {2} node | {3} berhasil, {4} gagal{5}.' -f $label, $Result.Direction, $Result.NodeCount, $Result.SuccessCount, $Result.FailedCount, $totalText
        $color = if ($Result.Succeeded) { '#22C55E' } else { '#EF4444' }
    }
    [pscustomobject]@{ Text=$message; Color=$color; Details=($details -join "`n") }
}

function Start-SSHManagerScpBatch {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)]$Paths,
        [string]$TerminalProfile = '', [bool]$StartMaximized = $true,
        [bool]$ReturnToManager = $true, [int]$ManagerProcessId = 0, [long]$ManagerWindowHandle = 0
    )
    $statusFile = Join-Path $Paths.ScpStatusRoot ('scp-batch-{0}.json' -f $Plan.BatchId)
    $planFile = Join-Path $Paths.ScpStatusRoot ('plan-{0}.json' -f $Plan.BatchId)
    $runtimeScript = Join-Path $Paths.RuntimeRoot 'Connect-SCP.ps1'
    if (-not (Test-Path -LiteralPath $runtimeScript -PathType Leaf)) { throw 'Runtime SCP tidak ditemukan.' }
    $literal = { param([string]$Value) "'" + $Value.Replace("'", "''") + "'" }
    # Only the encoded command crosses wt's command parser; host/path semicolons stay data.
    $commandText = '& {0} -ApplicationRoot {1} -BatchFile {2} -StatusFile {3} -ManagerProcessId {4} -ManagerWindowHandle {5}' -f (& $literal $runtimeScript), (& $literal $Paths.ApplicationRoot), (& $literal $planFile), (& $literal $statusFile), $ManagerProcessId, $ManagerWindowHandle
    if ($ReturnToManager) { $commandText += ' -ReturnToManager' }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($commandText))
    $arguments = New-Object 'Collections.Generic.List[string]'
    $arguments.Add('--window'); $arguments.Add('0')
    if ($StartMaximized) { $arguments.Add('--maximized') }
    $arguments.Add('new-tab')
    if ($TerminalProfile) { $arguments.Add('--profile'); $arguments.Add($TerminalProfile) }
    $arguments.Add('--title'); $arguments.Add(('SCP {0} - {1} node' -f $Plan.Direction, @($Plan.Jobs).Count))
    $arguments.Add('--suppressApplicationTitle'); $arguments.Add('powershell.exe')
    if (-not $ReturnToManager) { $arguments.Add('-NoExit') }
    $arguments.Add('-NoProfile'); $arguments.Add('-ExecutionPolicy'); $arguments.Add('Bypass'); $arguments.Add('-EncodedCommand'); $arguments.Add($encoded)
    try {
        Write-SSHManagerScpBatchStatus -Result (New-SSHManagerScpBatchStatus -Plan $Plan) -StatusFile $statusFile
        $Plan | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $planFile -Encoding UTF8
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = 'wt.exe'
        $startInfo.Arguments = Join-WindowsCommandLine -Arguments $arguments.ToArray()
        $startInfo.UseShellExecute = $true
        $terminalProcess = [Diagnostics.Process]::Start($startInfo)
        if ($null -eq $terminalProcess) { throw 'Windows Terminal gagal menerima antrean SCP.' }
        [void]$terminalProcess.WaitForExit(1000)
        if ($terminalProcess.HasExited -and $terminalProcess.ExitCode -ne 0) { throw "Windows Terminal berhenti dengan exit code $($terminalProcess.ExitCode)." }
    }
    catch {
        Remove-Item -LiteralPath $planFile,$statusFile -Force -ErrorAction SilentlyContinue
        throw
    }
    return $statusFile
}
