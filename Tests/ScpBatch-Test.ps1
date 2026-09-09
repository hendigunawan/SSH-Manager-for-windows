[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$applicationRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $applicationRoot 'Modules/SSHManager.Core.psm1') -Force -DisableNameChecking
function Assert-True { param([bool]$Value, [string]$Message) if (-not $Value) { throw $Message } }
Assert-True ($null -ne (Get-Command New-SSHManagerScpBatchPlan -ErrorAction SilentlyContinue)) 'SCP belum mendukung rencana transfer banyak node.'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('scp-batch-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $localFile = Join-Path $testRoot 'daily report.txt'
    Set-Content -LiteralPath $localFile -Value 'local fixture'
    $localFolder = Join-Path $testRoot 'logs'
    New-Item -ItemType Directory -Path $localFolder | Out-Null
    $nodes = @(
        [pscustomobject]@{ Id='node-a'; Name='../CON'; VpnProfileId='vpn-a' },
        [pscustomobject]@{ Id='node-b'; Name='../CON'; VpnProfileId='vpn-b' },
        [pscustomobject]@{ Id='node-c'; Name='ITCH'; VpnProfileId='' }
    )
    $selections = @{}
    foreach ($node in $nodes) {
        $selections[$node.Id] = [pscustomobject]@{ RemotePaths=@('~/incoming/'); RemoteHasDirectory=$true; RemoteFileCount=0; RemoteFolderCount=0 }
    }
    $upload = New-SSHManagerScpBatchPlan -HostEntries @($nodes + $nodes[0]) -Direction Upload -LocalPaths @($localFile,$localFolder) -NodeSelections $selections
    Assert-True (@($upload.Jobs).Count -eq 3) 'Node pilihan harus berbeda dan duplikasi ID tidak boleh ditransfer dua kali.'
    Assert-True (($upload.Jobs.HostId -join ',') -eq 'node-a,node-b,node-c') 'Urutan node berubah.'
    foreach ($job in $upload.Jobs) {
        Assert-True (@($job.LocalPaths).Count -eq 2 -and $job.LocalPaths[0] -eq $localFile) 'Sumber lokal tidak utuh pada setiap node.'
        Assert-True ($job.Recursive -and $job.SourceFileCount -eq 1 -and $job.SourceFolderCount -eq 1) 'Jumlah file/folder atau recursive upload salah.'
    }
    Assert-True ($upload.Jobs[1].VpnProfileId -eq 'vpn-b') 'VPN per node tidak diteruskan.'
    $selections['node-a'].RemotePaths = @('/home/mme/a b.txt', "/home/mme/it's.txt")
    $selections['node-a'].RemoteHasDirectory = $false
    $selections['node-a'].RemoteFileCount = 2
    $selections['node-b'].RemotePaths = @('~/log')
    $selections['node-b'].RemoteFolderCount = 1
    $downloadRoot = Join-Path $testRoot 'downloads'
    $download = New-SSHManagerScpBatchPlan -HostEntries $nodes -Direction Download -LocalPaths @($downloadRoot) -NodeSelections $selections -VpnOverride '__NONE__'
    Assert-True (@($download.Jobs.LocalPaths | Sort-Object -Unique).Count -eq 3) 'Download antar-node akan saling menimpa.'
    foreach ($job in $download.Jobs) {
        Assert-True ((Split-Path -Parent $job.LocalPaths[0]) -eq $downloadRoot) 'Folder node keluar dari folder tujuan.'
        Assert-True ((Split-Path -Leaf $job.LocalPaths[0]) -notmatch '[<>:"/\\|?*]') 'Nama folder node tidak aman di Windows.'
        Assert-True ([string]::IsNullOrWhiteSpace($job.VpnProfileId)) 'Override tanpa VPN tidak diikuti.'
    }
    Assert-True ($download.Jobs[0].RemotePaths[0] -eq '/home/mme/a b.txt' -and @($download.Jobs[0].RemotePaths).Count -eq 2) 'Path dengan spasi terpecah atau multi-file tergabung.'
    Assert-True ($download.Jobs[1].Recursive -and -not $download.Jobs[0].Recursive) 'Recursive tidak mengikuti sumber tiap node.'
    $roundTrip = $download | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    Assert-True (@($roundTrip.Jobs[0].RemotePaths).Count -eq 2 -and @($roundTrip.Jobs[1].RemotePaths).Count -eq 1) 'Manifest merusak bentuk daftar path.'

    $single = New-SSHManagerScpBatchPlan -HostEntries @($nodes[0]) -Direction Download -LocalPaths @($downloadRoot) -NodeSelections $selections
    Assert-True ($single.Jobs[0].LocalPaths[0] -eq $downloadRoot) 'Download satu node harus memakai folder tujuan langsung.'
    $nodes[0].Name = 'CON.log'
    $reserved = New-SSHManagerScpBatchPlan -HostEntries $nodes -Direction Download -LocalPaths @($downloadRoot) -NodeSelections $selections
    $reservedLeaf = Split-Path -Leaf $reserved.Jobs[0].LocalPaths[0]
    Assert-True ($reservedLeaf -notmatch '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') 'Nama node menghasilkan device filename terlarang Windows.'
    $selections['node-c'].RemotePaths = @()
    $rejected = $false
    try { $null = New-SSHManagerScpBatchPlan -HostEntries $nodes -Direction Download -LocalPaths @($downloadRoot) -NodeSelections $selections } catch { $rejected = $true }
    Assert-True $rejected 'Node tanpa sumber remote harus ditolak sebelum transfer.'

    $statusFile = Join-Path $testRoot 'status.json'
    $visited = New-Object 'Collections.Generic.List[string]'
    $result = Invoke-SSHManagerScpBatch -Plan $roundTrip -StatusFile $statusFile -TransferAction {
        param($job)
        $live = Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json
        Assert-True (-not $live.IsComplete -and $live.ActiveHost -eq $job.HostName) 'Status node aktif harus tersedia sebelum transfer.'
        $visited.Add($job.HostId)
        if ($job.HostId -eq 'node-b') { throw 'simulated disconnect' }
        New-Item -ItemType Directory -Path $job.LocalPaths[0] -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $job.LocalPaths[0] 'result.txt') -Value $job.HostId
        [pscustomobject]@{ Succeeded=$true; FileCount=$job.SourceFileCount; FolderCount=$job.SourceFolderCount; ItemCount=$job.SourceItemCount; Message='' }
    }
    Assert-True (($visited -join ',') -eq 'node-a,node-b,node-c') 'Kegagalan satu node menghentikan node berikutnya.'
    Assert-True ($result.IsComplete -and -not $result.Succeeded -and $result.SuccessCount -eq 2 -and $result.FailedCount -eq 1) 'Ringkasan sebagian gagal keliru.'
    Assert-True ($result.Results[1].Message -eq 'simulated disconnect') 'Penyebab kegagalan node hilang.'
    $saved = Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json
    Assert-True ($saved.IsComplete -and @($saved.Results).Count -eq 3) 'Hasil final tidak ditulis lengkap.'
    $summary = Get-SSHManagerScpBatchStatusText -Result $saved
    Assert-True ($summary.Text -match '2 berhasil' -and $summary.Text -match '1 gagal' -and $summary.Details -match 'simulated disconnect') 'Status bawah menyembunyikan hasil sebagian gagal.'
    $success = Invoke-SSHManagerScpBatch -Plan $upload -StatusFile $statusFile -TransferAction {
        param($job)
        [pscustomobject]@{ Succeeded=$true; FileCount=1; FolderCount=1; ItemCount=2; Message='' }
    }
    Assert-True ($success.Succeeded -and $success.SuccessCount -eq 3 -and $success.FailedCount -eq 0) 'Batch sukses ditandai gagal.'
    $summary = Get-SSHManagerScpBatchStatusText -Result $success
    Assert-True ($summary.Text -match '3 file' -and $summary.Text -match '3 folder') 'Total sumber sukses salah.'
    $writeFailureProbe = & (Get-Module SSHManager.Core) {
        param($probePlan, $probeFile)
        $script:ScpTestOriginalWriter = (Get-Command Write-SSHManagerScpBatchStatus).ScriptBlock
        $script:ScpTestWrites = 0
        function script:Write-SSHManagerScpBatchStatus {
            param($Result, $StatusFile)
            $script:ScpTestWrites++
            if ($script:ScpTestWrites -eq 3) { throw 'simulated status sharing violation' }
            & $script:ScpTestOriginalWriter -Result $Result -StatusFile $StatusFile
        }
        $seen = New-Object 'Collections.Generic.List[string]'
        $batchOutcome = $null
        try {
            $batchOutcome = Invoke-SSHManagerScpBatch -Plan $probePlan -StatusFile $probeFile -TransferAction {
                param($job)
                $seen.Add($job.HostId)
                [pscustomobject]@{ Succeeded=$true; FileCount=1; FolderCount=1; ItemCount=2; Message='' }
            }
        }
        catch { }
        finally { Set-Item Function:\Write-SSHManagerScpBatchStatus -Value $script:ScpTestOriginalWriter }
        [pscustomobject]@{ Seen=$seen.ToArray(); Outcome=$batchOutcome }
    } $upload $statusFile
    Assert-True (($writeFailureProbe.Seen -join ',') -eq 'node-a,node-b,node-c') 'Gangguan penulisan progres menghentikan transfer node berikutnya.'
    Assert-True ($writeFailureProbe.Outcome.Succeeded) 'Hasil transfer berubah menjadi gagal hanya karena penulisan progres sementara.'
    # Execute the actual UI polling functions without loading WPF.
    $tokens = $null; $parseErrors = $null
    $uiAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $applicationRoot 'SSHManager.ps1'), [ref]$tokens, [ref]$parseErrors)
    foreach ($functionName in @('Register-ScpStatusFile','Update-PendingScpStatus','Format-ScpItemSummary')) {
        $functionAst = $uiAst.Find({ param($ast) $ast -is [Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -eq $functionName }, $true)
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }
    function Set-Status { param($Text,$Color,$Details) $script:LastTestStatus = [pscustomobject]@{ Text=$Text; Color=$Color; Details=$Details } }
    function Get-Process {
        param($Id, $ErrorAction)
        if ($Id -eq 777) { [pscustomobject]@{ StartTime=[datetime]'2026-09-08T10:00:00Z' } }
    }
    $script:Paths = [pscustomobject]@{ LogsRoot=(Join-Path $testRoot 'logs') }
    $script:PendingScpStatusFiles = @{}
    $activeStatus = New-SSHManagerScpBatchStatus -Plan $upload
    $activeStatus.ProcessId = 777
    $activeStatus.ProcessStartedAt = '2026-09-08T10:00:00.0000000Z'
    Write-SSHManagerScpBatchStatus -Result $activeStatus -StatusFile $statusFile
    Register-ScpStatusFile -StatusFile $statusFile
    Update-PendingScpStatus
    Assert-True (Test-Path -LiteralPath $statusFile) 'UI menghapus status batch yang masih aktif.'
    Assert-True ($script:PendingScpStatusFiles.Count -eq 1 -and $script:LastTestStatus.Color -eq '#38BDF8') 'UI salah menganggap proses aktif telah berhenti (termasuk tanggal JSON).' 
    Write-SSHManagerScpBatchStatus -Result $success -StatusFile $statusFile
    Update-PendingScpStatus
    Assert-True (-not (Test-Path -LiteralPath $statusFile) -and $script:PendingScpStatusFiles.Count -eq 0) 'UI tidak menyelesaikan pemantauan batch final.'
    Assert-True ($script:LastTestStatus.Text -match '3 berhasil' -and $script:LastTestStatus.Color -eq '#22C55E') 'UI tidak menampilkan hasil akhir sukses.'
    $activeStatus.ProcessId = 888
    Write-SSHManagerScpBatchStatus -Result $activeStatus -StatusFile $statusFile
    Register-ScpStatusFile -StatusFile $statusFile
    Update-PendingScpStatus
    Assert-True ($script:LastTestStatus.Text -match '3 gagal' -and $script:LastTestStatus.Details -match 'Tab SCP ditutup') 'UI tidak mendeteksi tab SCP yang dihentikan.'
    Remove-Item Function:\Get-Process
    Write-Host 'PASS: pemetaan node, path per node, download terpisah, recursive, VPN override, JSON, progres, lanjut setelah gagal, dan hasil akhir.' -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
