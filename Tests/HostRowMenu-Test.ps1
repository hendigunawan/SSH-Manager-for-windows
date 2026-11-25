[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
# Native WPF regression for the "..." row menu crash ("The property 'SelectedItem' cannot be found on this object")
# plus the real host editor for Duplicate/Add RDP. Launchers and storage are replaced; no server or mstsc is used.
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Jalankan powershell.exe -STA -File Tests\HostRowMenu-Test.ps1.' }
Add-Type -AssemblyName @('PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml', 'System.Windows.Forms')
$script:ApplicationRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:ApplicationRoot 'Modules/SSHManager.Core.psm1') -Force -DisableNameChecking
. (Join-Path $script:ApplicationRoot 'UI/WorkspaceModel.ps1')
. (Join-Path $script:ApplicationRoot 'UI/Workspace.ps1')
. (Join-Path $script:ApplicationRoot 'UI/RdpManager.ps1')
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:ApplicationRoot 'SSHManager.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Read-XamlWindow', 'Get-NamedControl', 'Apply-DarkComboBoxTheme', 'Get-HostById', 'Invoke-HostRowAction', 'Show-HostEditor', 'Duplicate-Host', 'Add-Host', 'Save-HostEditorRdpCredential', 'Remove-HostRdpCredentialIfOwned')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if ($null -eq $definition) { throw "Function $name not found." }
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Assert-Menu { param([bool]$Value, [string]$Message) if (-not $Value) { throw $Message } }

