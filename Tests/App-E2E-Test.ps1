[CmdletBinding()]
param([int]$TimeoutSeconds = 60)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
# End-to-end on the real application process via UI Automation (Windows desktop session required).
# Uses an isolated data folder with a legacy config and a local TCP listener as the "RDP server".
# No SSH/RDP login, mstsc or Windows Terminal is started. Close any running Proper SSH Manager first.
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Uji ini membutuhkan Windows.' }
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$applicationRoot = Split-Path -Parent $PSScriptRoot
function Assert-E2E { param([bool]$Value, [string]$Message) if (-not $Value) { throw $Message } }
$ui = [Windows.Automation.AutomationElement]
$tree = [Windows.Automation.TreeScope]

function Wait-Element {
    param($Root, [Windows.Automation.Condition]$Condition, [string]$Label, [int]$Seconds = $TimeoutSeconds, [switch]$Children)
    $deadline = (Get-Date).AddSeconds($Seconds)
    $scope = if ($Children) { $tree::Children } else { $tree::Descendants }
    do {
        $found = $Root.FindFirst($scope, $Condition)
        if ($null -ne $found) { return $found }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "UI element not found: $Label"
}
function New-IdCondition { param([string]$Id) New-Object Windows.Automation.PropertyCondition($ui::AutomationIdProperty, $Id) }
function New-NameCondition { param([string]$Name) New-Object Windows.Automation.PropertyCondition($ui::NameProperty, $Name) }
function Invoke-Element { param($Element) $Element.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke() }
function Find-TopWindow {
    param([string]$Name, [int]$ProcessId)
    # Match windows only: a grid column header can share a dialog title such as "Host".
    $condition = New-Object Windows.Automation.AndCondition((New-NameCondition $Name), (New-Object Windows.Automation.PropertyCondition($ui::ProcessIdProperty, $ProcessId)), (New-Object Windows.Automation.PropertyCondition($ui::ControlTypeProperty, [Windows.Automation.ControlType]::Window)))
    return Wait-Element $ui::RootElement $condition "window '$Name'"
}
function Close-MessageBox {
    param([string]$Title, [int]$ProcessId)
    $box = Find-TopWindow $Title $ProcessId
    # Win32 message box parts are exposed as panes (caption localized); read every name, then close the dialog.
    $texts = @($box.FindAll($tree::Descendants, [Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name }) -join "`n"
    $box.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()
    return $texts
}

if (Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq 'Proper SSH Manager' }) { throw 'Tutup Proper SSH Manager yang sedang berjalan sebelum uji E2E.' }
$dataRoot = Join-Path ([IO.Path]::GetTempPath()) ('psm-e2e-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$listener.Start()
$rdpPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
@"
{ "Version": 1, "App": { "ConfirmBeforeDelete": true }, "VpnProfiles": [],
  "Hosts": [
    { "name": "Server01", "host": "127.0.0.1", "port": 22, "Username": "ops", "AuthType": "Agent" },
    { "Id": "win01", "Name": "Windows01", "HostName": "127.0.0.1", "Port": 22, "Username": "", "AuthType": "Agent", "SshEnabled": false, "RdpEnabled": true, "RdpPort": $rdpPort }
  ] }
"@ | Set-Content -LiteralPath (Join-Path $dataRoot 'config.json') -Encoding UTF8

$previousData = $env:PROPER_SSH_MANAGER_DATA
$env:PROPER_SSH_MANAGER_DATA = $dataRoot
$process = $null
try {
    $process = Start-Process powershell.exe -ArgumentList @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $applicationRoot 'SSHManager.ps1')) -PassThru -WindowStyle Hidden
    $main = Find-TopWindow 'Proper SSH Manager' $process.Id
    Assert-E2E ($null -ne (Wait-Element $main (New-NameCondition 'Server01') 'legacy host row')) 'Legacy host not listed.'

    # Original crash path: "..." -> Duplikat host on the Connections page.
    $hostGrid = Wait-Element $main (New-IdCondition 'HostGrid') 'HostGrid'
    $moreButtons = $hostGrid.FindAll($tree::Descendants, (New-Object Windows.Automation.PropertyCondition($ui::HelpTextProperty, 'Aksi lainnya')))
    Assert-E2E ($moreButtons.Count -eq 2) "Expected 2 row menu buttons, found $($moreButtons.Count)."
    foreach ($attempt in 1..3) {
        Invoke-Element $moreButtons[0]
        $duplicate = Wait-Element $ui::RootElement (New-Object Windows.Automation.AndCondition((New-NameCondition 'Duplikat host'), (New-Object Windows.Automation.PropertyCondition($ui::ProcessIdProperty, $process.Id)))) 'Duplikat host menu item'
        Invoke-Element $duplicate
        $editor = Find-TopWindow 'Host' $process.Id
        $nameValue = (Wait-Element $editor (New-IdCondition 'NameBox') 'NameBox').GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
        Assert-E2E ($nameValue -like '* - Copy') "Duplicate editor proposed '$nameValue'."
        Invoke-Element (Wait-Element $editor (New-IdCondition 'CancelButton') 'CancelButton')
        Start-Sleep -Milliseconds 400
        Assert-E2E (-not $process.HasExited) 'Application exited after the row menu action.'
    }

    # RDP Manager inside the same window.
    Invoke-Element (Wait-Element $main (New-IdCondition 'NavRdp') 'NavRdp')
    [void](Wait-Element $main (New-NameCondition 'Kelola dan buka Remote Desktop dari workspace yang sama.') 'RDP header')
    $topWindows = @($ui::RootElement.FindAll($tree::Children, (New-Object Windows.Automation.PropertyCondition($ui::ProcessIdProperty, $process.Id))))
    Assert-E2E ($topWindows.Count -eq 1) "RDP Manager created $($topWindows.Count) top-level windows."
    $rdpGrid = Wait-Element $main (New-IdCondition 'RdpGrid') 'RdpGrid'
    Assert-E2E ($null -ne (Wait-Element $rdpGrid (New-NameCondition 'Windows01') 'Windows01 RDP row')) 'RDP host not listed.'
    $checkbox = Wait-Element $rdpGrid (New-Object Windows.Automation.PropertyCondition($ui::ControlTypeProperty, [Windows.Automation.ControlType]::CheckBox)) 'RDP row checkbox'
    $checkbox.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
    Invoke-Element (Wait-Element $main (New-IdCondition 'BtnRdpTest') 'BtnRdpTest')
    $acceptTask = $listener.AcceptTcpClientAsync()
    $resultText = Close-MessageBox 'Hasil Test RDP' $process.Id
    Assert-E2E ($resultText -match "127\.0\.0\.1:$rdpPort\s+Connected · Latency: \d+ ms") "Unexpected Test RDP result: $resultText"
    Assert-E2E ($acceptTask.Wait(5000)) 'Test RDP did not reach the listener.'
    $status = (Wait-Element $main (New-IdCondition 'StatusText') 'StatusText').Current.Name
    Assert-E2E ($status -match "127\.0\.0\.1:$rdpPort Connected") "Status bar not updated: $status"

    # Back to Connections, then close normally.
    Invoke-Element (Wait-Element $main (New-IdCondition 'NavConnections') 'NavConnections')
    [void](Wait-Element $main (New-NameCondition 'Kelola host, group, dan pilihan koneksi Anda.') 'Connections header')
    $main.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()
    Assert-E2E ($process.WaitForExit(15000)) 'Application did not exit after closing the main window.'

    $log = Get-Content -LiteralPath (Join-Path $dataRoot 'logs\ProperSSHManager.log') -Raw
    Assert-E2E ($log -match '\| INFO  \| App \| Startup \|' -and $log -match '\| RDP \| Test \| host=127\.0\.0\.1:') 'Log file missing startup/RDP test entries.'
    Assert-E2E ($log -notmatch '\| ERROR \|') "Unexpected errors in log:`n$log"
}
finally {
    $env:PROPER_SSH_MANAGER_DATA = $previousData
    if ($null -ne $process -and -not $process.HasExited) { $process.Kill() }
    $listener.Stop()
    Remove-Item -LiteralPath $dataRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'PASS app E2E: real process starts with legacy config; Connections row menu Duplicate x3 without crash; RDP Manager in the same window; Test RDP async result/status bar; clean exit; structured log.'
