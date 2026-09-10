[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$applicationRoot=Split-Path -Parent $PSScriptRoot
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $applicationRoot 'Runtime/Connect-SCP.ps1'),[ref]$tokens,[ref]$parseErrors)
foreach ($name in @('Expand-JoinedRemotePathList','Expand-JoinedLocalPathList')) {
    $functionAst=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if ($null -eq $functionAst) { throw "Missing compatibility normalizer: $name" }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}
$remote=@(Expand-JoinedRemotePathList -Paths @('/home/itch/libs/libFIX5.a /home/itch/libs/libmisc.a'))
if ($remote.Count -ne 2 -or $remote[1] -cne '/home/itch/libs/libmisc.a') { throw 'Legacy remote list did not split.' }
$local=@(Expand-JoinedLocalPathList -Paths @('D:\my files\one.a D:\my files\two.a'))
if ($local.Count -ne 2 -or $local[0] -cne 'D:\my files\one.a' -or $local[1] -cne 'D:\my files\two.a') { throw 'Legacy local list did not preserve filenames with spaces.' }
$unc=@(Expand-JoinedLocalPathList -Paths @('\\server\share\one.a \\server\share\two.a'))
if ($unc.Count -ne 2) { throw 'Legacy UNC list did not split.' }
$single=@(Expand-JoinedLocalPathList -Paths @('D:\my files\one.a'))
if ($single.Count -ne 1 -or $single[0] -cne 'D:\my files\one.a') { throw 'Single local filename split on an ordinary space.' }
$multiple=@(Expand-JoinedRemotePathList -Paths @('/home/user/a b.txt','/home/user/c.txt'))
if ($multiple.Count -ne 2 -or $multiple[0] -cne '/home/user/a b.txt') { throw 'Explicit remote array was corrupted.' }
Write-Host 'PASS v1.7.5 path compatibility: legacy remote, Windows drive/UNC, spaces, and explicit arrays'
