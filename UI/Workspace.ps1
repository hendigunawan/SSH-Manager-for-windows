# One visible workspace window; UserControl pages retain their controller scope until navigation.
$script:WorkspaceState = @{ Ready=$false; Initialized=$false; ActiveFeature=$null; Page='Connections'; RequestedPage=$null; Routing=$false; LastTransfer=$null; ActiveStatusFile=$null; NavigationHosts=$null }
# Sidebar buttons are named 'Nav'+page; built-in pages are Grids named page+'Page' inside MainWindow.
$script:WorkspaceNavPages = @('Connections','Layout','Scp','Editor','Rdp','Vpn','Settings')
$script:WorkspaceBuiltInPages = @('Connections','Layout','Scp','Rdp')
$script:WorkspaceTheme = $null
$script:WorkspaceSidebar = $null

function Add-WorkspaceResourceReference {
    param([xml]$Document)
    $ns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
    $root=$Document.DocumentElement
    $resourceName=$root.LocalName+'.Resources'
    $resources=$root.SelectSingleNode("*[local-name()='$resourceName']")
    if ($null -eq $resources) { $resources=$Document.CreateElement($resourceName,$ns); [void]$root.PrependChild($resources) }
    # Existing resources use implicit dictionary syntax; move them into an explicit dictionary.
    $dictionary=$resources.SelectSingleNode("*[local-name()='ResourceDictionary']")
    if ($null -eq $dictionary) {
        $dictionary=$Document.CreateElement('ResourceDictionary',$ns)
        while ($resources.HasChildNodes) { [void]$dictionary.AppendChild($resources.FirstChild) }
        [void]$resources.AppendChild($dictionary)
    }
    $merged=$dictionary.SelectSingleNode("*[local-name()='ResourceDictionary.MergedDictionaries']")
    if ($null -eq $merged) { $merged=$Document.CreateElement('ResourceDictionary.MergedDictionaries',$ns); [void]$dictionary.PrependChild($merged) }
    $theme=$Document.CreateElement('ResourceDictionary',$ns)
    $theme.SetAttribute('Source',([uri]::new((Join-Path $script:ApplicationRoot 'UI/Theme.xaml'),[UriKind]::Absolute)).AbsoluteUri)
    [void]$merged.AppendChild($theme)
}

