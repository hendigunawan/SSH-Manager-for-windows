[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Uji ini membutuhkan Windows dan WPF native.' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Jalankan powershell.exe -STA -File Tests\Workspace-Windows-Test.ps1.' }
Add-Type -AssemblyName @('PresentationFramework','PresentationCore','WindowsBase','System.Xaml','System.Windows.Forms')
$script:ApplicationRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:ApplicationRoot 'Modules/SSHManager.Core.psm1') -Force -DisableNameChecking
. (Join-Path $script:ApplicationRoot 'UI/WorkspaceModel.ps1')
. (Join-Path $script:ApplicationRoot 'UI/Workspace.ps1')
. (Join-Path $script:ApplicationRoot 'UI/RemoteEditor.ps1')
. (Join-Path $script:ApplicationRoot 'UI/RdpManager.ps1')
# Use real WPF, real controllers and the real dispatcher; no persistent config or server I/O.
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $script:ApplicationRoot 'SSHManager.ps1'),[ref]$null,[ref]$null)
foreach ($name in @('Read-XamlWindow','Get-NamedControl','Apply-DarkComboBoxTheme','Get-SelectedHostEntries','Show-ScpDialog','Show-VpnManager','Show-SettingsDialog','Get-VpnById')) {
 $functionAst=$ast.Find({param($node);$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
 . ([scriptblock]::Create($functionAst.Extent.Text))
}
function Assert-Native { param([bool]$Value,[string]$Message);if (-not $Value) { throw $Message } }
function Set-Status {}
function Show-ErrorMessage { param($Message,$Title);throw $Message }
function Save-CurrentConfig { $script:SaveCount++ }
function Refresh-AllViews {}
function Ensure-SSHManagerVpnForHost {}
function Invoke-SSHManagerRemoteTextFile {
 param($Operation,$RemotePath,$Bytes,$OnProgress)
 Assert-Native (-not (Test-WorkspaceCanLeave)) 'Editor allowed navigation during server work.'
 & $OnProgress 100
 if ($Operation -eq 'read') {
  return [pscustomobject]@{ok=$true;path=$RemotePath;content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("first`nsecond`n"));size=13;version=('a'*64)}
 }
 return [pscustomobject]@{ok=$true;path=$RemotePath;size=$Bytes.Length;version=('b'*64);backup='/tmp/fixture-backup'}
}
function Find-NativeCheckbox {
 param($Element)
 if ($Element -is [Windows.Controls.CheckBox]) { return $Element }
 for ($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Element);$i++) {
  $found=Find-NativeCheckbox ([Windows.Media.VisualTreeHelper]::GetChild($Element,$i))
  if ($null -ne $found) { return $found }
 }
 return $null
}
function Invoke-NativePageProbe {
 param([string]$Page)
 $script:ProbePage=$Page;$script:ProbeFailure=$null;$script:ProbeVisited=$false
 $operation=$script:MainWindow.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background,[Action]{
  try {
   $script:ProbeVisited=$true
   $feature=$script:WorkspaceState.ActiveFeature
   Assert-Native ($null -ne $feature -and $feature.Page -eq $script:ProbePage) 'Requested page is not active.'
   $view=$feature.View
   $script:MainWindow.UpdateLayout()
   Assert-Native ($view -is [Windows.Controls.UserControl]) 'Feature is a separate window.'
   Assert-Native ([Windows.Window]::GetWindow($view) -eq $script:MainWindow) 'Feature not hosted in the main window.'
   Assert-Native ($script:MainWindow.OwnedWindows.Count -eq 0) 'Opening a page created an owned feature window.'
   Assert-Native ($view.ActualWidth -gt 0 -and $view.ActualHeight -gt 0) 'Page has no layout size.'
   Assert-Native (-not $script:MainWindow.FindName('MainMenu').IsEnabled) 'Host mutation menu remained enabled.'
   switch ($script:ProbePage) {
    'Scp' {
     $nodes=$view.FindName('NodeList')
     Assert-Native ($nodes.Items.Count -eq 3 -and -not $view.FindName('StartButton').IsEnabled) 'SCP did not open with all nodes and zero selection.'
     $checkbox=Find-NativeCheckbox ($nodes.ItemContainerGenerator.ContainerFromIndex(0))
     Assert-Native ($null -ne $checkbox) 'Node checkbox template missing.'
     $checkbox.IsChecked=$true
     $checkbox.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
     Assert-Native ($view.FindName('NodeCombo').Items.Count -eq 1 -and $view.FindName('StartButton').IsEnabled) 'Direct node checkbox did not update transfer controls.'
     $view.FindName('SelectAllNodesButton').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
     Assert-Native ($view.FindName('NodeCombo').Items.Count -eq 3) 'Select all failed with WPF binding.'
     $view.FindName('ClearNodesButton').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
     Assert-Native (-not $view.FindName('StartButton').IsEnabled) 'Clear selection failed with WPF binding.'
    }
    'Editor' {
     Assert-Native ($view.FindName('NodeCombo').Items.Count -eq 3) 'Editor does not offer all hosts.'
     $view.FindName('RemotePathBox').Text='/tmp/fixture.txt'
     $view.FindName('OpenButton').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
     $box=$view.FindName('EditorBox')
     Assert-Native ($box.IsEnabled -and $box.Text -match 'first') 'Real editor open handler failed.'
     $box.Text="updated`r`ntext`r`n"
     Assert-Native $view.FindName('SaveButton').IsEnabled 'Dirty editor did not enable save.'
     $view.FindName('SaveButton').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
     Assert-Native (-not $view.FindName('SaveButton').IsEnabled) 'Save handler failed.'
     $script:MainWindow.UpdateLayout()
     Assert-Native ($view.FindName('LineNumberGutter').Children.Count -gt 0) 'Editor line gutter empty.'
    }
    'Settings' {
     $view.FindName('TimeoutBox').Text='12'
     $view.FindName('SaveButton').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
     Assert-Native ($script:Config.App.ConnectTimeoutSeconds -eq 12 -and $script:SaveCount -eq 1) 'Settings handler did not save.'
     Assert-Native ($script:WorkspaceState.ActiveFeature.View -eq $view) 'Saving settings left the current page.'
    }
    'Vpn' { Assert-Native ($view.FindName('VpnList').Items.Count -eq 1) 'VPN profile list did not render.' }
   }
   Invoke-WorkspaceNavigation 'Connections'
  }
  catch { $script:ProbeFailure=$_ }
  finally { Complete-WorkspaceFeature -Destination 'Connections' }
 })
 Invoke-WorkspaceNavigation $Page
 if (-not $script:ProbeVisited) { [void]$operation.Abort();throw "Page $Page did not enter its dispatcher frame." }
 if ($script:ProbeFailure) { throw $script:ProbeFailure }
 Assert-Native ($null -eq $script:WorkspaceState.ActiveFeature -and $null -eq $script:MainWindow.FindName('FeatureHost').Content) 'Page did not release its frame/content.'
 Assert-Native $script:MainWindow.FindName('MainMenu').IsEnabled 'Main menu was not restored.'
}
$script:Config=New-SSHManagerDefaultConfig
$script:Config.Hosts=@(1..3 | ForEach-Object { [pscustomobject]@{Id="test-$_";Name="Test node $_";HostName="test-$_.invalid";Username='demo';Port=22;AuthType='Agent';VpnProfileId=''} })
$script:Config.Hosts[0] | Add-Member NoteProperty RdpEnabled $true
$script:Config.Hosts[0] | Add-Member NoteProperty RdpPort 3389
$script:Config.Hosts=@($script:Config.Hosts)+[pscustomobject]@{Id='test-rdp';Name='Windows only';HostName='win.invalid';Username='';Port=22;AuthType='Agent';VpnProfileId='';SshEnabled=$false;RdpEnabled=$true;RdpPort=3390}
$script:Config.VpnProfiles=@([pscustomobject]@{Id='test-vpn';Name='Fixture VPN';Type='WindowsRas'})
$script:Paths=[pscustomobject]@{};$script:SaveCount=0
$script:MainWindow=Read-XamlWindow (Get-Content (Join-Path $script:ApplicationRoot 'UI/MainWindow.xaml') -Raw -Encoding UTF8)
$script:HostGrid=Get-NamedControl $script:MainWindow 'HostGrid'
$script:LayoutCombo=Get-NamedControl $script:MainWindow 'LayoutCombo'
Initialize-WorkspaceUi
try {
 $script:HostGrid.ItemsSource=@($script:Config.Hosts | Select-Object -First 3 | ForEach-Object {
  [pscustomobject]@{Id=$_.Id;IsChecked=$true;FavoriteMark='';Name=$_.Name;HostName=$_.HostName;Username=$_.Username;Port=$_.Port;GroupLabel='Test';GroupBrush='#174D7A';Source=$_}
 })
 $script:LayoutCombo.SelectedValue='FourGrid'
 $script:MainWindow.Show();$script:MainWindow.Width=$script:MainWindow.MinWidth;$script:MainWindow.Height=$script:MainWindow.MinHeight
 foreach ($page in @('Connections','Layout','ScpActivity')) { Set-WorkspacePage $page;$script:MainWindow.UpdateLayout();[Windows.Forms.Application]::DoEvents() }
 Assert-Native ($script:MainWindow.FindName('LayoutPreviewGrid').Children.Count -eq 3) 'Partial layout preview differs from terminal.'
 foreach ($row in $script:HostGrid.ItemsSource) { $row.IsChecked=$false }
 $script:HostGrid.SelectedItems.Clear()
 foreach ($page in @('Scp','Editor','Vpn','Settings','Scp')) { Invoke-NativePageProbe $page }
 # RDP Manager is a built-in page: repeated visits must reuse one view and one set of handlers.
 $rdpView=$script:MainWindow.FindName('RdpPage').Content
 foreach ($visit in 1..3) {
  Invoke-WorkspaceNavigation 'Rdp'; $script:MainWindow.UpdateLayout(); [Windows.Forms.Application]::DoEvents()
  Assert-Native ($script:MainWindow.FindName('RdpPage').Visibility -eq 'Visible' -and $script:MainWindow.FindName('ConnectionsPage').Visibility -eq 'Collapsed') 'RDP page not shown in the main content.'
  Assert-Native ($script:MainWindow.FindName('RdpPage').Content -eq $rdpView) 'RDP view was recreated on navigation.'
  Invoke-WorkspaceNavigation 'Connections'
 }
 Invoke-WorkspaceNavigation 'Rdp'; $script:MainWindow.UpdateLayout()
 Assert-Native ($rdpView.FindName('RdpGrid').Items.Count -eq 2) 'RDP grid does not list exactly the RDP-enabled hosts.'
 Assert-Native ($script:MainWindow.OwnedWindows.Count -eq 0) 'RDP Manager opened a separate window.'
 $script:RdpTestCalls=0
 function Test-RdpHosts { param($Hosts) $script:RdpTestCalls++ }
 $rdpView.FindName('BtnRdpTest').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
 Assert-Native ($script:RdpTestCalls -eq 1) "Test RDP handler ran $($script:RdpTestCalls) times for one click."
 Initialize-WorkspaceUi
 Initialize-RdpManagerView
 $rdpView.FindName('BtnRdpTest').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
 Assert-Native ($script:RdpTestCalls -eq 2) 'Re-initialisation attached a duplicate handler.'
 $rdpRow=@($rdpView.FindName('RdpGrid').Items)[0]
 Assert-Native ($rdpRow.Port -eq 3389 -or $rdpRow.Port -eq 3390) 'RDP row port missing.'
 Invoke-WorkspaceNavigation 'Connections'
 Write-Host 'PASS native WPF: single window, RDP page reuse/no duplicate handlers, real dispatcher/controller lifetime, direct SCP checkboxes, settings save, editor open/save/gutter, page cleanup.' -ForegroundColor Green
}
finally { Complete-WorkspaceFeature -Destination ''; $script:MainWindow.Close() }