# Static guard: the row menu must not rely on closures or SelectedItem again.
$menuSource = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-HostRowMenu' }, $true)
Assert-Menu ($null -eq $menuSource) 'Show-HostRowMenu must live in UI/Workspace.ps1 only.'
$workspaceAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:ApplicationRoot 'UI/Workspace.ps1'), [ref]$null, [ref]$null)
$menuText = $workspaceAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-HostRowMenu' }, $true).Body.Extent.Text
$menuCode = ($menuText -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
Assert-Menu ($menuCode -notmatch '\.GetNewClosure\(' -and $menuCode -notmatch 'SelectedItem') 'Row menu still uses GetNewClosure/SelectedItem.'

$script:Calls = New-Object 'Collections.Generic.List[string]'
$script:Warnings = New-Object 'Collections.Generic.List[string]'
$script:Errors = New-Object 'Collections.Generic.List[string]'
function Connect-SelectedHosts { param([object[]]$HostEntries) $script:Calls.Add('Ssh:' + $HostEntries[0].Id) }
function Start-RdpLaunchBatch { param([object[]]$Hosts, [string]$VpnOverride) $script:Calls.Add('Rdp:' + $Hosts[0].Id + ':' + $VpnOverride) }
function Test-RdpHosts { param([object[]]$Hosts) $script:Calls.Add('TestRdp:' + $Hosts[0].Id) }
function Invoke-WorkspaceNavigation { param([string]$Page) $script:Calls.Add($Page + ':' + @(Get-WorkspacePreferredHosts)[0].Id) }
function Get-SelectedHostEntries { return @() }
function Edit-Host { param($HostEntry) $script:Calls.Add('Edit:' + $HostEntry.Id) }
function Delete-Hosts { param([object[]]$HostEntries) $script:Calls.Add('Delete:' + $HostEntries[0].Id) }
function Show-Warning { param($Message) $script:Warnings.Add($Message) }
function Show-AppError { param($Summary, $Detail) $script:Errors.Add("$Summary $Detail") }
function Refresh-AllViews { }
function Save-CurrentConfig { }
function Set-Status { }
function Set-SSHManagerSecret { }
function Test-SSHManagerSecret { return $false }

$script:VpnOverride = [pscustomobject]@{ SelectedValue = '__HOST__' }
$script:Paths = [pscustomobject]@{ DataRoot = [IO.Path]::GetTempPath() }
$script:Config = New-SSHManagerDefaultConfig
$script:Config.VpnProfiles = @([pscustomobject]@{ Id = 'harita'; Name = 'Harita DRC'; Type = 'WindowsRas' })
$both = [pscustomobject]@{ Id = 'both'; Name = 'Server01'; Group = 'Prod'; HostName = '10.10.10.1'; Port = 22; Username = 'ops'; AuthType = 'Agent'; KeyPath = ''; VpnProfileId = 'harita'; JumpHost = ''; KeepAliveInterval = 15; KeepAliveCountMax = 4; HostKeyPolicy = 'AcceptNew'; Tags = 't'; Notes = 'n'; Favorite = $false; LastConnectedAt = 'x'; SshEnabled = $true; RdpEnabled = $true; RdpPort = 3390; RdpUsername = 'CORP\ops'; RdpFullscreen = $false; RdpMultiMonitor = $true; RdpAdmin = $true; RdpWidth = 1600; RdpHeight = 900; RdpCredentialSaved = $true }
$sshOnly = [pscustomobject]@{ Id = 'ssh'; Name = 'Linux01'; HostName = '10.10.10.2'; Port = 22; SshEnabled = $true; RdpEnabled = $false }
$rdpOnly = [pscustomobject]@{ Id = 'rdp'; Name = 'Windows01'; HostName = '10.10.10.3'; Port = 22; SshEnabled = $false; RdpEnabled = $true }
$script:Config.Hosts = @($both, $sshOnly, $rdpOnly)

$script:MainWindow = New-Object Windows.Window
$script:MainWindow.Width = 400; $script:MainWindow.Height = 300; $script:MainWindow.ShowInTaskbar = $false
$button = New-Object Windows.Controls.Button
$button.Content = '...'
$script:MainWindow.Content = $button
$script:MainWindow.Show()
try {
    $expected = @{
        both = @('Ssh', 'Rdp', 'TestRdp', 'Scp', 'Editor', 'Edit', 'Duplicate', 'Delete')
        ssh  = @('Ssh', 'Scp', 'Editor', 'Edit', 'Duplicate', 'Delete')
        rdp  = @('Rdp', 'TestRdp', 'Edit', 'Duplicate', 'Delete')
    }
    foreach ($round in 1..20) {
        foreach ($hostEntry in $script:Config.Hosts) {
            $menu = Show-HostRowMenu -Button $button -HostEntry $hostEntry -Context 'Connections'
            [Windows.Forms.Application]::DoEvents()
            Assert-Menu ($round -gt 1 -or $menu.IsOpen) 'Row menu did not open on a loaded button.'
            $items = @($menu.Items | Where-Object { $_ -is [Windows.Controls.MenuItem] })
            $actions = @($items | ForEach-Object { $_.Tag.Action })
            Assert-Menu (($actions -join ',') -eq ($expected[$hostEntry.Id] -join ',')) ("Menu for {0} has {1}" -f $hostEntry.Id, ($actions -join ','))
            $menu.IsOpen = $false
            foreach ($item in $items) {
                if ($item.Tag.Action -eq 'Duplicate') { continue }
                $script:Calls.Clear()
                $item.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.MenuItem]::ClickEvent, $item)))
                Assert-Menu ($script:Calls.Count -eq 1) ("Click {0} ran {1} actions." -f $item.Tag.Action, $script:Calls.Count)
                $call = $script:Calls[0]
                Assert-Menu ($call -match [regex]::Escape($hostEntry.Id)) ("Click {0} targeted the wrong host: {1}" -f $item.Tag.Action, $call)
            }
        }
    }
    Assert-Menu ($script:Errors.Count -eq 0) ('Row actions reported errors: ' + ($script:Errors -join '; '))
    $script:Calls.Clear()
    Invoke-HostRowAction -Action 'Rdp' -HostId 'both' -Context 'Connections'
    Assert-Menu ($script:Calls[0] -eq 'Rdp:both:__HOST__') 'Connections RDP action ignored the VPN selection.'
    Invoke-HostRowAction -Action 'Edit' -HostId 'missing'
    Assert-Menu ($script:Warnings.Count -eq 1) 'Missing host did not produce a friendly warning.'

    # Real host editor: Duplicate copies SSH/RDP/VPN settings under a new Id, never the credential flag.
    $script:DialogAction = $null
    function Invoke-NextDialog {
        param([scriptblock]$Action)
        $script:DialogAction = $Action
        [void]$script:MainWindow.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [Action]{
            $dialog = $script:MainWindow.OwnedWindows[0]
            try { & $script:DialogAction $dialog }
            finally { if ($dialog.IsVisible -and $null -eq $dialog.DialogResult) { $dialog.FindName('SaveButton').RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } }
        })
    }
    foreach ($expectedName in @('Server01 - Copy', 'Server01 - Copy 2')) {
        Invoke-NextDialog { param($dialog) $script:SeenName = $dialog.FindName('NameBox').Text }
        Duplicate-Host -HostEntry $both
        Assert-Menu ($script:SeenName -eq $expectedName) "Duplicate proposed '$($script:SeenName)' instead of '$expectedName'."
    }
    $copies = @($script:Config.Hosts | Where-Object { $_.Name -like 'Server01 - Copy*' })
    Assert-Menu ($copies.Count -eq 2) 'Duplicate did not add exactly two hosts.'
    $copy = $copies[0]
    Assert-Menu ($copy.Id -ne 'both' -and $copies[1].Id -ne $copy.Id) 'Duplicate reused an existing Id.'
    Assert-Menu ($copy.HostName -eq '10.10.10.1' -and $copy.Port -eq 22 -and $copy.Username -eq 'ops' -and $copy.SshEnabled) 'SSH settings not copied.'
    Assert-Menu ($copy.RdpEnabled -and $copy.RdpPort -eq 3390 -and $copy.RdpUsername -eq 'CORP\ops' -and $copy.RdpAdmin -and $copy.RdpMultiMonitor -and -not $copy.RdpFullscreen -and $copy.RdpWidth -eq 1600 -and $copy.RdpHeight -eq 900) 'RDP settings not copied.'
    Assert-Menu ($copy.VpnProfileId -eq 'harita' -and $copy.Group -eq 'Prod' -and $copy.Tags -eq 't') 'VPN/group/tags not copied.'
    Assert-Menu (-not $copy.RdpCredentialSaved -and $copy.LastConnectedAt -eq '') 'Duplicate inherited credential flag or history.'
    Assert-Menu ($both.Name -eq 'Server01' -and $both.Id -eq 'both' -and $both.RdpCredentialSaved) 'Duplicate modified the original host.'

    # Add RDP from the RDP Manager: SSH off, RDP on, default port 3389.
    Invoke-NextDialog {
        param($dialog)
        $script:AddDefaults = @([bool]$dialog.FindName('SshEnabledBox').IsChecked, [bool]$dialog.FindName('RdpEnabledBox').IsChecked, $dialog.FindName('RdpPortBox').Text, [bool]$dialog.FindName('SshSection').IsEnabled)
        $dialog.FindName('NameBox').Text = 'Windows Server 01'
        $dialog.FindName('HostBox').Text = '10.10.10.10'
    }
    Add-Host -Rdp
    Assert-Menu (-not $script:AddDefaults[0] -and $script:AddDefaults[1] -and $script:AddDefaults[2] -eq '3389' -and -not $script:AddDefaults[3]) 'Add RDP defaults wrong.'
    $added = @($script:Config.Hosts | Where-Object { $_.Name -eq 'Windows Server 01' })
    Assert-Menu ($added.Count -eq 1 -and -not $added[0].SshEnabled -and $added[0].RdpEnabled -and $added[0].RdpPort -eq 3389 -and $added[0].Port -eq 22) 'RDP-only host saved incorrectly.'
    Assert-Menu ($script:MainWindow.OwnedWindows.Count -eq 0) 'Host editor left a window open.'
}
finally { $script:MainWindow.Close() }
Write-Host 'PASS row menu/native WPF: 20x open/click for SSH/RDP/SSH+RDP hosts with correct targets and protocol items, missing host handled, Duplicate (new Id, "- Copy"/"- Copy 2", SSH/RDP/VPN copied, no credential), Add RDP defaults.'
