function Get-WorkspaceGroupBrush {
    param([AllowEmptyString()][string]$Name)
    $palette=@('#174D7A','#5A3A81','#155E63','#6B4E22','#6C3348','#254F53')
    $value=0
    foreach ($character in $Name.ToLowerInvariant().ToCharArray()) { $value=($value*31+[int]$character)%997 }
    return $palette[$value%$palette.Count]
}

function Get-WorkspaceLayoutPreview {
    param(
        [ValidateSet('Single','TwoColumns','TwoRows','TopOneBottomTwo','TopTwoBottomOne','FourGrid')][string]$Layout='Single',
        [AllowEmptyCollection()][object[]]$Hosts=@()
    )
    $requestedCapacity=@{Single=1;TwoColumns=2;TwoRows=2;TopOneBottomTwo=3;TopTwoBottomOne=3;FourGrid=4}[$Layout]
    $effectiveLayout=$Layout
    # Match the launcher's partial-tab normalization; a single host is duplicated first.
    if ($Hosts.Count -gt 1 -and $Hosts.Count -lt $requestedCapacity) {
        $effectiveLayout=if ($Hosts.Count -eq 2) { 'TwoColumns' } else { 'TopOneBottomTwo' }
    }
    $rows=2; $columns=2
    $cells=@(switch ($effectiveLayout) {
        'Single' { $rows=1; $columns=1; ,@(0,0,1,1) }
        'TwoColumns' { $rows=1; ,@(0,0,1,1); ,@(0,1,1,1) }
        'TwoRows' { $columns=1; ,@(0,0,1,1); ,@(1,0,1,1) }
        'TopOneBottomTwo' { ,@(0,0,1,2); ,@(1,0,1,1); ,@(1,1,1,1) }
        'TopTwoBottomOne' { ,@(0,0,1,1); ,@(0,1,1,1); ,@(1,0,1,2) }
        'FourGrid' { ,@(0,0,1,1); ,@(0,1,1,1); ,@(1,0,1,1); ,@(1,1,1,1) }
    })
    $cellList=@($cells)
    $panes=for ($index=0; $index -lt $cellList.Count; $index++) {
        $entry=$null
        if ($Hosts.Count -eq 1) { $entry=$Hosts[0] }
        elseif ($index -lt $Hosts.Count) { $entry=$Hosts[$index] }
        $cell=$cellList[$index]
        [pscustomobject]@{
            Number=$index+1; Row=$cell[0]; Column=$cell[1]; RowSpan=$cell[2]; ColumnSpan=$cell[3]
            IsAssigned=($null -ne $entry)
            HostId=$(if ($entry) { [string]$entry.Id } else { '' })
            Name=$(if ($entry) { [string]$entry.Name } else { 'Belum ada host' })
            Endpoint=$(if ($entry) { '{0}@{1}:{2}' -f $entry.Username,$entry.HostName,$entry.Port } else { 'Pilih host pada Connections' })
        }
    }
    return [pscustomobject]@{Layout=$Layout;EffectiveLayout=$effectiveLayout;Rows=$rows;Columns=$columns;Capacity=$requestedCapacity;TabCount=[int][Math]::Ceiling($Hosts.Count/[double]$requestedCapacity);Panes=@($panes)}
}

function Get-WorkspaceTransferRows {
    param([Parameter(Mandatory=$true)]$Result)
    $sourceRows=if ($Result.PSObject.Properties.Name -contains 'Kind' -and $Result.Kind -eq 'ScpBatch') { @($Result.Results) }
        else { @([pscustomobject]@{HostName=$Result.HostName;State=$(if ($Result.Succeeded) {'Succeeded'} else {'Failed'});ItemCount=$Result.ItemCount;FileCount=$Result.FileCount;FolderCount=$Result.FolderCount;Message=$Result.Message}) }
    foreach ($row in $sourceRows) {
        $status='Menunggu';$color='#94A3B8'
        switch ([string]$row.State) {
            'Running' { $status='Berjalan';$color='#38BDF8' }
            'Succeeded' { $status='Selesai';$color='#34D399' }
            'Failed' { $status='Gagal';$color='#F87171' }
            'Interrupted' { $status='Terhenti';$color='#FBBF24' }
        }
        [pscustomobject]@{Name=[string]$row.HostName;Status=$status;Color=$color;IsRunning=($row.State -eq 'Running');Items=('{0} item' -f $row.ItemCount);Message=[string]$row.Message}
    }
}

function New-WorkspaceScpNodeRows {
    param([object[]]$Hosts=@(),[object[]]$SelectedHosts=@())
    $ids=New-Object 'Collections.Generic.HashSet[string]'
    foreach ($entry in $SelectedHosts) { [void]$ids.Add([string]$entry.Id) }
    foreach ($entry in @($Hosts | Sort-Object Name)) {
        [pscustomobject]@{Id=[string]$entry.Id;Name=[string]$entry.Name;HostName=[string]$entry.HostName;IsChecked=$ids.Contains([string]$entry.Id);Source=$entry}
    }
}

function Get-WorkspaceScpSelectedHosts {
    param([object[]]$Rows=@())
    foreach ($row in $Rows) { if ($row.IsChecked) { $row.Source } }
}
