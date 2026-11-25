# RDP Manager page and RDP connection flow.
# The view is created once and lives in MainWindow's RdpPage host; its handlers are attached exactly once.
# Network work (VPN connect, TCP probe) is polled by one DispatcherTimer, so the UI thread never waits on it.
$script:RdpView = $null
$script:RdpControls = @{}
$script:RdpCheckedHostIds = New-Object 'Collections.Generic.HashSet[string]'
$script:RdpHostStatus = @{}
$script:RdpState = [pscustomobject]@{ Refreshing = $false; Operation = $null; Timer = $null }
$script:RdpMaxSessionsWithoutConfirm = 5

function Initialize-RdpManagerView {
    if ($null -ne $script:RdpView) { return }
    $pageHost = Get-NamedControl $script:MainWindow 'RdpPage'
    $view = Read-WorkspaceView (Get-Content -LiteralPath (Join-Path $script:ApplicationRoot 'UI\RdpManager.xaml') -Raw -Encoding UTF8)
    foreach ($name in @('BtnRdpAdd', 'BtnRdpOpen', 'BtnRdpTest', 'RdpSearchBox', 'RdpGroupFilter', 'RdpVpnOverride', 'RdpGrid', 'RdpEmptyState', 'BtnRdpSelectAll', 'BtnRdpClear', 'RdpSelectionText')) {
        $script:RdpControls[$name] = Get-NamedControl $view $name
    }
    $pageHost.Content = $view
    $script:RdpView = $view

    $script:RdpControls.RdpSearchBox.Add_TextChanged({ if (-not $script:RdpState.Refreshing) { Update-RdpManagerGrid } })
    $script:RdpControls.RdpGroupFilter.Add_SelectionChanged({ if (-not $script:RdpState.Refreshing) { Update-RdpManagerGrid } })
    $script:RdpControls.BtnRdpAdd.Add_Click({ Add-Host -Rdp })
    $script:RdpControls.BtnRdpOpen.Add_Click({ Start-RdpLaunchBatch -Hosts @(Get-RdpSelectedHosts) -VpnOverride (Get-RdpVpnOverride) })
    $script:RdpControls.BtnRdpTest.Add_Click({ Test-RdpHosts -Hosts @(Get-RdpSelectedHosts) })
    $script:RdpControls.BtnRdpSelectAll.Add_Click({ Set-RdpRowsChecked $true })
    $script:RdpControls.BtnRdpClear.Add_Click({ Set-RdpRowsChecked $false })
    $script:RdpControls.RdpGrid.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
        param($sender, $routedArgs)
        $checkBox = Get-WorkspaceEventElement -RoutedArgs $routedArgs -Type ([Windows.Controls.CheckBox]) -Tag 'RdpSelection'
        if ($null -ne $checkBox) {
            $row = $checkBox.DataContext
            if ($null -eq $row -or $null -eq $row.PSObject.Properties['Id']) { return }
            $row.IsChecked = [bool]$checkBox.IsChecked
            if ($row.IsChecked) { [void]$script:RdpCheckedHostIds.Add([string]$row.Id) } else { [void]$script:RdpCheckedHostIds.Remove([string]$row.Id) }
            Update-RdpSelectionText
            return
        }
        $button = Get-WorkspaceEventElement -RoutedArgs $routedArgs -Type ([Windows.Controls.Button])
        if ($null -eq $button -or [string]$button.Tag -notin @('RdpRowConnect', 'RdpRowEdit', 'RdpRowMore')) { return }
        $row = $button.DataContext
        if ($null -eq $row -or $null -eq $row.PSObject.Properties['Source'] -or $null -eq $row.Source) { return }
        switch ([string]$button.Tag) {
            'RdpRowConnect' { Start-RdpLaunchBatch -Hosts @($row.Source) -VpnOverride (Get-RdpVpnOverride) }
            'RdpRowEdit' { Edit-Host -HostEntry $row.Source }
            'RdpRowMore' { [void](Show-HostRowMenu -Button $button -HostEntry $row.Source -Context 'Rdp') }
        }
        $routedArgs.Handled = $true
    }, $true)
    $script:RdpControls.RdpGrid.Add_MouseDoubleClick({
        param($sender, $mouseArgs)
        $source = $mouseArgs.OriginalSource
        while ($null -ne $source -and $source -ne $sender) {
            if ($source -is [Windows.Controls.Primitives.ButtonBase]) { return }
            if ($source -isnot [Windows.Media.Visual]) { return }
            $source = [Windows.Media.VisualTreeHelper]::GetParent($source)
        }
        $row = $sender.SelectedItem
        if ($null -ne $row -and $null -ne $row.PSObject.Properties['Source']) { Start-RdpLaunchBatch -Hosts @($row.Source) -VpnOverride (Get-RdpVpnOverride) }
    })
    Update-RdpManagerView
}

