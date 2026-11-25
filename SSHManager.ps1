[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Proper SSH Manager hanya dapat dijalankan di Windows.'
}

Add-Type -AssemblyName @('PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml')
Add-Type -AssemblyName System.Windows.Forms

$script:ApplicationRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:AppVersion = (Get-Content -LiteralPath (Join-Path $script:ApplicationRoot 'VERSION') -Raw -ErrorAction SilentlyContinue)
if ([string]::IsNullOrWhiteSpace($script:AppVersion)) { $script:AppVersion = '1.10.0' } else { $script:AppVersion = $script:AppVersion.Trim() }
Import-Module (Join-Path $script:ApplicationRoot 'Modules\SSHManager.Core.psm1') -Force
$script:Paths = Get-SSHManagerPaths -ApplicationRoot $script:ApplicationRoot
Initialize-SSHManagerData -Paths $script:Paths
[void](Initialize-SSHManagerLog -Paths $script:Paths)
$script:Config = Read-SSHManagerConfig -Paths $script:Paths
$script:IsRefreshing = $false
$script:CheckedHostIds = New-Object 'Collections.Generic.HashSet[string]'
$script:PendingScpStatusFiles = @{}
$script:ScpStatusTimer = $null
. (Join-Path $script:ApplicationRoot 'UI\WorkspaceModel.ps1')
. (Join-Path $script:ApplicationRoot 'UI\Workspace.ps1')
. (Join-Path $script:ApplicationRoot 'UI\RemoteEditor.ps1')
. (Join-Path $script:ApplicationRoot 'UI\RdpManager.ps1')

$createdNew = $false
$script:SingleInstanceMutex = New-Object Threading.Mutex($true, 'Local\ProperSSHManager.MainWindow', [ref]$createdNew)
if (-not $createdNew) {
    [Windows.MessageBox]::Show(
        'Proper SSH Manager sudah berjalan.',
        'Proper SSH Manager',
        [Windows.MessageBoxButton]::OK,
        [Windows.MessageBoxImage]::Information
    ) | Out-Null
    return
}

function Apply-DarkComboBoxTheme {
    param([Parameter(Mandatory = $true)]$Window)

    $brushConverter = New-Object Windows.Media.BrushConverter
    $window.Resources[([Windows.SystemColors]::WindowBrushKey)] = $brushConverter.ConvertFromString('#111827')
    $window.Resources[([Windows.SystemColors]::WindowTextBrushKey)] = $brushConverter.ConvertFromString('#E5E7EB')
    $window.Resources[([Windows.SystemColors]::ControlBrushKey)] = $brushConverter.ConvertFromString('#172033')
    $window.Resources[([Windows.SystemColors]::ControlTextBrushKey)] = $brushConverter.ConvertFromString('#F8FAFC')
    $window.Resources[([Windows.SystemColors]::HighlightBrushKey)] = $brushConverter.ConvertFromString('#2563EB')
    $window.Resources[([Windows.SystemColors]::HighlightTextBrushKey)] = $brushConverter.ConvertFromString('#FFFFFF')

    [xml]$itemStyleXaml = @'
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="{x:Type ComboBoxItem}">
 <Setter Property="Foreground" Value="#E5E7EB"/>
 <Setter Property="Background" Value="#111827"/>
 <Setter Property="Padding" Value="9,6"/>
 <Setter Property="MinHeight" Value="30"/>
 <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
 <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
 <Setter Property="Template">
  <Setter.Value>
   <ControlTemplate TargetType="{x:Type ComboBoxItem}">
    <Border x:Name="ItemBorder" Background="{TemplateBinding Background}" BorderBrush="#263348" BorderThickness="0,0,0,1" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
     <ContentPresenter ContentSource="Content" VerticalAlignment="Center" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" RecognizesAccessKey="True"/>
    </Border>
    <ControlTemplate.Triggers>
     <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ItemBorder" Property="Background" Value="#1E3A5F"/></Trigger>
     <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="ItemBorder" Property="Background" Value="#1D4ED8"/><Setter Property="Foreground" Value="#FFFFFF"/></Trigger>
     <Trigger Property="IsSelected" Value="True"><Setter TargetName="ItemBorder" Property="Background" Value="#2563EB"/><Setter Property="Foreground" Value="#FFFFFF"/></Trigger>
     <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="#64748B"/><Setter TargetName="ItemBorder" Property="Background" Value="#0F172A"/></Trigger>
    </ControlTemplate.Triggers>
   </ControlTemplate>
  </Setter.Value>
 </Setter>
</Style>
'@
    $styleReader = New-Object Xml.XmlNodeReader $itemStyleXaml
    try { $itemStyle = [Windows.Markup.XamlReader]::Load($styleReader) }
    finally { $styleReader.Close() }
    $window.Resources[([Windows.Controls.ComboBoxItem])] = $itemStyle

    [xml]$comboStyleXaml = @'
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="{x:Type ComboBox}">
 <Setter Property="Foreground" Value="#F8FAFC"/>
 <Setter Property="Background" Value="#172033"/>
 <Setter Property="BorderBrush" Value="#475569"/>
 <Setter Property="BorderThickness" Value="1"/>
 <Setter Property="Padding" Value="9,5"/>
 <Setter Property="MinHeight" Value="32"/>
 <Setter Property="MaxDropDownHeight" Value="320"/>
 <Setter Property="VerticalContentAlignment" Value="Center"/>
 <Setter Property="HorizontalContentAlignment" Value="Left"/>
 <Setter Property="ScrollViewer.CanContentScroll" Value="True"/>
 <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
 <Setter Property="ScrollViewer.VerticalScrollBarVisibility" Value="Auto"/>
 <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
 <Setter Property="Template">
  <Setter.Value>
   <ControlTemplate TargetType="{x:Type ComboBox}">
    <Grid SnapsToDevicePixels="True">
     <Border x:Name="FieldBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="2">
      <Grid>
       <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="32"/></Grid.ColumnDefinitions>
       <ContentPresenter x:Name="ContentSite" Grid.Column="0" Margin="{TemplateBinding Padding}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}" ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}" ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}" RecognizesAccessKey="True" SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}"/>
       <Border Grid.Column="1" BorderBrush="#334155" BorderThickness="1,0,0,0">
        <Path x:Name="Arrow" Data="M 0 0 L 4 4 L 8 0 Z" Fill="#CBD5E1" Stretch="None" HorizontalAlignment="Center" VerticalAlignment="Center"/>
       </Border>
      </Grid>
     </Border>
     <ToggleButton x:Name="DropDownToggle" Background="Transparent" BorderThickness="0" Focusable="False" ClickMode="Press" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
      <ToggleButton.Template><ControlTemplate TargetType="{x:Type ToggleButton}"><Border Background="{TemplateBinding Background}"/></ControlTemplate></ToggleButton.Template>
     </ToggleButton>
     <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
      <Grid x:Name="DropDown" MinWidth="{TemplateBinding ActualWidth}" MaxHeight="{TemplateBinding MaxDropDownHeight}" SnapsToDevicePixels="True">
       <Border Background="#111827" BorderBrush="#475569" BorderThickness="1" CornerRadius="2" Padding="1">
        <ScrollViewer CanContentScroll="True" SnapsToDevicePixels="True"><ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer>
       </Border>
      </Grid>
     </Popup>
    </Grid>
    <ControlTemplate.Triggers>
     <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="FieldBorder" Property="Background" Value="#1E293B"/><Setter TargetName="FieldBorder" Property="BorderBrush" Value="#64748B"/></Trigger>
     <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="FieldBorder" Property="BorderBrush" Value="#3B82F6"/></Trigger>
     <Trigger Property="IsDropDownOpen" Value="True"><Setter TargetName="FieldBorder" Property="Background" Value="#1E293B"/><Setter TargetName="Arrow" Property="Fill" Value="#60A5FA"/></Trigger>
     <Trigger Property="IsEnabled" Value="False"><Setter TargetName="FieldBorder" Property="Background" Value="#0F172A"/><Setter TargetName="FieldBorder" Property="BorderBrush" Value="#263348"/><Setter TargetName="Arrow" Property="Fill" Value="#475569"/><Setter Property="Foreground" Value="#64748B"/></Trigger>
    </ControlTemplate.Triggers>
   </ControlTemplate>
  </Setter.Value>
 </Setter>
</Style>
'@
    $comboStyleReader = New-Object Xml.XmlNodeReader $comboStyleXaml
    try { $comboStyle = [Windows.Markup.XamlReader]::Load($comboStyleReader) }
    finally { $comboStyleReader.Close() }
    $window.Resources[([Windows.Controls.ComboBox])] = $comboStyle

    $queue = New-Object Collections.Queue
    $queue.Enqueue($Window)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if ($current -is [Windows.Controls.ComboBox]) {
            $current.Style = $comboStyle
            $current.ItemContainerStyle = $itemStyle
        }
        elseif ($current -is [Windows.Controls.ComboBoxItem]) {
            $current.Style = $itemStyle
        }
        if ($current -is [Windows.DependencyObject]) {
            foreach ($child in @([Windows.LogicalTreeHelper]::GetChildren($current))) {
                if ($child -is [Windows.DependencyObject]) { $queue.Enqueue($child) }
            }
        }
    }
}

function Read-XamlWindow {
    param([Parameter(Mandatory = $true)][string]$Xaml)

    [xml]$xml = $Xaml
    Add-WorkspaceResourceReference $xml
    $reader = New-Object Xml.XmlNodeReader $xml
    try {
        $window = [Windows.Markup.XamlReader]::Load($reader)
        Apply-WorkspaceTheme -Window $window
        Apply-DarkComboBoxTheme -Window $window
        return $window
    }
    finally { $reader.Close() }
}

function Get-NamedControl {
    param($Window, [string]$Name)
    $control = $Window.FindName($Name)
    if ($null -eq $control) { throw "Kontrol UI '$Name' tidak ditemukan." }
    return $control
}

