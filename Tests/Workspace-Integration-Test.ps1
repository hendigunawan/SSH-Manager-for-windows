[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$script:ApplicationRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:ApplicationRoot 'Modules/SSHManager.Core.psm1') -Force -DisableNameChecking
. (Join-Path $script:ApplicationRoot 'UI/Workspace.ps1')
function Assert-Workspace { param([bool]$Value,[string]$Message) if (-not $Value) { throw $Message } }
# Keep controller locals alive while navigating on the same main window.
$script:MainWindow=[pscustomobject]@{IsVisible=$true}
$script:FakeControls=@{
 FeatureHost=[pscustomobject]@{Content=$null;Visibility='Collapsed'}
 MainMenu=[pscustomobject]@{IsEnabled=$true}
}
function Get-NamedControl { param($Window,$Name);return $script:FakeControls[$Name] }
function New-WorkspaceDispatcherFrame { return [pscustomobject]@{Continue=$true} }
function Mount-WorkspaceFeatureView {
 param($View,$Page)
 $script:FakeControls.FeatureHost.Content=$View
 $script:FakeControls.FeatureHost.Visibility='Visible'
 $script:WorkspaceState.Page=$Page
}
function Enter-WorkspaceDispatcherFrame { param($Frame); & $script:FrameScenario $Frame }
function Test-InlineController {
 $controllerState=@{AllowLeave=$false;Token='scope-alive'}
 $guard={ Assert-Workspace ($controllerState.Token -eq 'scope-alive') 'Controller scope lost.';return $controllerState.AllowLeave }
 $view=[pscustomobject]@{Kind='UserControl fixture'}
 $script:FrameScenario={
  param($Frame)
  Assert-Workspace (-not $script:FakeControls.MainMenu.IsEnabled) 'Host mutations remain enabled while editing.'
  Assert-Workspace ($script:FakeControls.FeatureHost.Content -eq $view) 'Feature not mounted in main host.'
  Invoke-WorkspaceNavigation 'Scp'
  Assert-Workspace ($Frame.Continue -and $null -eq $script:WorkspaceState.RequestedPage) 'Rejected navigation left the current page.'
  $controllerState.AllowLeave=$true
  Invoke-WorkspaceNavigation 'Editor'
  Assert-Workspace $Frame.Continue 'Same-page navigation reopened the feature.'
  Invoke-WorkspaceNavigation 'Scp'
  Assert-Workspace (-not $Frame.Continue -and $script:WorkspaceState.RequestedPage -eq 'Scp') 'Confirmed navigation lost destination.'
 }
 $result=Show-WorkspaceFeature -View $view -Page 'Editor' -CanLeave $guard
 Assert-Workspace (-not $result) 'Navigation marked a transfer as accepted.'
}
Test-InlineController
Assert-Workspace ($null -eq $script:WorkspaceState.ActiveFeature -and $null -eq $script:FakeControls.FeatureHost.Content -and $script:FakeControls.MainMenu.IsEnabled) 'Page cleanup leaked content, menu lock or active feature.'
$script:FrameScenario={param($Frame);Complete-WorkspaceFeature -Accepted $true -Destination 'ScpActivity'}
$accepted=Show-WorkspaceFeature -View ([pscustomobject]@{}) -Page 'Scp'
Assert-Workspace ($accepted -and $script:WorkspaceState.RequestedPage -eq 'ScpActivity') 'Successful transfer lost activity destination.'
$script:FrameScenario={throw 'frame failure fixture'}
$failed=$false
try { Show-WorkspaceFeature -View ([pscustomobject]@{}) -Page 'Settings' } catch { $failed=$true }
Assert-Workspace ($failed -and $null -eq $script:WorkspaceState.ActiveFeature -and $script:FakeControls.MainMenu.IsEnabled) 'Failed page left the workspace locked.'
$script:WorkspaceState.RequestedPage=$null
$script:WorkspaceState.Page='Connections'

# A late result from an older batch must not replace the currently displayed transfer.
$script:WorkspaceState.ActiveStatusFile='current.json'
$current=[pscustomobject]@{HostName='current transfer'}
Update-WorkspaceTransferActivity -Result $current -StatusFile 'current.json'
Update-WorkspaceTransferActivity -Result ([pscustomobject]@{HostName='old transfer'}) -StatusFile 'old.json'
Assert-Workspace ($script:WorkspaceState.LastTransfer.HostName -eq 'current transfer') 'Older concurrent transfer overwrote current activity.'
$script:WorkspaceState.ActiveStatusFile=$null