function Apply-WorkspaceTheme {
    param($Window)
    if ($null -eq $script:WorkspaceTheme) {
        [xml]$themeXml=Get-Content -LiteralPath (Join-Path $script:ApplicationRoot 'UI/Theme.xaml') -Raw -Encoding UTF8
        $reader=New-Object Xml.XmlNodeReader $themeXml
        try { $script:WorkspaceTheme=[Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    }
    foreach ($key in @($script:WorkspaceTheme.Keys)) { $Window.Resources[$key]=$script:WorkspaceTheme[$key] }
    $Window.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#080F19')
    $Window.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#E7EEF8')
    $Window.FontFamily=[Windows.Media.FontFamily]::new('Segoe UI')
    $Window.FontSize=12
    $queue=New-Object Collections.Queue; $queue.Enqueue($Window)
    while ($queue.Count -gt 0) {
        $element=$queue.Dequeue()
        if ($element -is [Windows.Controls.Button] -and [string]$element.Background -in @('#FF16A34A','#FF22C55E')) {
            $element.ClearValue([Windows.Controls.Control]::BackgroundProperty)
            $element.ClearValue([Windows.Controls.Control]::BorderBrushProperty)
            $element.SetResourceReference([Windows.FrameworkElement]::StyleProperty,'PrimaryButton')
        }
        if ($element -is [Windows.DependencyObject]) {
            foreach ($child in [Windows.LogicalTreeHelper]::GetChildren($element)) { if ($child -is [Windows.DependencyObject]) { $queue.Enqueue($child) } }
        }
    }
}

function Get-OptionalControl {
    param($Window,[string]$Name)
    # FindName returns $null for unknown names; callers decide how to degrade instead of crashing.
    if ($null -eq $Window -or $null -eq $Window.PSObject.Methods['FindName']) { return $null }
    return $Window.FindName($Name)
}

function Get-WorkspaceEventElement {
    param($RoutedArgs,[type]$Type,[string]$Tag='')
    # Routed events from DataTemplates report the ItemsControl as Source; walk from OriginalSource instead.
    $element=$RoutedArgs.OriginalSource
    while ($null -ne $element) {
        if ($element -is $Type -and ([string]::IsNullOrEmpty($Tag) -or [string]$element.Tag -eq $Tag)) { return $element }
        if ($element -isnot [Windows.DependencyObject]) { return $null }
        $parent=$null
        if ($element -is [Windows.Media.Visual] -or $element -is [Windows.Media.Media3D.Visual3D]) { $parent=[Windows.Media.VisualTreeHelper]::GetParent($element) }
        if ($null -eq $parent) { $parent=[Windows.LogicalTreeHelper]::GetParent($element) }
        $element=$parent
    }
    return $null
}

function Set-WorkspaceSidebarSelection {
    param($Sidebar,[string]$Page)
    if ($null -eq $Sidebar) { return }
    foreach ($name in $script:WorkspaceNavPages) {
        $button=Get-OptionalControl $Sidebar ('Nav'+$name)
        if ($null -eq $button) { continue }
        $button.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($(if ($name -eq $Page) { '#0D4AAA' } else { 'Transparent' }))
        $button.BorderBrush=[Windows.Media.BrushConverter]::new().ConvertFromString($(if ($name -eq $Page) { '#246DD0' } else { 'Transparent' }))
    }
}

function New-WorkspaceSidebar {
    param([string]$Page)
    [xml]$xml=Get-Content -LiteralPath (Join-Path $script:ApplicationRoot 'UI/Sidebar.xaml') -Raw -Encoding UTF8
    Add-WorkspaceResourceReference $xml
    $reader=New-Object Xml.XmlNodeReader $xml
    try { $sidebar=[Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    Set-WorkspaceSidebarSelection $sidebar $Page
    foreach ($name in $script:WorkspaceNavPages) {
        $navButton=Get-OptionalControl $sidebar ('Nav'+$name)
        if ($null -eq $navButton) { throw "Navigasi sidebar 'Nav$name' tidak ditemukan." }
        $navButton.Add_Click({
            param($sender,$eventArgs)
            Invoke-WorkspaceNavigation ([string]$sender.Tag)
            $eventArgs.Handled=$true
        })
    }
    return $sidebar
}

function Read-WorkspaceView {
    param([Parameter(Mandatory=$true)][string]$Xaml)
    # Read-XamlWindow is the common theme-aware XAML loader; this root is a UserControl.
    return Read-XamlWindow $Xaml
}

function Test-WorkspaceCanLeave {
    $feature=$script:WorkspaceState.ActiveFeature
    if ($null -eq $feature) { return $true }
    if ($feature.CheckingLeave) { return $false }
    if ($null -eq $feature.CanLeave) { return $true }
    $feature.CheckingLeave=$true
    try { return [bool](& $feature.CanLeave) }
    finally { $feature.CheckingLeave=$false }
}

function Complete-WorkspaceFeature {
    param([bool]$Accepted=$false,[string]$Destination='Connections')
    $feature=$script:WorkspaceState.ActiveFeature
    if ($null -eq $feature) { return }
    $feature.Accepted=$Accepted
    $script:WorkspaceState.RequestedPage=$Destination
    $feature.Frame.Continue=$false
}

function New-WorkspaceDispatcherFrame { return (New-Object Windows.Threading.DispatcherFrame) }
function Enter-WorkspaceDispatcherFrame {
    param($Frame)
    [Windows.Threading.Dispatcher]::PushFrame($Frame)
}

function Mount-WorkspaceFeatureView {
    param($View,[string]$Page)
    foreach ($candidate in $script:WorkspaceBuiltInPages) {
        (Get-NamedControl $script:MainWindow ($candidate+'Page')).Visibility='Collapsed'
    }
    $hostControl=Get-NamedControl $script:MainWindow 'FeatureHost'
    $hostControl.Content=$View
    $hostControl.Visibility='Visible'
    $script:WorkspaceState.Page=$Page
    Set-WorkspaceSidebarSelection $script:WorkspaceSidebar $Page
}

function Show-WorkspaceFeature {
    param($View,[ValidateSet('Scp','Editor','Vpn','Settings')][string]$Page,[scriptblock]$CanLeave=$null)
    if ($null -ne $script:WorkspaceState.ActiveFeature) { throw 'Halaman aktif harus ditutup sebelum halaman lain dipasang.' }
    $feature=[pscustomobject]@{View=$View;Page=$Page;Frame=(New-WorkspaceDispatcherFrame);CanLeave=$CanLeave;CheckingLeave=$false;Accepted=$false}
    $script:WorkspaceState.ActiveFeature=$feature
    $mainMenu=Get-NamedControl $script:MainWindow 'MainMenu'
    $menuWasEnabled=$mainMenu.IsEnabled
    try {
        $mainMenu.IsEnabled=$false
        Mount-WorkspaceFeatureView -View $View -Page $Page
        # Keep each controller's PowerShell scope alive for its handlers. Unlike ShowDialog,
        # this pumps the existing main-window dispatcher and creates no feature window.
        Enter-WorkspaceDispatcherFrame -Frame $feature.Frame
        return $feature.Accepted
    }
    finally {
        $hostControl=Get-NamedControl $script:MainWindow 'FeatureHost'
        $hostControl.Content=$null
        $hostControl.Visibility='Collapsed'
        $script:WorkspaceState.ActiveFeature=$null
        $mainMenu.IsEnabled=$menuWasEnabled
    }
}

function Set-WorkspacePage {
    param([ValidateSet('Connections','Layout','ScpActivity','Rdp')][string]$Page)
    $script:WorkspaceState.Page=$Page
    (Get-NamedControl $script:MainWindow 'FeatureHost').Visibility='Collapsed'
    $visiblePage=if ($Page -eq 'ScpActivity') {'Scp'} else {$Page}
    foreach ($candidate in $script:WorkspaceBuiltInPages) {
        (Get-NamedControl $script:MainWindow ($candidate+'Page')).Visibility=if ($candidate -eq $visiblePage) { 'Visible' } else { 'Collapsed' }
    }
    Set-WorkspaceSidebarSelection $script:WorkspaceSidebar $visiblePage
    if ($Page -eq 'Layout') { Update-WorkspaceLayoutPreview }
    if ($Page -eq 'Rdp') { Update-RdpManagerView }
}

function Invoke-WorkspaceNavigation {
    param([ValidateSet('Connections','Layout','Scp','ScpActivity','Editor','Rdp','Vpn','Settings')][string]$Page)
    if ($null -ne $script:WorkspaceState.ActiveFeature) {
        if ($Page -eq $script:WorkspaceState.ActiveFeature.Page) { return }
        if (Test-WorkspaceCanLeave) { Complete-WorkspaceFeature -Destination $Page }
        return
    }
    if ($script:WorkspaceState.Routing) { return }
    $script:WorkspaceState.Routing=$true
    try {
        $destination=$Page
        do {
            $script:WorkspaceState.RequestedPage=$null
            switch ($destination) {
                'Connections' { Set-WorkspacePage 'Connections' }
                'Layout' { Set-WorkspacePage 'Layout' }
                'ScpActivity' { Set-WorkspacePage 'ScpActivity' }
                'Rdp' { Set-WorkspacePage 'Rdp' }
                'Scp' { Show-ScpDialog }
                'Editor' { Show-RemoteTextEditor }
                'Vpn' { Show-VpnManager }
                'Settings' { Show-SettingsDialog }
            }
            $destination=$script:WorkspaceState.RequestedPage
        } while ($destination -and $script:MainWindow.IsVisible)
        if ($script:MainWindow.IsVisible -and $script:WorkspaceState.Page -in @('Scp','Editor','Vpn','Settings')) { Set-WorkspacePage 'Connections' }
    }
    catch { Set-WorkspacePage 'Connections'; Show-ErrorMessage $_.Exception.Message 'Workspace' }
    finally { $script:WorkspaceState.RequestedPage=$null; $script:WorkspaceState.NavigationHosts=$null; $script:WorkspaceState.Routing=$false }
}

function Wait-WorkspaceCondition {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$Until,
        [scriptblock]$OnTick=$null,
        [int]$IntervalMilliseconds=100,
        [int]$TimeoutSeconds=0
    )
    # Keeps the UI thread pumping (repaint, progress text) while the awaited work runs elsewhere
    # (runspace or async socket). The main window is disabled meanwhile, so no second action can start.
    # The tick handler is a closure over its own locals only: nested waits can never stop each other's frame.
    if (& $Until) { return }
    $waitFrame=New-Object Windows.Threading.DispatcherFrame
    $waitTimer=New-Object Windows.Threading.DispatcherTimer
    $waitTimer.Interval=[TimeSpan]::FromMilliseconds($IntervalMilliseconds)
    # TimeoutSeconds > 0 bounds the wait; the caller receives a TimeoutException and cleans up its own work.
    $waitState=@{ Error=$null; TimedOut=$false; Watch=[Diagnostics.Stopwatch]::StartNew() }
    $waitTimer.Add_Tick({
        $waitTimer.Stop()
        try {
            if ($null -ne $OnTick) { & $OnTick }
            if (& $Until) { $waitFrame.Continue=$false; return }
            if ($TimeoutSeconds -gt 0 -and $waitState.Watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { $waitState.TimedOut=$true; $waitFrame.Continue=$false; return }
            $waitTimer.Start()
        }
        catch { $waitState.Error=$_; $waitFrame.Continue=$false }
    }.GetNewClosure())
    $lockWindow=$script:MainWindow -is [Windows.Window] -and $script:MainWindow.IsEnabled
    if ($lockWindow) { $script:MainWindow.IsEnabled=$false }
    try {
        $waitTimer.Start()
        [Windows.Threading.Dispatcher]::PushFrame($waitFrame)
    }
    finally {
        $waitTimer.Stop()
        if ($lockWindow) { $script:MainWindow.IsEnabled=$true }
    }
    if ($null -ne $waitState.Error) { throw $waitState.Error }
    if ($waitState.TimedOut) { throw (New-Object TimeoutException ('Tidak selesai dalam {0} detik.' -f $TimeoutSeconds)) }
}

function Get-WorkspacePreferredHosts {
    # A row action (e.g. "SCP Transfer" from the ... menu) preselects that host once; otherwise use the Connections selection.
    $navigationHosts=$script:WorkspaceState.NavigationHosts
    if ($null -ne $navigationHosts -and @($navigationHosts).Count -gt 0) {
        $script:WorkspaceState.NavigationHosts=$null
        return @($navigationHosts)
    }
    return @(Get-SelectedHostEntries)
}
function Update-WorkspaceLayoutPreview {
    if (-not $script:WorkspaceState.Ready) { return }
    $selected=@(Get-SelectedHostEntries)
    $layout=[string]$script:LayoutCombo.SelectedValue
    if (-not $layout) { $layout='Single' }
    $preview=Get-WorkspaceLayoutPreview -Layout $layout -Hosts $selected
    $grid=Get-NamedControl $script:MainWindow 'LayoutPreviewGrid'
    $grid.Children.Clear(); $grid.RowDefinitions.Clear(); $grid.ColumnDefinitions.Clear()
    for ($i=0;$i -lt $preview.Rows;$i++) { [void]$grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition)) }
    for ($i=0;$i -lt $preview.Columns;$i++) { [void]$grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition)) }
    foreach ($pane in $preview.Panes) {
        $border=New-Object Windows.Controls.Border; $border.BorderThickness=[Windows.Thickness]::new(1); $border.Margin=[Windows.Thickness]::new(3); $border.Padding=[Windows.Thickness]::new(17)
        $border.BorderBrush=[Windows.Media.BrushConverter]::new().ConvertFromString('#254568')
        $stack=New-Object Windows.Controls.StackPanel
        $label=New-Object Windows.Controls.TextBlock; $label.Text='PANEL '+$pane.Number; $label.FontSize=10; $label.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#6882A1'); [void]$stack.Children.Add($label)
        $name=New-Object Windows.Controls.TextBlock; $name.Text=$pane.Name; $name.FontSize=16; $name.Margin=[Windows.Thickness]::new(0,16,0,5); $name.TextWrapping='Wrap'; [void]$stack.Children.Add($name)
        $endpoint=New-Object Windows.Controls.TextBlock; $endpoint.Text=$pane.Endpoint; $endpoint.FontFamily=[Windows.Media.FontFamily]::new('Consolas'); $endpoint.TextWrapping='Wrap'; $endpoint.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#6AA9FF'); [void]$stack.Children.Add($endpoint)
        $border.Child=$stack
        [Windows.Controls.Grid]::SetRow($border,$pane.Row); [Windows.Controls.Grid]::SetColumn($border,$pane.Column)
        [Windows.Controls.Grid]::SetRowSpan($border,$pane.RowSpan); [Windows.Controls.Grid]::SetColumnSpan($border,$pane.ColumnSpan); [void]$grid.Children.Add($border)
    }
    foreach ($button in (Get-NamedControl $script:MainWindow 'LayoutCards').Children) {
        $button.BorderBrush=[Windows.Media.BrushConverter]::new().ConvertFromString($(if ($button.Tag -eq $layout) {'#3D92FF'} else {'#2A405A'}))
        $button.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($(if ($button.Tag -eq $layout) {'#143461'} else {'#101D2D'}))
    }
    $summary=if ($selected.Count -eq 0) { 'Pilih host di Connections untuk melihat pemetaan panel.' }
        elseif ($selected.Count -eq 1 -and $preview.Capacity -gt 1) { '1 host dipilih · dibuka pada seluruh {0} panel dalam 1 tab.' -f $preview.Capacity }
        else { '{0} host dipilih · {1} tab · pratinjau tab pertama. Panel mengikuti urutan host pada tabel.' -f $selected.Count,$preview.TabCount }
    (Get-NamedControl $script:MainWindow 'LayoutSelectionText').Text=$summary
}

