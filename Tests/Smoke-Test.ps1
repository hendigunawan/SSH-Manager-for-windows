[CmdletBinding()]
param([switch]$SkipWindowsChecks)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$applicationRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = New-Object 'Collections.Generic.List[string]'

Write-Host 'Proper SSH Manager smoke test' -ForegroundColor Cyan

$requiredFiles = @(
    'SSHManager.ps1',
    'Modules\SSHManager.Core.psm1',
    'Modules\SSHManager.ScpBatch.ps1',
    'Modules\SSHManager.RemoteEditor.ps1',
    'UI\RemoteEditor.ps1',
    'UI\RemoteEditor.xaml',
    'UI\UnsavedChanges.xaml',
    'Runtime\RemoteTextFile.py',
    'Tests\RemoteEditor-Test.ps1',
    'Tests\ScpBatch-Test.ps1',
    'Runtime\Connect-SSH.ps1',
    'Runtime\Connect-SCP.ps1',
    'Runtime\AskPass.cs',
    'UI\MainWindow.xaml',
    'Install.ps1',
    'Uninstall.ps1',
    'Start-SSHManager.cmd',
    'VERSION',
    'README.md'
)

foreach ($relative in $requiredFiles) {
    $path = Join-Path $applicationRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures.Add("File wajib tidak ditemukan: $relative")
    }
}

$powershellFiles = Get-ChildItem -LiteralPath $applicationRoot -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') }
foreach ($file in $powershellFiles) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    foreach ($parseError in @($errors)) {
        $failures.Add("Syntax $($file.Name):$($parseError.Extent.StartLineNumber): $($parseError.Message)")
    }
}

try {
    if (-not $SkipWindowsChecks) { Add-Type -AssemblyName @('PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml') }
    foreach ($xamlFile in @(Get-ChildItem -LiteralPath (Join-Path $applicationRoot 'UI') -Filter '*.xaml' -File)) {
        [xml]$xaml = Get-Content -LiteralPath $xamlFile.FullName -Raw -Encoding UTF8
        if (-not $SkipWindowsChecks) {
            $reader = New-Object Xml.XmlNodeReader $xaml
            try { [void][Windows.Markup.XamlReader]::Load($reader) }
            finally { $reader.Close() }
        }
    }

    $mainSource = Get-Content -LiteralPath (Join-Path $applicationRoot 'SSHManager.ps1') -Raw -Encoding UTF8
    $inlineWindows = [regex]::Matches($mainSource, "(?s)@'\r?\n(<Window.*?</Window>)\r?\n'@")
    if ($inlineWindows.Count -ne 8) {
        throw "Diharapkan 8 dialog XAML inline, ditemukan $($inlineWindows.Count)."
    }
    foreach ($match in $inlineWindows) {
        [xml]$inlineXaml = $match.Groups[1].Value
        if (-not $SkipWindowsChecks) {
            $inlineReader = New-Object Xml.XmlNodeReader $inlineXaml
            try { [void][Windows.Markup.XamlReader]::Load($inlineReader) }
            finally { $inlineReader.Close() }
        }
    }

    $themeStyles = [regex]::Matches($mainSource, "(?s)\[xml\]\`$\w+StyleXaml = @'\r?\n(.*?)\r?\n'@")
    if ($themeStyles.Count -ne 2) {
        throw "Diharapkan 2 style tema dinamis, ditemukan $($themeStyles.Count)."
    }
    foreach ($match in $themeStyles) {
        [xml]$styleXaml = $match.Groups[1].Value
        if (-not $SkipWindowsChecks) {
            $styleReader = New-Object Xml.XmlNodeReader $styleXaml
            try { [void][Windows.Markup.XamlReader]::Load($styleReader) }
            finally { $styleReader.Close() }
        }
    }
}
catch { $failures.Add("MainWindow.xaml: $($_.Exception.Message)") }

