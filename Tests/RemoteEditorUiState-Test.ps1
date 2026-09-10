[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
# Run the actual modal controller with control/transport doubles. This is not a WPF render test.
$script:ApplicationRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:ApplicationRoot 'Modules/SSHManager.Core.psm1') -Force -DisableNameChecking
. (Join-Path $script:ApplicationRoot 'UI/RemoteEditor.ps1')
if (-not ('Windows.Visibility' -as [type])) {
    Add-Type -TypeDefinition @'
namespace Windows {
 public enum Visibility { Visible, Collapsed }
 namespace Media { public class BrushConverter { public object ConvertFromString(string s) { return s; } } }
 namespace Forms { public static class Application { public static void DoEvents() {} } }
}
'@
}
function Assert-Editor { param([bool]$Value,[string]$Message) if (-not $Value) { throw $Message } }
function New-ControlDouble {
    $control=[pscustomobject]@{
        Text=''; ToolTip=$null; Foreground=$null; IsEnabled=$true; IsChecked=$true
        ItemsSource=@(); SelectedIndex=0; SelectedItem='LF'; Visibility=[Windows.Visibility]::Collapsed
        CanUndo=$false; CanRedo=$false; IsUndoEnabled=$true; SelectionStart=0; SelectionLength=0; CaretIndex=0
        Handlers=@{}
    }
    foreach ($eventName in @('Click','KeyDown','TextChanged','SelectionChanged')) {
        $method=[scriptblock]::Create('$this.Handlers["'+$eventName+'"]=$args[0]')
        $control | Add-Member -MemberType ScriptMethod -Name ('Add_'+$eventName) -Value $method
    }
    $control | Add-Member -MemberType ScriptMethod -Name Clear -Value { $this.Text='' }
    $control | Add-Member -MemberType ScriptMethod -Name GetLineIndexFromCharacterIndex -Value { return 0 }
    $control | Add-Member -MemberType ScriptMethod -Name GetCharacterIndexFromLineIndex -Value { return 0 }
    $control | Add-Member -MemberType ScriptMethod -Name Focus -Value { return $true }
    $control | Add-Member -MemberType ScriptMethod -Name SelectAll -Value {}
    $control | Add-Member -MemberType ScriptMethod -Name Select -Value { param($start,$length); $this.SelectionStart=$start; $this.SelectionLength=$length }
    $control | Add-Member -MemberType ScriptMethod -Name ScrollToLine -Value {}
    return $control
}
function Read-XamlWindow {
    param($Xaml)
    $window=[pscustomobject]@{ Title=''; Owner=$null; Tag=$null; DialogResult=$false; Controls=@{}; Handlers=@{}; IsPrompt=($Xaml -match 'UnsavedFileText') }
    foreach ($match in [regex]::Matches($Xaml,'x:Name="([^"]+)"')) { $window.Controls[$match.Groups[1].Value]=New-ControlDouble }
    foreach ($eventName in @('Closing','PreviewKeyDown')) {
        $method=[scriptblock]::Create('$this.Handlers["'+$eventName+'"]=$args[0]')
        $window | Add-Member -MemberType ScriptMethod -Name ('Add_'+$eventName) -Value $method
    }
    $window | Add-Member -MemberType ScriptMethod -Name ShowDialog -Value {
        if ($this.IsPrompt) {
            Assert-Editor ($script:PromptChoices.Count -gt 0) 'Unexpected unsaved prompt.'
            $this.Tag=$script:PromptChoices.Dequeue()
        }
        else { & $script:EditorScenario $this }
        return $true
    }
    return $window
}
function Get-NamedControl { param($Window,$Name); return $Window.Controls[$Name] }
function Get-SelectedHostEntries { return $script:Config.Hosts }
function Ensure-SSHManagerVpnForHost { param($HostEntry); $script:VpnTargets.Add($HostEntry.Id) }
function Set-Status { param($Text,$Color,$Details); $script:LastEditorMainStatus=$Text }
function Invoke-SSHManagerRemoteTextFile {
    param($HostEntry,$Paths,$Operation,$RemotePath,$ExpectedVersion,$Bytes,$Backup,$TimeoutSeconds,$OnProgress)
    & $OnProgress 100
    if ($Operation -eq 'read') {
        if ($script:FailRead) { throw 'simulated read failure' }
        return [pscustomobject]@{ok=$true; path=$RemotePath; content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("first`n")); size=6; version=('a'*64)}
    }
    $script:SaveCalls.Add([pscustomobject]@{Node=$HostEntry.Id;Path=$RemotePath;Version=$ExpectedVersion;Bytes=$Bytes})
    if ($script:FailSave) { throw 'CONFLICT: changed on server' }
    return [pscustomobject]@{ok=$true;path=$RemotePath;size=$Bytes.Length;version=('b'*64);backup=('/remote/.backup-'+$HostEntry.Id)}
}
$script:Config=[pscustomobject]@{
    App=[pscustomobject]@{ConnectTimeoutSeconds=8}
    Hosts=@([pscustomobject]@{Id='a';Name='node A';Username='user-a';HostName='node-a';Port=22},[pscustomobject]@{Id='b';Name='node B';Username='user-b';HostName='node-b';Port=2222})
}
$script:MainWindow=$null
$script:Paths=[pscustomobject]@{}
$script:PromptChoices=New-Object 'Collections.Generic.Queue[string]'
$script:SaveCalls=New-Object 'Collections.Generic.List[object]'
$script:VpnTargets=New-Object 'Collections.Generic.List[string]'
$script:FailRead=$false; $script:FailSave=$false
$script:EditorScenario = {
    param($window)
    $c=$window.Controls
    $c.NodeCombo.SelectedItem=$script:Config.Hosts[0]
    Assert-Editor (-not $c.SaveButton.IsEnabled -and -not $c.EditorBox.IsEnabled) 'Editor enabled before a file is open.'
    $c.RemotePathBox.Text='/remote/a.cfg'
    & $c.OpenButton.Handlers.Click
    Assert-Editor ($c.EditorBox.Text -ceq "first`r`n") ('Opened text not displayed: '+$c.EditorStatus.Text)
    $c.EditorBox.Text="modified`r`n"
    & $c.EditorBox.Handlers.TextChanged
    Assert-Editor ($c.SaveButton.IsEnabled -and $window.Title.StartsWith('* ')) 'Dirty state missing.'
    $c.RemotePathBox.Text='/remote/must-not-be-saved.cfg'
    & $c.SaveButton.Handlers.Click
    Assert-Editor ($script:SaveCalls[0].Path -ceq '/remote/a.cfg' -and $script:SaveCalls[0].Node -ceq 'a') 'Typing a path redirected save.'
    Assert-Editor (-not $c.SaveButton.IsEnabled -and -not $window.Title.StartsWith('* ')) 'Successful save did not mark document clean.'
    Assert-Editor ($script:LastEditorMainStatus -match 'Selesai edit file') 'Main status did not report save.'

    $c.EditorBox.Text="unsaved`r`n"; & $c.EditorBox.Handlers.TextChanged
    $script:PromptChoices.Enqueue('Cancel')
    $c.NodeCombo.SelectedItem=$script:Config.Hosts[1]; & $c.NodeCombo.Handlers.SelectionChanged
    Assert-Editor ($c.NodeCombo.SelectedItem.Id -eq 'a' -and $c.EditorBox.Text -ceq "unsaved`r`n") 'Cancel node switch lost text or node.'
    $script:FailSave=$true
    $script:PromptChoices.Enqueue('Save')
    $c.NodeCombo.SelectedItem=$script:Config.Hosts[1]; & $c.NodeCombo.Handlers.SelectionChanged
    Assert-Editor ($c.NodeCombo.SelectedItem.Id -eq 'a' -and $c.SaveButton.IsEnabled) 'Failed save allowed switching node.'
    Assert-Editor ($script:SaveCalls[1].Node -eq 'a' -and $script:SaveCalls[1].Version -eq ('b'*64)) 'Unsaved prompt saved wrong node/version.'

    $script:PromptChoices.Enqueue('Save')
    $closing=[pscustomobject]@{Cancel=$false}; & $window.Handlers.Closing $window $closing
    Assert-Editor ($closing.Cancel -and $c.EditorBox.Text -ceq "unsaved`r`n") 'Failed save allowed closing editor.'
    $script:FailSave=$false
    $script:PromptChoices.Enqueue('Save')
    $c.NodeCombo.SelectedItem=$script:Config.Hosts[1]; & $c.NodeCombo.Handlers.SelectionChanged
    Assert-Editor ($script:SaveCalls[3].Node -eq 'a' -and $c.NodeCombo.SelectedItem.Id -eq 'b') 'Save-then-switch did not save old node first.'
    Assert-Editor (-not $c.EditorBox.IsEnabled -and $c.EditorBox.Text -ceq '') 'New node retained previous document.'

    $c.RemotePathBox.Text='/remote/b.cfg'; & $c.OpenButton.Handlers.Click
    $c.EditorBox.Text="keep this`r`n"; & $c.EditorBox.Handlers.TextChanged
    $script:FailRead=$true; $script:PromptChoices.Enqueue('Discard')
    $c.RemotePathBox.Text='/remote/missing'; & $c.OpenButton.Handlers.Click
    Assert-Editor ($c.EditorBox.Text -ceq "keep this`r`n" -and $c.SaveButton.IsEnabled) 'Read failure discarded current document.'
    & $c.SaveButton.Handlers.Click
    Assert-Editor ($script:SaveCalls[4].Path -eq '/remote/b.cfg' -and $script:SaveCalls[4].Node -eq 'b') 'Read failure changed loaded save target.'
    $closing=[pscustomobject]@{Cancel=$false}; & $window.Handlers.Closing $window $closing
    Assert-Editor (-not $closing.Cancel) 'Clean editor cannot close.'
    Assert-Editor ($script:PromptChoices.Count -eq 0) 'Prompt scenario was not consumed.'
}
Show-RemoteTextEditor
Write-Host 'PASS editor controller: dirty state, loaded save target, save/conflict, cancelled node switch/close, old-node save, read failure recovery'