function Update-WorkspaceSelection {
    if (-not $script:WorkspaceState.Ready) { return }
    (Get-NamedControl $script:MainWindow 'EmptyConnections').Visibility=if (@($script:HostGrid.ItemsSource).Count -eq 0) { 'Visible' } else { 'Collapsed' }
    # Protocol buttons follow the selection; with no selection both stay enabled and explain what to pick.
    $selected=@(Get-SelectedHostEntries)
    $sshButton=Get-OptionalControl $script:MainWindow 'BtnConnect'
    $rdpButton=Get-OptionalControl $script:MainWindow 'BtnRdp'
    if ($null -ne $sshButton) { $sshButton.IsEnabled=($selected.Count -eq 0 -or @($selected | Where-Object { Test-SSHManagerSshEnabled $_ }).Count -gt 0) }
    if ($null -ne $rdpButton) { $rdpButton.IsEnabled=($selected.Count -eq 0 -or @($selected | Where-Object { Test-SSHManagerRdpEnabled $_ }).Count -gt 0) }
    if ($script:WorkspaceState.Page -eq 'Layout') { Update-WorkspaceLayoutPreview }
}

function Update-WorkspaceTransferActivity {
    param($Result,[string]$StatusFile='')
    # Keep the activity page on the last transfer launched from this manager.
    # Other pending transfers still update their status/log through the existing poller.
    if ($script:WorkspaceState.ActiveStatusFile -and $StatusFile -and $StatusFile -ne $script:WorkspaceState.ActiveStatusFile) { return }
    $script:WorkspaceState.LastTransfer=$Result
    if (-not $script:WorkspaceState.Ready) { return }
    (Get-NamedControl $script:MainWindow 'NodeActivityGrid').ItemsSource=@(Get-WorkspaceTransferRows -Result $Result)
    $summary=if ($Result.PSObject.Properties.Name -contains 'Kind' -and $Result.Kind -eq 'ScpBatch') { (Get-SSHManagerScpBatchStatusText -Result $Result).Text }
        else { 'SCP {0} · {1} · {2}' -f $Result.Direction,$Result.HostName,$(if ($Result.Succeeded) {'Selesai'} else {'Gagal'}) }
    (Get-NamedControl $script:MainWindow 'ProgressSummaryText').Text=$summary
}

