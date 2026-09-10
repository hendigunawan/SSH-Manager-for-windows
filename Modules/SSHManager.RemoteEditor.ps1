function ConvertFrom-SSHManagerTextBytes {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)
    if ($Bytes.Length -gt 2097152) { throw 'Editor mendukung file maksimal 2 MiB.' }
    $offset = 0
    $encodingName = 'UTF-8'
    $encoding = New-Object Text.UTF8Encoding($false,$true)
    if ($Bytes.Length -ge 4 -and (($Bytes[0] -eq 255 -and $Bytes[1] -eq 254 -and $Bytes[2] -eq 0 -and $Bytes[3] -eq 0) -or ($Bytes[0] -eq 0 -and $Bytes[1] -eq 0 -and $Bytes[2] -eq 254 -and $Bytes[3] -eq 255))) {
        throw 'UTF-32 tidak didukung editor ini. Gunakan UTF-8 atau UTF-16 dengan BOM.'
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191) {
        $encodingName = 'UTF-8 BOM'; $offset = 3
    }
    elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254) {
        $encodingName = 'UTF-16 LE'; $offset = 2; $encoding = New-Object Text.UnicodeEncoding($false,$true,$true)
    }
    elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 254 -and $Bytes[1] -eq 255) {
        $encodingName = 'UTF-16 BE'; $offset = 2; $encoding = New-Object Text.UnicodeEncoding($true,$true,$true)
    }
    try { $text = $encoding.GetString($Bytes,$offset,($Bytes.Length-$offset)) }
    catch { throw 'Encoding file tidak didukung. Editor menerima UTF-8, UTF-8 BOM, atau UTF-16 dengan BOM.' }
    if ($text -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') { throw 'File mengandung data biner/control character; tidak dibuka sebagai teks agar isinya tidak rusak.' }
    $withoutPairs = $text.Replace("`r`n",'')
    $crlfCount = ($text.Length-$withoutPairs.Length)/2
    $lfCount = $withoutPairs.Length-$withoutPairs.Replace("`n",'').Length
    $crCount = $withoutPairs.Length-$withoutPairs.Replace("`r",'').Length
    $lineEnding = 'LF'
    if ($crlfCount -gt 0 -and $crlfCount -ge $lfCount -and $crlfCount -ge $crCount) { $lineEnding = 'CRLF' }
    elseif ($crCount -gt $lfCount) { $lineEnding = 'CR' }
    $mixed = (@(@($crlfCount,$lfCount,$crCount) | Where-Object { $_ -gt 0 }).Count -gt 1)
    $viewText = [regex]::Replace($text,"`r`n|`r|`n","`r`n")
    [pscustomobject]@{ Text=$viewText; OriginalText=$viewText; OriginalBytes=[byte[]]$Bytes.Clone(); EncodingName=$encodingName; LineEnding=$lineEnding; MixedLineEndings=$mixed }
}

