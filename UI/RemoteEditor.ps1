function Show-RemoteTextEditor {
    $editorHosts = @(Get-SelectedHostEntries)
    if ($editorHosts.Count -eq 0) { $editorHosts = @($script:Config.Hosts) }
    if ($editorHosts.Count -eq 0) { Show-Warning 'Tambahkan host terlebih dahulu untuk mengedit file remote.'; return }

    $editorWindow = Read-XamlWindow (Get-Content -LiteralPath (Join-Path $script:ApplicationRoot 'UI\RemoteEditor.xaml') -Raw -Encoding UTF8)
    $editorWindow.Owner = $script:MainWindow
    $editorControls = @{}
    foreach ($controlName in @('NodeCombo','EndpointText','RemotePathBox','OpenButton','BrowseButton','CurrentFileText','SaveButton','ReloadButton','SaveLocalButton','UndoButton','RedoButton','WrapBox','FindBox','FindNextButton','EditorBox','EncodingText','LineEndingCombo','BackupBox','CaretText','MixedEndingText','EditorStatus')) {
        $editorControls[$controlName] = Get-NamedControl $editorWindow $controlName
    }
    $editorState = [pscustomobject]@{
        HostEntry=$editorHosts[0]; RemoteFile=$null; Document=$null
        Dirty=$false; Busy=$false; Loading=$false; SwitchingNode=$false
    }
    $editorControls.NodeCombo.ItemsSource = $editorHosts
    $editorControls.NodeCombo.SelectedIndex = 0
    $editorControls.LineEndingCombo.ItemsSource = @('LF','CRLF','CR')
    $editorControls.LineEndingCombo.SelectedIndex = 0

    $setEditorStatus = {
        param([string]$Text,[string]$Color='#94A3B8')
        $editorControls.EditorStatus.Text = $Text
        $editorControls.EditorStatus.ToolTip = $Text
        $editorControls.EditorStatus.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    }
    $refreshEditorUi = {
        $hasDocument = $null -ne $editorState.Document
        foreach ($controlName in @('NodeCombo','RemotePathBox','OpenButton','BrowseButton','BackupBox','WrapBox','FindBox')) {
            $editorControls[$controlName].IsEnabled = -not $editorState.Busy
        }
        foreach ($controlName in @('EditorBox','ReloadButton','SaveLocalButton','LineEndingCombo','FindNextButton')) {
            $editorControls[$controlName].IsEnabled = $hasDocument -and -not $editorState.Busy
        }
        $editorControls.SaveButton.IsEnabled = $hasDocument -and $editorState.Dirty -and -not $editorState.Busy
        $editorControls.UndoButton.IsEnabled = $hasDocument -and $editorControls.EditorBox.CanUndo -and -not $editorState.Busy
        $editorControls.RedoButton.IsEnabled = $hasDocument -and $editorControls.EditorBox.CanRedo -and -not $editorState.Busy
        $editorControls.EndpointText.Text = '{0}@{1}:{2}' -f $editorState.HostEntry.Username,$editorState.HostEntry.HostName,$editorState.HostEntry.Port
        $editorControls.EndpointText.ToolTip = $editorControls.EndpointText.Text
        $title = 'Edit file remote — Proper SSH Manager'
        if ($hasDocument) {
            $fileLabel = '{0} • {1}' -f $editorState.HostEntry.Name,$editorState.RemoteFile.path
            $editorControls.CurrentFileText.Text = $fileLabel
            $editorControls.CurrentFileText.ToolTip = $fileLabel
            $title = '{0}{1} — Edit file remote' -f $(if ($editorState.Dirty) { '* ' } else { '' }),$fileLabel
        }
        $editorWindow.Title = $title
    }
    $updateEditorDirty = {
        if ($editorState.Loading -or $null -eq $editorState.Document) { return }
        $editorState.Dirty = ($editorControls.EditorBox.Text -cne $editorState.Document.OriginalText) -or ([string]$editorControls.LineEndingCombo.SelectedItem -ne $editorState.Document.LineEnding)
        & $refreshEditorUi
    }
    $setEditorBusy = {
        param([bool]$Busy)
        $editorState.Busy = $Busy
        & $refreshEditorUi
        if ($Busy) { [Windows.Forms.Application]::DoEvents() }
    }
    $saveRemoteFile = {
        if ($editorState.Busy -or $null -eq $editorState.Document) { return $false }
        if (-not $editorState.Dirty) { return $true }
        try {
            & $setEditorStatus 'Menyiapkan koneksi untuk menyimpan file...' '#38BDF8'
            & $setEditorBusy $true
            $savedLineEnding = [string]$editorControls.LineEndingCombo.SelectedItem
            $savedBytes = ConvertTo-SSHManagerTextBytes -Document $editorState.Document -Text $editorControls.EditorBox.Text -LineEnding $savedLineEnding
            Ensure-SSHManagerVpnForHost -HostEntry $editorState.HostEntry
            $timeout = [Math]::Min(120,[Math]::Max(30,[int]$script:Config.App.ConnectTimeoutSeconds))
            $progressControls = $editorControls
            $progressNodeName = [string]$editorState.HostEntry.Name
            $progressAction = {
                param($elapsedMilliseconds)
                $progressControls.EditorStatus.Text = 'Menyimpan ke {0}... {1:N1} / {2} detik' -f $progressNodeName,($elapsedMilliseconds/1000.0),$timeout
                [Windows.Forms.Application]::DoEvents()
            }.GetNewClosure()
            # The loaded document owns the target; editing the path box cannot redirect a save.
            $saved = Invoke-SSHManagerRemoteTextFile -HostEntry $editorState.HostEntry -Paths $script:Paths -Operation save -RemotePath $editorState.RemoteFile.path -ExpectedVersion $editorState.RemoteFile.version -Bytes $savedBytes -Backup ([bool]$editorControls.BackupBox.IsChecked) -TimeoutSeconds $timeout -OnProgress $progressAction
            $baseline = ConvertFrom-SSHManagerTextBytes -Bytes $savedBytes
            $baseline.LineEnding = $savedLineEnding
            $editorState.Document = $baseline
            $editorState.RemoteFile = $saved
            $editorState.Dirty = $false
            $editorControls.RemotePathBox.Text = [string]$saved.path
            $editorControls.MixedEndingText.Visibility = if ($baseline.MixedLineEndings) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
            $message = 'Tersimpan: {0} di {1} ({2} byte).' -f $saved.path,$editorState.HostEntry.Name,$saved.size
            if ($saved.backup) { $message += ' Backup: ' + $saved.backup }
            & $setEditorStatus $message '#22C55E'
            Set-Status ('Selesai edit file: {0} di node {1}.' -f $saved.path,$editorState.HostEntry.Name) '#22C55E' $message
            return $true
        }
        catch {
            $message = 'Gagal menyimpan: ' + $_.Exception.Message
            & $setEditorStatus $message '#F87171'
            Set-Status ('Gagal menyimpan file di node {0}.' -f $editorState.HostEntry.Name) '#F87171' $message
            return $false
        }
        finally { & $setEditorBusy $false }
    }
    $confirmEditorChanges = {
        if (-not $editorState.Dirty) { return $true }
        $unsavedWindow = Read-XamlWindow (Get-Content -LiteralPath (Join-Path $script:ApplicationRoot 'UI\UnsavedChanges.xaml') -Raw -Encoding UTF8)
        $unsavedWindow.Owner = $editorWindow
        $unsavedWindow.Tag = 'Cancel'
        (Get-NamedControl $unsavedWindow 'UnsavedFileText').Text = '{0} • {1}' -f $editorState.HostEntry.Name,$editorState.RemoteFile.path
        (Get-NamedControl $unsavedWindow 'ConfirmSaveButton').Add_Click({ $unsavedWindow.Tag='Save'; $unsavedWindow.DialogResult=$true })
        (Get-NamedControl $unsavedWindow 'DiscardButton').Add_Click({ $unsavedWindow.Tag='Discard'; $unsavedWindow.DialogResult=$true })
        [void]$unsavedWindow.ShowDialog()
        if ($unsavedWindow.Tag -eq 'Save') { return (& $saveRemoteFile) }
        return $unsavedWindow.Tag -eq 'Discard'
    }
    $openRemoteFile = {
        param([string]$RequestedPath,[bool]$AlreadyConfirmed=$false)
        if ($editorState.Busy) { return }
        if ([string]::IsNullOrWhiteSpace($RequestedPath)) { & $setEditorStatus 'Masukkan path file remote atau gunakan Pilih file...' '#FBBF24'; return }
        if (-not $AlreadyConfirmed -and -not (& $confirmEditorChanges)) { return }
        try {
            & $setEditorStatus 'Menyiapkan koneksi untuk membuka file...' '#38BDF8'
            & $setEditorBusy $true
            Ensure-SSHManagerVpnForHost -HostEntry $editorState.HostEntry
            $timeout = [Math]::Min(120,[Math]::Max(30,[int]$script:Config.App.ConnectTimeoutSeconds))
            $progressControls = $editorControls
            $progressNodeName = [string]$editorState.HostEntry.Name
            $progressAction = {
                param($elapsedMilliseconds)
                $progressControls.EditorStatus.Text = 'Membuka file di {0}... {1:N1} / {2} detik' -f $progressNodeName,($elapsedMilliseconds/1000.0),$timeout
                [Windows.Forms.Application]::DoEvents()
            }.GetNewClosure()
            $remoteFile = Invoke-SSHManagerRemoteTextFile -HostEntry $editorState.HostEntry -Paths $script:Paths -Operation read -RemotePath $RequestedPath -TimeoutSeconds $timeout -OnProgress $progressAction
            $document = ConvertFrom-SSHManagerTextBytes -Bytes ([Convert]::FromBase64String($remoteFile.content))
            $editorState.Loading = $true
            $editorState.Document = $document
            $editorState.RemoteFile = $remoteFile
            $editorControls.EditorBox.IsUndoEnabled = $false
            $editorControls.EditorBox.Text = $document.Text
            $editorControls.EditorBox.IsUndoEnabled = $true
            $editorControls.LineEndingCombo.SelectedItem = $document.LineEnding
            $editorControls.EncodingText.Text = 'Encoding: ' + $document.EncodingName
            $editorControls.RemotePathBox.Text = [string]$remoteFile.path
            $editorControls.MixedEndingText.Visibility = if ($document.MixedLineEndings) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
            $editorState.Dirty = $false
            & $setEditorStatus ('Terbuka: {0} ({1} byte). Edit teks lalu tekan Ctrl+S untuk menyimpan.' -f $remoteFile.path,$remoteFile.size) '#22C55E'
        }
        catch { & $setEditorStatus ('Gagal membuka: ' + $_.Exception.Message) '#F87171' }
        finally { $editorState.Loading=$false; & $setEditorBusy $false }
    }
    $findNext = {
        if ($editorState.Busy -or $null -eq $editorState.Document) { return }
        $pattern = $editorControls.FindBox.Text
        if ([string]::IsNullOrEmpty($pattern)) { [void]$editorControls.FindBox.Focus(); return }
        $start = $editorControls.EditorBox.SelectionStart + $editorControls.EditorBox.SelectionLength
        $index = Find-SSHManagerEditorText -Text $editorControls.EditorBox.Text -Pattern $pattern -StartIndex $start
        if ($index -lt 0) { & $setEditorStatus ('Teks tidak ditemukan: ' + $pattern) '#FBBF24'; return }
        $editorControls.EditorBox.Select($index,$pattern.Length)
        [void]$editorControls.EditorBox.Focus()
        $line = $editorControls.EditorBox.GetLineIndexFromCharacterIndex($index)
        if ($line -ge 0) { $editorControls.EditorBox.ScrollToLine($line) }
        & $setEditorStatus 'Teks ditemukan. Tekan F3 atau Berikutnya untuk melanjutkan.'
    }

    $editorControls.OpenButton.Add_Click({ & $openRemoteFile $editorControls.RemotePathBox.Text })
    $editorControls.RemotePathBox.Add_KeyDown({ param($sender,$eventArgs); if ($eventArgs.Key -eq [Windows.Input.Key]::Enter) { & $openRemoteFile $editorControls.RemotePathBox.Text; $eventArgs.Handled=$true } })
    $editorControls.BrowseButton.Add_Click({
        if ($editorState.Busy -or -not (& $confirmEditorChanges)) { return }
        $selection = $null
        try {
            & $setEditorStatus 'Menghubungkan node untuk memilih file...' '#38BDF8'
            & $setEditorBusy $true
            Ensure-SSHManagerVpnForHost -HostEntry $editorState.HostEntry
            $initialPath = '~/'
            if ($editorState.RemoteFile) {
                $slash = $editorState.RemoteFile.path.LastIndexOf('/')
                if ($slash -gt 0) { $initialPath=$editorState.RemoteFile.path.Substring(0,$slash) } else { $initialPath='/' }
            }
            $selection = Show-RemotePathPicker -Owner $editorWindow -HostEntry $editorState.HostEntry -InitialPath $initialPath -FilesOnly
            if ($null -eq $selection) { & $setEditorStatus 'Pemilihan file dibatalkan. Isi editor tetap tersedia.' }
        }
        catch { & $setEditorStatus ('Gagal memilih file: ' + $_.Exception.Message) '#F87171' }
        finally { & $setEditorBusy $false }
        if ($null -ne $selection) { & $openRemoteFile ([string]$selection.Path) $true }
    })
    $editorControls.SaveButton.Add_Click({ [void](& $saveRemoteFile) })
    $editorControls.ReloadButton.Add_Click({ if ($editorState.RemoteFile) { & $openRemoteFile ([string]$editorState.RemoteFile.path) } })
    $editorControls.SaveLocalButton.Add_Click({
        if ($editorState.Busy -or $null -eq $editorState.Document) { return }
        try {
            $localPicker = New-Object Microsoft.Win32.SaveFileDialog
            $localPicker.Filter = 'Semua file (*.*)|*.*'
            $suggested = [string]$editorState.RemoteFile.path
            $localPicker.FileName = ($suggested.Substring($suggested.LastIndexOf('/')+1) -replace '[<>:"/\\|?*\x00-\x1F]','_')
            if ($localPicker.ShowDialog($editorWindow)) {
                $localBytes = ConvertTo-SSHManagerTextBytes -Document $editorState.Document -Text $editorControls.EditorBox.Text -LineEnding ([string]$editorControls.LineEndingCombo.SelectedItem)
                [IO.File]::WriteAllBytes($localPicker.FileName,$localBytes)
                & $setEditorStatus ('Salinan lokal tersimpan: {0}. File remote belum diubah oleh tindakan ini.' -f $localPicker.FileName) '#22C55E'
            }
        }
        catch { & $setEditorStatus ('Gagal membuat salinan lokal: ' + $_.Exception.Message) '#F87171' }
    })
    $editorControls.NodeCombo.Add_SelectionChanged({
        if ($editorState.SwitchingNode) { return }
        $nextHost = $editorControls.NodeCombo.SelectedItem
        if ($null -eq $nextHost -or $nextHost.Id -eq $editorState.HostEntry.Id) { return }
        if ($editorState.Busy -or -not (& $confirmEditorChanges)) {
            $editorState.SwitchingNode=$true
            try { $editorControls.NodeCombo.SelectedItem=$editorState.HostEntry }
            finally { $editorState.SwitchingNode=$false }
            return
        }
        $editorState.Loading=$true
        try {
            $editorState.HostEntry=$nextHost; $editorState.RemoteFile=$null; $editorState.Document=$null; $editorState.Dirty=$false
            $editorControls.EditorBox.IsUndoEnabled=$false
            $editorControls.EditorBox.Clear()
            $editorControls.EditorBox.IsUndoEnabled=$true
            $editorControls.CurrentFileText.Text='Belum ada file dibuka. Pilih file pada node ini.'
            $editorControls.CurrentFileText.ToolTip=$null
            $editorControls.RemotePathBox.Text='~/'
            $editorControls.EncodingText.Text='Encoding: —'
            $editorControls.MixedEndingText.Visibility=[Windows.Visibility]::Collapsed
            & $setEditorStatus ('Node {0} dipilih. Buka file yang akan diedit.' -f $nextHost.Name)
        }
        finally { $editorState.Loading=$false; & $refreshEditorUi }
    })
    $editorControls.EditorBox.Add_TextChanged({ & $updateEditorDirty })
    $editorControls.LineEndingCombo.Add_SelectionChanged({ & $updateEditorDirty })
    $editorControls.EditorBox.Add_SelectionChanged({
        $line = $editorControls.EditorBox.GetLineIndexFromCharacterIndex($editorControls.EditorBox.CaretIndex)
        if ($line -ge 0) {
            $column = $editorControls.EditorBox.CaretIndex-$editorControls.EditorBox.GetCharacterIndexFromLineIndex($line)+1
            $editorControls.CaretText.Text = 'Baris {0}, kolom {1}' -f ($line+1),$column
        }
        & $refreshEditorUi
    })
    $editorControls.UndoButton.Add_Click({ if ($editorControls.EditorBox.CanUndo) { $editorControls.EditorBox.Undo(); & $refreshEditorUi } })
    $editorControls.RedoButton.Add_Click({ if ($editorControls.EditorBox.CanRedo) { $editorControls.EditorBox.Redo(); & $refreshEditorUi } })
    $editorControls.WrapBox.Add_Click({
        $editorControls.EditorBox.TextWrapping = if ($editorControls.WrapBox.IsChecked) { [Windows.TextWrapping]::Wrap } else { [Windows.TextWrapping]::NoWrap }
        $editorControls.EditorBox.HorizontalScrollBarVisibility = if ($editorControls.WrapBox.IsChecked) { [Windows.Controls.ScrollBarVisibility]::Disabled } else { [Windows.Controls.ScrollBarVisibility]::Auto }
    })
    $editorControls.FindNextButton.Add_Click({ & $findNext })
    $editorControls.FindBox.Add_KeyDown({ param($sender,$eventArgs); if ($eventArgs.Key -eq [Windows.Input.Key]::Enter) { & $findNext; $eventArgs.Handled=$true } })
    $editorWindow.Add_PreviewKeyDown({
        param($sender,$eventArgs)
        $ctrl = [Windows.Input.Keyboard]::Modifiers.HasFlag([Windows.Input.ModifierKeys]::Control)
        if ($ctrl -and $eventArgs.Key -eq [Windows.Input.Key]::S) { if (-not $editorState.Busy) { [void](& $saveRemoteFile) }; $eventArgs.Handled=$true }
        elseif ($ctrl -and $eventArgs.Key -eq [Windows.Input.Key]::F) { if (-not $editorState.Busy) { [void]$editorControls.FindBox.Focus(); $editorControls.FindBox.SelectAll() }; $eventArgs.Handled=$true }
        elseif ($eventArgs.Key -eq [Windows.Input.Key]::F3) { & $findNext; $eventArgs.Handled=$true }
    })
    $editorWindow.Add_Closing({
        param($sender,$eventArgs)
        if ($editorState.Busy) { $eventArgs.Cancel=$true; return }
        if (-not (& $confirmEditorChanges)) { $eventArgs.Cancel=$true }
    })
    & $refreshEditorUi
    [void]$editorWindow.ShowDialog()
}