function Show-Info {
    param([string]$Message, [string]$Title = 'Proper SSH Manager')
    [Windows.MessageBox]::Show($script:MainWindow, $Message, $Title, [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information) | Out-Null
}

function Show-Warning {
    param([string]$Message, [string]$Title = 'Proper SSH Manager')
    [Windows.MessageBox]::Show($script:MainWindow, $Message, $Title, [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Warning) | Out-Null
}

function Show-ErrorMessage {
    param([string]$Message, [string]$Title = 'Proper SSH Manager')
    [Windows.MessageBox]::Show($script:MainWindow, $Message, $Title, [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Error) | Out-Null
}

function Confirm-Action {
    param([string]$Message, [string]$Title = 'Konfirmasi')
    return [Windows.MessageBox]::Show($script:MainWindow, $Message, $Title, [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question) -eq [Windows.MessageBoxResult]::Yes
}

function Show-AppError {
    param(
        [string]$Summary = 'Terjadi kesalahan.',
        [string]$Detail = '',
        [string]$Component = 'App',
        [string]$Action = '',
        [string]$HostName = '',
        $ErrorRecord = $null,
        [string]$Title = 'Proper SSH Manager'
    )
    # Users get a short explanation; the technical exception goes only to logs\ProperSSHManager.log.
    Write-SSHManagerLog -Level ERROR -Component $Component -Action $Action -HostName $HostName -Message ('{0} {1}' -f $Summary, $Detail).Trim() -ErrorRecord $ErrorRecord
    $text = if ([string]::IsNullOrWhiteSpace($Detail)) { $Summary } else { "{0}`n`nDetail:`n{1}" -f $Summary, $Detail }
    $logFile = Get-SSHManagerLogFile
    if ($logFile) { $text += "`n`nLog teknis: $logFile" }
    if ($null -ne $script:MainWindow -and $script:MainWindow.IsVisible) {
        [Windows.MessageBox]::Show($script:MainWindow, $text, $Title, [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Error) | Out-Null
    }
    else { [Windows.MessageBox]::Show($text, $Title, [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Error) | Out-Null }
}

function Set-Status {
    param([string]$Text, [string]$Color = '#94A3B8', [string]$Details = '')
    $script:StatusText.Text = $Text
    $script:StatusText.ToolTip = if ($Details) { $Details } else { $Text }
    $script:StatusText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    [Windows.Forms.Application]::DoEvents()
}

function New-ConnectionProgressWindow {
    param(
        [string]$Stage = 'Menyiapkan koneksi...',
        [string]$Detail = ''
    )

    $progressWindow = Read-XamlWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Status koneksi" Width="500" Height="235" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#0B1220" Foreground="#E5E7EB" ShowInTaskbar="False">
 <Window.Resources><Style TargetType="TextBlock"><Setter Property="Foreground" Value="#E5E7EB"/></Style></Window.Resources>
 <Grid Margin="22">
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <TextBlock Text="Menghubungkan" FontSize="23" FontWeight="SemiBold"/>
  <StackPanel Grid.Row="1" Margin="0,16,0,12">
   <TextBlock x:Name="StageText" FontSize="16" FontWeight="SemiBold" Foreground="#38BDF8" TextWrapping="Wrap"/>
   <TextBlock x:Name="DetailText" Foreground="#94A3B8" Margin="0,5,0,0" TextWrapping="Wrap"/>
  </StackPanel>
  <ProgressBar Grid.Row="2" Height="8" IsIndeterminate="True" Foreground="#22C55E" Background="#172033"/>
  <TextBlock x:Name="ElapsedText" Grid.Row="3" Text="Menunggu respons..." Foreground="#CBD5E1" Margin="0,12,0,0"/>
 </Grid>
</Window>
'@
    $progressWindow.Owner = $script:MainWindow
    (Get-NamedControl $progressWindow 'StageText').Text = $Stage
    (Get-NamedControl $progressWindow 'DetailText').Text = $Detail
    $progressWindow.Show()
    [void]$progressWindow.Activate()
    [Windows.Forms.Application]::DoEvents()
    return $progressWindow
}

function Update-ConnectionProgressWindow {
    param(
        $Window,
        [string]$Stage,
        [string]$Detail,
        [long]$ElapsedMilliseconds = 0,
        [int]$TimeoutSeconds = 0
    )

    if ($null -eq $Window -or -not $Window.IsVisible) { return }
    (Get-NamedControl $Window 'StageText').Text = $Stage
    (Get-NamedControl $Window 'DetailText').Text = $Detail
    if ($TimeoutSeconds -gt 0) {
        $elapsedSeconds = [Math]::Min([double]$TimeoutSeconds, [Math]::Max(0, $ElapsedMilliseconds) / 1000.0)
        (Get-NamedControl $Window 'ElapsedText').Text = ('Menunggu respons... {0:0.0} / {1} detik' -f $elapsedSeconds, $TimeoutSeconds)
        Set-Status ('{0} — {1:0.0}/{2} detik' -f $Stage, $elapsedSeconds, $TimeoutSeconds) '#38BDF8'
    }
    else {
        (Get-NamedControl $Window 'ElapsedText').Text = 'Sedang diproses...'
        Set-Status $Stage '#38BDF8'
    }
    [Windows.Forms.Application]::DoEvents()
}

function Close-ConnectionProgressWindow {
    param($Window)
    if ($null -eq $Window) { return }
    try {
        if ($Window.IsVisible) { $Window.Close() }
    }
    catch { }
    [Windows.Forms.Application]::DoEvents()
}

function Show-ConnectionFailureDialog {
    param([Parameter(Mandatory = $true)][object[]]$Failures)

    $failureWindow = Read-XamlWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Koneksi SSH belum siap" Width="640" Height="430" MinWidth="560" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#0B1220" Foreground="#E5E7EB" ShowInTaskbar="False">
 <Window.Resources>
  <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#E5E7EB"/></Style>
  <Style TargetType="Button"><Setter Property="Foreground" Value="#E5E7EB"/><Setter Property="Background" Value="#263348"/><Setter Property="BorderBrush" Value="#475569"/><Setter Property="Padding" Value="16,9"/><Setter Property="Margin" Value="5,0,0,0"/></Style>
 </Window.Resources>
 <Grid Margin="22">
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <TextBlock Text="Koneksi SSH belum siap" FontSize="23" FontWeight="SemiBold"/>
  <TextBlock Grid.Row="1" Text="Tes port TCP belum berhasil. Periksa endpoint dan penyebab berikut:" Foreground="#FBBF24" Margin="0,8,0,12" TextWrapping="Wrap"/>
  <Border Grid.Row="2" Background="#0F172A" BorderBrush="#334155" BorderThickness="1" CornerRadius="4" Padding="13">
   <ScrollViewer VerticalScrollBarVisibility="Auto"><TextBlock x:Name="FailureDetailsText" FontFamily="Consolas" FontSize="13" LineHeight="20" TextWrapping="Wrap"/></ScrollViewer>
  </Border>
  <TextBlock Grid.Row="3" Text="Coba lagi hanya menguji host yang gagal. Tetap buka SSH akan membuka terminal meskipun port belum terjangkau." Foreground="#94A3B8" Margin="0,12,0,14" TextWrapping="Wrap"/>
  <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
   <Button x:Name="CancelButton" Content="Batal" IsCancel="True"/>
   <Button x:Name="RetryButton" Content="Coba lagi" Background="#2563EB" BorderBrush="#3B82F6" IsDefault="True"/>
   <Button x:Name="ContinueButton" Content="Tetap buka SSH" Background="#B45309" BorderBrush="#F59E0B"/>
  </StackPanel>
 </Grid>
</Window>
'@
    $failureWindow.Owner = $script:MainWindow
    $detailLines = New-Object 'Collections.Generic.List[string]'
    foreach ($failure in $Failures) {
        $hostEntry = $failure.Host
        $detailLines.Add(('{0}' -f [string]$hostEntry.Name))
        $detailLines.Add(('  Endpoint : {0}@{1}:{2}' -f $hostEntry.Username, $hostEntry.HostName, $hostEntry.Port))
        $detailLines.Add(('  Penyebab : {0}' -f [string]$failure.Message))
        $detailLines.Add('')
    }
    (Get-NamedControl $failureWindow 'FailureDetailsText').Text = ($detailLines -join "`n").TrimEnd()
    $failureWindow.Tag = 'Cancel'
    (Get-NamedControl $failureWindow 'RetryButton').Add_Click({ $failureWindow.Tag = 'Retry'; $failureWindow.DialogResult = $true })
    (Get-NamedControl $failureWindow 'ContinueButton').Add_Click({ $failureWindow.Tag = 'Continue'; $failureWindow.DialogResult = $true })
    [void]$failureWindow.ShowDialog()
    return [string]$failureWindow.Tag
}

function Format-ScpItemSummary {
    param(
        [int]$FileCount,
        [int]$FolderCount,
        [int]$ItemCount
    )

    $parts = New-Object 'Collections.Generic.List[string]'
    if ($FileCount -gt 0) { $parts.Add(('{0} file' -f $FileCount)) }
    if ($FolderCount -gt 0) { $parts.Add(('{0} folder' -f $FolderCount)) }
    if ($parts.Count -gt 0) { return ($parts -join ' dan ') }
    return ('{0} item' -f [Math]::Max(0, $ItemCount))
}

function Register-ScpStatusFile {
    param([Parameter(Mandatory = $true)][string]$StatusFile)
    $script:PendingScpStatusFiles[$StatusFile] = (Get-Date)
}

function Update-PendingScpStatus {
    foreach ($statusFile in @($script:PendingScpStatusFiles.Keys)) {
        if (-not (Test-Path -LiteralPath $statusFile -PathType Leaf)) { continue }

        try {
            $result = Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($result.PSObject.Properties.Name -contains 'Kind' -and $result.Kind -eq 'ScpBatch') {
                if (-not $result.IsComplete) {
                    $runtimeMissing = $false
                    if ([int]$result.ProcessId -gt 0) {
                        $runtimeProcess = Get-Process -Id ([int]$result.ProcessId) -ErrorAction SilentlyContinue
                        $runtimeMissing = ($null -eq $runtimeProcess)
                        if (-not $runtimeMissing -and $result.ProcessStartedAt -and $runtimeProcess.StartTime) {
                            $runtimeMissing = ($runtimeProcess.StartTime.ToUniversalTime().Ticks -ne ([datetime]$result.ProcessStartedAt).ToUniversalTime().Ticks)
                        }
                    }
                    elseif (((Get-Date) - [datetime]$result.StartedAt).TotalSeconds -gt 120) { $runtimeMissing = $true }
                    if ($runtimeMissing) {
                        foreach ($row in $result.Results) {
                            if ($row.State -in @('Pending','Running')) {
                                $row.State = 'Interrupted'; $row.Message = 'Tab SCP ditutup atau runtime tidak berjalan.'; $result.FailedCount++
                            }
                        }
                        $result.IsComplete = $true; $result.Succeeded = $false
                        $result.FinishedAt = (Get-Date).ToString('o')
                        $interruptedLog = Join-Path $script:Paths.LogsRoot ('scp-batch-{0}.json' -f $result.BatchId)
                        Write-SSHManagerScpBatchStatus -Result $result -StatusFile $interruptedLog
                    }
                }
                if (Get-Command Update-WorkspaceTransferActivity -ErrorAction SilentlyContinue) { Update-WorkspaceTransferActivity -Result $result -StatusFile $statusFile }
                $batchSummary = Get-SSHManagerScpBatchStatusText -Result $result
                if ($result.IsComplete) {
                    Remove-Item -LiteralPath $statusFile -Force -ErrorAction SilentlyContinue
                    [void]$script:PendingScpStatusFiles.Remove($statusFile)
                }
                Set-Status $batchSummary.Text $batchSummary.Color $batchSummary.Details
                continue
            }
            if (Get-Command Update-WorkspaceTransferActivity -ErrorAction SilentlyContinue) { Update-WorkspaceTransferActivity -Result $result -StatusFile $statusFile }
            $itemSummary = Format-ScpItemSummary -FileCount ([int]$result.FileCount) -FolderCount ([int]$result.FolderCount) -ItemCount ([int]$result.ItemCount)
            $direction = [string]$result.Direction
            $hostName = [string]$result.HostName
            $relation = if ($direction -eq 'Upload') { 'ke' } else { 'dari' }

            if ([bool]$result.Succeeded) {
                $statusText = "Selesai SCP {0}: {1} {2} host {3}." -f $direction, $itemSummary, $relation, $hostName
                $statusColor = '#22C55E'
            }
            else {
                $errorDetail = [string]$result.Message
                if ([string]::IsNullOrWhiteSpace($errorDetail)) { $errorDetail = 'Transfer tidak selesai.' }
                $statusText = "SCP {0} gagal: {1} {2} host {3}. {4}" -f $direction, $itemSummary, $relation, $hostName, $errorDetail
                $statusColor = '#EF4444'
            }

            Remove-Item -LiteralPath $statusFile -Force -ErrorAction SilentlyContinue
            [void]$script:PendingScpStatusFiles.Remove($statusFile)
            Set-Status $statusText $statusColor
        }
        catch {
            # File ditulis secara atomik oleh runtime. Jika pembacaan sesaat gagal,
            # timer akan mencoba kembali tanpa mengganggu UI manager.
        }
    }
}

function Save-CurrentConfig {
    Save-SSHManagerConfig -Config $script:Config -Paths $script:Paths
}

function Get-VpnById {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    $matches = @($script:Config.VpnProfiles | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Get-AuthDisplay {
    param([string]$AuthType)
    switch ($AuthType) {
        'PrivateKey' { 'Private key' }
        'Agent' { 'SSH agent' }
        default { 'Password' }
    }
}

function Get-VpnDisplay {
    param([string]$VpnProfileId)
    if ([string]::IsNullOrWhiteSpace($VpnProfileId)) { return 'Tanpa VPN' }
    $profile = Get-VpnById $VpnProfileId
    if ($null -eq $profile) { return 'Profil hilang' }
    return [string]$profile.Name
}

function Refresh-GroupFilter {
    $selected = [string]$script:GroupFilter.SelectedItem
    $groups = @('Semua group') + @($script:Config.Hosts | ForEach-Object { [string]$_.Group } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $script:GroupFilter.ItemsSource = $groups
    if ($groups -contains $selected) { $script:GroupFilter.SelectedItem = $selected }
    else { $script:GroupFilter.SelectedIndex = 0 }
}

function Refresh-VpnOverride {
    $selected = [string]$script:VpnOverride.SelectedValue
    $items = @(
        [pscustomobject]@{ Id = '__HOST__'; Name = 'Ikuti konfigurasi setiap host' },
        [pscustomobject]@{ Id = '__NONE__'; Name = 'Tanpa VPN untuk semua host' }
    ) + @($script:Config.VpnProfiles | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ Id = [string]$_.Id; Name = "Paksa VPN: $($_.Name)" }
    })
    $script:VpnOverride.ItemsSource = $items
    if (@($items.Id) -contains $selected) { $script:VpnOverride.SelectedValue = $selected }
    else { $script:VpnOverride.SelectedValue = '__HOST__' }
}

function Get-HostPortDisplay {
    param($HostEntry)
    $parts = @()
    if (Test-SSHManagerSshEnabled $HostEntry) { $parts += [string][int]$HostEntry.Port }
    if (Test-SSHManagerRdpEnabled $HostEntry) { $parts += [string](Get-SSHManagerRdpPort $HostEntry) }
    if ($parts.Count -eq 0) { return '—' }
    return $parts -join ' / '
}

function Get-HostProtocolDisplay {
    param($HostEntry)
    $parts = @()
    if (Test-SSHManagerSshEnabled $HostEntry) { $parts += ('SSH  {0}@{1}:{2}' -f $HostEntry.Username, $HostEntry.HostName, $HostEntry.Port) }
    if (Test-SSHManagerRdpEnabled $HostEntry) {
        $rdpUserName = [string](Get-SSHManagerHostValue $HostEntry 'RdpUsername')
        $rdpUser = if ([string]::IsNullOrWhiteSpace($rdpUserName)) { '' } else { '{0}@' -f $rdpUserName }
        $parts += ('RDP  {0}{1}:{2}' -f $rdpUser, $HostEntry.HostName, (Get-SSHManagerRdpPort $HostEntry))
    }
    if ($parts.Count -eq 0) { return '—' }
    return $parts -join "`n"
}

function Refresh-HostGrid {
    $script:IsRefreshing = $true
    try {
        $query = $script:SearchBox.Text.Trim().ToLowerInvariant()
        $group = [string]$script:GroupFilter.SelectedItem
        $sortProperties = @(
            @{ Expression = 'Favorite'; Descending = $true }
            'Group'
            'Name'
        )
        $sortedHosts = @($script:Config.Hosts | Sort-Object -Property $sortProperties)
        $rows = foreach ($hostEntry in $sortedHosts) {
            if ($group -and $group -ne 'Semua group' -and $hostEntry.Group -ne $group) { continue }

            $haystackParts = @($hostEntry.Name, $hostEntry.Group, $hostEntry.HostName, $hostEntry.Username, (Get-SSHManagerHostValue $hostEntry 'RdpUsername'), $hostEntry.Tags)
            if ([bool]$script:Config.App.SearchIncludesNotes) { $haystackParts += $hostEntry.Notes }
            $haystack = ($haystackParts -join ' ').ToLowerInvariant()
            if ($query.Length -gt 0 -and -not $haystack.Contains($query)) { continue }

            [pscustomobject]@{
                Id         = [string]$hostEntry.Id
                IsChecked  = $script:CheckedHostIds.Contains([string]$hostEntry.Id)
                Favorite   = [bool]$hostEntry.Favorite
                FavoriteMark = if ([bool]$hostEntry.Favorite) { '★' } else { '' }
                Name       = [string]$hostEntry.Name
                Group      = [string]$hostEntry.Group
                GroupLabel = if ([string]::IsNullOrWhiteSpace([string]$hostEntry.Group)) { 'Default' } else { [string]$hostEntry.Group }
                GroupBrush = Get-WorkspaceGroupBrush -Name ([string]$hostEntry.Group)
                HostName   = [string]$hostEntry.HostName
                Username   = [string]$hostEntry.Username
                Port       = [int]$hostEntry.Port
                PortDisplay = Get-HostPortDisplay $hostEntry
                SshVisibility = if (Test-SSHManagerSshEnabled $hostEntry) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
                RdpVisibility = if (Test-SSHManagerRdpEnabled $hostEntry) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
                AuthDisplay = Get-AuthDisplay $hostEntry.AuthType
                VpnDisplay  = Get-VpnDisplay $hostEntry.VpnProfileId
                Source      = $hostEntry
            }
        }
        $script:HostGrid.ItemsSource = @($rows)
        $script:CountText.Text = ('{0} dari {1} host' -f @($rows).Count, @($script:Config.Hosts).Count)
        Update-HostDetails
    }
    finally { $script:IsRefreshing = $false }
    Update-WorkspaceSelection
}

function Refresh-AllViews {
    $script:IsRefreshing = $true
    try {
        Refresh-GroupFilter
        Refresh-VpnOverride
        $layout = [string]$script:Config.App.DefaultLayout
        $script:LayoutCombo.SelectedValue = $layout
        if ($script:LayoutCombo.SelectedIndex -lt 0) { $script:LayoutCombo.SelectedIndex = 0 }
    }
    finally { $script:IsRefreshing = $false }
    Refresh-HostGrid
    Update-RdpManagerView
}

function Get-SelectedHostEntries {
    $checkedRows = @($script:HostGrid.ItemsSource | Where-Object { [bool]$_.IsChecked })
    if ($checkedRows.Count -gt 0) {
        return @($checkedRows | ForEach-Object { $_.Source })
    }
    return @($script:HostGrid.SelectedItems | ForEach-Object { $_.Source })
}

function Get-PrimarySelectedHost {
    $selected = @(Get-SelectedHostEntries)
    if ($selected.Count -eq 0) { return $null }
    return $selected[0]
}

function Update-HostDetails {
    if ($null -eq $script:HostGrid) { return }
    $hostEntry = Get-PrimarySelectedHost
    if ($null -eq $hostEntry) {
        $script:DetailName.Text = 'Pilih sebuah host'
        $script:DetailEndpoint.Text = '—'
        $script:DetailProtocols.Text = '—'
        $script:DetailGroup.Text = '—'
        $script:DetailAuth.Text = '—'
        $script:DetailVpn.Text = '—'
        $script:DetailTags.Text = '—'
        $script:DetailNotes.Text = '—'
        return
    }
    $script:DetailName.Text = [string]$hostEntry.Name
    $script:DetailEndpoint.Text = if (Test-SSHManagerSshEnabled $hostEntry) { '{0}@{1}:{2}' -f $hostEntry.Username, $hostEntry.HostName, $hostEntry.Port } else { '{0}:{1}' -f $hostEntry.HostName, (Get-SSHManagerRdpPort $hostEntry) }
    $script:DetailProtocols.Text = Get-HostProtocolDisplay $hostEntry
    $script:DetailGroup.Text = if ([string]::IsNullOrWhiteSpace([string]$hostEntry.Group)) { 'Default' } else { [string]$hostEntry.Group }
    $script:DetailAuth.Text = Get-AuthDisplay $hostEntry.AuthType
    $script:DetailVpn.Text = Get-VpnDisplay $hostEntry.VpnProfileId
    $script:DetailTags.Text = if ([string]::IsNullOrWhiteSpace([string]$hostEntry.Tags)) { '—' } else { [string]$hostEntry.Tags }
    $script:DetailNotes.Text = if ([string]::IsNullOrWhiteSpace([string]$hostEntry.Notes)) { '—' } else { [string]$hostEntry.Notes }
}

function Show-HostEditor {
    param($Existing, [switch]$AsCopy, [switch]$RdpDefault)

    $dialog = Read-XamlWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="Host" Width="680" Height="800" MinHeight="650" WindowStartupLocation="CenterOwner" ResizeMode="CanResize"
 Background="#0B1220" Foreground="#E5E7EB" ShowInTaskbar="False">
 <Window.Resources>
  <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#E5E7EB"/></Style>
  <Style TargetType="Label"><Setter Property="Foreground" Value="#CBD5E1"/><Setter Property="Padding" Value="0,7,0,3"/></Style>
  <Style TargetType="TextBox"><Setter Property="Foreground" Value="#F8FAFC"/><Setter Property="Background" Value="#0F172A"/><Setter Property="BorderBrush" Value="#334155"/><Setter Property="Padding" Value="8,6"/></Style>
  <Style TargetType="PasswordBox"><Setter Property="Foreground" Value="#F8FAFC"/><Setter Property="Background" Value="#0F172A"/><Setter Property="BorderBrush" Value="#334155"/><Setter Property="Padding" Value="8,6"/></Style>
  <Style TargetType="ComboBox"><Setter Property="Foreground" Value="#F8FAFC"/><Setter Property="Background" Value="#172033"/><Setter Property="BorderBrush" Value="#475569"/><Setter Property="Padding" Value="6,4"/></Style>
  <Style TargetType="Button"><Setter Property="Foreground" Value="#E5E7EB"/><Setter Property="Background" Value="#263348"/><Setter Property="BorderBrush" Value="#34445D"/><Setter Property="Padding" Value="14,8"/><Setter Property="Margin" Value="4"/></Style>
 </Window.Resources>
 <DockPanel Margin="18">
  <StackPanel DockPanel.Dock="Top" Margin="0,0,0,12">
   <TextBlock x:Name="TitleText" Text="Tambah host" FontSize="23" FontWeight="SemiBold"/>
   <TextBlock Text="Password SSH dienkripsi DPAPI; credential RDP disimpan di Windows Credential Manager." Foreground="#94A3B8" Margin="0,4,0,0" TextWrapping="Wrap"/>
  </StackPanel>
  <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
   <Button x:Name="CancelButton" Content="Batal" IsCancel="True"/>
   <Button x:Name="SaveButton" Content="Simpan host" Background="#16A34A" BorderBrush="#22C55E" IsDefault="True"/>
  </StackPanel>
  <ScrollViewer VerticalScrollBarVisibility="Auto">
   <StackPanel Margin="0,0,8,0">
    <Grid>
     <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="16"/><ColumnDefinition/></Grid.ColumnDefinitions>
     <StackPanel><Label Content="Nama host *"/><TextBox x:Name="NameBox"/></StackPanel>
     <StackPanel Grid.Column="2"><Label Content="Group"/><TextBox x:Name="GroupBox"/></StackPanel>
    </Grid>
    <Label Content="IP / hostname *"/><TextBox x:Name="HostBox"/>
    <Label Content="Connection Type"/>
    <StackPanel Orientation="Horizontal"><CheckBox x:Name="SshEnabledBox" Content="SSH" Foreground="#E5E7EB"/><CheckBox x:Name="RdpEnabledBox" Content="RDP" Foreground="#E5E7EB" Margin="22,0,0,0"/></StackPanel>
    <Border x:Name="SshSection" Background="#111827" BorderBrush="#263348" BorderThickness="1" CornerRadius="4" Padding="12" Margin="0,12,0,0"><StackPanel>
     <TextBlock Text="SSH" FontWeight="SemiBold"/>
     <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="100"/><ColumnDefinition Width="16"/><ColumnDefinition/><ColumnDefinition Width="16"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <StackPanel><Label Content="SSH Port *"/><TextBox x:Name="PortBox"/></StackPanel>
      <StackPanel Grid.Column="2"><Label Content="SSH Username *"/><TextBox x:Name="UsernameBox"/></StackPanel>
      <StackPanel Grid.Column="4"><Label Content="Autentikasi"/><ComboBox x:Name="AuthCombo" DisplayMemberPath="Name" SelectedValuePath="Id"/></StackPanel>
     </Grid>
     <Label Content="Password SSH"/>
     <PasswordBox x:Name="PasswordBox"/>
     <TextBlock x:Name="PasswordHint" Text="Untuk host baru dengan autentikasi password, field ini wajib diisi." Foreground="#94A3B8" FontSize="11" Margin="0,4,0,0" TextWrapping="Wrap"/>
     <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel><Label Content="Path private key"/><TextBox x:Name="KeyPathBox"/></StackPanel>
      <Button x:Name="BrowseKeyButton" Grid.Column="1" Content="Pilih..." VerticalAlignment="Bottom" Margin="8,0,0,0"/>
     </Grid>
     <Label Content="Kebijakan host key"/><ComboBox x:Name="HostKeyCombo" DisplayMemberPath="Name" SelectedValuePath="Id"/>
     <Label Content="Jump host / bastion (-J), opsional"/><TextBox x:Name="JumpHostBox" ToolTip="Contoh: mme@10.10.10.1:22"/>
     <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="16"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <StackPanel><Label Content="Keep-alive interval (detik)"/><TextBox x:Name="KeepAliveBox"/></StackPanel>
      <StackPanel Grid.Column="2"><Label Content="Maksimum missed keep-alive"/><TextBox x:Name="KeepAliveMaxBox"/></StackPanel>
     </Grid>
    </StackPanel></Border>
    <Border x:Name="RdpSection" Background="#111827" BorderBrush="#263348" BorderThickness="1" CornerRadius="4" Padding="12" Margin="0,12,0,0"><StackPanel>
     <TextBlock Text="RDP (Remote Desktop)" FontWeight="SemiBold"/>
     <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="100"/><ColumnDefinition Width="16"/><ColumnDefinition/><ColumnDefinition Width="16"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <StackPanel><Label Content="RDP Port *"/><TextBox x:Name="RdpPortBox"/></StackPanel>
      <StackPanel Grid.Column="2"><Label Content="RDP Username (opsional)"/><TextBox x:Name="RdpUsernameBox" ToolTip="Contoh: DOMAIN\user atau .\Administrator"/></StackPanel>
      <StackPanel Grid.Column="4"><Label Content="Password RDP (opsional)"/><PasswordBox x:Name="RdpPasswordBox"/></StackPanel>
     </Grid>
     <TextBlock x:Name="RdpPasswordHint" Text="Password RDP disimpan di Windows Credential Manager (TERMSRV/host), tidak di file konfigurasi. Kosongkan agar Windows meminta password saat connect." Foreground="#94A3B8" FontSize="11" Margin="0,4,0,0" TextWrapping="Wrap"/>
     <WrapPanel Margin="0,10,0,0"><CheckBox x:Name="RdpFullscreenBox" Content="Fullscreen" Foreground="#E5E7EB" Margin="0,0,18,6"/><CheckBox x:Name="RdpMultiMonitorBox" Content="Multi monitor" Foreground="#E5E7EB" Margin="0,0,18,6"/><CheckBox x:Name="RdpAdminBox" Content="Admin session (/admin)" Foreground="#E5E7EB" Margin="0,0,18,6"/></WrapPanel>
     <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="16"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <StackPanel><Label Content="Lebar resolusi (0 = default)"/><TextBox x:Name="RdpWidthBox"/></StackPanel>
      <StackPanel Grid.Column="2"><Label Content="Tinggi resolusi (0 = default)"/><TextBox x:Name="RdpHeightBox"/></StackPanel>
     </Grid>
    </StackPanel></Border>
    <Label Content="Profil VPN"/><ComboBox x:Name="VpnCombo" DisplayMemberPath="Name" SelectedValuePath="Id"/>
    <Label Content="Tags (pisahkan dengan koma)"/><TextBox x:Name="TagsBox"/>
    <Label Content="Catatan"/><TextBox x:Name="NotesBox" AcceptsReturn="True" Height="75" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
    <CheckBox x:Name="FavoriteBox" Content="Tandai sebagai favorit" Foreground="#E5E7EB" Margin="0,12,0,0"/>
   </StackPanel>
  </ScrollViewer>
 </DockPanel>
</Window>
'@
    $dialog.Owner = $script:MainWindow
    $controls = @{}
    foreach ($name in @('TitleText','NameBox','GroupBox','HostBox','SshEnabledBox','RdpEnabledBox','SshSection','RdpSection','PortBox','UsernameBox','AuthCombo','PasswordBox','PasswordHint','KeyPathBox','BrowseKeyButton','VpnCombo','HostKeyCombo','JumpHostBox','KeepAliveBox','KeepAliveMaxBox','RdpPortBox','RdpUsernameBox','RdpPasswordBox','RdpPasswordHint','RdpFullscreenBox','RdpMultiMonitorBox','RdpAdminBox','RdpWidthBox','RdpHeightBox','TagsBox','NotesBox','FavoriteBox','SaveButton')) {
        $controls[$name] = Get-NamedControl $dialog $name
    }

    $controls.AuthCombo.ItemsSource = @(
        [pscustomobject]@{ Id='Password'; Name='Password otomatis' },
        [pscustomobject]@{ Id='PrivateKey'; Name='Private key' },
        [pscustomobject]@{ Id='Agent'; Name='SSH agent' }
    )
    $controls.VpnCombo.ItemsSource = @([pscustomobject]@{ Id=''; Name='Tanpa VPN' }) + @($script:Config.VpnProfiles | Sort-Object Name | ForEach-Object { [pscustomobject]@{ Id=$_.Id; Name=$_.Name } })
    $controls.HostKeyCombo.ItemsSource = @(
        [pscustomobject]@{ Id='AcceptNew'; Name='Terima host baru, tolak perubahan' },
        [pscustomobject]@{ Id='Ask'; Name='Tanya saat host baru' },
        [pscustomobject]@{ Id='Strict'; Name='Hanya host yang sudah dikenal' }
    )

    if ($null -ne $Existing) {
        $controls.TitleText.Text = if ($AsCopy) { 'Duplikat host' } else { 'Edit host' }
        $controls.NameBox.Text = if ($AsCopy) { Get-SSHManagerCopyName -Name ([string]$Existing.Name) -ExistingNames ([string[]]@($script:Config.Hosts | ForEach-Object { [string]$_.Name })) } else { [string]$Existing.Name }
        $controls.GroupBox.Text = [string]$Existing.Group
        $controls.HostBox.Text = [string]$Existing.HostName
        $controls.SshEnabledBox.IsChecked = Test-SSHManagerSshEnabled $Existing
        $controls.RdpEnabledBox.IsChecked = Test-SSHManagerRdpEnabled $Existing
        $controls.PortBox.Text = [string]$Existing.Port
        $controls.UsernameBox.Text = [string]$Existing.Username
        $controls.AuthCombo.SelectedValue = [string]$Existing.AuthType
        $controls.KeyPathBox.Text = [string]$Existing.KeyPath
        $controls.VpnCombo.SelectedValue = [string]$Existing.VpnProfileId
        $controls.HostKeyCombo.SelectedValue = [string]$Existing.HostKeyPolicy
        $controls.JumpHostBox.Text = [string]$Existing.JumpHost
        $controls.KeepAliveBox.Text = [string]$Existing.KeepAliveInterval
        $controls.KeepAliveMaxBox.Text = [string]$Existing.KeepAliveCountMax
        $controls.RdpPortBox.Text = [string](Get-SSHManagerRdpPort $Existing)
        $controls.RdpUsernameBox.Text = [string](Get-SSHManagerHostValue $Existing 'RdpUsername')
        $controls.RdpFullscreenBox.IsChecked = [bool](Get-SSHManagerHostValue $Existing 'RdpFullscreen' $true)
        $controls.RdpMultiMonitorBox.IsChecked = [bool](Get-SSHManagerHostValue $Existing 'RdpMultiMonitor' $false)
        $controls.RdpAdminBox.IsChecked = [bool](Get-SSHManagerHostValue $Existing 'RdpAdmin' $false)
        $controls.RdpWidthBox.Text = [string][int](Get-SSHManagerHostValue $Existing 'RdpWidth' 0)
        $controls.RdpHeightBox.Text = [string][int](Get-SSHManagerHostValue $Existing 'RdpHeight' 0)
        $controls.TagsBox.Text = [string]$Existing.Tags
        $controls.NotesBox.Text = [string]$Existing.Notes
        $controls.FavoriteBox.IsChecked = [bool]$Existing.Favorite
        $controls.PasswordHint.Text = if ($AsCopy) { 'Masukkan password baru; password host asal tidak disalin.' } else { 'Kosongkan jika password tersimpan tidak ingin diubah.' }
        if ($AsCopy) { $controls.RdpPasswordHint.Text = 'Credential RDP host asal tidak disalin. Isi password bila ingin menyimpan credential baru di Windows Credential Manager.' }
        elseif ([bool](Get-SSHManagerHostValue $Existing 'RdpCredentialSaved' $false)) { $controls.RdpPasswordHint.Text = 'Credential RDP sudah tersimpan di Windows Credential Manager. Kosongkan jika tidak ingin diubah.' }
    }
    else {
        $controls.GroupBox.Text = 'Default'
        $controls.SshEnabledBox.IsChecked = -not $RdpDefault
        $controls.RdpEnabledBox.IsChecked = [bool]$RdpDefault
        $controls.PortBox.Text = '22'
        $controls.AuthCombo.SelectedValue = 'Password'
        $controls.VpnCombo.SelectedValue = ''
        $controls.HostKeyCombo.SelectedValue = 'AcceptNew'
        $controls.KeepAliveBox.Text = '15'
        $controls.KeepAliveMaxBox.Text = '4'
        $controls.RdpPortBox.Text = '3389'
        $controls.RdpFullscreenBox.IsChecked = $true
        $controls.RdpWidthBox.Text = '0'
        $controls.RdpHeightBox.Text = '0'
        if ($RdpDefault) { $controls.TitleText.Text = 'Tambah host RDP' }
    }

    $updateSections = {
        $controls.SshSection.IsEnabled = [bool]$controls.SshEnabledBox.IsChecked
        $controls.RdpSection.IsEnabled = [bool]$controls.RdpEnabledBox.IsChecked
        $controls.SshSection.Opacity = if ($controls.SshSection.IsEnabled) { 1.0 } else { 0.45 }
        $controls.RdpSection.Opacity = if ($controls.RdpSection.IsEnabled) { 1.0 } else { 0.45 }
    }
    & $updateSections
    $controls.SshEnabledBox.Add_Click({ & $updateSections })
    $controls.RdpEnabledBox.Add_Click({ & $updateSections })

    $controls.BrowseKeyButton.Add_Click({
        $picker = New-Object Microsoft.Win32.OpenFileDialog
        $picker.Title = 'Pilih private key SSH'
        $picker.Filter = 'OpenSSH private key|id_*;*.pem;*.key|Semua file|*.*'
        if ($picker.ShowDialog($dialog)) { $controls.KeyPathBox.Text = $picker.FileName }
    })

    $controls.SaveButton.Add_Click({
        try {
            $port = 22; $keepAlive = 15; $keepAliveMax = 4; $rdpPort = 3389; $rdpWidth = 0; $rdpHeight = 0
            $sshEnabled = [bool]$controls.SshEnabledBox.IsChecked
            $rdpEnabled = [bool]$controls.RdpEnabledBox.IsChecked
            if ([string]::IsNullOrWhiteSpace($controls.NameBox.Text)) { throw 'Nama host wajib diisi.' }
            if ([string]::IsNullOrWhiteSpace($controls.HostBox.Text) -or $controls.HostBox.Text.Trim() -match '\s') { throw 'IP/hostname wajib diisi dan tidak boleh mengandung spasi.' }
            if (-not $sshEnabled -and -not $rdpEnabled) { throw 'Pilih minimal satu Connection Type: SSH atau RDP.' }
            $authType = [string]$controls.AuthCombo.SelectedValue
            if ([string]::IsNullOrWhiteSpace($authType)) { $authType = 'Password' }
            if ($sshEnabled) {
                if ([string]::IsNullOrWhiteSpace($controls.UsernameBox.Text)) { throw 'SSH Username wajib diisi.' }
                if (-not [int]::TryParse($controls.PortBox.Text, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw 'SSH Port harus berupa angka 1–65535.' }
                if (-not [int]::TryParse($controls.KeepAliveBox.Text, [ref]$keepAlive) -or $keepAlive -lt 0) { throw 'Keep-alive interval tidak valid.' }
                if (-not [int]::TryParse($controls.KeepAliveMaxBox.Text, [ref]$keepAliveMax) -or $keepAliveMax -lt 1) { throw 'Maksimum missed keep-alive minimal 1.' }
                if ($authType -eq 'PrivateKey' -and [string]::IsNullOrWhiteSpace($controls.KeyPathBox.Text)) { throw 'Path private key wajib diisi.' }
                $existingSecretAvailable = $false
                if ($null -ne $Existing -and -not $AsCopy) {
                    $existingSecretAvailable = Test-SSHManagerSecret -Paths $script:Paths -Kind host -Id $Existing.Id
                }
                $passwordRequired = $authType -eq 'Password' -and -not $existingSecretAvailable
                if ($passwordRequired -and $controls.PasswordBox.Password.Length -eq 0) { throw 'Password SSH wajib diisi karena host ini belum memiliki password tersimpan.' }
            }
            else {
                # Keep previously entered SSH values when SSH is only switched off.
                [void][int]::TryParse($controls.PortBox.Text, [ref]$port); if ($port -lt 1 -or $port -gt 65535) { $port = 22 }
                [void][int]::TryParse($controls.KeepAliveBox.Text, [ref]$keepAlive); if ($keepAlive -lt 0) { $keepAlive = 15 }
                [void][int]::TryParse($controls.KeepAliveMaxBox.Text, [ref]$keepAliveMax); if ($keepAliveMax -lt 1) { $keepAliveMax = 4 }
            }
            if ($rdpEnabled) {
                if (-not [int]::TryParse($controls.RdpPortBox.Text, [ref]$rdpPort) -or $rdpPort -lt 1 -or $rdpPort -gt 65535) { throw 'RDP Port harus berupa angka 1–65535.' }
                if (-not [int]::TryParse($controls.RdpWidthBox.Text, [ref]$rdpWidth) -or $rdpWidth -lt 0 -or $rdpWidth -gt 8192) { throw 'Lebar resolusi RDP harus 0–8192.' }
                if (-not [int]::TryParse($controls.RdpHeightBox.Text, [ref]$rdpHeight) -or $rdpHeight -lt 0 -or $rdpHeight -gt 8192) { throw 'Tinggi resolusi RDP harus 0–8192.' }
                if (($rdpWidth -eq 0) -ne ($rdpHeight -eq 0)) { throw 'Isi lebar dan tinggi resolusi RDP bersamaan, atau kosongkan keduanya (0).' }
                if ($controls.RdpPasswordBox.Password.Length -gt 0 -and [string]::IsNullOrWhiteSpace($controls.RdpUsernameBox.Text)) { throw 'RDP Username wajib diisi bila password RDP ingin disimpan.' }
            }
            else {
                [void][int]::TryParse($controls.RdpPortBox.Text, [ref]$rdpPort); if ($rdpPort -lt 1 -or $rdpPort -gt 65535) { $rdpPort = 3389 }
                [void][int]::TryParse($controls.RdpWidthBox.Text, [ref]$rdpWidth); [void][int]::TryParse($controls.RdpHeightBox.Text, [ref]$rdpHeight)
            }

            $isSameHost = ($null -ne $Existing -and -not $AsCopy)
            $id = if ($isSameHost) { [string]$Existing.Id } else { [guid]::NewGuid().ToString('N') }
            $dialog.Tag = [pscustomobject]@{
                Host = [pscustomobject]@{
                    Id = $id; Name = $controls.NameBox.Text.Trim(); Group = $controls.GroupBox.Text.Trim()
                    HostName = $controls.HostBox.Text.Trim(); Port = $port; Username = $controls.UsernameBox.Text.Trim()
                    AuthType = $authType; KeyPath = $controls.KeyPathBox.Text.Trim(); VpnProfileId = [string]$controls.VpnCombo.SelectedValue
                    JumpHost = $controls.JumpHostBox.Text.Trim(); KeepAliveInterval = $keepAlive; KeepAliveCountMax = $keepAliveMax
                    HostKeyPolicy = [string]$controls.HostKeyCombo.SelectedValue; Tags = $controls.TagsBox.Text.Trim(); Notes = $controls.NotesBox.Text.Trim()
                    Favorite = [bool]$controls.FavoriteBox.IsChecked
                    LastConnectedAt = if ($isSameHost) { [string]$Existing.LastConnectedAt } else { '' }
                    SshEnabled = $sshEnabled; RdpEnabled = $rdpEnabled; RdpPort = $rdpPort; RdpUsername = $controls.RdpUsernameBox.Text.Trim()
                    RdpFullscreen = [bool]$controls.RdpFullscreenBox.IsChecked; RdpMultiMonitor = [bool]$controls.RdpMultiMonitorBox.IsChecked; RdpAdmin = [bool]$controls.RdpAdminBox.IsChecked
                    RdpWidth = $rdpWidth; RdpHeight = $rdpHeight
                    # A copy never inherits the original's stored credential.
                    RdpCredentialSaved = if ($isSameHost) { [bool](Get-SSHManagerHostValue $Existing 'RdpCredentialSaved' $false) } else { $false }
                }
                PasswordChanged = ($sshEnabled -and $controls.PasswordBox.Password.Length -gt 0)
                Password = $controls.PasswordBox.SecurePassword
                RdpPasswordChanged = ($rdpEnabled -and $controls.RdpPasswordBox.Password.Length -gt 0)
                RdpPassword = $controls.RdpPasswordBox.SecurePassword
            }
            $dialog.DialogResult = $true
        }
        catch {
            [Windows.MessageBox]::Show($dialog, $_.Exception.Message, 'Data belum valid', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Warning) | Out-Null
        }
    })

    if ($dialog.ShowDialog()) { return $dialog.Tag }
    return $null
}

function Get-HostById {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    $found = @(@($script:Config.Hosts) | Where-Object { [string]$_.Id -eq $Id } | Select-Object -First 1)
    if ($found.Count -eq 0) { return $null }
    return $found[0]
}

function Remove-HostRdpCredentialIfOwned {
    param($HostEntry, [string[]]$IgnoreIds = @())
    # Only credentials this app saved are removed, and only when no other host still uses that address.
    if ($null -eq $HostEntry -or -not [bool](Get-SSHManagerHostValue $HostEntry 'RdpCredentialSaved' $false) -or [string]::IsNullOrWhiteSpace([string]$HostEntry.HostName)) { return }
    $sharedBy = @(@($script:Config.Hosts) | Where-Object { [string]$_.Id -notin $IgnoreIds -and [string]$_.Id -ne [string]$HostEntry.Id -and [bool](Get-SSHManagerHostValue $_ 'RdpCredentialSaved' $false) -and [string]$_.HostName -eq [string]$HostEntry.HostName })
    if ($sharedBy.Count -gt 0) { return }
    try { [void](Remove-RdpCredential -HostName ([string]$HostEntry.HostName)) }
    catch { Write-SSHManagerLog -Level WARN -Component 'RDP' -Action 'RemoveCredential' -HostName ([string]$HostEntry.HostName) -Message 'Credential RDP tidak dapat dihapus.' -ErrorRecord $_ }
}

function Save-HostEditorRdpCredential {
    param([Parameter(Mandatory = $true)]$Result, $Previous = $null)
    $hostEntry = $Result.Host
    $addressChanged = $null -ne $Previous -and [string]$Previous.HostName -ne [string]$hostEntry.HostName
    if ($null -ne $Previous -and ((-not $hostEntry.RdpEnabled) -or $addressChanged)) {
        # RDP switched off or moved to another address: the old TERMSRV entry no longer belongs to this host.
        Remove-HostRdpCredentialIfOwned -HostEntry $Previous
        $hostEntry.RdpCredentialSaved = $false
    }
    if ($Result.RdpPasswordChanged) {
        Save-RdpCredential -HostName ([string]$hostEntry.HostName) -Username ([string]$hostEntry.RdpUsername) -Password $Result.RdpPassword
        $hostEntry.RdpCredentialSaved = $true
        Write-SSHManagerLog -Component 'RDP' -Action 'SaveCredential' -HostName ([string]$hostEntry.HostName) -Message 'Credential RDP disimpan di Windows Credential Manager.'
    }
}

function Add-Host {
    param([switch]$Rdp)
    $result = Show-HostEditor -RdpDefault:$Rdp
    if ($null -eq $result) { return }
    $script:Config.Hosts = @($script:Config.Hosts) + $result.Host
    if ($result.PasswordChanged) { Set-SSHManagerSecret -Paths $script:Paths -Kind host -Id $result.Host.Id -Secret $result.Password | Out-Null }
    try { Save-HostEditorRdpCredential -Result $result }
    catch { Show-AppError -Summary 'Host disimpan, tetapi credential RDP tidak dapat disimpan.' -Detail $_.Exception.Message -Component 'Host' -Action 'Add' -HostName $result.Host.HostName -ErrorRecord $_ }
    Save-CurrentConfig
    Refresh-AllViews
    Write-SSHManagerLog -Component 'Host' -Action 'Add' -HostName $result.Host.HostName -Message ("Host '{0}' ditambahkan." -f $result.Host.Name)
    Set-Status "Host '$($result.Host.Name)' ditambahkan." '#22C55E'
}

function Edit-Host {
    param($HostEntry=$null)
    $existing = if ($null -ne $HostEntry) { $HostEntry } else { Get-PrimarySelectedHost }
    if ($null -eq $existing) { Show-Warning 'Pilih satu host yang akan diedit.'; return }
    $result = Show-HostEditor -Existing $existing
    if ($null -eq $result) { return }
    $script:Config.Hosts = @($script:Config.Hosts | Where-Object { $_.Id -ne $existing.Id }) + $result.Host
    if ($result.Host.SshEnabled -and $result.Host.AuthType -ne 'Password') {
        Remove-SSHManagerSecret -Paths $script:Paths -Kind host -Id $result.Host.Id
    }
    elseif ($result.PasswordChanged) {
        Set-SSHManagerSecret -Paths $script:Paths -Kind host -Id $result.Host.Id -Secret $result.Password | Out-Null
    }
    try { Save-HostEditorRdpCredential -Result $result -Previous $existing }
    catch { Show-AppError -Summary 'Host disimpan, tetapi credential RDP tidak dapat disimpan.' -Detail $_.Exception.Message -Component 'Host' -Action 'Edit' -HostName $result.Host.HostName -ErrorRecord $_ }
    Save-CurrentConfig
    Refresh-AllViews
    Write-SSHManagerLog -Component 'Host' -Action 'Edit' -HostName $result.Host.HostName -Message ("Host '{0}' diperbarui." -f $result.Host.Name)
    Set-Status "Host '$($result.Host.Name)' diperbarui." '#22C55E'
}

function Duplicate-Host {
    param($HostEntry=$null)
    $existing = if ($null -ne $HostEntry) { $HostEntry } else { Get-PrimarySelectedHost }
    if ($null -eq $existing) { Show-Warning 'Pilih satu host yang akan diduplikat.'; return }
    $result = Show-HostEditor -Existing $existing -AsCopy
    if ($null -eq $result) { return }
    $script:Config.Hosts = @($script:Config.Hosts) + $result.Host
    if ($result.PasswordChanged) { Set-SSHManagerSecret -Paths $script:Paths -Kind host -Id $result.Host.Id -Secret $result.Password | Out-Null }
    try { Save-HostEditorRdpCredential -Result $result }
    catch { Show-AppError -Summary 'Duplikat disimpan, tetapi credential RDP tidak dapat disimpan.' -Detail $_.Exception.Message -Component 'Host' -Action 'Duplicate' -HostName $result.Host.HostName -ErrorRecord $_ }
    Save-CurrentConfig
    Refresh-AllViews
    Write-SSHManagerLog -Component 'Host' -Action 'Duplicate' -HostName $result.Host.HostName -Message ("Duplikat '{0}' dibuat dari '{1}'." -f $result.Host.Name, $existing.Name)
    Set-Status "Duplikat '$($result.Host.Name)' dibuat." '#22C55E'
}

function Delete-Hosts {
    param([object[]]$HostEntries=@())
    $selected = if (@($HostEntries).Count -gt 0) { @($HostEntries) } else { @(Get-SelectedHostEntries) }
    if ($selected.Count -eq 0) { Show-Warning 'Pilih host yang akan dihapus.'; return }
    $names = ($selected | ForEach-Object { $_.Name }) -join ', '
    if ([bool]$script:Config.App.ConfirmBeforeDelete -and -not (Confirm-Action "Hapus $($selected.Count) host berikut?`n`n$names`n`nPassword SSH tersimpan dan credential RDP yang disimpan aplikasi untuk host tersebut juga akan dihapus." 'Hapus host')) { return }
    $ids = @($selected | ForEach-Object { [string]$_.Id })
    foreach ($item in $selected) {
        Remove-SSHManagerSecret -Paths $script:Paths -Kind host -Id $item.Id
        Remove-HostRdpCredentialIfOwned -HostEntry $item -IgnoreIds $ids
        [void]$script:CheckedHostIds.Remove([string]$item.Id)
        [void]$script:RdpCheckedHostIds.Remove([string]$item.Id)
    }
    $script:Config.Hosts = @($script:Config.Hosts | Where-Object { $ids -notcontains [string]$_.Id })
    Save-CurrentConfig
    Refresh-AllViews
    Write-SSHManagerLog -Component 'Host' -Action 'Delete' -Message ("{0} host dihapus: {1}" -f $selected.Count, $names)
    Set-Status "$($selected.Count) host dihapus." '#F59E0B'
}

function Invoke-HostRowAction {
    param([string]$Action, [string]$HostId, [string]$Context = 'Connections')
    $hostEntry = Get-HostById $HostId
    if ($null -eq $hostEntry) {
        Write-SSHManagerLog -Level WARN -Component 'Connections' -Action $Action -Message ("Host dengan ID '{0}' tidak ditemukan." -f $HostId)
        Show-Warning "Host tidak ditemukan.`n`nDaftar host mungkin sudah berubah; tampilan diperbarui."
        Refresh-AllViews
        return
    }
    try {
        $vpnOverride = if ($Context -eq 'Rdp') { Get-RdpVpnOverride } else { [string]$script:VpnOverride.SelectedValue }
        switch ($Action) {
            'Ssh' { Connect-SelectedHosts -HostEntries @($hostEntry) }
            'Rdp' { Start-RdpLaunchBatch -Hosts @($hostEntry) -VpnOverride $vpnOverride }
            'TestRdp' { Test-RdpHosts -Hosts @($hostEntry) }
            'Scp' { $script:WorkspaceState.NavigationHosts = @($hostEntry); Invoke-WorkspaceNavigation 'Scp' }
            'Editor' { $script:WorkspaceState.NavigationHosts = @($hostEntry); Invoke-WorkspaceNavigation 'Editor' }
            'Edit' { Edit-Host -HostEntry $hostEntry }
            'Duplicate' { Duplicate-Host -HostEntry $hostEntry }
            'Delete' { Delete-Hosts -HostEntries @($hostEntry) }
            default { throw "Aksi '$Action' tidak dikenal." }
        }
    }
    catch {
        Show-AppError -Summary 'Aksi host tidak dapat dijalankan.' -Detail $_.Exception.Message -Component 'Connections' -Action $Action -HostName ([string]$hostEntry.HostName) -ErrorRecord $_
    }
}

function Show-VpnEditor {
    param($Existing)
    $dialog = Read-XamlWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="Profil VPN" Width="650" Height="690" WindowStartupLocation="CenterOwner" Background="#0B1220" Foreground="#E5E7EB" ShowInTaskbar="False">
 <Window.Resources>
  <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#E5E7EB"/></Style><Style TargetType="Label"><Setter Property="Foreground" Value="#CBD5E1"/><Setter Property="Padding" Value="0,7,0,3"/></Style>
  <Style TargetType="TextBox"><Setter Property="Foreground" Value="#F8FAFC"/><Setter Property="Background" Value="#0F172A"/><Setter Property="BorderBrush" Value="#334155"/><Setter Property="Padding" Value="8,6"/></Style>
  <Style TargetType="PasswordBox"><Setter Property="Foreground" Value="#F8FAFC"/><Setter Property="Background" Value="#0F172A"/><Setter Property="BorderBrush" Value="#334155"/><Setter Property="Padding" Value="8,6"/></Style>
  <Style TargetType="ComboBox"><Setter Property="Foreground" Value="#F8FAFC"/><Setter Property="Background" Value="#172033"/><Setter Property="BorderBrush" Value="#475569"/><Setter Property="Padding" Value="6,4"/></Style>
  <Style TargetType="Button"><Setter Property="Foreground" Value="#E5E7EB"/><Setter Property="Background" Value="#263348"/><Setter Property="BorderBrush" Value="#34445D"/><Setter Property="Padding" Value="14,8"/><Setter Property="Margin" Value="4"/></Style>
 </Window.Resources>
 <DockPanel Margin="18">
  <StackPanel DockPanel.Dock="Top" Margin="0,0,0,10"><TextBlock x:Name="TitleText" Text="Tambah profil VPN" FontSize="23" FontWeight="SemiBold"/><TextBlock Text="Gunakan Windows VPN/RAS atau perintah CLI khusus." Foreground="#94A3B8" Margin="0,4,0,0"/></StackPanel>
  <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0"><Button Content="Batal" IsCancel="True"/><Button x:Name="SaveButton" Content="Simpan profil" Background="#16A34A" BorderBrush="#22C55E" IsDefault="True"/></StackPanel>
  <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="0,0,8,0">
   <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="16"/><ColumnDefinition/></Grid.ColumnDefinitions>
    <StackPanel><Label Content="Nama profil *"/><TextBox x:Name="NameBox"/></StackPanel>
    <StackPanel Grid.Column="2"><Label Content="Jenis"/><ComboBox x:Name="TypeCombo" DisplayMemberPath="Name" SelectedValuePath="Id"/></StackPanel>
   </Grid>
   <Border Background="#111827" BorderBrush="#263348" BorderThickness="1" CornerRadius="4" Padding="12" Margin="0,12,0,5"><StackPanel>
    <TextBlock Text="Windows VPN / RAS" FontWeight="SemiBold"/>
    <Label Content="Nama koneksi seperti pada Windows Settings"/><TextBox x:Name="ConnectionNameBox"/>
    <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="16"/><ColumnDefinition/></Grid.ColumnDefinitions>
     <StackPanel><Label Content="Username (kosong = kredensial Windows tersimpan)"/><TextBox x:Name="UsernameBox"/></StackPanel>
     <StackPanel Grid.Column="2"><Label Content="Password VPN"/><PasswordBox x:Name="PasswordBox"/></StackPanel>
    </Grid>
    <TextBlock x:Name="PasswordHint" Text="Isi password hanya bila username diisi." Foreground="#94A3B8" FontSize="11" Margin="0,4,0,0"/>
   </StackPanel></Border>
   <Border Background="#111827" BorderBrush="#263348" BorderThickness="1" CornerRadius="4" Padding="12" Margin="0,8,0,5"><StackPanel>
    <TextBlock Text="Perintah khusus (FortiClient/OpenVPN/klien lain)" FontWeight="SemiBold"/>
    <Label Content="Perintah connect"/><TextBox x:Name="ConnectCommandBox" AcceptsReturn="True" Height="55" TextWrapping="Wrap"/>
    <Label Content="Perintah pengecekan (exit code 0 = terhubung)"/><TextBox x:Name="CheckCommandBox" AcceptsReturn="True" Height="50" TextWrapping="Wrap"/>
    <Label Content="Perintah disconnect"/><TextBox x:Name="DisconnectCommandBox" AcceptsReturn="True" Height="50" TextWrapping="Wrap"/>
    <CheckBox x:Name="RunAsAdminBox" Content="Jalankan perintah connect sebagai Administrator" Foreground="#E5E7EB" Margin="0,8,0,0"/>
   </StackPanel></Border>
   <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="16"/><ColumnDefinition/></Grid.ColumnDefinitions>
    <StackPanel><Label Content="Wait awal (detik)"/><TextBox x:Name="WaitBox"/></StackPanel><StackPanel Grid.Column="2"><Label Content="Catatan"/><TextBox x:Name="NotesBox"/></StackPanel>
   </Grid>
  </StackPanel></ScrollViewer>
 </DockPanel>
</Window>
'@
    $dialog.Owner = $script:MainWindow
    $c = @{}; foreach ($name in @('TitleText','NameBox','TypeCombo','ConnectionNameBox','UsernameBox','PasswordBox','PasswordHint','ConnectCommandBox','CheckCommandBox','DisconnectCommandBox','RunAsAdminBox','WaitBox','NotesBox','SaveButton')) { $c[$name] = Get-NamedControl $dialog $name }
    $c.TypeCombo.ItemsSource = @([pscustomobject]@{Id='WindowsRas';Name='Windows VPN / RAS'},[pscustomobject]@{Id='CustomCommand';Name='Perintah khusus'})
    if ($null -ne $Existing) {
        $c.TitleText.Text='Edit profil VPN'; $c.NameBox.Text=[string]$Existing.Name; $c.TypeCombo.SelectedValue=[string]$Existing.Type
        $c.ConnectionNameBox.Text=[string]$Existing.ConnectionName; $c.UsernameBox.Text=[string]$Existing.Username
        $c.ConnectCommandBox.Text=[string]$Existing.ConnectCommand; $c.CheckCommandBox.Text=[string]$Existing.CheckCommand
        $c.DisconnectCommandBox.Text=[string]$Existing.DisconnectCommand; $c.RunAsAdminBox.IsChecked=[bool]$Existing.RunAsAdministrator
        $c.WaitBox.Text=[string]$Existing.WaitSeconds; $c.NotesBox.Text=[string]$Existing.Notes; $c.PasswordHint.Text='Kosongkan jika password tersimpan tidak diubah.'
    } else { $c.TypeCombo.SelectedValue='WindowsRas'; $c.WaitBox.Text='3' }
    $c.SaveButton.Add_Click({
        try {
            $wait=0; if ([string]::IsNullOrWhiteSpace($c.NameBox.Text)) { throw 'Nama profil wajib diisi.' }
            if (-not [int]::TryParse($c.WaitBox.Text,[ref]$wait) -or $wait -lt 0 -or $wait -gt 300) { throw 'Wait awal harus 0–300 detik.' }
            $type=[string]$c.TypeCombo.SelectedValue
            if ($type -eq 'WindowsRas' -and [string]::IsNullOrWhiteSpace($c.ConnectionNameBox.Text)) { throw 'Nama koneksi Windows VPN wajib diisi.' }
            if ($type -eq 'CustomCommand' -and [string]::IsNullOrWhiteSpace($c.ConnectCommandBox.Text)) { throw 'Perintah connect wajib diisi.' }
            $vpnSecretAvailable = $false
            if ($null -ne $Existing) {
                $vpnSecretAvailable = Test-SSHManagerSecret -Paths $script:Paths -Kind vpn -Id $Existing.Id
            }
            $passwordRequired = $type -eq 'WindowsRas' -and -not [string]::IsNullOrWhiteSpace($c.UsernameBox.Text) -and -not $vpnSecretAvailable
            if ($passwordRequired -and $c.PasswordBox.Password.Length -eq 0) { throw 'Password VPN wajib diisi ketika username digunakan dan belum ada password tersimpan.' }
            $id=if($null -eq $Existing){[guid]::NewGuid().ToString('N')}else{[string]$Existing.Id}
            $dialog.Tag=[pscustomobject]@{ Profile=[pscustomobject]@{Id=$id;Name=$c.NameBox.Text.Trim();Type=$type;ConnectionName=$c.ConnectionNameBox.Text.Trim();Username=$c.UsernameBox.Text.Trim();ConnectCommand=$c.ConnectCommandBox.Text.Trim();CheckCommand=$c.CheckCommandBox.Text.Trim();DisconnectCommand=$c.DisconnectCommandBox.Text.Trim();RunAsAdministrator=[bool]$c.RunAsAdminBox.IsChecked;WaitSeconds=$wait;Notes=$c.NotesBox.Text.Trim()};PasswordChanged=($c.PasswordBox.Password.Length -gt 0);Password=$c.PasswordBox.SecurePassword }
            $dialog.DialogResult=$true
        } catch { [Windows.MessageBox]::Show($dialog,$_.Exception.Message,'Data belum valid',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Warning)|Out-Null }
    })
    if($dialog.ShowDialog()){return $dialog.Tag}; return $null
}

function Show-VpnManager {
    $window = Read-WorkspaceView @'
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Background="#0B1220" Foreground="#E5E7EB">
 <UserControl.Resources><Style TargetType="TextBlock"><Setter Property="Foreground" Value="#E5E7EB"/></Style><Style TargetType="Button"><Setter Property="Foreground" Value="#E5E7EB"/><Setter Property="Background" Value="#263348"/><Setter Property="BorderBrush" Value="#34445D"/><Setter Property="Padding" Value="12,7"/><Setter Property="Margin" Value="3"/></Style><Style TargetType="ListBox"><Setter Property="Background" Value="#0F172A"/><Setter Property="Foreground" Value="#E5E7EB"/><Setter Property="BorderBrush" Value="#263348"/></Style></UserControl.Resources>
 <DockPanel Margin="0"><StackPanel DockPanel.Dock="Top" Margin="0,0,0,12"><TextBlock Text="Profil VPN" FontSize="23" FontWeight="SemiBold"/><TextBlock Text="Host dapat memilih profil ini atau terhubung tanpa VPN." Foreground="#94A3B8"/></StackPanel><StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0"><Button x:Name="CloseButton" Content="Kembali ke Connections"/></StackPanel>
 <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="170"/></Grid.ColumnDefinitions><ListBox x:Name="VpnList" DisplayMemberPath="Display"/><StackPanel Grid.Column="1" Margin="10,0,0,0"><Button x:Name="AddButton" Content="Tambah"/><Button x:Name="EditButton" Content="Edit"/><Button x:Name="DeleteButton" Content="Hapus" Background="#7F1D1D"/><Separator Margin="4,10" Background="#334155"/><Button x:Name="ConnectButton" Content="Connect sekarang" Background="#166534"/><Button x:Name="DisconnectButton" Content="Disconnect"/></StackPanel></Grid></DockPanel>
</UserControl>
'@
    
    $list=Get-NamedControl $window 'VpnList'; $add=Get-NamedControl $window 'AddButton'; $edit=Get-NamedControl $window 'EditButton'; $delete=Get-NamedControl $window 'DeleteButton'; $connect=Get-NamedControl $window 'ConnectButton'; $disconnect=Get-NamedControl $window 'DisconnectButton'
    $refresh = {
        $list.ItemsSource = @($script:Config.VpnProfiles | Sort-Object Name | ForEach-Object {
            $typeDisplay = if ($_.Type -eq 'WindowsRas') { 'Windows VPN' } else { 'Perintah khusus' }
            [pscustomobject]@{ Display = ("{0}  —  {1}" -f $_.Name, $typeDisplay); Source = $_ }
        })
    }
    & $refresh
    $add.Add_Click({
        $result = Show-VpnEditor
        if ($result) {
            $script:Config.VpnProfiles = @($script:Config.VpnProfiles) + $result.Profile
            if ($result.PasswordChanged) {
                Set-SSHManagerSecret -Paths $script:Paths -Kind vpn -Id $result.Profile.Id -Secret $result.Password | Out-Null
            }
            Save-CurrentConfig
            & $refresh
            Refresh-AllViews
        }
    })
    $edit.Add_Click({
        if (-not $list.SelectedItem) { return }
        $old = $list.SelectedItem.Source
        $result = Show-VpnEditor $old
        if ($result) {
            $script:Config.VpnProfiles = @($script:Config.VpnProfiles | Where-Object { $_.Id -ne $old.Id }) + $result.Profile
            if ($result.Profile.Type -ne 'WindowsRas' -or [string]::IsNullOrWhiteSpace($result.Profile.Username)) {
                Remove-SSHManagerSecret -Paths $script:Paths -Kind vpn -Id $result.Profile.Id
            }
            elseif ($result.PasswordChanged) {
                Set-SSHManagerSecret -Paths $script:Paths -Kind vpn -Id $result.Profile.Id -Secret $result.Password | Out-Null
            }
            Save-CurrentConfig
            & $refresh
            Refresh-AllViews
        }
    })
    $delete.Add_Click({
        if (-not $list.SelectedItem) { return }
        $profile = $list.SelectedItem.Source
        $answer = [Windows.MessageBox]::Show($script:MainWindow, "Hapus profil VPN '$($profile.Name)'? Host yang menggunakannya akan diubah menjadi Tanpa VPN.", 'Hapus VPN', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question)
        if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
        foreach ($hostEntry in @($script:Config.Hosts | Where-Object { $_.VpnProfileId -eq $profile.Id })) {
            $hostEntry.VpnProfileId = ''
        }
        $script:Config.VpnProfiles = @($script:Config.VpnProfiles | Where-Object { $_.Id -ne $profile.Id })
        Remove-SSHManagerSecret -Paths $script:Paths -Kind vpn -Id $profile.Id
        Save-CurrentConfig
        & $refresh
        Refresh-AllViews
    })
    $connect.Add_Click({
        if (-not $list.SelectedItem) { return }
        $profile = $list.SelectedItem.Source
        $result = Invoke-SSHManagerVpnConnectAsync -Profile $profile
        Set-Status $result.Message $(if ($result.Success) { '#22C55E' } else { '#EF4444' })
        $icon = if ($result.Success) { [Windows.MessageBoxImage]::Information } else { [Windows.MessageBoxImage]::Error }
        [Windows.MessageBox]::Show($script:MainWindow, $result.Message, 'VPN', [Windows.MessageBoxButton]::OK, $icon) | Out-Null
    })
    $disconnect.Add_Click({
        if (-not $list.SelectedItem) { return }
        $result = Invoke-SSHManagerVpnDisconnectAsync -Profile $list.SelectedItem.Source
        $icon = if ($result.Success) { [Windows.MessageBoxImage]::Information } else { [Windows.MessageBoxImage]::Error }
        [Windows.MessageBox]::Show($script:MainWindow, $result.Message, 'VPN', [Windows.MessageBoxButton]::OK, $icon) | Out-Null
    })
    (Get-NamedControl $window 'CloseButton').Add_Click({ Invoke-WorkspaceNavigation 'Connections' })
    [void](Show-WorkspaceFeature -View $window -Page 'Vpn')
}

function Show-SettingsDialog {
    $d=Read-WorkspaceView @'
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Background="#0B1220" Foreground="#E5E7EB">
 <UserControl.Resources><Style TargetType="TextBlock"><Setter Property="Foreground" Value="#E5E7EB"/></Style><Style TargetType="Label"><Setter Property="Foreground" Value="#CBD5E1"/><Setter Property="Padding" Value="0,8,0,3"/></Style><Style TargetType="TextBox"><Setter Property="Foreground" Value="#F8FAFC"/><Setter Property="Background" Value="#0F172A"/><Setter Property="BorderBrush" Value="#334155"/><Setter Property="Padding" Value="8,6"/></Style><Style TargetType="ComboBox"><Setter Property="Foreground" Value="#F8FAFC"/><Setter Property="Background" Value="#172033"/><Setter Property="BorderBrush" Value="#475569"/><Setter Property="Padding" Value="6,4"/></Style><Style TargetType="Button"><Setter Property="Foreground" Value="#E5E7EB"/><Setter Property="Background" Value="#263348"/><Setter Property="Padding" Value="14,8"/><Setter Property="Margin" Value="4"/></Style></UserControl.Resources>
 <DockPanel Margin="0"><TextBlock DockPanel.Dock="Top" Text="Pengaturan aplikasi" FontSize="23" FontWeight="SemiBold" Margin="0,0,0,10"/><StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="CancelButton" Content="Kembali"/><Button x:Name="SaveButton" Content="Simpan"  Background="#16A34A"/></StackPanel><StackPanel>
  <Label Content="Layout default"/><ComboBox x:Name="LayoutCombo" DisplayMemberPath="Name" SelectedValuePath="Id"/>
  <Label Content="Nama profil Windows Terminal (kosong = default)"/><TextBox x:Name="TerminalProfileBox"/>
  <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="16"/><ColumnDefinition/></Grid.ColumnDefinitions><StackPanel><Label Content="Timeout tes SSH (detik)"/><TextBox x:Name="TimeoutBox"/></StackPanel><StackPanel Grid.Column="2"><Label Content="Timeout connect VPN (detik)"/><TextBox x:Name="VpnTimeoutBox"/></StackPanel></Grid>
  <CheckBox x:Name="MaximizedBox" Content="Maximize bila Windows Terminal belum terbuka" Foreground="#E5E7EB" Margin="0,16,0,4"/>
  <CheckBox x:Name="PreTestBox" Content="Tes port SSH sebelum membuka terminal" Foreground="#E5E7EB" Margin="0,4"/>
  <CheckBox x:Name="NotesSearchBox" Content="Sertakan catatan dalam pencarian" Foreground="#E5E7EB" Margin="0,4"/>
  <CheckBox x:Name="ConfirmDeleteBox" Content="Minta konfirmasi sebelum menghapus" Foreground="#E5E7EB" Margin="0,4"/>
  <CheckBox x:Name="CloseAfterBox" Content="Tutup hanya tab manager setelah terminal dibuka" Foreground="#E5E7EB" Margin="0,4"/>
  <CheckBox x:Name="ReturnAfterScpBox" Content="Kembali ke manager setelah transfer SCP berhasil" Foreground="#E5E7EB" Margin="0,4"/>
 </StackPanel></DockPanel>
</UserControl>
'@
    $lc=Get-NamedControl $d 'LayoutCombo';$tp=Get-NamedControl $d 'TerminalProfileBox';$to=Get-NamedControl $d 'TimeoutBox';$vto=Get-NamedControl $d 'VpnTimeoutBox';$mx=Get-NamedControl $d 'MaximizedBox';$pre=Get-NamedControl $d 'PreTestBox';$notes=Get-NamedControl $d 'NotesSearchBox';$del=Get-NamedControl $d 'ConfirmDeleteBox';$close=Get-NamedControl $d 'CloseAfterBox';$returnScp=Get-NamedControl $d 'ReturnAfterScpBox';$save=Get-NamedControl $d 'SaveButton'
    $close.ToolTip='Bila aplikasi dibuka lewat profil Windows Terminal hasil installer, hanya tab Proper SSH Manager yang ditutup. Tab SSH tetap terbuka.'
    $returnScp.ToolTip='Saat SCP sukses, tab transfer ditutup dan jendela manager yang sama dipulihkan. Transfer gagal tetap menampilkan tab hasil.'
    $lc.ItemsSource=@([pscustomobject]@{Id='Single';Name='1 panel per tab'},[pscustomobject]@{Id='TwoColumns';Name='Maks. 2 — kiri | kanan'},[pscustomobject]@{Id='TwoRows';Name='Maks. 2 — atas / bawah'},[pscustomobject]@{Id='TopOneBottomTwo';Name='Maks. 3 — atas 1, bawah 2'},[pscustomobject]@{Id='TopTwoBottomOne';Name='Maks. 3 — atas 2, bawah 1'},[pscustomobject]@{Id='FourGrid';Name='Maks. 4 — grid 2 × 2'})
    $lc.SelectedValue=[string]$script:Config.App.DefaultLayout;$tp.Text=[string]$script:Config.App.TerminalProfile;$to.Text=[string]$script:Config.App.ConnectTimeoutSeconds;$vto.Text=[string]$script:Config.App.VpnConnectTimeoutSeconds;$mx.IsChecked=[bool]$script:Config.App.StartMaximized;$pre.IsChecked=[bool]$script:Config.App.TestConnectionBeforeOpen;$notes.IsChecked=[bool]$script:Config.App.SearchIncludesNotes;$del.IsChecked=[bool]$script:Config.App.ConfirmBeforeDelete;$close.IsChecked=[bool]$script:Config.App.CloseManagerAfterLaunch;$returnScp.IsChecked=[bool]$script:Config.App.ReturnToManagerAfterScp
    $save.Add_Click({
        try {
            $timeout = 0
            $vpnTimeout = 0
            if (-not [int]::TryParse($to.Text, [ref]$timeout) -or $timeout -lt 1 -or $timeout -gt 120) { throw 'Timeout SSH harus 1–120 detik.' }
            if (-not [int]::TryParse($vto.Text, [ref]$vpnTimeout) -or $vpnTimeout -lt 1 -or $vpnTimeout -gt 300) { throw 'Timeout VPN harus 1–300 detik.' }
            $script:Config.App.DefaultLayout = [string]$lc.SelectedValue
            $script:Config.App.TerminalProfile = $tp.Text.Trim()
            $script:Config.App.ConnectTimeoutSeconds = $timeout
            $script:Config.App.VpnConnectTimeoutSeconds = $vpnTimeout
            $script:Config.App.StartMaximized = [bool]$mx.IsChecked
            $script:Config.App.TestConnectionBeforeOpen = [bool]$pre.IsChecked
            $script:Config.App.SearchIncludesNotes = [bool]$notes.IsChecked
            $script:Config.App.ConfirmBeforeDelete = [bool]$del.IsChecked
            $script:Config.App.CloseManagerAfterLaunch = [bool]$close.IsChecked
            $script:Config.App.ReturnToManagerAfterScp = [bool]$returnScp.IsChecked
            Save-CurrentConfig
            Refresh-AllViews
            Set-Status 'Pengaturan disimpan.' '#22C55E'
        }
        catch {
            [Windows.MessageBox]::Show($script:MainWindow, $_.Exception.Message, 'Data belum valid', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Warning) | Out-Null
        }
    })
    (Get-NamedControl $d 'CancelButton').Add_Click({ Invoke-WorkspaceNavigation 'Connections' })
    [void](Show-WorkspaceFeature -View $d -Page 'Settings')
}

function Show-DependencyDialog {
    $lines = foreach ($item in Get-SSHManagerDependencyStatus) {
        $mark = if ($item.Available) { '✓' } else { '✗' }
        $path = if ($item.Available) { $item.Path } else { 'Tidak ditemukan' }
        '{0}  {1,-20} {2}' -f $mark, $item.Name, $path
    }
    try {
        $helper = Initialize-SSHManagerAskPass -Paths $script:Paths
        $lines += ('✓  {0,-20} {1}' -f 'Password helper', $helper)
    }
    catch { $lines += ('✗  {0,-20} {1}' -f 'Password helper', $_.Exception.Message) }
    Show-Info (($lines -join "`n") + "`n`nKomponen bertanda silang harus diperbaiki sebelum fitur terkait digunakan.") 'Pemeriksaan dependensi'
}

function Test-SelectedHosts {
    $chosen = @(Get-SelectedHostEntries)
    if ($chosen.Count -eq 0) { Show-Warning 'Pilih minimal satu host.'; return }
    # RDP ports are tested by the RDP engine (no RDP login); SSH ports below. Neither blocks the UI thread.
    $rdpHosts = @($chosen | Where-Object { Test-SSHManagerRdpEnabled $_ })
    if ($rdpHosts.Count -gt 0) { Test-RdpHosts -Hosts $rdpHosts }
    $selected = @($chosen | Where-Object { Test-SSHManagerSshEnabled $_ })
    if ($selected.Count -eq 0) { return }
    $messages = @()
    $connectionProgress = New-ConnectionProgressWindow -Stage 'Menyiapkan tes koneksi...' -Detail ('{0} host dipilih' -f $selected.Count)
    try {
        $results = @(Invoke-SSHManagerPortChecks -HostEntries $selected -Protocol Ssh -ProgressWindow $connectionProgress -Stage ('Menguji port SSH {0} host' -f $selected.Count))
        foreach ($result in $results) {
            $mark = if ($result.Success) { '✓' } else { '✗' }
            $messages += ('{0}  {1,-22} {2} ms  {3}' -f $mark, $result.Host.Name, $result.Milliseconds, $result.Message)
            Write-SSHManagerLog -Level $(if ($result.Success) { 'INFO' } else { 'WARN' }) -Component 'SSH' -Action 'Test' -HostName ('{0}:{1}' -f $result.Host.HostName, $result.Port) -Message ('{0} ({1} ms)' -f $result.Message, $result.Milliseconds)
        }
    }
    finally {
        Close-ConnectionProgressWindow -Window $connectionProgress
    }
    Show-Info ($messages -join "`n") 'Hasil tes koneksi SSH'
    Set-Status 'Tes koneksi SSH selesai.'
}

function Invoke-SSHManagerVpnConnectAsync {
    param([Parameter(Mandatory = $true)]$Profile, $ProgressWindow = $null, [string]$Detail = 'Menunggu koneksi VPN terdeteksi aktif')
    # rasdial/custom commands run in a runspace; the UI thread only polls (see DEC-005).
    $timeout = [Math]::Max(1, [int]$script:Config.App.VpnConnectTimeoutSeconds)
    $stage = "Menghubungkan VPN '$($Profile.Name)'..."
    Set-Status $stage '#38BDF8'
    Write-SSHManagerLog -Component 'VPN' -Action 'Connect' -Message ("VPN '{0}'" -f $Profile.Name)
    $job = Start-SSHManagerVpnJob -Profile $Profile -Paths $script:Paths -TimeoutSeconds $timeout
    $watch = [Diagnostics.Stopwatch]::StartNew()
    # Closures only see global/module commands, so script functions are captured by reference (DEC-006).
    $updateProgress = ${function:Update-ConnectionProgressWindow}
    $setStatus = ${function:Set-Status}
    try {
        # Connect has its own deadline; the extra margin covers runspace start-up and a hung custom command.
        Wait-WorkspaceCondition -TimeoutSeconds ($timeout + 30) -Until { $null -ne (Receive-SSHManagerVpnJob -Job $job) }.GetNewClosure() -OnTick {
            if ($null -ne $ProgressWindow) { & $updateProgress -Window $ProgressWindow -Stage $stage -Detail $Detail -ElapsedMilliseconds $watch.ElapsedMilliseconds -TimeoutSeconds $timeout }
            else { & $setStatus ('{0} {1:0.0}/{2} detik' -f $stage, [Math]::Min([double]$timeout, $watch.ElapsedMilliseconds / 1000.0), $timeout) '#38BDF8' }
        }.GetNewClosure()
        $result = Receive-SSHManagerVpnJob -Job $job
    }
    catch [TimeoutException] { $result = Stop-SSHManagerVpnJob -Job $job -Message ("Perintah VPN tidak merespons dalam {0} detik." -f ($timeout + 30)) }
    if (-not [bool]$result.Success) { Write-SSHManagerLog -Level WARN -Component 'VPN' -Action 'Connect' -Message ("VPN '{0}' gagal: {1}" -f $Profile.Name, $result.Message) }
    return $result
}

function Invoke-SSHManagerVpnDisconnectAsync {
    param([Parameter(Mandatory = $true)]$Profile)
    $timeout = [Math]::Max(5, [int]$script:Config.App.VpnConnectTimeoutSeconds)
    $stage = "Memutus VPN '$($Profile.Name)'..."
    Set-Status $stage '#38BDF8'
    $job = Start-SSHManagerVpnJob -Profile $Profile -Paths $script:Paths -Operation Disconnect
    try { Wait-WorkspaceCondition -TimeoutSeconds $timeout -Until { $null -ne (Receive-SSHManagerVpnJob -Job $job) }.GetNewClosure() }
    catch [TimeoutException] { [void](Stop-SSHManagerVpnJob -Job $job -Message ("Disconnect VPN '{0}' tidak selesai dalam {1} detik." -f $Profile.Name, $timeout)) }
    $result = Receive-SSHManagerVpnJob -Job $job
    Write-SSHManagerLog -Level $(if ($result.Success) { 'INFO' } else { 'WARN' }) -Component 'VPN' -Action 'Disconnect' -Message ("VPN '{0}': {1}" -f $Profile.Name, $result.Message)
    Set-Status $result.Message $(if ($result.Success) { '#22C55E' } else { '#EF4444' })
    return $result
}

function Invoke-SSHManagerPortChecks {
    param(
        [Parameter(Mandatory = $true)][object[]]$HostEntries,
        [ValidateSet('Ssh', 'Rdp')][string]$Protocol = 'Ssh',
        $ProgressWindow = $null,
        [string]$Stage = 'Menguji port...'
    )
    # All hosts are probed in parallel with TcpClient.ConnectAsync; the UI thread only polls.
    $timeout = [Math]::Max(1, [int]$script:Config.App.ConnectTimeoutSeconds)
    $checks = @(foreach ($hostEntry in $HostEntries) {
        $port = if ($Protocol -eq 'Rdp') { Get-SSHManagerRdpPort $hostEntry } else { [int]$hostEntry.Port }
        [pscustomobject]@{ Host = $hostEntry; Port = $port; Probe = (Start-SSHManagerTcpProbe -HostName ([string]$hostEntry.HostName) -Port $port -TimeoutSeconds $timeout) }
    })
    $detail = if ($checks.Count -eq 1) { '{0}:{1}' -f $checks[0].Host.HostName, $checks[0].Port } else { '{0} host diuji bersamaan' -f $checks.Count }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $updateProgress = ${function:Update-ConnectionProgressWindow}
    $setStatus = ${function:Set-Status}
    Wait-WorkspaceCondition -Until { @($checks | Where-Object { $null -eq (Get-SSHManagerTcpProbeResult -Probe $_.Probe) }).Count -eq 0 }.GetNewClosure() -OnTick {
        if ($null -ne $ProgressWindow) { & $updateProgress -Window $ProgressWindow -Stage $Stage -Detail $detail -ElapsedMilliseconds $watch.ElapsedMilliseconds -TimeoutSeconds $timeout }
        else { & $setStatus ('{0} {1}' -f $Stage, $detail) '#38BDF8' }
    }.GetNewClosure()
    foreach ($check in $checks) {
        $result = Get-SSHManagerTcpProbeResult -Probe $check.Probe
        [pscustomobject]@{
            Host = $check.Host; Port = $check.Port; Success = [bool]$result.Success; Milliseconds = [long]$result.Milliseconds
            Message = if ($result.Success) { 'Port dapat dijangkau.' } else { [string]$result.Message }
        }
    }
}

function Ensure-SSHManagerVpnForHost {
    param([Parameter(Mandatory = $true)]$HostEntry)

    $vpnId = Resolve-SSHManagerVpnId -HostEntry $HostEntry -Override ([string]$script:VpnOverride.SelectedValue)
    if ([string]::IsNullOrWhiteSpace($vpnId)) { return }

    $profile = Get-VpnById $vpnId
    if ($null -eq $profile) { throw "Profil VPN dengan ID '$vpnId' tidak ditemukan." }
    $vpnResult = Invoke-SSHManagerVpnConnectAsync -Profile $profile
    if (-not $vpnResult.Success) { throw "VPN '$($profile.Name)' gagal: $($vpnResult.Message)" }
}

function Show-RemotePathPicker {
    param(
        [Parameter(Mandatory = $true)]$Owner,
        [Parameter(Mandatory = $true)]$HostEntry,
        [string]$InitialPath = '~/',
        [switch]$AllowFiles,
        [switch]$AllowMultiple,
        [switch]$FilesOnly
    )

    $pickerWindow = Read-XamlWindow @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Pilih path remote" Width="680" Height="570" MinWidth="580" MinHeight="470" WindowStartupLocation="CenterOwner" Background="#0B1220" Foreground="#E5E7EB" ShowInTaskbar="False">
 <Window.Resources>
  <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#E5E7EB"/></Style>
  <Style TargetType="TextBox"><Setter Property="Foreground" Value="#F8FAFC"/><Setter Property="Background" Value="#0F172A"/><Setter Property="BorderBrush" Value="#334155"/><Setter Property="Padding" Value="8,7"/></Style>
  <Style TargetType="Button"><Setter Property="Foreground" Value="#E5E7EB"/><Setter Property="Background" Value="#263348"/><Setter Property="BorderBrush" Value="#34445D"/><Setter Property="Padding" Value="13,8"/><Setter Property="Margin" Value="4"/></Style>
  <Style TargetType="ListBoxItem"><Setter Property="Foreground" Value="#E5E7EB"/><Setter Property="Background" Value="Transparent"/><Setter Property="Padding" Value="9,7"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#1E3A5F"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#2563EB"/><Setter Property="Foreground" Value="#FFFFFF"/></Trigger></Style.Triggers></Style>
 </Window.Resources>
 <Grid Margin="18">
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <StackPanel><TextBlock Text="Browser file remote" FontSize="23" FontWeight="SemiBold"/><TextBlock x:Name="EndpointText" Foreground="#22C55E" Margin="0,4,0,12"/></StackPanel>
  <Grid Grid.Row="1"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBox x:Name="PathBox"/><Button x:Name="GoButton" Grid.Column="1" Content="Buka path" Margin="8,0,0,0"/></Grid>
  <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,7,0,7"><Button x:Name="HomeButton" Content="Home (~/)"/><Button x:Name="UpButton" Content="Naik"/><Button x:Name="RefreshButton" Content="Refresh"/></StackPanel>
  <Border Grid.Row="3" Background="#0F172A" BorderBrush="#334155" BorderThickness="1" CornerRadius="3">
   <ListBox x:Name="RemoteList" Background="Transparent" BorderThickness="0" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
    <ListBox.ItemTemplate><DataTemplate><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="85"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="{Binding TypeLabel}" Foreground="#94A3B8"/><TextBlock Grid.Column="1" Text="{Binding Name}" TextTrimming="CharacterEllipsis"/></Grid></DataTemplate></ListBox.ItemTemplate>
   </ListBox>
  </Border>
  <TextBlock x:Name="StatusText" Grid.Row="4" Foreground="#94A3B8" TextWrapping="Wrap" Margin="2,9,0,4"/>
  <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,7,0,0"><Button Content="Batal" IsCancel="True"/><Button x:Name="SelectButton" Content="Pilih" IsDefault="True" Background="#16A34A" BorderBrush="#22C55E"/></StackPanel>
 </Grid>
</Window>
'@
    $pickerWindow.Owner = $Owner
    $endpoint = Get-NamedControl $pickerWindow 'EndpointText'
    $pathBox = Get-NamedControl $pickerWindow 'PathBox'
    $go = Get-NamedControl $pickerWindow 'GoButton'
    $homeButton = Get-NamedControl $pickerWindow 'HomeButton'
    $up = Get-NamedControl $pickerWindow 'UpButton'
    $refresh = Get-NamedControl $pickerWindow 'RefreshButton'
    $remoteList = Get-NamedControl $pickerWindow 'RemoteList'
    $status = Get-NamedControl $pickerWindow 'StatusText'
    $select = Get-NamedControl $pickerWindow 'SelectButton'
    $allowFileSelection = [bool]$AllowFiles -or [bool]$FilesOnly
    $filesOnlySelection = [bool]$FilesOnly
    $allowMultipleSelection = [bool]$AllowMultiple -and -not $filesOnlySelection
    $remoteList.SelectionMode = if ($allowMultipleSelection) { [Windows.Controls.SelectionMode]::Extended } else { [Windows.Controls.SelectionMode]::Single }

    $endpoint.Text = ('{0}@{1}:{2}' -f $HostEntry.Username, $HostEntry.HostName, $HostEntry.Port)
    $pathBox.Text = if ([string]::IsNullOrWhiteSpace($InitialPath)) { '~/' } else { $InitialPath }
    $select.Content = if ($filesOnlySelection) { 'Edit file ini' } elseif ($allowFileSelection) { 'Pilih sumber' } else { 'Pilih tujuan' }

    $loadRemotePath = {
        param([string]$RequestedPath)
        try {
            $go.IsEnabled = $false
            $homeButton.IsEnabled = $false
            $up.IsEnabled = $false
            $refresh.IsEnabled = $false
            $select.IsEnabled = $false
            $status.Text = "Membaca folder remote $RequestedPath..."
            [Windows.Forms.Application]::DoEvents()
            $timeout = [Math]::Max(10, [int]$script:Config.App.ConnectTimeoutSeconds)
            $result = Invoke-SSHManagerRemoteDirectoryList -HostEntry $HostEntry -Paths $script:Paths -RemotePath $RequestedPath -TimeoutSeconds $timeout
            $pathBox.Text = [string]$result.Path
            $remoteList.ItemsSource = @($result.Items)
            $remoteList.SelectedIndex = -1
            $status.Text = if ($allowMultipleSelection) {
                ('{0} item — gunakan Ctrl/Shift untuk memilih banyak; double-click folder untuk membukanya.' -f @($result.Items).Count)
            }
            else {
                ('{0} item — double-click folder untuk membukanya.' -f @($result.Items).Count)
            }
        }
        catch {
            $status.Text = $_.Exception.Message
            [Windows.MessageBox]::Show($pickerWindow, $_.Exception.Message, 'Folder remote tidak dapat dibuka', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Error) | Out-Null
        }
        finally {
            $go.IsEnabled = $true
            $homeButton.IsEnabled = $true
            $up.IsEnabled = $true
            $refresh.IsEnabled = $true
            $select.IsEnabled = $true
        }
    }

    $go.Add_Click({ & $loadRemotePath $pathBox.Text.Trim() })
    $homeButton.Add_Click({ & $loadRemotePath '~/' })
    $refresh.Add_Click({ & $loadRemotePath $pathBox.Text.Trim() })
    $up.Add_Click({
        $current = $pathBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($current) -or $current -eq '/') { return }
        $trimmed = $current.TrimEnd('/')
        $lastSlash = $trimmed.LastIndexOf('/')
        $parent = if ($lastSlash -le 0) { '/' } else { $trimmed.Substring(0, $lastSlash) }
        & $loadRemotePath $parent
    })
    $remoteList.Add_SelectionChanged({
        $selectedCount = [int]$remoteList.SelectedItems.Count
        if ($selectedCount -eq 1) {
            $selectedItem = $remoteList.SelectedItems[0]
            $status.Text = ('{0}: {1}' -f $selectedItem.TypeLabel, $selectedItem.FullPath)
        }
        elseif ($selectedCount -gt 1) {
            $status.Text = ('{0} item dipilih. Gunakan Ctrl/Shift untuk menambah atau mengurangi pilihan.' -f $selectedCount)
        }
    })
    $remoteList.Add_MouseDoubleClick({
        $item = $remoteList.SelectedItem
        if ($null -eq $item) { return }
        if ([bool]$item.IsDirectory) {
            & $loadRemotePath ([string]$item.FullPath)
        }
        elseif ($allowFileSelection -and -not $allowMultipleSelection) {
            $pickerWindow.Tag = [pscustomobject]@{
                Paths = @([string]$item.FullPath)
                Path = [string]$item.FullPath
                IsDirectory = $false
                HasDirectory = $false
                FileCount = 1
                FolderCount = 0
                Count = 1
                CurrentDirectory = $pathBox.Text.Trim()
            }
            $pickerWindow.DialogResult = $true
        }
    })
    $select.Add_Click({
        $selectedCount = [int]$remoteList.SelectedItems.Count
        $selectedPaths = New-Object 'Collections.Generic.List[string]'
        $hasDirectory = $false
        $hasFile = $false
        $directoryCount = 0
        $fileCount = 0
        for ($selectedIndex = 0; $selectedIndex -lt $selectedCount; $selectedIndex++) {
            $selectedItem = $remoteList.SelectedItems[$selectedIndex]
            $selectedPaths.Add([string]$selectedItem.FullPath)
            if ([bool]$selectedItem.IsDirectory) { $hasDirectory = $true; $directoryCount++ }
            else { $hasFile = $true; $fileCount++ }
        }
        if ($hasFile -and -not $allowFileSelection) {
            [Windows.MessageBox]::Show($pickerWindow, 'Untuk tujuan upload, pilih sebuah folder remote.', 'Pilih folder', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information) | Out-Null
            return
        }
        if ($filesOnlySelection -and ($selectedCount -ne 1 -or $hasDirectory)) {
            $status.Text = 'Pilih satu file teks. Double-click folder untuk membukanya.'
            return
        }
        if ($selectedCount -gt 0) {
            $pickerWindow.Tag = [pscustomobject]@{
                Paths = [string[]]$selectedPaths.ToArray()
                Path = [string]$selectedPaths[0]
                IsDirectory = ($selectedCount -eq 1 -and $hasDirectory)
                HasDirectory = $hasDirectory
                FileCount = $fileCount
                FolderCount = $directoryCount
                Count = $selectedCount
                CurrentDirectory = $pathBox.Text.Trim()
            }
        }
        else {
            $currentPath = $pathBox.Text.Trim()
            $pickerWindow.Tag = [pscustomobject]@{
                Paths = @($currentPath)
                Path = $currentPath
                IsDirectory = $true
                HasDirectory = $true
                FileCount = 0
                FolderCount = 1
                Count = 1
                CurrentDirectory = $currentPath
            }
        }
        $pickerWindow.DialogResult = $true
    })
    $pickerWindow.Add_Loaded({ & $loadRemotePath $pathBox.Text.Trim() })

    if ($pickerWindow.ShowDialog()) { return $pickerWindow.Tag }
    return $null
}

function Show-ScpDialog {
    try {
        $allHosts = @($script:Config.Hosts | Where-Object { Test-SSHManagerSshEnabled $_ } | Sort-Object Name)
        $nodeRows = @(New-WorkspaceScpNodeRows -Hosts $allHosts -SelectedHosts @(Get-WorkspacePreferredHosts))
        $d = Read-WorkspaceView (Get-Content -LiteralPath (Join-Path $script:ApplicationRoot 'UI\ScpTransfer.xaml') -Raw -Encoding UTF8)
        $hostNameText = Get-NamedControl $d 'HostNameText'
        $endpointText = Get-NamedControl $d 'EndpointText'
        $directionCombo = Get-NamedControl $d 'DirectionCombo'
        $localLabel = Get-NamedControl $d 'LocalLabel'
        $remoteLabel = Get-NamedControl $d 'RemoteLabel'
        $localPathBox = Get-NamedControl $d 'LocalPathBox'
        $remotePathBox = Get-NamedControl $d 'RemotePathBox'
        $browseFile = Get-NamedControl $d 'BrowseFileButton'
        $browseFolder = Get-NamedControl $d 'BrowseFolderButton'
        $browseRemote = Get-NamedControl $d 'BrowseRemoteButton'
        $recursive = Get-NamedControl $d 'RecursiveBox'
        $preserve = Get-NamedControl $d 'PreserveBox'
        $compression = Get-NamedControl $d 'CompressionBox'
        $hint = Get-NamedControl $d 'DirectionHint'
        $start = Get-NamedControl $d 'StartButton'
        $nodeControls = Get-NamedControl $d 'NodeControls'
        $nodeCombo = Get-NamedControl $d 'NodeCombo'
        $applyRemoteAll = Get-NamedControl $d 'ApplyRemoteAllButton'
        $nodeSummaryText = Get-NamedControl $d 'NodeSummaryText'
        $dropZone = Get-NamedControl $d 'DropZone'
        $dropHint = Get-NamedControl $d 'DropHint'
        $localFileList = Get-NamedControl $d 'LocalFileList'
        $nodeList = Get-NamedControl $d 'NodeList'
        $nodeList.ItemsSource = @($nodeRows)
        $hostNameText.Text = 'Centang node untuk transfer'
        $endpointText.Text = 'Pilih node di sebelah kiri.'
        $directionCombo.ItemsSource = @(
            [pscustomobject]@{ Id = 'Upload'; Name = 'Upload — komputer ke server' },
            [pscustomobject]@{ Id = 'Download'; Name = 'Download — server ke komputer' }
        )
        $directionCombo.SelectedValue = 'Upload'

        $transferState = [pscustomobject]@{
            ActiveHostEntry = $null
            ChangingNodes = $false
            Busy = $false
            LaunchedHosts = @()
            NodeStates = @{}
            Direction = ''
            LocalPaths = @()
            LocalDisplay = ''
            LocalHasDirectory = $false
            RemotePaths = @('~/')
            RemoteDisplay = '~/'
            RemoteHasDirectory = $true
            RemoteFileCount = 0
            RemoteFolderCount = 1
            RemoteBrowsePath = '~/'
        }
        $setLocalSelection = {
            param([string[]]$Values, [bool]$HasDirectory)
            $cleanValues = @($Values | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
            $display = if ($cleanValues.Count -eq 0) { '' } elseif ($cleanValues.Count -eq 1) { $cleanValues[0] } else { '{0} file dipilih' -f $cleanValues.Count }
            $transferState.LocalPaths = @($cleanValues)
            $transferState.LocalDisplay = $display
            $transferState.LocalHasDirectory = $HasDirectory
            $localPathBox.Text = $display
            $localFileList.ItemsSource = @($cleanValues)
            $localPathBox.ToolTip = if ($cleanValues.Count -gt 0) { $cleanValues -join "`n" } else { $null }
        }
        $setRemoteSelection = {
            param([object]$Values, [bool]$HasDirectory, [string]$BrowsePath, [int]$FileCount = 0, [int]$FolderCount = 0)
            $cleanValueList = New-Object 'Collections.Generic.List[string]'
            if ($Values -is [string]) {
                if (-not [string]::IsNullOrWhiteSpace([string]$Values)) { $cleanValueList.Add([string]$Values) }
            }
            elseif ($Values -is [Collections.IList]) {
                for ($valueIndex = 0; $valueIndex -lt $Values.Count; $valueIndex++) {
                    $value = [string]$Values[$valueIndex]
                    if (-not [string]::IsNullOrWhiteSpace($value)) { $cleanValueList.Add($value) }
                }
            }
            else {
                $value = [string]$Values
                if (-not [string]::IsNullOrWhiteSpace($value)) { $cleanValueList.Add($value) }
            }
            $cleanValues = [string[]]$cleanValueList.ToArray()
            $display = if ($cleanValues.Count -eq 0) { '' } elseif ($cleanValues.Count -eq 1) { $cleanValues[0] } else { '{0} item remote dipilih' -f $cleanValues.Count }
            $transferState.RemotePaths = @($cleanValues)
            $transferState.RemoteDisplay = $display
            $transferState.RemoteHasDirectory = $HasDirectory
            $transferState.RemoteFileCount = [Math]::Max(0, $FileCount)
            $transferState.RemoteFolderCount = [Math]::Max(0, $FolderCount)
            $transferState.RemoteBrowsePath = if ([string]::IsNullOrWhiteSpace($BrowsePath)) { '~/' } else { $BrowsePath }
            $remotePathBox.Text = $display
            $remotePathBox.ToolTip = if ($cleanValues.Count -gt 0) { $cleanValues -join "`n" } else { $null }
        }

        $saveActiveRemote = {
            if ($null -eq $transferState.ActiveHostEntry) { return }
            $remoteText = $remotePathBox.Text.Trim()
            if ($remoteText -ne $transferState.RemoteDisplay) {
                $transferState.RemotePaths = @($remoteText)
                $transferState.RemoteDisplay = $remoteText
                $transferState.RemoteHasDirectory = $false
                $transferState.RemoteFileCount = 0
                $transferState.RemoteFolderCount = 0
                $transferState.RemoteBrowsePath = if ($remoteText) { $remoteText } else { '~/' }
            }
            $transferState.NodeStates[[string]$transferState.ActiveHostEntry.Id] = [pscustomobject]@{
                RemotePaths = [string[]]@($transferState.RemotePaths)
                RemoteDisplay = [string]$transferState.RemoteDisplay
                RemoteHasDirectory = [bool]$transferState.RemoteHasDirectory
                RemoteFileCount = [int]$transferState.RemoteFileCount
                RemoteFolderCount = [int]$transferState.RemoteFolderCount
                RemoteBrowsePath = [string]$transferState.RemoteBrowsePath
            }
        }
        $getScpSelection = { Get-WorkspaceScpSelectedHosts -Rows $nodeRows }
        $updateNodeSummary = {
            $configured = 0
            $lines = New-Object 'Collections.Generic.List[string]'
            foreach ($node in @(& $getScpSelection)) {
                $entry = $transferState.NodeStates[[string]$node.Id]
                $nodePaths = @($entry.RemotePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($nodePaths.Count -gt 0) { $configured++ }
                $lines.Add(('{0}: {1}' -f $node.Name, ($nodePaths -join ', ')))
            }
            $nodeSummaryText.Text = 'Path remote terisi: {0}/{1} node. Arahkan mouse ke sini untuk melihat daftar path.' -f $configured, @(& $getScpSelection).Count
            $nodeSummaryText.ToolTip = $lines -join "`n"
        }
        $nodeCombo.Add_SelectionChanged({
            if ($transferState.ChangingNodes -or $null -eq $nodeCombo.SelectedItem) { return }
            & $saveActiveRemote
            $transferState.ActiveHostEntry = $nodeCombo.SelectedItem
            $entry = $transferState.NodeStates[[string]$transferState.ActiveHostEntry.Id]
            & $setRemoteSelection -Values ([string[]]@($entry.RemotePaths)) -HasDirectory ([bool]$entry.RemoteHasDirectory) -BrowsePath ([string]$entry.RemoteBrowsePath) -FileCount ([int]$entry.RemoteFileCount) -FolderCount ([int]$entry.RemoteFolderCount)
            $activeNode = $transferState.ActiveHostEntry
            $endpointText.Text = '{0} | {1}@{2}:{3}' -f $activeNode.Name, $activeNode.Username, $activeNode.HostName, $activeNode.Port
            & $updateNodeSummary
        })
        $applyRemoteAll.Add_Click({
            if ($null -eq $transferState.ActiveHostEntry) { return }
            & $saveActiveRemote
            $activeId = [string]$transferState.ActiveHostEntry.Id
            $entry = $transferState.NodeStates[$activeId]
            foreach ($node in @(& $getScpSelection)) {
                if ([string]$node.Id -eq $activeId) { continue }
                $transferState.NodeStates[[string]$node.Id] = [pscustomobject]@{
                    RemotePaths=[string[]]@($entry.RemotePaths); RemoteDisplay=[string]$entry.RemoteDisplay
                    RemoteHasDirectory=[bool]$entry.RemoteHasDirectory; RemoteBrowsePath=[string]$entry.RemoteBrowsePath
                    RemoteFileCount=0; RemoteFolderCount=0
                }
            }
            & $updateNodeSummary
        })
        $remotePathBox.Add_LostKeyboardFocus({ & $saveActiveRemote; & $updateNodeSummary })

        $updateDirection = {
            $currentDirection = [string]$directionCombo.SelectedValue
            $isUpload = ($currentDirection -eq 'Upload')
            if ($transferState.Direction -ne $currentDirection) {
                $transferState.Direction = $currentDirection
                & $setLocalSelection -Values @() -HasDirectory $false
                $defaultRemote = if ($isUpload) { '~/' } else { '' }
                foreach ($node in $allHosts) {
                    $transferState.NodeStates[[string]$node.Id] = [pscustomobject]@{
                        RemotePaths=@($defaultRemote); RemoteDisplay=$defaultRemote; RemoteHasDirectory=$false
                        RemoteFileCount=0; RemoteFolderCount=0; RemoteBrowsePath='~/'
                    }
                }
                & $setRemoteSelection -Values @($defaultRemote) -HasDirectory $false -BrowsePath '~/' -FileCount 0 -FolderCount 0
                & $updateNodeSummary
                $recursive.IsChecked = $false
            }
            $localLabel.Content = if ($isUpload) { 'Sumber lokal' } else { 'Folder tujuan lokal' }
            $remoteLabel.Content = if ($isUpload) { 'Tujuan remote' } else { 'Sumber remote' }
            $browseFile.IsEnabled = $isUpload
            $dropZone.AllowDrop = $isUpload
            $dropHint.Text = if ($isUpload) { 'Tarik file atau folder ke sini untuk upload' } else { 'Pilih sumber remote dan folder tujuan download' }
            $browseFolder.Content = if ($isUpload) { 'Pilih folder...' } else { 'Folder tujuan...' }
            $hint.Text = if ($isUpload) {
                'Upload: sumber lokal yang sama dikirim ke semua node pilihan. Atur folder tujuan per node, atau terapkan path yang sama ke semua node. Recursive aktif otomatis jika sumber berupa folder.'
            }
            else {
                'Download: pilih sumber remote per node dengan Ctrl/Shift. Jika banyak node, hasil disimpan dalam subfolder nama-node-ID di bawah folder tujuan lokal. Satu node memakai folder tujuan langsung.'
            }
        }
        $directionCombo.Add_SelectionChanged($updateDirection)
        & $updateDirection

        $localPathBox.Add_TextChanged({
            if ($localPathBox.Text -ne $transferState.LocalDisplay) {
                $localFileList.ItemsSource = if ([string]::IsNullOrWhiteSpace($localPathBox.Text)) { @() } else { @($localPathBox.Text) }
            }
        })
        $dropZone.Add_PreviewDragOver({
            param($sender,$eventArgs)
            $eventArgs.Effects = if ($directionCombo.SelectedValue -eq 'Upload' -and $eventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { [Windows.DragDropEffects]::Copy } else { [Windows.DragDropEffects]::None }
            $eventArgs.Handled=$true
        })
        $dropZone.Add_Drop({
            param($sender,$eventArgs)
            if ($directionCombo.SelectedValue -ne 'Upload' -or -not $eventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { return }
            $paths=[string[]]@($eventArgs.Data.GetData([Windows.DataFormats]::FileDrop))
            $hasFolder=@($paths | Where-Object { Test-Path -LiteralPath $_ -PathType Container }).Count -gt 0
            & $setLocalSelection -Values $paths -HasDirectory $hasFolder
            $recursive.IsChecked=$hasFolder
            $eventArgs.Handled=$true
        })

        $browseFile.Add_Click({
            $picker = New-Object Microsoft.Win32.OpenFileDialog
            $picker.Title = 'Pilih satu atau beberapa file untuk di-upload'
            $picker.Filter = 'Semua file|*.*'
            $picker.Multiselect = $true
            if ($picker.ShowDialog($script:MainWindow)) {
                & $setLocalSelection -Values ([string[]]@($picker.FileNames)) -HasDirectory $false
                $recursive.IsChecked = $false
            }
        })
        $browseFolder.Add_Click({
            $picker = New-Object Windows.Forms.FolderBrowserDialog
            $picker.Description = if ([string]$directionCombo.SelectedValue -eq 'Upload') { 'Pilih folder untuk di-upload' } else { 'Pilih folder tujuan download' }
            $picker.ShowNewFolderButton = $true
            if (@($transferState.LocalPaths).Count -eq 1 -and (Test-Path -LiteralPath $transferState.LocalPaths[0] -PathType Container)) {
                $picker.SelectedPath = $transferState.LocalPaths[0]
            }
            if ($picker.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
                $isUpload = ([string]$directionCombo.SelectedValue -eq 'Upload')
                & $setLocalSelection -Values @([string]$picker.SelectedPath) -HasDirectory $isUpload
                if ($isUpload) { $recursive.IsChecked = $true }
            }
            $picker.Dispose()
        })
        $browseRemote.Add_Click({
            if ($null -eq $transferState.ActiveHostEntry -or $transferState.Busy) { return }
            $transferState.Busy=$true
            $d.IsEnabled=$false
            try {
                $activeNode = $transferState.ActiveHostEntry
                & $saveActiveRemote
                if ([string]$activeNode.AuthType -eq 'Password') {
                    Initialize-SSHManagerAskPass -Paths $script:Paths | Out-Null
                }
                Ensure-SSHManagerVpnForHost -HostEntry $activeNode
                $isDownload = ([string]$directionCombo.SelectedValue -eq 'Download')
                $remoteSelection = Show-RemotePathPicker -Owner $script:MainWindow -HostEntry $activeNode -InitialPath $transferState.RemoteBrowsePath -AllowFiles:$isDownload -AllowMultiple:$isDownload
                if ($remoteSelection) {
                    $remoteSelectionPaths = New-Object 'Collections.Generic.List[string]'
                    for ($remotePathIndex = 0; $remotePathIndex -lt [int]$remoteSelection.Count; $remotePathIndex++) {
                        $remoteSelectionPaths.Add([string]$remoteSelection.Paths[$remotePathIndex])
                    }
                    & $setRemoteSelection -Values ([string[]]$remoteSelectionPaths.ToArray()) -HasDirectory ([bool]$remoteSelection.HasDirectory) -BrowsePath ([string]$remoteSelection.CurrentDirectory) -FileCount ([int]$remoteSelection.FileCount) -FolderCount ([int]$remoteSelection.FolderCount)
                    if ($isDownload -and [bool]$remoteSelection.HasDirectory) { $recursive.IsChecked = $true }
                    & $saveActiveRemote
                    & $updateNodeSummary
                }
            }
            catch {
                [Windows.MessageBox]::Show($script:MainWindow, $_.Exception.Message, 'Browser remote tidak dapat dibuka', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Error) | Out-Null
            }
            finally { $transferState.Busy=$false; $d.IsEnabled=$true }
        })

        $start.Add_Click({
            if ($transferState.Busy) { return }
            $transferState.Busy=$true
            $d.IsEnabled=$false
            $managerMinimizedForTransfer = $false
            try {
                $selected = @(& $getScpSelection)
                if ($selected.Count -eq 0) { throw 'Centang minimal satu node pada halaman SCP.' }
                $hostEntry=$selected[0]
                if (-not (Get-Command scp.exe -ErrorAction SilentlyContinue)) { throw 'scp.exe tidak ditemukan. Install Windows OpenSSH Client terlebih dahulu.' }
                if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) { throw 'wt.exe tidak ditemukan. Install atau aktifkan Windows Terminal terlebih dahulu.' }
                $direction = [string]$directionCombo.SelectedValue
                $localText = $localPathBox.Text.Trim()
                $remoteText = $remotePathBox.Text.Trim()
                $localPaths = if ($localText -eq $transferState.LocalDisplay) { @($transferState.LocalPaths) } else { @($localText) }
                $remotePaths = if ($remoteText -eq $transferState.RemoteDisplay) { @($transferState.RemotePaths) } else { @($remoteText) }
                $localPaths = @($localPaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
                $remotePaths = @($remotePaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
                if ($localPaths.Count -eq 0) { throw 'Path lokal wajib diisi.' }
                if ($remotePaths.Count -eq 0) { throw 'Path remote wajib diisi.' }
                & $saveActiveRemote
                if ($selected.Count -gt 1) {
                    $plan = New-SSHManagerScpBatchPlan -HostEntries $selected -Direction $direction -LocalPaths ([string[]]$localPaths) -NodeSelections $transferState.NodeStates -Recursive ([bool]$recursive.IsChecked) -PreserveTimes ([bool]$preserve.IsChecked) -Compression ([bool]$compression.IsChecked) -VpnOverride ([string]$script:VpnOverride.SelectedValue)
                    $windowHelper = New-Object -TypeName Windows.Interop.WindowInteropHelper -ArgumentList $script:MainWindow
                    $returnToManagerAfterScp = [bool]$script:Config.App.ReturnToManagerAfterScp
                    if ($returnToManagerAfterScp) {
                        $script:MainWindow.WindowState = [Windows.WindowState]::Minimized
                        $managerMinimizedForTransfer = $true
                    }
                    $statusFile = Start-SSHManagerScpBatch -Plan $plan -Paths $script:Paths -TerminalProfile ([string]$script:Config.App.TerminalProfile) -StartMaximized ([bool]$script:Config.App.StartMaximized) -ReturnToManager $returnToManagerAfterScp -ManagerProcessId $PID -ManagerWindowHandle $windowHelper.Handle.ToInt64()
                    $d.Tag = $statusFile
                    $transferState.LaunchedHosts=@($selected)
                Complete-WorkspaceFeature -Accepted $true -Destination 'ScpActivity'
                    return
                }

                if ([string]$hostEntry.AuthType -eq 'Password') {
                    Initialize-SSHManagerAskPass -Paths $script:Paths | Out-Null
                }

                Ensure-SSHManagerVpnForHost -HostEntry $hostEntry

                if ([bool]$script:Config.App.TestConnectionBeforeOpen) {
                    Set-Status "Menguji $($hostEntry.Name)..."
                    $testResult = @(Invoke-SSHManagerPortChecks -HostEntries @($hostEntry) -Protocol Ssh -Stage ("Menguji {0}..." -f $hostEntry.Name))[0]
                    if (-not $testResult.Success) {
                        $continue = [Windows.MessageBox]::Show($script:MainWindow, "Port SSH belum dapat dijangkau: $($testResult.Message)`n`nTetap mulai transfer?", 'Koneksi belum siap', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Warning)
                        if ($continue -ne [Windows.MessageBoxResult]::Yes) { return }
                    }
                }

                $windowHelper = New-Object -TypeName Windows.Interop.WindowInteropHelper -ArgumentList $script:MainWindow
                $managerWindowHandle = $windowHelper.Handle.ToInt64()
                $returnToManagerAfterScp = [bool]$script:Config.App.ReturnToManagerAfterScp
                $sourceFileCount = 0
                $sourceFolderCount = 0
                if ($direction -eq 'Download') {
                    if ($remoteText -eq $transferState.RemoteDisplay) {
                        $sourceFileCount = [int]$transferState.RemoteFileCount
                        $sourceFolderCount = [int]$transferState.RemoteFolderCount
                    }
                    elseif ([bool]$recursive.IsChecked) {
                        $sourceFolderCount = $remotePaths.Count
                    }
                    else {
                        $sourceFileCount = $remotePaths.Count
                    }
                }
                $statusFile = Join-Path $script:Paths.ScpStatusRoot ('scp-{0}.json' -f [guid]::NewGuid().ToString('N'))
                if ($returnToManagerAfterScp) {
                    $script:MainWindow.WindowState = [Windows.WindowState]::Minimized
                    $managerMinimizedForTransfer = $true
                }
                Start-SSHManagerScp -HostEntry $hostEntry -Paths $script:Paths -Direction $direction -LocalPaths ([string[]]$localPaths) -RemotePaths ([string[]]$remotePaths) -TerminalProfile ([string]$script:Config.App.TerminalProfile) -Recursive ([bool]$recursive.IsChecked) -PreserveTimes ([bool]$preserve.IsChecked) -Compression ([bool]$compression.IsChecked) -StartMaximized ([bool]$script:Config.App.StartMaximized) -ReturnToManager $returnToManagerAfterScp -ManagerProcessId $PID -ManagerWindowHandle $managerWindowHandle -StatusFile $statusFile -SourceFileCount $sourceFileCount -SourceFolderCount $sourceFolderCount
                $hostEntry.LastConnectedAt = (Get-Date).ToString('o')
                Save-CurrentConfig
                $d.Tag = $statusFile
                $transferState.LaunchedHosts=@($selected)
                Complete-WorkspaceFeature -Accepted $true -Destination 'ScpActivity'
            }
            catch {
                if ($managerMinimizedForTransfer) {
                    $script:MainWindow.WindowState = [Windows.WindowState]::Normal
                    [void]$script:MainWindow.Activate()
                }
                [Windows.MessageBox]::Show($script:MainWindow, $_.Exception.Message, 'Transfer belum dapat dimulai', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Error) | Out-Null
                Set-Status $_.Exception.Message '#EF4444'
            }
            finally { $transferState.Busy=$false; $d.IsEnabled=$true }
        })

        $refreshScpSelection = {
            & $saveActiveRemote
            $chosen=@(& $getScpSelection)
            $activeId=if ($transferState.ActiveHostEntry) { [string]$transferState.ActiveHostEntry.Id } else { '' }
            $transferState.ChangingNodes=$true
            try {
                $nodeCombo.ItemsSource=@($chosen)
                $matching=@($chosen | Where-Object { $_.Id -eq $activeId })
                $active=if ($matching.Count -gt 0) { $matching[0] } elseif ($chosen.Count -gt 0) { $chosen[0] } else { $null }
                $transferState.ActiveHostEntry=$active
                if ($null -ne $active) {
                    $nodeCombo.SelectedValue=[string]$active.Id
                    $entry=$transferState.NodeStates[[string]$active.Id]
                    & $setRemoteSelection -Values ([string[]]@($entry.RemotePaths)) -HasDirectory ([bool]$entry.RemoteHasDirectory) -BrowsePath ([string]$entry.RemoteBrowsePath) -FileCount ([int]$entry.RemoteFileCount) -FolderCount ([int]$entry.RemoteFolderCount)
                    $endpointText.Text='{0}@{1}:{2}' -f $active.Username,$active.HostName,$active.Port
                }
                else {
                    & $setRemoteSelection -Values @() -HasDirectory $false -BrowsePath '~/'
                    $endpointText.Text='Centang node pada daftar di sebelah kiri.'
                }
            }
            finally { $transferState.ChangingNodes=$false }
            $nodeControls.IsEnabled=$chosen.Count -gt 0
            $remotePathBox.IsEnabled=$chosen.Count -gt 0
            $browseRemote.IsEnabled=$chosen.Count -gt 0
            $applyRemoteAll.IsEnabled=$chosen.Count -gt 1
            $hostNameText.Text='{0} dari {1} node dipilih' -f $chosen.Count,$allHosts.Count
            $start.Content='Mulai transfer · {0} node' -f $chosen.Count
            $start.IsEnabled=$chosen.Count -gt 0
            & $updateNodeSummary
        }
        $nodeList.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent,[Windows.RoutedEventHandler]{
            param($sender,$eventArgs)
            $checkbox=Get-WorkspaceEventElement -RoutedArgs $eventArgs -Type ([Windows.Controls.CheckBox]) -Tag 'ScpNodeSelection'
            if ($null -eq $checkbox -or $null -eq $checkbox.DataContext) { return }
            $checkbox.DataContext.IsChecked=[bool]$checkbox.IsChecked
            & $refreshScpSelection
            $eventArgs.Handled=$true
        })
        (Get-NamedControl $d 'SelectAllNodesButton').Add_Click({ foreach ($row in $nodeRows) { $row.IsChecked=$true };$nodeList.Items.Refresh();& $refreshScpSelection })
        (Get-NamedControl $d 'ClearNodesButton').Add_Click({ foreach ($row in $nodeRows) { $row.IsChecked=$false };$nodeList.Items.Refresh();& $refreshScpSelection })
        (Get-NamedControl $d 'CancelButton').Add_Click({ Invoke-WorkspaceNavigation 'Connections' })
        (Get-NamedControl $d 'ActivityButton').Add_Click({ Invoke-WorkspaceNavigation 'ScpActivity' })
        & $refreshScpSelection

        if (Show-WorkspaceFeature -View $d -Page 'Scp' -CanLeave { return -not $transferState.Busy }) {
            $selected=@($transferState.LaunchedHosts)
            $hostEntry=$selected[0]
            Reset-WorkspaceTransferActivity -Hosts @($selected) -Direction ([string]$directionCombo.SelectedValue) -StatusFile ([string]$d.Tag)
            if ($selected.Count -gt 1) {
                Set-Status ("Menyiapkan SCP {0} untuk {1} node..." -f [string]$directionCombo.SelectedValue, $selected.Count) '#38BDF8'
            }
            else { Set-Status ("Membuka tab SCP {0} untuk host {1}." -f [string]$directionCombo.SelectedValue, $hostEntry.Name) '#22C55E' }
            if (-not [string]::IsNullOrWhiteSpace([string]$d.Tag)) {
                Register-ScpStatusFile -StatusFile ([string]$d.Tag)
            }
            if (-not [bool]$script:Config.App.ReturnToManagerAfterScp -and [bool]$script:Config.App.CloseManagerAfterLaunch) {
                $script:MainWindow.Close()
            }
        }
    }
    catch {
        Show-ErrorMessage $_.Exception.Message 'SCP tidak dapat dibuka'
        Set-Status $_.Exception.Message '#EF4444'
    }
}

function Test-ManagerStillOpen {
    # A pumped wait lets the user close the window; do not launch anything after that.
    return -not ($script:MainWindow -is [Windows.Window] -and -not $script:MainWindow.IsVisible)
}

function Connect-SelectedHosts {
    param([object[]]$HostEntries=@())
    $connectionProgress = $null
    try {
        $selected = if ($HostEntries.Count -gt 0) { @($HostEntries) } else { @(Get-SelectedHostEntries) }
        $selected = @($selected)
        $layout = [string]$script:LayoutCombo.SelectedValue
        if ($selected.Count -eq 0) {
            $visibleRows = @($script:HostGrid.ItemsSource)
            if ($visibleRows.Count -eq 1) {
                $script:HostGrid.SelectedItem = $visibleRows[0]
                $selected = @($visibleRows[0].Source)
            }
            else {
                throw 'Pilih minimal satu host. Centang kolom Pilih untuk membuka beberapa host pada layout yang sama.'
            }
        }
        $withoutSsh = @($selected | Where-Object { -not (Test-SSHManagerSshEnabled $_) })
        if ($withoutSsh.Count -gt 0) {
            $selected = @($selected | Where-Object { Test-SSHManagerSshEnabled $_ })
            if ($selected.Count -eq 0) { throw 'Host yang dipilih tidak memiliki SSH. Gunakan Buka RDP untuk host RDP.' }
            Write-SSHManagerLog -Component 'SSH' -Action 'Connect' -Message ('{0} host tanpa SSH dilewati: {1}' -f $withoutSsh.Count, (($withoutSsh | ForEach-Object { $_.Name }) -join ', '))
        }
        Set-Status ('Menghubungkan SSH ke {0}...' -f (($selected | ForEach-Object { $_.Name }) -join ', ')) '#38BDF8'

        $connectionProgress = New-ConnectionProgressWindow -Stage 'Menyiapkan koneksi SSH...' -Detail ('{0} host dengan layout {1}' -f $selected.Count, $layout)
        Update-ConnectionProgressWindow -Window $connectionProgress -Stage 'Memeriksa dependensi...' -Detail 'OpenSSH, Windows Terminal, dan password helper'

        $missing = @(Get-SSHManagerDependencyStatus | Where-Object { $_.Required -and -not $_.Available })
        if ($missing.Count -gt 0) {
            throw ('Dependensi wajib belum tersedia: ' + (($missing.Name) -join ', '))
        }
        if (@($selected | Where-Object { $_.AuthType -eq 'Password' }).Count -gt 0) {
            Initialize-SSHManagerAskPass -Paths $script:Paths | Out-Null
        }

        $override = [string]$script:VpnOverride.SelectedValue
        $vpnIds = @()
        if ($override -eq '__HOST__') {
            $vpnIds = @($selected | ForEach-Object { $_.VpnProfileId } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        }
        elseif ($override -ne '__NONE__') { $vpnIds = @($override) }

        foreach ($vpnId in $vpnIds) {
            $profile = Get-VpnById $vpnId
            if ($null -eq $profile) { throw "Profil VPN dengan ID '$vpnId' tidak ditemukan." }
            Update-ConnectionProgressWindow -Window $connectionProgress -Stage "Menghubungkan VPN '$($profile.Name)'..." -Detail 'Menunggu koneksi VPN terdeteksi aktif'
            $result = Invoke-SSHManagerVpnConnectAsync -Profile $profile -ProgressWindow $connectionProgress
            if (-not $result.Success) { throw "VPN '$($profile.Name)' gagal terhubung; SSH dibatalkan. $($result.Message)" }
            if (-not (Test-ManagerStillOpen)) { return }
        }

        if ([bool]$script:Config.App.TestConnectionBeforeOpen) {
            $hostsToTest = @($selected)
            :connectionRetry do {
                $progressStage = if ($hostsToTest.Count -eq 1) { 'Menghubungkan {0}' -f $hostsToTest[0].Name } else { 'Menguji port SSH {0} host' -f $hostsToTest.Count }
                $checks = @(Invoke-SSHManagerPortChecks -HostEntries $hostsToTest -Protocol Ssh -ProgressWindow $connectionProgress -Stage $progressStage)
                if (-not (Test-ManagerStillOpen)) { return }
                $failed = @($checks | Where-Object { -not $_.Success } | ForEach-Object {
                    [pscustomobject]@{ Host = $_.Host; Message = [string]$_.Message; Milliseconds = [long]$_.Milliseconds }
                })

                if ($failed.Count -eq 0) { break connectionRetry }

                Close-ConnectionProgressWindow -Window $connectionProgress
                $connectionProgress = $null
                Set-Status ('{0} host belum dapat dijangkau. Menunggu pilihan pengguna.' -f $failed.Count) '#F59E0B'
                $failureChoice = Show-ConnectionFailureDialog -Failures ([object[]]$failed)
                switch ($failureChoice) {
                    'Continue' { break connectionRetry }
                    'Retry' {
                        $hostsToTest = @($failed | ForEach-Object { $_.Host })
                        $connectionProgress = New-ConnectionProgressWindow -Stage 'Mencoba kembali koneksi SSH...' -Detail ('{0} host yang sebelumnya gagal' -f $hostsToTest.Count)
                        continue connectionRetry
                    }
                    default {
                        Set-Status 'Pembukaan SSH dibatalkan.' '#F59E0B'
                        return
                    }
                }
            } while ($true)
        }

        if ($null -eq $connectionProgress -or -not $connectionProgress.IsVisible) {
            $connectionProgress = New-ConnectionProgressWindow -Stage 'Membuka Windows Terminal...' -Detail ('Membuat workspace dengan layout {0}' -f $layout)
        }
        Update-ConnectionProgressWindow -Window $connectionProgress -Stage 'Membuka Windows Terminal...' -Detail ('Membuat workspace dengan layout {0}' -f $layout)
        Start-SSHManagerLayout -Hosts $selected -Paths $script:Paths -Layout $layout -TerminalProfile ([string]$script:Config.App.TerminalProfile) -StartMaximized ([bool]$script:Config.App.StartMaximized)
        $now = (Get-Date).ToString('o')
        foreach ($hostEntry in $selected) { $hostEntry.LastConnectedAt = $now }
        Save-CurrentConfig
        $layoutCapacity = @{ Single = 1; TwoColumns = 2; TwoRows = 2; TopOneBottomTwo = 3; TopTwoBottomOne = 3; FourGrid = 4 }[$layout]
        if ($selected.Count -eq 1 -and $layoutCapacity -gt 1) {
            Set-Status ("Membuka host {0} pada {1} panel dengan layout {2}." -f $selected[0].Name, $layoutCapacity, $layout) '#22C55E'
        }
        else {
            Set-Status ("Membuka {0} host dengan layout {1}." -f $selected.Count, $layout) '#22C55E'
        }
        if ([bool]$script:Config.App.CloseManagerAfterLaunch) { $script:MainWindow.Close() }
    }
    catch {
        Close-ConnectionProgressWindow -Window $connectionProgress
        $connectionProgress = $null
        Write-SSHManagerLog -Level ERROR -Component 'SSH' -Action 'Connect' -Message 'Gagal membuka SSH' -ErrorRecord $_
        Show-ErrorMessage ("Tidak dapat membuka koneksi SSH.`n`nDetail:`n{0}" -f $_.Exception.Message) 'Gagal membuka SSH'
        Set-Status ('SSH gagal — {0}' -f $_.Exception.Message) '#EF4444'
    }
    finally {
        Close-ConnectionProgressWindow -Window $connectionProgress
    }
}

function Invoke-PageSelectionAction {
    param([ValidateSet('Edit','Duplicate','Delete','Connect')][string]$Action)
    # On RDP Manager the RDP table selection is the target; elsewhere the Connections selection is.
    if ($script:WorkspaceState.Page -eq 'Rdp') {
        $selected = @(Get-RdpSelectedHosts)
        if ($selected.Count -eq 0) { Show-Warning 'Pilih host pada tabel RDP Manager terlebih dahulu.'; return }
        switch ($Action) {
            'Edit' { Edit-Host -HostEntry $selected[0] }
            'Duplicate' { Duplicate-Host -HostEntry $selected[0] }
            'Delete' { Delete-Hosts -HostEntries $selected }
            'Connect' { Start-RdpLaunchBatch -Hosts $selected -VpnOverride (Get-RdpVpnOverride) }
        }
        return
    }
    switch ($Action) {
        'Edit' { Edit-Host }
        'Duplicate' { Duplicate-Host }
        'Delete' { Delete-Hosts }
        'Connect' { Connect-SelectedHosts }
    }
}

function Export-ConfigurationUi {
    $picker=New-Object Microsoft.Win32.SaveFileDialog;$picker.Title='Export konfigurasi';$picker.Filter='Proper SSH Manager JSON|*.json';$picker.FileName='proper-ssh-manager-config.json'
    if ($picker.ShowDialog($script:MainWindow)) {
        Export-SSHManagerConfig -Config $script:Config -Destination $picker.FileName
        Show-Info "Konfigurasi berhasil diekspor.`n`nPassword tidak disertakan." 'Export selesai'
    }
}

function Import-ConfigurationUi {
    $picker=New-Object Microsoft.Win32.OpenFileDialog;$picker.Title='Import konfigurasi';$picker.Filter='Proper SSH Manager JSON|*.json|Semua file|*.*'
    if (-not $picker.ShowDialog($script:MainWindow)) { return }
    if (-not (Confirm-Action 'Import akan mengganti daftar host dan VPN saat ini. Backup otomatis akan dibuat. Lanjutkan?' 'Import konfigurasi')) { return }
    try {
        $script:Config = Import-SSHManagerConfig -Source $picker.FileName
        $script:CheckedHostIds.Clear()
        Save-CurrentConfig
        Refresh-AllViews
        Show-Info 'Konfigurasi berhasil diimpor. Password tidak berada di file export; masukkan kembali password pada host yang memerlukannya.' 'Import selesai'
    }
    catch { Show-ErrorMessage $_.Exception.Message 'Import gagal' }
}

try {
    $mainXaml = Get-Content -LiteralPath (Join-Path $script:ApplicationRoot 'UI\MainWindow.xaml') -Raw -Encoding UTF8
    $script:MainWindow = Read-XamlWindow $mainXaml
    foreach ($name in @('SearchBox','GroupFilter','VpnOverride','LayoutCombo','HostGrid','StatusText','CountText','DetailName','DetailEndpoint','DetailProtocols','DetailGroup','DetailAuth','DetailVpn','DetailTags','DetailNotes')) { Set-Variable -Scope Script -Name $name -Value (Get-NamedControl $script:MainWindow $name) }

    Initialize-WorkspaceUi
    # Last line of defence: an unexpected handler error is logged and reported instead of closing the app.
    $script:MainWindow.Dispatcher.Add_UnhandledException({
        param($sender, $dispatcherArgs)
        $dispatcherArgs.Handled = $true
        try {
            $baseException = $dispatcherArgs.Exception.GetBaseException()
            Show-AppError -Summary 'Terjadi kesalahan yang tidak terduga. Aplikasi tetap berjalan.' -Detail $baseException.Message -Component 'UI' -Action 'UnhandledException' -ErrorRecord $dispatcherArgs.Exception
            Set-Status 'Terjadi kesalahan; detail tersimpan di log.' '#EF4444'
        }
        catch { }
    })
    Write-SSHManagerLog -Component 'App' -Action 'Startup' -Message ('Proper SSH Manager {0} dimulai; {1} host.' -f $script:AppVersion, @($script:Config.Hosts).Count)

    $script:ScpStatusTimer = New-Object Windows.Threading.DispatcherTimer
    $script:ScpStatusTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:ScpStatusTimer.Add_Tick({ Update-PendingScpStatus })
    foreach ($completedStatus in @(Get-ChildItem -LiteralPath $script:Paths.ScpStatusRoot -Filter 'scp-*.json' -File -ErrorAction SilentlyContinue)) {
        Register-ScpStatusFile -StatusFile $completedStatus.FullName
    }
    $script:ScpStatusTimer.Start()

    $events = @{
        BtnAddHost = { Add-Host }; MenuAddHost = { Add-Host }
        MenuEditHost = { Invoke-PageSelectionAction 'Edit' }; MenuDuplicateHost = { Invoke-PageSelectionAction 'Duplicate' }; MenuDeleteHost = { Invoke-PageSelectionAction 'Delete' }
        BtnRdp = { Start-RdpLaunchBatch -Hosts @(Get-SelectedHostEntries) -VpnOverride ([string]$script:VpnOverride.SelectedValue) }
        MenuRdpManager = { Invoke-WorkspaceNavigation 'Rdp' }
        BtnScp = { Invoke-WorkspaceNavigation 'Scp' }; MenuScp = { Invoke-WorkspaceNavigation 'Scp' }
        BtnEditFile = { Invoke-WorkspaceNavigation 'Editor' }; MenuEditFile = { Invoke-WorkspaceNavigation 'Editor' }
        BtnConnect = { Connect-SelectedHosts }; BtnTest = { Test-SelectedHosts }
        MenuVpnProfiles = { Invoke-WorkspaceNavigation 'Vpn' }; MenuSettings = { Invoke-WorkspaceNavigation 'Settings' }
        MenuDependencies = { Show-DependencyDialog }; MenuImport = { Import-ConfigurationUi }
        MenuExport = { Export-ConfigurationUi }
    }
    foreach ($entry in $events.GetEnumerator()) { (Get-NamedControl $script:MainWindow $entry.Key).Add_Click($entry.Value) }
    (Get-NamedControl $script:MainWindow 'MenuExit').Add_Click({$script:MainWindow.Close()})
    (Get-NamedControl $script:MainWindow 'MenuOpenData').Add_Click({Start-Process explorer.exe -ArgumentList $script:Paths.DataRoot})
    (Get-NamedControl $script:MainWindow 'MenuAbout').Add_Click({
        Show-Info "Proper SSH Manager $($script:AppVersion)`n`nPowerShell WPF SSH/SCP/RDP workspace manager untuk Windows 10/11.`nPassword SSH dilindungi DPAPI CurrentUser; credential RDP di Windows Credential Manager." 'Tentang'
    })
    (Get-NamedControl $script:MainWindow 'MenuShortcuts').Add_Click({
        Show-Info "Ctrl+Alt+S       Buka manager dari Windows`nCtrl+Shift+F12  Buka manager dari Windows Terminal`n`nCtrl+F           Fokus pencarian`nCtrl+N           Tambah host`nCtrl+E           Edit host`nCtrl+D           Duplikat host`nCtrl+Shift+S     Transfer SCP`nCtrl+Shift+E     Edit file remote`nCtrl+Shift+R     RDP Manager`nDelete           Hapus host`nCtrl+Enter       Buka SSH`nF5               Refresh`nAlt+1..6         Pilih layout`nCheckbox Pilih   Pilih host untuk setiap panel`nCtrl+klik         Tambah pilihan row`nShift+klik        Pilih rentang row`nCtrl+A            Pilih semua row (saat tabel fokus)" 'Shortcut keyboard'
    })
    (Get-NamedControl $script:MainWindow 'MenuDisconnectVpn').Add_Click({
        $id = [string]$script:VpnOverride.SelectedValue
        if ($id -eq '__HOST__' -or $id -eq '__NONE__') {
            Show-Warning 'Pilih profil tertentu pada field VPN saat connect terlebih dahulu.'
            return
        }
        $profile = Get-VpnById $id
        if ($profile) {
            $result = Invoke-SSHManagerVpnDisconnectAsync -Profile $profile
            if ($result.Success) { Show-Info $result.Message 'VPN' }
            else { Show-ErrorMessage $result.Message 'VPN' }
        }
    })

    $script:SearchBox.Add_TextChanged({if(-not$script:IsRefreshing){Refresh-HostGrid}})
    $script:GroupFilter.Add_SelectionChanged({if(-not$script:IsRefreshing){Refresh-HostGrid}})
    $script:HostGrid.Add_SelectionChanged({Update-HostDetails; Update-WorkspaceSelection})
    $hostSelectionClickHandler = [System.Windows.RoutedEventHandler]{
        param($sender, $eventArgs)
        # Source is the DataGrid for templated cells; resolve the clicked CheckBox from OriginalSource.
        $checkBox = Get-WorkspaceEventElement -RoutedArgs $eventArgs -Type ([System.Windows.Controls.CheckBox]) -Tag 'HostSelection'
        if ($null -eq $checkBox) { return }

        $row = $checkBox.DataContext
        if ($null -eq $row -or [string]::IsNullOrWhiteSpace([string]$row.Id)) { return }
        $row.IsChecked = [bool]$checkBox.IsChecked
        if ([bool]$checkBox.IsChecked) {
            [void]$script:CheckedHostIds.Add([string]$row.Id)
        }
        else {
            [void]$script:CheckedHostIds.Remove([string]$row.Id)
        }

        $checkedRows = @($script:HostGrid.ItemsSource | Where-Object { [bool]$_.IsChecked })
        Update-HostDetails
        Update-WorkspaceSelection
        if ($checkedRows.Count -gt 0) {
            Set-Status ('{0} host dipilih: {1}' -f $checkedRows.Count, (($checkedRows | ForEach-Object { $_.Name }) -join ', ')) '#38BDF8'
        }
        else {
            Set-Status 'Pilihan checkbox dikosongkan. Klik row atau centang host yang ingin dibuka.'
        }
    }
    $script:HostGrid.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $hostSelectionClickHandler)
    $script:HostGrid.Add_MouseDoubleClick({
        param($sender,$eventArgs)
        $source=$eventArgs.OriginalSource
        while ($null -ne $source -and $source -ne $script:HostGrid) {
            if ($source -is [Windows.Controls.Primitives.ButtonBase]) { return }
            if ($source -isnot [Windows.Media.Visual]) { return }
            $source=[Windows.Media.VisualTreeHelper]::GetParent($source)
        }
        $doubleClickSelection = @(Get-SelectedHostEntries)
        if ($doubleClickSelection.Count -eq 1) {
            Connect-SelectedHosts
        }
    })
    $script:LayoutCombo.Add_SelectionChanged({
        if (-not $script:IsRefreshing -and $script:LayoutCombo.SelectedValue) {
            $script:Config.App.DefaultLayout = [string]$script:LayoutCombo.SelectedValue
            Save-CurrentConfig
            Update-WorkspaceLayoutPreview
        }
    })

    $script:MainWindow.Add_PreviewKeyDown({
        param($sender, $eventArgs)
        if ($null -ne $script:WorkspaceState.ActiveFeature) { return }
        $ctrl = [Windows.Input.Keyboard]::Modifiers.HasFlag([Windows.Input.ModifierKeys]::Control)
        $alt = [Windows.Input.Keyboard]::Modifiers.HasFlag([Windows.Input.ModifierKeys]::Alt)
        $shift = [Windows.Input.Keyboard]::Modifiers.HasFlag([Windows.Input.ModifierKeys]::Shift)

        if ($ctrl -and $eventArgs.Key -eq [Windows.Input.Key]::F) {
            Set-WorkspacePage 'Connections'
            $script:SearchBox.Focus() | Out-Null
            $script:SearchBox.SelectAll()
            $eventArgs.Handled = $true
        }
        elseif ($ctrl -and $eventArgs.Key -eq [Windows.Input.Key]::N) { Add-Host; $eventArgs.Handled = $true }
        elseif ($ctrl -and $shift -and $eventArgs.Key -eq [Windows.Input.Key]::E) { Invoke-WorkspaceNavigation 'Editor'; $eventArgs.Handled = $true }
        elseif ($ctrl -and $shift -and $eventArgs.Key -eq [Windows.Input.Key]::R) { Invoke-WorkspaceNavigation 'Rdp'; $eventArgs.Handled = $true }
        elseif ($ctrl -and $eventArgs.Key -eq [Windows.Input.Key]::E) { Invoke-PageSelectionAction 'Edit'; $eventArgs.Handled = $true }
        elseif ($ctrl -and $eventArgs.Key -eq [Windows.Input.Key]::D) { Invoke-PageSelectionAction 'Duplicate'; $eventArgs.Handled = $true }
        elseif ($ctrl -and $shift -and $eventArgs.Key -eq [Windows.Input.Key]::S) { Invoke-WorkspaceNavigation 'Scp'; $eventArgs.Handled = $true }
        elseif ($ctrl -and $eventArgs.Key -eq [Windows.Input.Key]::Enter) { Invoke-PageSelectionAction 'Connect'; $eventArgs.Handled = $true }
        elseif ($eventArgs.Key -eq [Windows.Input.Key]::F5) { Refresh-AllViews; Set-Status 'Daftar diperbarui.'; $eventArgs.Handled = $true }
        elseif ($eventArgs.Key -eq [Windows.Input.Key]::Delete -and -not ([Windows.Input.Keyboard]::FocusedElement -is [Windows.Controls.Primitives.TextBoxBase])) {
            Invoke-PageSelectionAction 'Delete'
            $eventArgs.Handled = $true
        }
        elseif ($alt -and $eventArgs.Key -ge [Windows.Input.Key]::D1 -and $eventArgs.Key -le [Windows.Input.Key]::D6) {
            $index = [int]$eventArgs.Key - [int][Windows.Input.Key]::D1
            $script:LayoutCombo.SelectedIndex = $index
            $eventArgs.Handled = $true
        }
    })

    Refresh-AllViews
    $script:MainWindow.ShowDialog() | Out-Null
}
catch {
    Write-SSHManagerLog -Level ERROR -Component 'App' -Action 'Fatal' -Message 'Aplikasi berhenti karena error.' -ErrorRecord $_
    [Windows.MessageBox]::Show("Aplikasi berhenti karena error:`n`n$($_.Exception.GetBaseException().Message)`n`nLog teknis: $(Get-SSHManagerLogFile)",'Proper SSH Manager',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Error)|Out-Null
    throw
}
finally {
    if ($script:ScpStatusTimer) { $script:ScpStatusTimer.Stop() }
    if ($script:SingleInstanceMutex) { $script:SingleInstanceMutex.ReleaseMutex(); $script:SingleInstanceMutex.Dispose() }
}