try {
    Import-Module (Join-Path $applicationRoot 'Modules\SSHManager.Core.psm1') -Force -DisableNameChecking
    $oldData = $env:PROPER_SSH_MANAGER_DATA
    $testData = Join-Path ([IO.Path]::GetTempPath()) ("ProperSSHManagerTest-{0}" -f [guid]::NewGuid().ToString('N'))
    $env:PROPER_SSH_MANAGER_DATA = $testData
    try {
        $paths = Get-SSHManagerPaths -ApplicationRoot $applicationRoot
        Initialize-SSHManagerData -Paths $paths
        if (-not (Test-Path -LiteralPath $paths.ScpStatusRoot -PathType Container)) { throw 'Folder status SCP tidak dibuat.' }
        $config = Read-SSHManagerConfig -Paths $paths
        if ($config.Version -ne 1) { throw 'Versi config default tidak sesuai.' }
        if ($config.App.DefaultLayout -ne 'Single') { throw 'Layout default tidak sesuai.' }
        if (-not [bool]$config.App.ReturnToManagerAfterScp) { throw 'Kembali ke manager setelah SCP belum aktif secara default.' }

        if (-not $SkipWindowsChecks) {
        $helperRuntime = Join-Path $testData 'HelperRuntime'
        New-Item -ItemType Directory -Path $helperRuntime -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $applicationRoot 'Runtime\AskPass.cs') -Destination $helperRuntime
        $helperPaths = [pscustomobject]@{ RuntimeRoot = $helperRuntime }
        $oldCompilerLib = [Environment]::GetEnvironmentVariable('LIB', [EnvironmentVariableTarget]::Process)
        $invalidCompilerLib = 'Z:\ProperSSHManager-Path-Yang-Tidak-Ada\lib'
        try {
            [Environment]::SetEnvironmentVariable('LIB', $invalidCompilerLib, [EnvironmentVariableTarget]::Process)
            $helperPath = Initialize-SSHManagerAskPass -Paths $helperPaths
            if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) { throw 'Password helper tidak berhasil dibuat.' }
            if ([Environment]::GetEnvironmentVariable('LIB', [EnvironmentVariableTarget]::Process) -ne $invalidCompilerLib) { throw 'Environment LIB tidak dipulihkan setelah kompilasi helper.' }
        }
        finally {
            [Environment]::SetEnvironmentVariable('LIB', $oldCompilerLib, [EnvironmentVariableTarget]::Process)
        }
        }
    }
    finally {
        if ($null -eq $oldData) { Remove-Item Env:\PROPER_SSH_MANAGER_DATA -ErrorAction SilentlyContinue }
        else { $env:PROPER_SSH_MANAGER_DATA = $oldData }
        if (Test-Path -LiteralPath $testData) { Remove-Item -LiteralPath $testData -Recurse -Force }
    }
}
catch { $failures.Add("Core/config: $($_.Exception.Message)") }