$script:NavigationCalls=New-Object 'Collections.Generic.List[string]'
$script:MainWindow=[pscustomobject]@{IsVisible=$true}
$script:CheckedHostIds=New-Object 'Collections.Generic.HashSet[string]';[void]$script:CheckedHostIds.Add('node-a')
function Set-WorkspacePage { param($Page);$script:WorkspaceState.Page=$Page;$script:NavigationCalls.Add('Page:'+ $Page) }
function Show-RemoteTextEditor { $script:NavigationCalls.Add('Editor');$script:WorkspaceState.RequestedPage='Scp';Invoke-WorkspaceNavigation 'Vpn' }
function Show-ScpDialog { $script:NavigationCalls.Add('Scp');$script:WorkspaceState.RequestedPage='Connections' }
function Show-VpnManager { $script:NavigationCalls.Add('Vpn') }
function Show-SettingsDialog { throw 'settings failure fixture' }
function Show-ErrorMessage { param($Message,$Title); $script:NavigationCalls.Add('Error:'+ $Message) }
Invoke-WorkspaceNavigation 'Editor'
Assert-Workspace (($script:NavigationCalls -join ',') -ceq 'Editor,Scp,Page:Connections') 'Routing lost/duplicated a page navigation or allowed reentry.'
Assert-Workspace ($script:CheckedHostIds.Contains('node-a') -and -not $script:WorkspaceState.Routing) 'Navigation changed host selection or retained lock.'
Invoke-WorkspaceNavigation 'Settings'
Assert-Workspace (-not $script:WorkspaceState.Routing -and $null -eq $script:WorkspaceState.RequestedPage) 'Failed dialog left navigation locked.'