function Show-HostRowMenu {
    param(
        [Parameter(Mandatory=$true)][Windows.Controls.Button]$Button,
        [Parameter(Mandatory=$true)]$HostEntry,
        [ValidateSet('Connections','Rdp')][string]$Context='Connections'
    )
    # No GetNewClosure: a closure is bound to a dynamic module where $script:* resolves to $null
    # (root cause of "The property 'SelectedItem' cannot be found on this object").
    # Each item carries its action and host Id in Tag; the shared handler resolves the host when clicked.
    $menu=New-Object Windows.Controls.ContextMenu
    $hasSsh=Test-SSHManagerSshEnabled $HostEntry
    $hasRdp=Test-SSHManagerRdpEnabled $HostEntry
    $clickHandler=[Windows.RoutedEventHandler]{
        param($sender,$eventArgs)
        $info=$sender.Tag
        if ($null -eq $info) { return }
        Invoke-HostRowAction -Action ([string]$info.Action) -HostId ([string]$info.HostId) -Context ([string]$info.Context)
        $eventArgs.Handled=$true
    }
    $items=@(
        @{Action='Ssh';Header='Connect SSH';Icon=[char]0xE756;Show=$hasSsh},
        @{Action='Rdp';Header='Connect RDP';Icon=[char]0xE7F4;Show=$hasRdp},
        @{Action='TestRdp';Header='Test RDP';Icon=[char]0xE701;Show=$hasRdp},
        @{Action='Scp';Header='SCP Transfer';Icon=[char]0xE8B7;Show=$hasSsh},
        @{Action='Editor';Header='Remote Editor';Icon=[char]0xE70F;Show=$hasSsh},
        @{Action='-';Show=$true},
        @{Action='Edit';Header='Edit host';Icon=[char]0xE70F;Show=$true},
        @{Action='Duplicate';Header='Duplikat host';Icon=[char]0xE8C8;Show=$true},
        @{Action='Delete';Header='Hapus host';Icon=[char]0xE74D;Show=$true;Danger=$true}
    )
    foreach ($item in $items) {
        if (-not $item.Show) { continue }
        if ($item.Action -eq '-') { [void]$menu.Items.Add((New-Object Windows.Controls.Separator)); continue }
        $menuItem=New-Object Windows.Controls.MenuItem
        $menuItem.Header=$item.Header
        $icon=New-Object Windows.Controls.TextBlock
        $icon.Text=[string]$item.Icon; $icon.FontFamily=[Windows.Media.FontFamily]::new('Segoe MDL2 Assets')
        $menuItem.Icon=$icon
        $menuItem.Tag=[pscustomobject]@{Action=$item.Action;HostId=[string]$HostEntry.Id;Context=$Context}
        if ($item.ContainsKey('Danger')) { $menuItem.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#FF6B75') }
        $menuItem.AddHandler([Windows.Controls.MenuItem]::ClickEvent,$clickHandler)
        [void]$menu.Items.Add($menuItem)
    }
    $menu.PlacementTarget=$Button
    $menu.Placement=[Windows.Controls.Primitives.PlacementMode]::Bottom
    if ($Button.IsLoaded) { $menu.IsOpen=$true }
    return $menu
}
function Initialize-WorkspaceUi {
    # Handlers on long-lived controls are attached exactly once; feature pages build fresh controls per visit.
    if ($script:WorkspaceState.Initialized) { return }
    $script:WorkspaceState.Initialized=$true
    $script:WorkspaceSidebar=New-WorkspaceSidebar 'Connections'
    (Get-NamedControl $script:MainWindow 'SidebarHost').Content=$script:WorkspaceSidebar
    (Get-NamedControl $script:MainWindow 'DetailsToggle').Add_Click({
        $panel=Get-NamedControl $script:MainWindow 'DetailsPanel'
        $panel.Visibility=if ($panel.Visibility -eq 'Visible') {'Collapsed'} else {'Visible'}
    })
    (Get-NamedControl $script:MainWindow 'SelectHostsButton').Add_Click({Set-WorkspacePage 'Connections'})
    (Get-NamedControl $script:MainWindow 'LayoutConnectButton').Add_Click({Connect-SelectedHosts})
    (Get-NamedControl $script:MainWindow 'StartNewScpButton').Add_Click({Invoke-WorkspaceNavigation 'Scp'})
    foreach ($button in (Get-NamedControl $script:MainWindow 'LayoutCards').Children) {
        $button.Add_Click({param($sender,$eventArgs); $script:LayoutCombo.SelectedValue=[string]$sender.Tag; Update-WorkspaceLayoutPreview; $eventArgs.Handled=$true})
    }
    $script:HostGrid.AddHandler(
        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
        [System.Windows.RoutedEventHandler]{
            param($sender, $e)
            $button = Get-WorkspaceEventElement -RoutedArgs $e -Type ([System.Windows.Controls.Button])
            if ($null -eq $button) { return }
            $action = [string]$button.Tag
            if ($action -notin @('RowConnect', 'RowRdp', 'RowEdit', 'RowMore')) { return }
            $row = $button.DataContext
            if ($null -eq $row -or $null -eq $row.PSObject.Properties['Source'] -or $null -eq $row.Source) { return }
            $hostEntry = $row.Source
            switch ($action) {
                'RowConnect' { Connect-SelectedHosts -HostEntries @($hostEntry) }
                'RowRdp'     { Start-RdpLaunchBatch -Hosts @($hostEntry) -VpnOverride ([string]$script:VpnOverride.SelectedValue) }
                'RowEdit'    { Edit-Host -HostEntry $hostEntry }
                'RowMore'    { [void](Show-HostRowMenu -Button $button -HostEntry $hostEntry -Context 'Connections') }
            }

            $e.Handled = $true
        },
        $true
    )
    $script:MainWindow.Add_Closing({
        param($sender,$eventArgs)
        if (-not (Test-WorkspaceCanLeave)) { $eventArgs.Cancel=$true; return }
        Complete-WorkspaceFeature -Destination ''
    })
    $script:MainWindow.Add_Closed({ Complete-WorkspaceFeature -Destination '' })
    Initialize-RdpManagerView
    $script:WorkspaceState.Ready=$true
}

function Initialize-EditorLineGutter {
    param($Window)
    $editorTextBox=Get-OptionalControl $Window 'EditorBox'
    $lineGutter=Get-OptionalControl $Window 'LineNumberGutter'
    if ($null -eq $editorTextBox -or $null -eq $lineGutter) { return }
    # Render only visible display lines; work stays bounded even for large documents.
    $renderLines={
        $lineGutter.Children.Clear()
        if (-not $editorTextBox.IsVisible) { return }
        $first=$editorTextBox.GetFirstVisibleLineIndex(); $last=$editorTextBox.GetLastVisibleLineIndex()
        if ($first -lt 0 -or $last -lt $first) { return }
        $last=[Math]::Min($last,$first+250)
        for ($lineIndex=$first;$lineIndex -le $last;$lineIndex++) {
            $characterIndex=$editorTextBox.GetCharacterIndexFromLineIndex($lineIndex)
            if ($characterIndex -lt 0) { continue }
            $rectangle=$editorTextBox.GetRectFromCharacterIndex($characterIndex)
            if ($rectangle.IsEmpty) { continue }
            $number=New-Object Windows.Controls.TextBlock
            $number.Text=[string]($lineIndex+1); $number.FontFamily=$editorTextBox.FontFamily; $number.FontSize=$editorTextBox.FontSize
            $number.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#5F7897'); $number.Width=42; $number.TextAlignment='Right'
            [Windows.Controls.Canvas]::SetTop($number,$rectangle.Top)
            [void]$lineGutter.Children.Add($number)
        }
    }.GetNewClosure()
    $redraw={ & $renderLines }.GetNewClosure()
    $editorTextBox.AddHandler([Windows.Controls.ScrollViewer]::ScrollChangedEvent,[Windows.Controls.ScrollChangedEventHandler]$redraw)
    $editorTextBox.Add_SizeChanged($redraw)
    $editorTextBox.Add_TextChanged($redraw)
    $Window.Add_Loaded($redraw)
    $lineGutter.ToolTip='Nomor baris tampilan; Word Wrap dapat membagi satu baris menjadi beberapa baris tampilan.'
}

function Reset-WorkspaceTransferActivity {
    param([object[]]$Hosts,[string]$Direction,[string]$StatusFile='')
    $script:WorkspaceState.ActiveStatusFile=$StatusFile
    if (-not $script:WorkspaceState.Ready) { return }
    $script:WorkspaceState.LastTransfer=$null
    (Get-NamedControl $script:MainWindow 'ProgressSummaryText').Text='SCP {0} dimulai · {1} node' -f $Direction,$Hosts.Count
    (Get-NamedControl $script:MainWindow 'NodeActivityGrid').ItemsSource=@($Hosts | ForEach-Object {
        [pscustomobject]@{Name=$_.Name;Status='Menunggu hasil';Color='#94A3B8';IsRunning=$false;Items='—';Message='Lihat Windows Terminal. Hasil belum diterima; proses belum dapat dipastikan aktif.'}
    })
}