try {
    $version = (Get-Content -LiteralPath (Join-Path $applicationRoot 'VERSION') -Raw -Encoding UTF8).Trim()
    $installerSource = Get-Content -LiteralPath (Join-Path $applicationRoot 'Install.ps1') -Raw -Encoding UTF8
    $uninstallerSource = Get-Content -LiteralPath (Join-Path $applicationRoot 'Uninstall.ps1') -Raw -Encoding UTF8
    $coreSource = Get-Content -LiteralPath (Join-Path $applicationRoot 'Modules\SSHManager.Core.psm1') -Raw -Encoding UTF8

    if ($version -ne '1.8.0') { throw "VERSION tidak sesuai: $version" }
    if ($installerSource -notmatch "closeOnExit\s+=\s+'always'") { throw 'Profil Windows Terminal belum memakai closeOnExit=always.' }
    if ($installerSource -notmatch "keys\s+=\s+'ctrl\+shift\+f12'") { throw 'Shortcut Windows Terminal belum terdaftar.' }
    if ($installerSource -notmatch "Hotkey\s+=\s+'CTRL\+ALT\+S'") { throw 'Shortcut Windows global belum terdaftar.' }
    $installCmdSource = Get-Content -LiteralPath (Join-Path $applicationRoot 'Install.cmd') -Raw -Encoding UTF8
    if ($installCmdSource -notmatch '-Force\s+-LaunchAfterInstall') { throw 'Install.cmd belum memaksa file versi lama ditimpa.' }
    if ($installerSource -notmatch "Fragments\\ProperSSHManager") { throw 'Lokasi JSON fragment Windows Terminal belum benar.' }
    if ($uninstallerSource -notmatch "Fragments\\ProperSSHManager") { throw 'Uninstaller belum membersihkan JSON fragment Windows Terminal.' }
    if ($coreSource -notmatch '\$arguments\.Add\(''0''\)') { throw 'Launcher SSH belum menargetkan window Terminal terakhir.' }
    if ($coreSource -notmatch "GetEnvironmentVariable\('LIB', \[EnvironmentVariableTarget\]::Process\)") { throw 'Kompilasi password helper belum mengisolasi environment LIB.' }
    if ($coreSource -notmatch 'SetEnvironmentVariable\(''LIB'', \$originalCompilerLib, \[EnvironmentVariableTarget\]::Process\)') { throw 'Environment LIB belum dipulihkan setelah kompilasi helper.' }
    if ($coreSource -notmatch 'function Invoke-SSHManagerRemoteDirectoryList') { throw 'Pembaca folder remote belum tersedia.' }
    if ($coreSource -notmatch '\[scriptblock\]\$ProgressAction') { throw 'Callback progres koneksi belum tersedia.' }
    if ($coreSource -notmatch 'while \(-not \$task\.IsCompleted\)') { throw 'Tes TCP masih menunggu timeout secara blocking.' }
    if ($coreSource -notmatch 'Start-Sleep -Milliseconds 100') { throw 'Interval pemantauan tes TCP belum tersedia.' }
    if ($coreSource -notmatch "'Invoke-SSHManagerRemoteDirectoryList'") { throw 'Pembaca folder remote belum diekspor dari module.' }
    if ($coreSource -notmatch '__PSM_PATH__\\t%s\\n') { throw 'Protokol path browser remote belum tersedia.' }
    if ($coreSource -notmatch '__PSM_ITEM__\\t%s\\t%s\\n') { throw 'Protokol item browser remote belum tersedia.' }
    if ($coreSource -notmatch '"~/"\*\) path="\$HOME/\$\{path#\?\?\}"') { throw 'Ekspansi path ~/ pada browser remote belum aman.' }
    if ($coreSource -match '\$\{path#~/\}') { throw 'Browser remote masih memakai ekspansi tilde yang menghasilkan HOME/~/.' }
    if ($coreSource -notmatch "'Start-SSHManagerScp'") { throw 'Fungsi launcher SCP belum diekspor.' }
    if ($mainSource -notmatch 'function Show-ScpDialog') { throw 'Dialog SCP belum tersedia.' }
    if ($mainSource -notmatch 'function Show-RemotePathPicker') { throw 'Dialog browser remote belum tersedia.' }
    if ($mainSource -notmatch 'x:Name="BrowseRemoteButton"') { throw 'Tombol pilih path remote belum tersedia.' }
    if ($mainSource -notmatch 'x:Name="ReturnAfterScpBox"') { throw 'Opsi kembali ke manager setelah SCP belum tersedia.' }
    if ($mainSource -notmatch '\$picker\.Multiselect\s*=\s*\$true') { throw 'Pemilih upload belum mendukung banyak file.' }
    if ($mainSource -notmatch 'SelectionMode\]::Extended') { throw 'Browser remote belum mendukung multi-select.' }
    if ($mainSource -notmatch '-AllowMultiple:\$isDownload') { throw 'Multi-select remote belum diaktifkan untuk download.' }
    if ($mainSource -notmatch '\$remoteList\.SelectedItems\[\$selectedIndex\]') { throw 'Koleksi pilihan remote belum dibaca berdasarkan indeks.' }
    if ($mainSource -match '\$selectedItems\s*=\s*@\(\$remoteList\.SelectedItems\)') { throw 'Koleksi pilihan remote masih dibungkus sebagai satu objek.' }
    if ($mainSource -notmatch '\[string\[\]\]\$selectedPaths\.ToArray\(\)') { throw 'Path remote belum dipaksa menjadi string array.' }
    if ($coreSource -notmatch "'-LocalPathsBase64'") { throw 'Launcher SCP belum mengirim daftar path lokal.' }
    if ($coreSource -notmatch "'-RemotePathsBase64'") { throw 'Launcher SCP belum mengirim daftar path remote.' }
    if ($coreSource -notmatch "'-ManagerWindowHandle'") { throw 'Launcher SCP belum mengirim handle jendela manager.' }
    if ($coreSource -notmatch "'-StatusFile'") { throw 'Launcher SCP belum mengirim file hasil ke manager.' }
    if ($coreSource -notmatch "'-SourceFileCount'") { throw 'Launcher SCP belum mengirim jumlah file.' }
    if ($coreSource -notmatch "'-SourceFolderCount'") { throw 'Launcher SCP belum mengirim jumlah folder.' }
    if ($coreSource -notmatch 'if \(-not \$ReturnToManager\) \{ \$arguments\.Add\(''-NoExit''\) \}') { throw 'Launcher SCP belum menonaktifkan NoExit saat kembali ke manager.' }
    if ($mainSource -notmatch 'WindowState\s*=\s*\[Windows\.WindowState\]::Minimized') { throw 'Manager belum diminimalkan selama SCP berjalan.' }
    if ($mainSource -notmatch '(?s)WindowState\s*=\s*\[Windows\.WindowState\]::Minimized.*?Start-SSHManagerScp') { throw 'Manager harus diminimalkan sebelum proses SCP dimulai.' }
    if ($mainSource -notmatch '(?s)\$managerMinimizedForTransfer.*?WindowState\s*=\s*\[Windows\.WindowState\]::Normal') { throw 'Manager belum dipulihkan bila launcher SCP gagal.' }
    if ($mainSource -notmatch 'function Update-PendingScpStatus') { throw 'Pemantau status hasil SCP belum tersedia.' }
    if ($mainSource -notmatch 'function New-ConnectionProgressWindow') { throw 'Dialog status koneksi belum tersedia.' }
    if ($mainSource -notmatch 'function Update-ConnectionProgressWindow') { throw 'Pembaruan status koneksi belum tersedia.' }
    if ($mainSource -notmatch 'function Show-ConnectionFailureDialog') { throw 'Dialog koneksi gagal khusus belum tersedia.' }
    if ($mainSource -notmatch 'IsIndeterminate="True"') { throw 'Indikator progres koneksi belum tersedia.' }
    if ($mainSource -notmatch '-ProgressAction \$progressAction') { throw 'Tes host belum mengirim progres ke UI.' }
    if ($mainSource -notmatch '-ProgressAction \$vpnProgressAction') { throw 'Koneksi VPN belum mengirim progres ke UI.' }
    if ($mainSource -notmatch 'Content="Coba lagi"') { throw 'Tindakan coba lagi belum tersedia.' }
    if ($mainSource -notmatch 'Content="Tetap buka SSH"') { throw 'Tindakan tetap buka SSH belum tersedia.' }
    if ($mainSource -notmatch '(?s)Close-ConnectionProgressWindow -Window \$connectionProgress.*?Show-ConnectionFailureDialog') { throw 'Dialog progres belum ditutup sebelum notifikasi kegagalan.' }
    if ($mainSource -notmatch '\$hostsToTest\s*=\s*@\(\$failed \| ForEach-Object \{ \$_\.Host \}\)') { throw 'Coba lagi belum dibatasi pada host yang gagal.' }
    if ($mainSource -notmatch 'Selesai SCP \{0\}: \{1\} \{2\} host \{3\}') { throw 'Pesan status selesai SCP belum tersedia.' }
    if ($mainSource -notmatch 'Register-ScpStatusFile -StatusFile') { throw 'Operasi SCP belum didaftarkan ke pemantau status.' }
    $scpRuntimeSource = Get-Content -LiteralPath (Join-Path $applicationRoot 'Runtime\Connect-SCP.ps1') -Raw -Encoding UTF8
    if ($scpRuntimeSource -notmatch 'foreach \(\$sourcePath in \$expandedLocalPaths\)') { throw 'Runtime SCP belum mengirim banyak sumber lokal.' }
    if ($scpRuntimeSource -notmatch 'foreach \(\$sourceSpec in \$remoteSpecs\)') { throw 'Runtime SCP belum mengambil banyak sumber remote.' }
    if ($scpRuntimeSource -notmatch 'function Expand-JoinedRemotePathList') { throw 'Runtime SCP belum memulihkan path remote yang terlanjur tergabung.' }
    if ($scpRuntimeSource -notmatch '\\s\+\(\?=\(\?:/\|~/\)\)') { throw 'Pemisah fallback path remote belum tersedia.' }
    if ($scpRuntimeSource -notmatch 'Proper SSH Manager \{0\}') { throw 'Banner runtime belum menampilkan versi aplikasi.' }
    if ($scpRuntimeSource -notmatch 'function Show-SSHManagerWindow') { throw 'Runtime belum dapat memulihkan jendela manager.' }
    if ($scpRuntimeSource -notmatch 'ShowWindowAsync\(\$nativeHandle, 9\)') { throw 'Runtime belum memulihkan window manager yang diminimalkan.' }
    if ($scpRuntimeSource -notmatch 'SetForegroundWindow\(\$nativeHandle\)') { throw 'Runtime belum memfokuskan kembali window manager.' }
    if ($scpRuntimeSource -notmatch 'SetEnvironmentVariable\(''LIB'', \$null, \[EnvironmentVariableTarget\]::Process\)') { throw 'Aktivator manager belum mengisolasi environment LIB saat Add-Type.' }
    if ($scpRuntimeSource -notmatch 'if \(\$ReturnToManager\)') { throw 'Runtime belum menangani mode kembali ke manager.' }
    if ($scpRuntimeSource -notmatch '(?s)if \(-not \$transferSucceeded\).*?Read-Host') { throw 'Transfer gagal belum menahan tab sampai pengguna selesai membaca error.' }
    if ($scpRuntimeSource -notmatch 'if \(\$transferSucceeded\) \{ exit 0 \}') { throw 'Transfer sukses belum mengakhiri proses SCP.' }
    if ($scpRuntimeSource -notmatch 'function Write-ScpStatusResult') { throw 'Runtime belum menulis hasil SCP untuk manager.' }
    if ($scpRuntimeSource -notmatch 'Move-Item -LiteralPath \$temporaryStatusFile -Destination \$StatusFile -Force') { throw 'Hasil SCP belum ditulis secara atomik.' }
    if ($scpRuntimeSource -notmatch 'FileCount\s*=\s*\[Math\]::Max') { throw 'Hasil SCP belum membawa jumlah file.' }
    if ($scpRuntimeSource -notmatch 'FolderCount\s*=\s*\[Math\]::Max') { throw 'Hasil SCP belum membawa jumlah folder.' }
    if ($mainSource -match '(?im)^\s*\$home\s*=') { throw 'Browser remote mencoba menimpa automatic variable HOME.' }
    if ($mainSource -notmatch '\$homeButton\s*=\s*Get-NamedControl') { throw 'Tombol Home browser remote belum memakai nama variabel yang aman.' }
    if ($mainSource -notmatch 'function Apply-DarkComboBoxTheme') { throw 'Tema dropdown ComboBox belum tersedia.' }
    if ($mainSource -notmatch 'x:Name="FieldBorder"') { throw 'Template permukaan ComboBox belum diganti.' }
    if ($mainSource -notmatch 'ContentTemplateSelector="\{TemplateBinding ItemTemplateSelector\}"') { throw 'Template ComboBox belum meneruskan DisplayMemberPath ke item terpilih.' }
    if ($mainSource -notmatch 'ContentStringFormat="\{TemplateBinding SelectionBoxItemStringFormat\}"') { throw 'Template ComboBox belum meneruskan format item terpilih.' }
    if ($mainSource -match '(?s)Add_MouseDoubleClick\(\{.*?LayoutCombo\.SelectedValue\s*=\s*''Single''.*?Connect-SelectedHosts') { throw 'Double-click host masih memaksa layout Single.' }
    $mainXamlSource = Get-Content -LiteralPath (Join-Path $applicationRoot 'UI\MainWindow.xaml') -Raw -Encoding UTF8
    if ($mainXamlSource -notmatch 'DataGridTemplateColumn Header="Pilih"') { throw 'Kolom checkbox Pilih host belum tersedia.' }
    if ($mainXamlSource -notmatch 'Tag="HostSelection"') { throw 'Checkbox pilihan host belum memiliki penanda event.' }
    if ($mainXamlSource -match 'DataGridCheckBoxColumn Header="★"') { throw 'Kolom Favorite masih terbaca sebagai checkbox pilihan host.' }
    if ($mainSource -notmatch '\$script:CheckedHostIds') { throw 'State checkbox pilihan host belum tersedia.' }
    if ($mainSource -notmatch '(?s)function Get-SelectedHostEntries.*?Where-Object \{ \[bool\]\$_\.IsChecked \}') { throw 'Pilihan checkbox belum menjadi sumber utama host.' }
    if ($mainSource -notmatch 'AddHandler\(\[System\.Windows\.Controls\.Primitives\.ButtonBase\]::ClickEvent') { throw 'Event checkbox pilihan host belum didaftarkan.' }
}
catch { $failures.Add("Integrasi Windows Terminal: $($_.Exception.Message)") }

if ($failures.Count -gt 0) {
    Write-Host ''
    foreach ($failure in $failures) { Write-Host "FAIL  $failure" -ForegroundColor Red }
    throw "$($failures.Count) pemeriksaan gagal."
}

if ($SkipWindowsChecks) {
    Write-Host 'PASS  Struktur, parser PowerShell, XML, config, dan pemeriksaan integrasi statis.' -ForegroundColor Green
    Write-Host 'SKIP  Pemuatan WPF native dan kompilasi helper Windows (jalankan kembali tanpa -SkipWindowsChecks di Windows).' -ForegroundColor Yellow
}
else { Write-Host 'PASS  Struktur paket, syntax PowerShell, XAML, config, dan integrasi Windows Terminal valid.' -ForegroundColor Green }