function Update-RdpManagerView {
    if ($null -eq $script:RdpView) { return }
    $script:RdpState.Refreshing = $true
    try {
        $groupCombo = $script:RdpControls.RdpGroupFilter
        $selectedGroup = [string]$groupCombo.SelectedItem
        $groups = @('Semua group') + @(@($script:Config.Hosts) | Where-Object { Test-SSHManagerRdpEnabled $_ } | ForEach-Object { [string](Get-SSHManagerHostValue $_ 'Group') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        $groupCombo.ItemsSource = $groups
        if ($groups -contains $selectedGroup) { $groupCombo.SelectedItem = $selectedGroup } else { $groupCombo.SelectedIndex = 0 }

        $vpnCombo = $script:RdpControls.RdpVpnOverride
        $selectedVpn = [string]$vpnCombo.SelectedValue
        $vpnItems = @(
            [pscustomobject]@{ Id = '__HOST__'; Name = 'Ikuti konfigurasi host' },
            [pscustomobject]@{ Id = '__NONE__'; Name = 'Tidak menggunakan VPN' }
        ) + @(@($script:Config.VpnProfiles) | Sort-Object Name | ForEach-Object { [pscustomobject]@{ Id = [string]$_.Id; Name = [string]$_.Name } })
        $vpnCombo.ItemsSource = $vpnItems
        $vpnCombo.SelectedValue = if (@($vpnItems.Id) -contains $selectedVpn) { $selectedVpn } else { '__HOST__' }
    }
    finally { $script:RdpState.Refreshing = $false }
    Update-RdpManagerGrid
}

function Get-RdpVpnOverride {
    if ($null -eq $script:RdpView) { return '__HOST__' }
    $value = [string]$script:RdpControls.RdpVpnOverride.SelectedValue
    if ([string]::IsNullOrWhiteSpace($value)) { return '__HOST__' }
    return $value
}

function Get-RdpStatusDisplay {
    param([string]$HostId)
    if ($script:RdpHostStatus.ContainsKey($HostId)) { return $script:RdpHostStatus[$HostId] }
    return [pscustomobject]@{ Text = 'Ready'; Color = '#91A5BF' }
}

function Update-RdpManagerGrid {
    if ($null -eq $script:RdpView) { return }
    $query = $script:RdpControls.RdpSearchBox.Text.Trim().ToLowerInvariant()
    $group = [string]$script:RdpControls.RdpGroupFilter.SelectedItem
    $knownIds = New-Object 'Collections.Generic.HashSet[string]'
    $rows = foreach ($hostEntry in @(@($script:Config.Hosts) | Where-Object { Test-SSHManagerRdpEnabled $_ } | Sort-Object { [string](Get-SSHManagerHostValue $_ 'Group') }, Name)) {
        [void]$knownIds.Add([string]$hostEntry.Id)
        $hostGroup = [string](Get-SSHManagerHostValue $hostEntry 'Group')
        if ($group -and $group -ne 'Semua group' -and $hostGroup -ne $group) { continue }
        $haystack = (@($hostEntry.Name, $hostGroup, $hostEntry.HostName, (Get-SSHManagerHostValue $hostEntry 'RdpUsername'), (Get-SSHManagerHostValue $hostEntry 'Tags')) -join ' ').ToLowerInvariant()
        if ($query.Length -gt 0 -and -not $haystack.Contains($query)) { continue }
        $status = Get-RdpStatusDisplay ([string]$hostEntry.Id)
        [pscustomobject]@{
            Id          = [string]$hostEntry.Id
            IsChecked   = $script:RdpCheckedHostIds.Contains([string]$hostEntry.Id)
            Name        = [string]$hostEntry.Name
            HostName    = [string]$hostEntry.HostName
            Port        = Get-SSHManagerRdpPort $hostEntry
            GroupLabel  = if ([string]::IsNullOrWhiteSpace($hostGroup)) { 'Default' } else { $hostGroup }
            GroupBrush  = Get-WorkspaceGroupBrush -Name $hostGroup
            StatusText  = [string]$status.Text
            StatusColor = [string]$status.Color
            Source      = $hostEntry
        }
    }
    # Hosts that were deleted or had RDP disabled must not stay selected invisibly.
    foreach ($id in @($script:RdpCheckedHostIds)) { if (-not $knownIds.Contains($id)) { [void]$script:RdpCheckedHostIds.Remove($id) } }
    $script:RdpControls.RdpGrid.ItemsSource = @($rows)
    $script:RdpControls.RdpEmptyState.Visibility = if (@($rows).Count -eq 0) { 'Visible' } else { 'Collapsed' }
    Update-RdpSelectionText
}

function Update-RdpSelectionText {
    if ($null -eq $script:RdpView) { return }
    $total = @(@($script:Config.Hosts) | Where-Object { Test-SSHManagerRdpEnabled $_ }).Count
    $script:RdpControls.RdpSelectionText.Text = '{0} dari {1} host RDP dipilih' -f $script:RdpCheckedHostIds.Count, $total
}

function Set-RdpRowsChecked {
    param([bool]$Checked)
    foreach ($row in @($script:RdpControls.RdpGrid.ItemsSource)) {
        if ($Checked) { [void]$script:RdpCheckedHostIds.Add([string]$row.Id) } else { [void]$script:RdpCheckedHostIds.Remove([string]$row.Id) }
    }
    Update-RdpManagerGrid
}

function Get-RdpSelectedHosts {
    if ($null -eq $script:RdpView) { return @() }
    # The binding is the source of truth for visible rows (keyboard/automation toggles raise no Click).
    foreach ($row in @($script:RdpControls.RdpGrid.ItemsSource)) {
        if ($null -eq $row) { continue }
        if ([bool]$row.IsChecked) { [void]$script:RdpCheckedHostIds.Add([string]$row.Id) } else { [void]$script:RdpCheckedHostIds.Remove([string]$row.Id) }
    }
    $checked = @(@($script:Config.Hosts) | Where-Object { $script:RdpCheckedHostIds.Contains([string]$_.Id) -and (Test-SSHManagerRdpEnabled $_) })
    if ($checked.Count -gt 0) { return $checked }
    return @(@($script:RdpControls.RdpGrid.SelectedItems) | ForEach-Object { $_.Source })
}

function Set-RdpHostStatus {
    param([string]$HostId, [string]$Text, [string]$Color = '#91A5BF')
    $script:RdpHostStatus[$HostId] = [pscustomobject]@{ Text = $Text; Color = $Color }
}

function Test-RdpOperationBusy {
    if ($null -eq $script:RdpState.Operation) { return $false }
    Set-Status 'Operasi RDP sebelumnya masih berjalan. Tunggu hingga selesai.' '#F59E0B'
    return $true
}

function Set-RdpBusyUi {
    param([bool]$Busy)
    if ($null -eq $script:RdpView) { return }
    foreach ($name in @('BtnRdpOpen', 'BtnRdpTest')) { $script:RdpControls[$name].IsEnabled = -not $Busy }
    $connectionsRdp = Get-OptionalControl $script:MainWindow 'BtnRdp'
    if ($null -ne $connectionsRdp -and $Busy) { $connectionsRdp.IsEnabled = $false }
    if (-not $Busy) { Update-WorkspaceSelection }
}

function Test-RdpHosts {
    param([object[]]$Hosts = @())
    $targets = @($Hosts | Where-Object { Test-SSHManagerRdpEnabled $_ })
    if ($targets.Count -eq 0) { Show-Warning 'Pilih minimal satu host yang mendukung RDP untuk dites.'; return }
    if (Test-RdpOperationBusy) { return }
    Start-RdpOperation -Kind 'Test' -Hosts $targets -VpnOverride '__NONE__'
}

function Start-RdpLaunchBatch {
    param([object[]]$Hosts = @(), [string]$VpnOverride = '__HOST__')
    $selected = @($Hosts | Where-Object { $null -ne $_ })
    $targets = @($selected | Where-Object { Test-SSHManagerRdpEnabled $_ })
    if ($selected.Count -eq 0) { Show-Warning 'Pilih minimal satu host RDP.'; return }
    if ($targets.Count -eq 0) { Show-Warning 'Host yang dipilih tidak memiliki RDP. Aktifkan RDP melalui Edit host.'; return }
    if (Test-RdpOperationBusy) { return }
    if ($targets.Count -gt $script:RdpMaxSessionsWithoutConfirm -and -not (Confirm-Action ("Anda akan membuka {0} sesi RDP.`n`nLanjutkan?" -f $targets.Count) 'Buka RDP')) {
        Set-Status 'Pembukaan RDP dibatalkan.' '#F59E0B'
        return
    }
    if ($targets.Count -lt $selected.Count) {
        Write-SSHManagerLog -Level INFO -Component 'RDP' -Action 'Launch' -Message ('{0} host tanpa RDP dilewati.' -f ($selected.Count - $targets.Count))
    }
    Start-RdpOperation -Kind 'Launch' -Hosts $targets -VpnOverride $VpnOverride
}

function Start-RdpOperation {
    param([ValidateSet('Test', 'Launch')][string]$Kind, [object[]]$Hosts, [string]$VpnOverride)
    $vpnQueue = New-Object 'Collections.Generic.Queue[object]'
    if ($Kind -eq 'Launch') {
        $vpnIds = @($Hosts | ForEach-Object { Resolve-SSHManagerVpnId -HostEntry $_ -Override $VpnOverride } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        foreach ($vpnId in $vpnIds) {
            $profile = Get-VpnById $vpnId
            if ($null -eq $profile) { Show-AppError -Summary 'VPN gagal terhubung. RDP dibatalkan.' -Detail ("Profil VPN dengan ID '{0}' tidak ditemukan." -f $vpnId) -Component 'RDP' -Action 'Vpn'; return }
            $vpnQueue.Enqueue($profile)
        }
    }
    $script:RdpState.Operation = [pscustomobject]@{
        Kind = $Kind; Hosts = @($Hosts); Phase = $(if ($vpnQueue.Count -gt 0) { 'Vpn' } else { 'StartProbe' })
        VpnQueue = $vpnQueue; VpnJob = $null; VpnDeadline = [datetime]::MaxValue; Probes = @{}; Results = @{}
    }
    Set-RdpBusyUi $true
    if ($null -eq $script:RdpState.Timer) {
        $script:RdpState.Timer = New-Object Windows.Threading.DispatcherTimer
        $script:RdpState.Timer.Interval = [TimeSpan]::FromMilliseconds(100)
        $script:RdpState.Timer.Add_Tick({ Step-RdpOperation })
    }
    Step-RdpOperation
}

function Complete-RdpOperation {
    if ($null -ne $script:RdpState.Timer) { $script:RdpState.Timer.Stop() }
    $script:RdpState.Operation = $null
    Set-RdpBusyUi $false
    Update-RdpManagerGrid
}

function Step-RdpOperation {
    $operation = $script:RdpState.Operation
    if ($null -eq $operation) { if ($script:RdpState.Timer) { $script:RdpState.Timer.Stop() }; return }
    # Stop while working so a modal dialog shown below cannot re-enter this tick.
    $script:RdpState.Timer.Stop()
    try {
        switch ($operation.Phase) {
            'Vpn' {
                if ($null -eq $operation.VpnJob) {
                    $profile = $operation.VpnQueue.Dequeue()
                    Set-Status ("Menghubungkan VPN '{0}' untuk RDP..." -f $profile.Name) '#38BDF8'
                    Write-SSHManagerLog -Component 'RDP' -Action 'VpnConnect' -Message ("VPN '{0}'" -f $profile.Name)
                    $operation.VpnJob = Start-SSHManagerVpnJob -Profile $profile -Paths $script:Paths -TimeoutSeconds ([int]$script:Config.App.VpnConnectTimeoutSeconds)
                    $operation.VpnDeadline = (Get-Date).AddSeconds([Math]::Max(1, [int]$script:Config.App.VpnConnectTimeoutSeconds) + 30)
                    break
                }
                $vpnResult = Receive-SSHManagerVpnJob -Job $operation.VpnJob
                if ($null -eq $vpnResult -and (Get-Date) -ge $operation.VpnDeadline) { $vpnResult = Stop-SSHManagerVpnJob -Job $operation.VpnJob -Message 'Perintah VPN tidak merespons.' }
                if ($null -eq $vpnResult) { break }
                $profileName = [string]$operation.VpnJob.Profile.Name
                $operation.VpnJob = $null
                if (-not [bool]$vpnResult.Success) {
                    Write-SSHManagerLog -Level ERROR -Component 'RDP' -Action 'VpnConnect' -Message ("VPN '{0}' gagal: {1}" -f $profileName, $vpnResult.Message)
                    Set-Status ("RDP gagal — VPN '{0}' gagal terhubung." -f $profileName) '#EF4444' ([string]$vpnResult.Message)
                    Complete-RdpOperation
                    Show-AppError -Summary "VPN gagal terhubung.`nRDP dibatalkan." -Detail ("VPN '{0}': {1}" -f $profileName, $vpnResult.Message) -Component 'RDP' -Action 'VpnConnect'
                    return
                }
                if ($operation.VpnQueue.Count -eq 0) { $operation.Phase = 'StartProbe' }
            }
            'StartProbe' {
                $timeout = [Math]::Max(1, [int]$script:Config.App.ConnectTimeoutSeconds)
                foreach ($hostEntry in $operation.Hosts) {
                    $port = Get-SSHManagerRdpPort $hostEntry
                    $operation.Probes[[string]$hostEntry.Id] = Start-SSHManagerTcpProbe -HostName ([string]$hostEntry.HostName) -Port $port -TimeoutSeconds $timeout
                    Set-RdpHostStatus ([string]$hostEntry.Id) 'Memeriksa…' '#38BDF8'
                }
                $first = $operation.Hosts[0]
                $label = if ($operation.Hosts.Count -eq 1) { '{0}:{1}' -f $first.HostName, (Get-SSHManagerRdpPort $first) } else { '{0} host' -f $operation.Hosts.Count }
                Set-Status ('Memeriksa RDP {0}...' -f $label) '#38BDF8'
                Update-RdpManagerGrid
                $operation.Phase = 'Probe'
            }
            'Probe' {
                $pending = 0
                foreach ($hostEntry in $operation.Hosts) {
                    $id = [string]$hostEntry.Id
                    if ($operation.Results.ContainsKey($id)) { continue }
                    $result = Get-SSHManagerTcpProbeResult -Probe $operation.Probes[$id]
                    if ($null -eq $result) { $pending++; continue }
                    $operation.Results[$id] = $result
                    if ($result.Success) { Set-RdpHostStatus $id ('Connected · {0} ms' -f $result.Milliseconds) '#34D399' }
                    else { Set-RdpHostStatus $id ('Gagal · {0}' -f $result.Message) '#F87171' }
                    Write-SSHManagerLog -Level $(if ($result.Success) { 'INFO' } else { 'WARN' }) -Component 'RDP' -Action 'Test' -HostName ('{0}:{1}' -f $hostEntry.HostName, (Get-SSHManagerRdpPort $hostEntry)) -Message ('{0} ({1} ms)' -f $result.Message, $result.Milliseconds)
                }
                if ($pending -gt 0) { break }
                Update-RdpManagerGrid
                if ($operation.Kind -eq 'Test') { Complete-RdpTest $operation; return }
                $operation.Phase = 'Launch'
            }
            'Launch' {
                Complete-RdpLaunch $operation
                return
            }
        }
        if ($null -ne $script:RdpState.Operation) { $script:RdpState.Timer.Start() }
    }
    catch {
        $failure = $_
        Complete-RdpOperation
        Set-Status 'RDP gagal — lihat log untuk detail.' '#EF4444'
        Show-AppError -Summary 'Operasi RDP tidak dapat diselesaikan.' -Detail $failure.Exception.Message -Component 'RDP' -Action ([string]$operation.Phase) -ErrorRecord $failure
    }
}

function Complete-RdpTest {
    param($Operation)
    $lines = New-Object 'Collections.Generic.List[string]'
    $okCount = 0
    foreach ($hostEntry in $Operation.Hosts) {
        $result = $Operation.Results[[string]$hostEntry.Id]
        $endpoint = '{0}:{1}' -f $hostEntry.HostName, (Get-SSHManagerRdpPort $hostEntry)
        if ($result.Success) { $okCount++; $lines.Add(('✓  {0}  {1}  Connected · Latency: {2} ms' -f $hostEntry.Name, $endpoint, $result.Milliseconds)) }
        else { $lines.Add(('✗  {0}  {1}  Connection failed · {2}' -f $hostEntry.Name, $endpoint, $result.Message)) }
    }
    $failed = $Operation.Hosts.Count - $okCount
    if ($Operation.Hosts.Count -eq 1) {
        $single = $Operation.Results[[string]$Operation.Hosts[0].Id]
        $endpoint = '{0}:{1}' -f $Operation.Hosts[0].HostName, (Get-SSHManagerRdpPort $Operation.Hosts[0])
        if ($single.Success) { Set-Status ('{0} Connected · Latency {1} ms' -f $endpoint, $single.Milliseconds) '#22C55E' }
        else { Set-Status ('RDP {0} — Connection failed · {1}' -f $endpoint, $single.Message) '#EF4444' }
    }
    else { Set-Status ('Test RDP selesai — {0} terhubung, {1} gagal.' -f $okCount, $failed) $(if ($failed -eq 0) { '#22C55E' } else { '#F59E0B' }) }
    Complete-RdpOperation
    Show-Info ($lines -join "`n") 'Hasil Test RDP'
}

function Complete-RdpLaunch {
    param($Operation)
    $reachable = @($Operation.Hosts | Where-Object { $Operation.Results[[string]$_.Id].Success })
    $unreachable = @($Operation.Hosts | Where-Object { -not $Operation.Results[[string]$_.Id].Success })
    $toLaunch = @($Operation.Hosts)
    if ($unreachable.Count -gt 0) {
        $details = ($unreachable | ForEach-Object { '{0}  {1}:{2}  {3}' -f $_.Name, $_.HostName, (Get-SSHManagerRdpPort $_), $Operation.Results[[string]$_.Id].Message }) -join "`n"
        $first = $Operation.Results[[string]$unreachable[0].Id]
        Set-Status ('RDP gagal — connection {0}.' -f ([string]$first.Message).ToLowerInvariant()) '#EF4444' $details
        $question = "Port RDP belum dapat dijangkau:`n`n{0}`n`nYes = tetap buka semua sesi RDP`nNo = buka hanya host yang terjangkau ({1})" -f $details, $reachable.Count
        $answer = [Windows.MessageBox]::Show($script:MainWindow, $question, 'RDP belum siap', [Windows.MessageBoxButton]::YesNoCancel, [Windows.MessageBoxImage]::Warning)
        if ($answer -eq [Windows.MessageBoxResult]::Cancel) { Complete-RdpOperation; Set-Status 'Pembukaan RDP dibatalkan.' '#F59E0B'; return }
        if ($answer -eq [Windows.MessageBoxResult]::No) { $toLaunch = $reachable }
        if ($toLaunch.Count -eq 0) { Complete-RdpOperation; Set-Status 'Tidak ada host RDP yang terjangkau.' '#EF4444' $details; return }
    }
    $rdpRoot = Join-Path $script:Paths.DataRoot 'rdp'
    $opened = 0
    $errors = New-Object 'Collections.Generic.List[string]'
    foreach ($hostEntry in $toLaunch) {
        $endpoint = '{0}:{1}' -f $hostEntry.HostName, (Get-SSHManagerRdpPort $hostEntry)
        try {
            Set-Status ('Membuka RDP {0}...' -f $hostEntry.Name) '#38BDF8'
            [void](Start-RdpConnection -HostName ([string]$hostEntry.HostName) -Port (Get-SSHManagerRdpPort $hostEntry) -Username ([string](Get-SSHManagerHostValue $hostEntry 'RdpUsername')) -Width ([int](Get-SSHManagerHostValue $hostEntry 'RdpWidth' 0)) -Height ([int](Get-SSHManagerHostValue $hostEntry 'RdpHeight' 0)) -Fullscreen:([bool](Get-SSHManagerHostValue $hostEntry 'RdpFullscreen' $true)) -Admin:([bool](Get-SSHManagerHostValue $hostEntry 'RdpAdmin' $false)) -MultiMonitor:([bool](Get-SSHManagerHostValue $hostEntry 'RdpMultiMonitor' $false)) -RdpFileRoot $rdpRoot -SessionName ([string]$hostEntry.Id))
            $hostEntry.LastConnectedAt = (Get-Date).ToString('o')
            Set-RdpHostStatus ([string]$hostEntry.Id) 'Sesi dibuka' '#34D399'
            Write-SSHManagerLog -Component 'RDP' -Action 'Launch' -HostName $endpoint -Message ('mstsc dibuka untuk {0}' -f $hostEntry.Name)
            $opened++
        }
        catch {
            $errors.Add(('{0}: {1}' -f $hostEntry.Name, $_.Exception.Message))
            Set-RdpHostStatus ([string]$hostEntry.Id) 'Gagal membuka mstsc' '#F87171'
            Write-SSHManagerLog -Level ERROR -Component 'RDP' -Action 'Launch' -HostName $endpoint -Message 'mstsc gagal dibuka' -ErrorRecord $_
        }
    }
    if ($opened -gt 0) { Save-CurrentConfig }
    Complete-RdpOperation
    if ($errors.Count -gt 0) {
        Set-Status ('RDP gagal dibuka untuk {0} host.' -f $errors.Count) '#EF4444' ($errors -join "`n")
        Show-AppError -Summary 'Tidak dapat membuka koneksi RDP.' -Detail ($errors -join "`n") -Component 'RDP' -Action 'Launch'
    }
    elseif ($opened -eq 1) { Set-Status ('Membuka RDP {0}.' -f $toLaunch[0].Name) '#22C55E' }
    else { Set-Status ('Membuka {0} sesi RDP.' -f $opened) '#22C55E' }
}