function ConvertTo-SSHManagerTextBytes {
    param(
        [Parameter(Mandatory = $true)]$Document,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [ValidateSet('LF','CRLF','CR')][string]$LineEnding = 'LF'
    )
    if ($Text -ceq $Document.OriginalText -and $LineEnding -eq $Document.LineEnding) { return ,([byte[]]$Document.OriginalBytes.Clone()) }
    if ($Text -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') { throw 'Isi editor mengandung control character yang tidak didukung.' }
    $separator = switch ($LineEnding) { 'CRLF' { "`r`n" } 'CR' { "`r" } default { "`n" } }
    $normalized = [regex]::Replace($Text,"`r`n|`r|`n",$separator)
    $bom = [byte[]]@()
    $encoding = New-Object Text.UTF8Encoding($false,$true)
    switch ($Document.EncodingName) {
        'UTF-8 BOM' { $bom = [byte[]]@(239,187,191) }
        'UTF-16 LE' { $bom = [byte[]]@(255,254); $encoding = New-Object Text.UnicodeEncoding($false,$true,$true) }
        'UTF-16 BE' { $bom = [byte[]]@(254,255); $encoding = New-Object Text.UnicodeEncoding($true,$true,$true) }
    }
    $body = $encoding.GetBytes($normalized)
    if (($body.Length+$bom.Length) -gt 2097152) { throw 'Isi file melebihi batas editor 2 MiB.' }
    $bytes = New-Object byte[] ($bom.Length+$body.Length)
    [Array]::Copy($bom,0,$bytes,0,$bom.Length)
    [Array]::Copy($body,0,$bytes,$bom.Length,$body.Length)
    return ,$bytes
}

function Find-SSHManagerEditorText {
    param([AllowEmptyString()][string]$Text,[AllowEmptyString()][string]$Pattern,[int]$StartIndex=0)
    if ([string]::IsNullOrEmpty($Pattern)) { return -1 }
    $start = [Math]::Min($Text.Length,[Math]::Max(0,$StartIndex))
    $index = $Text.IndexOf($Pattern,$start,[StringComparison]::OrdinalIgnoreCase)
    if ($index -lt 0 -and $start -gt 0) { $index = $Text.IndexOf($Pattern,0,[StringComparison]::OrdinalIgnoreCase) }
    return $index
}

function Invoke-SSHManagerRemoteTextFile {
    param(
        [Parameter(Mandatory = $true)]$HostEntry,
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][ValidateSet('read','save')][string]$Operation,
        [Parameter(Mandatory = $true)][string]$RemotePath,
        [string]$ExpectedVersion='',
        [AllowEmptyCollection()][byte[]]$Bytes=@(),
        [bool]$Backup=$true,
        [ValidateRange(3,120)][int]$TimeoutSeconds=30,
        [scriptblock]$OnProgress=$null
    )
    if ([string]::IsNullOrWhiteSpace($RemotePath) -or $RemotePath -match '[\x00\r\n]') { throw 'Path remote tidak valid.' }
    if ($Bytes.Length -gt 2097152) { throw 'Isi file melebihi batas editor 2 MiB.' }
    if ($Operation -eq 'save' -and $ExpectedVersion -notmatch '^[0-9a-f]{64}$') { throw 'Versi file belum tersedia. Buka file sebelum menyimpan.' }
    $helperPath = Join-Path $Paths.RuntimeRoot 'RemoteTextFile.py'
    $helperBytes = [IO.File]::ReadAllBytes($helperPath)
    $request = @{ operation=$Operation; path=$RemotePath }
    if ($Operation -eq 'save') {
        $request.expected=$ExpectedVersion; $request.content=[Convert]::ToBase64String($Bytes); $request.backup=$Backup
    }
    $inputText = [Convert]::ToBase64String($helperBytes) + "`n" + (ConvertTo-Json -InputObject $request -Compress) + "`n"
    $bootstrap = 'import sys,base64,io; sys.stdin=io.TextIOWrapper(sys.stdin.buffer,encoding="utf-8"); exec(compile(base64.b64decode(sys.stdin.readline()),"<proper-editor>","exec"))'
    $remoteCommand = 'python3 -c ' + (ConvertTo-SSHManagerPosixLiteral -Value $bootstrap)
    $startInfo = New-SSHManagerRemoteProcessStartInfo -HostEntry $HostEntry -Paths $Paths -RemoteCommand $remoteCommand -TimeoutSeconds $TimeoutSeconds
    $startInfo.RedirectStandardInput = $true
    $process = $null
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($OnProgress) { & $OnProgress 0 }
        $process = [Diagnostics.Process]::Start($startInfo)
        if ($null -eq $process) { throw 'Proses SSH editor gagal dimulai.' }
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        # Write UTF-8 bytes directly: Windows console code pages must not alter Unicode paths.
        $inputBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($inputText)
        $inputStream = $process.StandardInput.BaseStream
        $writeTask = $inputStream.WriteAsync($inputBytes,0,$inputBytes.Length)
        $inputClosed = $false
        while (-not $process.HasExited -or -not $outputTask.IsCompleted -or -not $errorTask.IsCompleted) {
            if (-not $inputClosed -and $writeTask.IsCompleted -and -not $process.HasExited) {
                [void]$writeTask.GetAwaiter().GetResult()
                $inputStream.Close(); $inputClosed = $true
            }
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "Timeout editor setelah $TimeoutSeconds detik. Jika sedang menyimpan, muat ulang untuk memeriksa apakah server sudah menerima perubahan." }
            if ($OnProgress) { & $OnProgress $watch.ElapsedMilliseconds }
            if ($process.HasExited) { [Threading.Thread]::Sleep(50) }
            else { [void]$process.WaitForExit(50) }
        }
        $output = $outputTask.Result
        $errorOutput = $errorTask.Result.Trim()
        if ($process.ExitCode -ne 0) {
            if ($errorOutput -match 'python3.*(not found|command not found)') { throw 'Editor remote membutuhkan python3 di server. SSH/SCP tetap dapat digunakan.' }
            if (-not $errorOutput) { $errorOutput='SSH editor berhenti dengan exit code ' + $process.ExitCode }
            throw $errorOutput
        }
        $responses = @($output -split "`r?`n" | Where-Object { $_.StartsWith('__PSM_TEXT__',[StringComparison]::Ordinal) })
        if ($responses.Count -ne 1) { throw 'Balasan editor remote tidak valid. Muat ulang file sebelum mencoba menyimpan lagi.' }
        $result = $responses[0].Substring(12) | ConvertFrom-Json
        if (-not $result.ok) { throw ('{0}: {1}' -f $result.code,$result.message) }
        return $result
    }
    finally {
        $watch.Stop()
        if ($process) {
            if (-not $process.HasExited) { try { $process.Kill(); [void]$process.WaitForExit(1000) } catch {} }
            $process.Dispose()
        }
    }
}
