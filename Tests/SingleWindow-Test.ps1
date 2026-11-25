[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$app=Split-Path -Parent $PSScriptRoot
$failures=New-Object 'Collections.Generic.List[string]'
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $app 'SSHManager.ps1'),[ref]$null,[ref]$null)
foreach ($name in @('Show-ScpDialog','Show-VpnManager','Show-SettingsDialog')) {
 $definition=$ast.Find({param($node);$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
 if ($definition.Extent.Text -match '\$(d|window)\.ShowDialog\(') { $failures.Add("$name still opens a separate feature window.") }
 if ($definition.Extent.Text -notmatch 'Show-WorkspaceFeature') { $failures.Add("$name does not mount in the main workspace.") }
}
$editor=Get-Content (Join-Path $app 'UI/RemoteEditor.ps1') -Raw -Encoding UTF8
if ($editor -match '\$editorWindow\.ShowDialog\(') { $failures.Add('Editor still opens a separate window.') }
foreach ($name in @('ScpTransfer','RemoteEditor')) {
 [xml]$view=Get-Content (Join-Path $app "UI/$name.xaml") -Raw -Encoding UTF8
 if ($view.DocumentElement.LocalName -ne 'UserControl') { $failures.Add("$name is not an inline page.") }
}
$scp=$ast.Find({param($node);$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-ScpDialog'},$true).Extent.Text
$beforeView=($scp -split '\$d = Read-',2)[0]
if ($beforeView -match 'throw .*Pilih satu') { $failures.Add('SCP blocks entry without a Connections selection.') }
# RDP Manager is a built-in page of the same window; no feature may relaunch the manager script.
[xml]$rdpView=Get-Content (Join-Path $app 'UI/RdpManager.xaml') -Raw -Encoding UTF8
if ($rdpView.DocumentElement.LocalName -ne 'UserControl') { $failures.Add('RdpManager is not an inline page.') }
[xml]$main=Get-Content (Join-Path $app 'UI/MainWindow.xaml') -Raw -Encoding UTF8
if ($null -eq $main.SelectSingleNode("//*[@*[local-name()='Name']='RdpPage']")) { $failures.Add('MainWindow has no RdpPage host.') }
[xml]$sidebar=Get-Content (Join-Path $app 'UI/Sidebar.xaml') -Raw -Encoding UTF8
if ($null -eq $sidebar.SelectSingleNode("//*[@*[local-name()='Name']='NavRdp']")) { $failures.Add('Sidebar has no RDP Manager entry.') }
foreach ($file in @('UI/RdpManager.ps1','UI/Workspace.ps1','UI/RemoteEditor.ps1','SSHManager.ps1')) {
 $text=Get-Content (Join-Path $app $file) -Raw -Encoding UTF8
 if ($text -match '(?i)(powershell|pwsh)(\.exe)?[^\r\n]*SSHManager\.ps1') { $failures.Add("$file relaunches the manager script.") }
 if ($file -eq 'UI/RdpManager.ps1' -and $text -match 'ShowDialog\(|New-Object\s+Windows\.Window') { $failures.Add('RDP Manager opens its own window.') }
}
if ($failures.Count) { throw ($failures -join "`n") }
Write-Host 'PASS single-window contracts: feature pages and RDP Manager mount inline, no manager relaunch, and SCP does not require Connections selection.'
