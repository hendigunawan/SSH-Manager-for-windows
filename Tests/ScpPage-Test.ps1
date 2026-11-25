[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
# Execute the actual SCP page handlers with UI/launcher doubles; no real servers.
$script:ApplicationRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:ApplicationRoot 'Modules/SSHManager.Core.psm1') -Force -DisableNameChecking
. (Join-Path $script:ApplicationRoot 'UI/WorkspaceModel.ps1')
. (Join-Path $script:ApplicationRoot 'UI/Workspace.ps1')
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $script:ApplicationRoot 'SSHManager.ps1'),[ref]$null,[ref]$null)
$definition=$ast.Find({param($node);$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-ScpDialog'},$true)
. ([scriptblock]::Create($definition.Extent.Text))
Add-Type -TypeDefinition @'
namespace Windows {
 public class RoutedEventArgs { public object Source; public object OriginalSource; public bool Handled; }
 public delegate void RoutedEventHandler(object sender, RoutedEventArgs args);
 public enum MessageBoxButton { OK, YesNo }
 public enum MessageBoxImage { Error, Warning }
 public enum MessageBoxResult { Yes }
 public static class MessageBox {
  public static string LastError="";
  public static MessageBoxResult Show(object owner,string message,string title,MessageBoxButton button,MessageBoxImage icon) { LastError=message; return MessageBoxResult.Yes; }
 }
 namespace Controls {
  public class CheckBox { public object Tag; public bool IsChecked; public object DataContext; }
  namespace Primitives { public class ButtonBase { public static string ClickEvent="Click"; } }
 }
 namespace Interop { public class WindowInteropHelper { public WindowInteropHelper(object window) {} public System.IntPtr Handle=new System.IntPtr(123); } }
}
'@
function Assert-Page { param([bool]$Value,[string]$Message);if (-not $Value) { throw $Message } }
function New-ScpControlDouble {
 $items=[pscustomobject]@{};$items | Add-Member ScriptMethod Refresh {}
 $control=[pscustomobject]@{
  Text='';Content='';ToolTip=$null;IsEnabled=$true;IsChecked=$false;ItemsSource=@();Items=$items
  SelectedValue='';SelectedItem=$null;AllowDrop=$false;Visibility='Visible';Handlers=@{}
 }
 foreach ($eventName in @('Click','SelectionChanged','LostKeyboardFocus','TextChanged','PreviewDragOver','Drop')) {
  $control | Add-Member ScriptMethod ('Add_'+$eventName) ([scriptblock]::Create('$this.Handlers["'+$eventName+'"]=$args[0]'))
 }
 $control | Add-Member ScriptMethod AddHandler { $this.Handlers.RoutedClick=$args[1] }
 return $control
}
function Read-WorkspaceView {
 param($Xaml)
 Assert-Page (([xml]$Xaml).DocumentElement.LocalName -eq 'UserControl') 'SCP tried to create a feature window.'
 $view=[pscustomobject]@{Controls=@{};Tag=$null;IsEnabled=$true}
 foreach ($match in [regex]::Matches($Xaml,'x:Name="([^"]+)"')) { $view.Controls[$match.Groups[1].Value]=New-ScpControlDouble }
 return $view
}
function Get-NamedControl { param($View,$Name);return $View.Controls[$Name] }
function Get-SelectedHostEntries { return $script:InitialSelection }
function Show-WorkspaceFeature {
 param($View,$Page,$CanLeave)
 $script:PageCanLeave=$CanLeave;$script:Accepted=$false
 Assert-Page ($Page -eq 'Scp' -and (& $CanLeave)) 'SCP page not ready.'
 & $script:ScpScenario $View
 return $script:Accepted
}
function Complete-WorkspaceFeature { param($Accepted,$Destination);$script:Accepted=$Accepted;$script:Destination=$Destination }
function Show-ErrorMessage { param($Message,$Title);throw $Message }
function Set-Status { param($Text,$Color);$script:LastStatus=$Text }
function Save-CurrentConfig {}
function scp.exe {}
function wt.exe {}
function Ensure-SSHManagerVpnForHost { param($HostEntry);Assert-Page (-not (& $script:PageCanLeave)) 'Navigation allowed during remote operation.' }
function Show-RemotePathPicker {
 param($Owner,$HostEntry,$InitialPath,$AllowFiles,$AllowMultiple)
 Assert-Page ($Owner -eq $script:MainWindow -and $AllowFiles -and $AllowMultiple) 'Download picker owner or multi-selection incorrect.'
 return [pscustomobject]@{Count=2;Paths=@(('/data/'+$HostEntry.Id+'/first file.txt'),('/data/'+$HostEntry.Id+'/second.txt'));HasDirectory=$false;FileCount=2;FolderCount=0;CurrentDirectory='/data'}
}
function Start-SSHManagerScpBatch {
 param($Plan)
 Assert-Page (-not (& $script:PageCanLeave)) 'Navigation allowed while launching.'
 if ($script:FailLaunch) { throw 'simulated launch failure' }
 $script:CapturedPlan=$Plan
 return (Join-Path $script:TestRoot 'batch.json')
}
function Start-SSHManagerScp {
 param($HostEntry,$Direction,$LocalPaths,$RemotePaths)
 $script:CapturedSingle=[pscustomobject]@{Host=$HostEntry;Direction=$Direction;LocalPaths=$LocalPaths;RemotePaths=$RemotePaths}
}
function Reset-WorkspaceTransferActivity { param($Hosts,$Direction,$StatusFile);$script:ActivityHosts=@($Hosts) }
function Register-ScpStatusFile { param($StatusFile);$script:RegisteredStatusFile=$StatusFile }
function Set-NodeCheck {
 param($Controls,[int]$Index,[bool]$Checked)
 $checkbox=New-Object Windows.Controls.CheckBox
 $checkbox.Tag='ScpNodeSelection';$checkbox.IsChecked=$Checked;$checkbox.DataContext=$Controls.NodeList.ItemsSource[$Index]
 # Real WPF reports the ListBox as Source for templated items; only OriginalSource is the CheckBox.
 $eventArgs=New-Object Windows.RoutedEventArgs;$eventArgs.Source=$Controls.NodeList;$eventArgs.OriginalSource=$checkbox
 $Controls.NodeList.Handlers.RoutedClick.Invoke($Controls.NodeList,$eventArgs)
 Assert-Page $eventArgs.Handled 'Node selection click not handled.'
}
function Select-RemoteNode {
 param($Controls,[int]$Index)
 $Controls.NodeCombo.SelectedItem=$Controls.NodeCombo.ItemsSource[$Index]
 & $Controls.NodeCombo.Handlers.SelectionChanged
}
$script:TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('scp-page-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $script:TestRoot | Out-Null
try {
 $script:LocalFile=Join-Path $script:TestRoot 'upload with spaces.txt';Set-Content -LiteralPath $script:LocalFile -Value 'fixture'
 $script:Config=[pscustomobject]@{
  Hosts=@(1..3 | ForEach-Object { [pscustomobject]@{Id="node-$_";Name="Node $_";HostName="node-$_.invalid";Username='demo';Port=22;AuthType='Agent';VpnProfileId='';LastConnectedAt=''} })
  App=[pscustomobject]@{ReturnToManagerAfterScp=$false;CloseManagerAfterLaunch=$false;StartMaximized=$false;TerminalProfile='';TestConnectionBeforeOpen=$false}
 }
 $script:InitialSelection=@();$script:MainWindow=[pscustomobject]@{IsVisible=$true}
 $script:Paths=[pscustomobject]@{ScpStatusRoot=$script:TestRoot};$script:VpnOverride=[pscustomobject]@{SelectedValue='__HOST__'}
 $script:FailLaunch=$false
 $script:ScpScenario={
  param($view);$c=$view.Controls
  Assert-Page ($c.NodeList.ItemsSource.Count -eq 3 -and -not $c.StartButton.IsEnabled) 'SCP requires selection before opening or does not show all nodes.'
  & $c.SelectAllNodesButton.Handlers.Click
  Assert-Page ($c.NodeCombo.ItemsSource.Count -eq 3 -and $c.StartButton.IsEnabled) 'Select all failed.'
  & $c.ClearNodesButton.Handlers.Click
  Assert-Page ($c.NodeCombo.ItemsSource.Count -eq 0 -and -not $c.BrowseRemoteButton.IsEnabled) 'Clear selection failed.'
  Set-NodeCheck $c 0 $true
  $c.RemotePathBox.Text='/srv/first destination'
  Set-NodeCheck $c 1 $true
  Select-RemoteNode $c 1
  $c.RemotePathBox.Text='/srv/second destination'
  Set-NodeCheck $c 1 $false
  Assert-Page ($c.RemotePathBox.Text -eq '/srv/first destination') 'Unchecking node corrupted another node path.'
  Set-NodeCheck $c 1 $true
  Select-RemoteNode $c 1
  Assert-Page ($c.RemotePathBox.Text -eq '/srv/second destination') 'Rechecking node lost its remote path.'
  $c.LocalPathBox.Text=$script:LocalFile
  & $c.StartButton.Handlers.Click
  Assert-Page ($script:Accepted -and $script:Destination -eq 'ScpActivity') ('Transfer failed: '+[Windows.MessageBox]::LastError)
 }
 Show-ScpDialog
 Assert-Page (($script:CapturedPlan.Jobs.HostId -join ',') -eq 'node-1,node-2') 'Launcher did not use the checkbox selection.'
 Assert-Page ($script:CapturedPlan.Jobs[0].RemotePaths[0] -eq '/srv/first destination/' -and $script:CapturedPlan.Jobs[1].RemotePaths[0] -eq '/srv/second destination/') ('Per-node upload paths not preserved: '+($script:CapturedPlan.Jobs | ConvertTo-Json -Depth 5 -Compress))
 Assert-Page ($script:CapturedPlan.Jobs[0].LocalPaths[0] -eq $script:LocalFile -and $script:ActivityHosts.Count -eq 2) 'Local path or activity node list was lost.'

 $script:ScpScenario={
  param($view);$c=$view.Controls
  Set-NodeCheck $c 0 $true;Set-NodeCheck $c 2 $true
  $c.DirectionCombo.SelectedValue='Download';& $c.DirectionCombo.Handlers.SelectionChanged
  Select-RemoteNode $c 0;& $c.BrowseRemoteButton.Handlers.Click
  Select-RemoteNode $c 1;& $c.BrowseRemoteButton.Handlers.Click
  $c.LocalPathBox.Text=Join-Path $script:TestRoot 'downloads'
  & $c.StartButton.Handlers.Click
  Assert-Page $script:Accepted ('Download failed: '+[Windows.MessageBox]::LastError)
 }
 Show-ScpDialog
 Assert-Page (($script:CapturedPlan.Jobs.HostId -join ',') -eq 'node-1,node-3') 'Download used stale Connections selection.'
 foreach ($job in $script:CapturedPlan.Jobs) {
  Assert-Page ($job.RemotePaths.Count -eq 2 -and $job.RemotePaths[0] -eq ('/data/'+$job.HostId+'/first file.txt')) 'Multi-file remote path list was split or merged.'
 }
 Assert-Page ($script:CapturedPlan.Jobs[0].LocalPaths[0] -ne $script:CapturedPlan.Jobs[1].LocalPaths[0]) 'Multi-node downloads share an output folder.'

 $script:InitialSelection=@($script:Config.Hosts[1])
 $script:ScpScenario={
  param($view);$c=$view.Controls
  Assert-Page ($c.NodeList.ItemsSource.Count -eq 3 -and $c.NodeCombo.ItemsSource.Count -eq 1) 'Initial selection hid other configured nodes.'
  $c.LocalPathBox.Text=$script:LocalFile;$c.RemotePathBox.Text='/single path'
  & $c.StartButton.Handlers.Click
  Assert-Page $script:Accepted ('Single transfer failed: '+[Windows.MessageBox]::LastError)
 }
 Show-ScpDialog
 Assert-Page ($script:CapturedSingle.Host.Id -eq 'node-2' -and $script:CapturedSingle.RemotePaths[0] -eq '/single path') 'Single-node launch changed target.'

 $script:FailLaunch=$true
 $script:ScpScenario={
  param($view);$c=$view.Controls
  & $c.SelectAllNodesButton.Handlers.Click
  $c.LocalPathBox.Text=$script:LocalFile
  & $c.StartButton.Handlers.Click
  Assert-Page (-not $script:Accepted -and $view.IsEnabled -and (& $script:PageCanLeave)) 'Failed launcher left page disabled or navigated away.'
  Assert-Page ([Windows.MessageBox]::LastError -eq 'simulated launch failure') 'Failed launcher error was hidden.'
 }
 Show-ScpDialog
 Write-Host 'PASS SCP page: direct node selection, select all/clear, per-node paths, multi-file download, single/batch launch, busy guard, launch failure recovery.'
}
finally { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force }