# Real XAML/controller contracts: load-time resources and named controls must resolve.
$mainSource=Get-Content -LiteralPath (Join-Path $script:ApplicationRoot 'SSHManager.ps1') -Raw -Encoding UTF8
[xml]$mainXaml=Get-Content -LiteralPath (Join-Path $script:ApplicationRoot 'UI/MainWindow.xaml') -Raw -Encoding UTF8
$names=@($mainXaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object { $_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml') })
foreach ($match in [regex]::Matches($mainSource,'(?:Btn|Menu)[A-Za-z]+\s*=\s*\{')) {
 $name=($match.Value -split '\s*=')[0]; Assert-Workspace ($names -contains $name) "Missing event control: $name"
}
foreach ($match in [regex]::Matches($mainSource,'Get-NamedControl \$script:MainWindow ''([^'']+)''' )) {
 Assert-Workspace ($names -contains $match.Groups[1].Value) ('Missing main control: '+$match.Groups[1].Value)
}
[xml]$editorXaml=Get-Content -LiteralPath (Join-Path $script:ApplicationRoot 'UI/RemoteEditor.xaml') -Raw -Encoding UTF8
$editorSource=Get-Content -LiteralPath (Join-Path $script:ApplicationRoot 'UI/RemoteEditor.ps1') -Raw -Encoding UTF8
$controlList=[regex]::Match($editorSource,'foreach \(\$controlName in @\((.*?)\)\)').Groups[1].Value
foreach ($match in [regex]::Matches($controlList,"'([^']+)'")) {
 $name=$match.Groups[1].Value
 Assert-Workspace ($null -ne $editorXaml.SelectSingleNode("//*[@*[local-name()='Name']='$name']")) "Missing editor control: $name"
}
$scpSource=$mainSource.Substring($mainSource.IndexOf('function Show-ScpDialog'),$mainSource.IndexOf('function Connect-SelectedHosts')-$mainSource.IndexOf('function Show-ScpDialog'))
[xml]$scpXaml=Get-Content -LiteralPath (Join-Path $script:ApplicationRoot 'UI/ScpTransfer.xaml') -Raw -Encoding UTF8
foreach ($match in [regex]::Matches($scpSource,'Get-NamedControl \$d ''([^'']+)''' )) {
 $name=$match.Groups[1].Value
 Assert-Workspace ($null -ne $scpXaml.SelectSingleNode("//*[@*[local-name()='Name']='$name']")) "Missing SCP control: $name"
}
foreach ($xamlFile in Get-ChildItem (Join-Path $script:ApplicationRoot 'UI') -Filter '*.xaml') {
 [xml]$document=Get-Content $xamlFile.FullName -Raw -Encoding UTF8
 if ($document.DocumentElement.LocalName -eq 'ResourceDictionary') { continue }
 Add-WorkspaceResourceReference $document
 # Select by local-name because XAML uses a default namespace.
 $theme=$document.SelectSingleNode('/*/*[contains(local-name(),".Resources")]/*[local-name()="ResourceDictionary"]/*[local-name()="ResourceDictionary.MergedDictionaries"]/*')
 Assert-Workspace ($null -ne $theme -and ([uri]$theme.GetAttribute('Source')).IsFile) "Theme reference missing: $($xamlFile.Name)"
 Assert-Workspace (Test-Path -LiteralPath ([uri]$theme.GetAttribute('Source')).LocalPath) 'Theme path does not exist.'
}
# Exercise the actual row-action entry points with launch/storage replaced, avoiding network.
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $script:ApplicationRoot 'SSHManager.ps1'),[ref]$null,[ref]$null)
foreach ($name in @('Connect-SelectedHosts','Edit-Host')) {
 $definition=$ast.Find({param($node);$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
 . ([scriptblock]::Create($definition.Extent.Text))
}
$script:CheckedNode=[pscustomobject]@{Id='a';Name='Checked A';AuthType='Agent';LastConnectedAt=''}
$otherNode=[pscustomobject]@{Id='b';Name='Clicked B';AuthType='Agent';LastConnectedAt=''}
$script:LayoutCombo=[pscustomobject]@{SelectedValue='FourGrid'}
$script:VpnOverride=[pscustomobject]@{SelectedValue='__NONE__'}
$script:Config=[pscustomobject]@{App=[pscustomobject]@{TestConnectionBeforeOpen=$false;TerminalProfile='';StartMaximized=$false;CloseManagerAfterLaunch=$false}}
$script:Paths=[pscustomobject]@{}
function Get-SelectedHostEntries { return $script:CheckedNode }
function Get-PrimarySelectedHost { return $script:CheckedNode }
function New-ConnectionProgressWindow { return [pscustomobject]@{IsVisible=$true} }
function Update-ConnectionProgressWindow { }
function Close-ConnectionProgressWindow { }
function Get-SSHManagerDependencyStatus { return [pscustomobject]@{Required=$true;Available=$true} }
function Start-SSHManagerLayout { param($Hosts,$Paths,$Layout,$TerminalProfile,$StartMaximized);$script:LaunchedHosts=@($Hosts);$script:LaunchedLayout=$Layout }
function Save-CurrentConfig { }
function Set-Status { }
function Show-ErrorMessage { param($Message,$Title); throw $Message }
function Show-HostEditor { param($Existing);$script:EditedHost=$Existing;return $null }
Connect-SelectedHosts -HostEntries @($otherNode)
Assert-Workspace ($script:LaunchedHosts.Count -eq 1 -and $script:LaunchedHosts[0].Id -eq 'b' -and $script:LaunchedLayout -eq 'FourGrid') 'Row SSH launched the checked host instead of clicked host.'
Connect-SelectedHosts
Assert-Workspace ($script:LaunchedHosts.Count -eq 1 -and $script:LaunchedHosts[0].Id -eq 'a') 'Default SSH no longer uses host selection.'
Edit-Host -HostEntry $otherNode
Assert-Workspace ($script:EditedHost.Id -eq 'b') 'Row edit targeted the checked host instead of clicked host.'
Assert-Workspace ($script:CheckedHostIds.Contains('node-a')) 'Row action changed checked selection.'

# RDP-only hosts must never be sent to the SSH launcher.
$rdpOnly=[pscustomobject]@{Id='r';Name='Windows01';AuthType='Agent';LastConnectedAt='';SshEnabled=$false;RdpEnabled=$true}
$script:LaunchedHosts=@();$rdpError=''
try { Connect-SelectedHosts -HostEntries @($rdpOnly) } catch { $rdpError=$_.Exception.Message }
Assert-Workspace ($script:LaunchedHosts.Count -eq 0 -and $rdpError -match 'tidak memiliki SSH') 'SSH was launched for an RDP-only host.'
Connect-SelectedHosts -HostEntries @($rdpOnly,$otherNode)
Assert-Workspace ($script:LaunchedHosts.Count -eq 1 -and $script:LaunchedHosts[0].Id -eq 'b') 'Mixed selection did not skip the RDP-only host.'
Assert-Workspace ($script:WorkspaceNavPages -contains 'Rdp' -and $script:WorkspaceBuiltInPages -contains 'Rdp') 'RDP Manager is not a workspace page.'

Write-Host 'PASS workspace integration: guarded navigation, controller scope, page routing/reentry, selection retention, error recovery, row action targets, UI control contracts and resource injection.'
