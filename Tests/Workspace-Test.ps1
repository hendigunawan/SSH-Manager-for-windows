[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$app=Split-Path -Parent $PSScriptRoot
$model=Join-Path $app 'UI/WorkspaceModel.ps1'
if (-not (Test-Path -LiteralPath $model)) { throw 'Workspace preview and activity model is missing.' }
. $model
function Assert-Workspace { param([bool]$Value,[string]$Message) if (-not $Value) { throw $Message } }
$nodes=@(1..5 | ForEach-Object { [pscustomobject]@{Id="n$_";Name="Node $_";Username='demo';HostName="node-$_.example";Port=2222} })
foreach ($layout in @('Single','TwoColumns','TwoRows','TopOneBottomTwo','TopTwoBottomOne','FourGrid')) {
    $preview=Get-WorkspaceLayoutPreview -Layout $layout -Hosts @()
    Assert-Workspace (@($preview.Panes | Where-Object IsAssigned).Count -eq 0) 'Empty preview invented connected hosts.'
    foreach ($pane in $preview.Panes) {
        Assert-Workspace ($pane.Row+$pane.RowSpan -le $preview.Rows -and $pane.Column+$pane.ColumnSpan -le $preview.Columns) 'Preview pane is outside grid.'
    }
    $single=Get-WorkspaceLayoutPreview -Layout $layout -Hosts @($nodes[0])
    Assert-Workspace (@($single.Panes | Where-Object { $_.HostId -ne 'n1' }).Count -eq 0) 'One-host layout does not duplicate the selected host.'
    $multi=Get-WorkspaceLayoutPreview -Layout $layout -Hosts $nodes
    Assert-Workspace ($multi.TabCount -eq [Math]::Ceiling(5.0/$multi.Capacity)) 'Overflow tab count differs from terminal layout.'
    Assert-Workspace (($multi.Panes.HostId -join ',') -eq (($nodes | Select-Object -First $multi.Capacity).Id -join ',')) 'Preview changed selected host order.'
}
$grid=Get-WorkspaceLayoutPreview -Layout FourGrid -Hosts @($nodes[0],$nodes[1],$nodes[2])
Assert-Workspace ($grid.Panes.Count -eq 3 -and $grid.Panes[0].ColumnSpan -eq 2 -and $grid.Panes[1].Row -eq 1) 'Partial grid must match actual terminal: one above two.'
$pair=Get-WorkspaceLayoutPreview -Layout TopTwoBottomOne -Hosts @($nodes[0],$nodes[1])
Assert-Workspace ($pair.Rows -eq 1 -and $pair.Columns -eq 2 -and $pair.Panes.Count -eq 2) 'Two hosts must match actual two-column terminal.'
# Compare every host-count/layout combination to the actual launcher helper.
Import-Module (Join-Path $app 'Modules/SSHManager.Core.psm1') -Force -DisableNameChecking
$core=Get-Module SSHManager.Core
foreach ($layout in @('Single','TwoColumns','TwoRows','TopOneBottomTwo','TopTwoBottomOne','FourGrid')) {
 foreach ($count in 1..5) {
  $preview=Get-WorkspaceLayoutPreview -Layout $layout -Hosts @($nodes | Select-Object -First $count)
  $tabCount=if ($count -eq 1) { $preview.Capacity } else { [Math]::Min($count,$preview.Capacity) }
  $actual=& $core { param($requested,$hostCount); Resolve-SSHManagerPartialLayout -RequestedLayout $requested -HostCount $hostCount } $layout $tabCount
  Assert-Workspace ($preview.EffectiveLayout -eq $actual) ("Preview/runtime mismatch: $layout with $count hosts")
 }
}
$badLayout=$false
try { Get-WorkspaceLayoutPreview -Layout Unknown -Hosts $nodes | Out-Null } catch { $badLayout=$true }
Assert-Workspace $badLayout 'Unknown layout accepted.'
$group=Get-WorkspaceGroupBrush -Name 'Production'
Assert-Workspace ($group -match '^#[0-9A-Fa-f]{6}$' -and $group -eq (Get-WorkspaceGroupBrush -Name 'Production')) 'Group badge color is invalid or unstable.'
$rows=@(Get-WorkspaceTransferRows -Result ([pscustomobject]@{Kind='ScpBatch';Results=@(
    [pscustomobject]@{HostName='Node 1';State='Succeeded';Message='OK';FileCount=2;FolderCount=1;ItemCount=3},
    [pscustomobject]@{HostName='Node 2';State='Running';Message='';FileCount=0;FolderCount=0;ItemCount=4},
    [pscustomobject]@{HostName='Node 3';State='Failed';Message='connection lost';FileCount=0;FolderCount=0;ItemCount=2}
)}))
Assert-Workspace ($rows.Count -eq 3 -and $rows[0].Status -eq 'Selesai' -and $rows[1].IsRunning -and $rows[2].Status -eq 'Gagal') 'Transfer activity does not reflect native results.'
Assert-Workspace ($rows[2].Message -eq 'connection lost') 'Transfer error detail lost.'
Assert-Workspace (@($rows | Where-Object { $_.PSObject.Properties.Name -contains 'Percent' }).Count -eq 0) 'Activity must not invent byte progress.'
$singleRows=@(Get-WorkspaceTransferRows -Result ([pscustomobject]@{HostName='Node 1';Succeeded=$true;FileCount=3;FolderCount=0;ItemCount=3;Message=''}))
Assert-Workspace ($singleRows.Count -eq 1 -and $singleRows[0].Status -eq 'Selesai') 'Single-node results missing from activity.'
Write-Host 'PASS workspace: six layouts, empty/one/many hosts, overflow tabs, stable group badges and real SCP results.'
