[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Modules/SSHManager.Core.psm1') -Force -DisableNameChecking
function Assert-Editor { param([bool]$Value,[string]$Message) if (-not $Value) { throw $Message } }
Assert-Editor ($null -ne (Get-Command ConvertFrom-SSHManagerTextBytes -ErrorAction SilentlyContinue)) 'Editor teks belum tersedia.'
$utf8=New-Object Text.UTF8Encoding($false,$true)
$samples=@(
    [byte[]]@(),
    $utf8.GetBytes("port=22`nname=日本`n"),
    $utf8.GetBytes("port=22`r`nname=tes"),
    $utf8.GetBytes("mixed`r`nlines`nlast`r"),
    [byte[]](@(239,187,191)+@($utf8.GetBytes("bom`n"))),
    [byte[]](@(255,254)+@([Text.Encoding]::Unicode.GetBytes("wide`n"))),
    [byte[]](@(254,255)+@([Text.Encoding]::BigEndianUnicode.GetBytes("wide`r`n")))
)
foreach ($bytes in $samples) {
    $document=ConvertFrom-SSHManagerTextBytes -Bytes $bytes
    $encoded=ConvertTo-SSHManagerTextBytes -Document $document -Text $document.Text -LineEnding $document.LineEnding
    Assert-Editor ([Convert]::ToBase64String($bytes) -ceq [Convert]::ToBase64String($encoded)) 'Buka/simpan tanpa edit mengubah byte file.'
}
$document=ConvertFrom-SSHManagerTextBytes -Bytes ($utf8.GetBytes("first`nsecond`n"))
$edited=ConvertTo-SSHManagerTextBytes -Document $document -Text "first`r`nchanged`r`n" -LineEnding $document.LineEnding
Assert-Editor ($utf8.GetString($edited) -ceq "first`nchanged`n") 'Editor mengubah LF Linux menjadi CRLF.'
$crlf=ConvertTo-SSHManagerTextBytes -Document $document -Text "first`r`nchanged" -LineEnding 'CRLF'
Assert-Editor ($utf8.GetString($crlf) -ceq "first`r`nchanged") 'Pilihan CRLF atau trailing newline salah.'
foreach ($invalid in @([byte[]]@(0,1,2),[byte[]]@(255,254,0,0),[byte[]]@(195,40))) {
    $rejected=$false
    try { $null=ConvertFrom-SSHManagerTextBytes -Bytes $invalid } catch { $rejected=$true }
    Assert-Editor $rejected 'Binary/encoding tidak didukung harus ditolak sebelum edit.'
}
$big=New-Object byte[] (2097152+1)
$rejected=$false
try { $null=ConvertFrom-SSHManagerTextBytes -Bytes $big } catch { $rejected=$true }
Assert-Editor $rejected 'File terlalu besar tidak ditolak.'
Assert-Editor ((Find-SSHManagerEditorText -Text 'abc DEF abc' -Pattern 'abc' -StartIndex 3) -eq 8) 'Cari berikutnya gagal.'
Assert-Editor ((Find-SSHManagerEditorText -Text 'abc DEF abc' -Pattern 'AbC' -StartIndex 11) -eq 0) 'Pencarian tidak kembali ke awal.'
Write-Host 'PASS: encoding, byte round-trip, line ending, file kosong, binary/size limit, dan pencarian.' -ForegroundColor Green
