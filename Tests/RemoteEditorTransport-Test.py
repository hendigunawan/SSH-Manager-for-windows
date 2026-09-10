"""Linux/WSL: exercise actual PowerShell-to-native-SSH pipe boundary locally.

The fake ssh.exe executes the remote command on temporary files, without network.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--pwsh', default='pwsh')
    options = parser.parse_args()
    app = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='proper-editor-transport-') as temporary:
        root = Path(temporary)
        binary = root / 'bin'
        binary.mkdir()
        fake = binary / 'ssh.exe'
        fake.write_text('''#!/usr/bin/env python3
import json, os, sys, time, subprocess
with open(os.environ['EDITOR_TEST_CAPTURE'], 'a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
mode = os.environ.get('EDITOR_TEST_MODE', '')
if mode == 'timeout':
    time.sleep(15)
    sys.exit(1)
if mode == 'missing-python':
    print('sh: python3: not found', file=sys.stderr)
    sys.exit(127)
if mode == 'bad-response':
    sys.stdin.read()
    print('not an editor response')
    sys.exit(0)
if mode == 'inherited-pipes':
    sys.stdin.read()
    child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(12)'],stdin=subprocess.DEVNULL,start_new_session=True)
    with open(os.environ['EDITOR_TEST_CHILD'],'w') as f: f.write(str(child.pid))
    sys.exit(0)
os.execv('/bin/sh', ['sh', '-c', sys.argv[-1]])
''')
        fake.chmod(0o755)
        file = root / "a ; it's 日本 $(false).cfg"
        file.write_bytes('name=日本\n'.encode())
        key = root / 'test key'
        key.write_text('fixture only; never used by real ssh')
        capture = root / 'arguments.jsonl'
        fixture = root / 'fixture.json'
        fixture.write_text(json.dumps(dict(file=str(file), directory=str(root), key=str(key))))
        harness = root / 'exercise.ps1'
        harness.write_text('''param($AppRoot,$FixturePath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
Import-Module (Join-Path $AppRoot 'Modules/SSHManager.Core.psm1') -Force -DisableNameChecking
$fixture=Get-Content -LiteralPath $FixturePath -Raw | ConvertFrom-Json
$paths=Get-SSHManagerPaths -ApplicationRoot $AppRoot
$node=[pscustomobject]@{Id='a';Name='node A';HostName='node-a';Username='user-a';Port=2223;AuthType='PrivateKey';KeyPath=$fixture.key;JumpHost='jumpuser@gateway:2200';HostKeyPolicy='Strict';KeepAliveInterval=15;KeepAliveCountMax=3}
$progress=[pscustomobject]@{Ticks=0}
$callback={param($milliseconds);$progress.Ticks++}.GetNewClosure()
$read=Invoke-SSHManagerRemoteTextFile -HostEntry $node -Paths $paths -Operation read -RemotePath $fixture.file -OnProgress $callback
if ($read.path -cne $fixture.file -or $progress.Ticks -eq 0) { throw 'Unicode path/progress did not survive native boundary.' }
$document=ConvertFrom-SSHManagerTextBytes -Bytes ([Convert]::FromBase64String($read.content))
$newText=$document.Text+'saved=ok'+"`r`n"
$bytes=ConvertTo-SSHManagerTextBytes -Document $document -Text $newText -LineEnding LF
$save=Invoke-SSHManagerRemoteTextFile -HostEntry $node -Paths $paths -Operation save -RemotePath $read.path -ExpectedVersion $read.version -Bytes $bytes -Backup $true
if (-not (Test-Path -LiteralPath $save.backup)) { throw 'Backup missing.' }
if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($read.path)) -cne [Convert]::ToBase64String($bytes)) { throw 'Save bytes corrupted.' }
$conflict=$false
try { Invoke-SSHManagerRemoteTextFile -HostEntry $node -Paths $paths -Operation save -RemotePath $read.path -ExpectedVersion $read.version -Bytes ([byte[]]@()) | Out-Null }
catch { $conflict=$_.Exception.Message -match 'CONFLICT' }
if (-not $conflict) { throw 'Stale save was not rejected.' }
$empty=Invoke-SSHManagerRemoteTextFile -HostEntry $node -Paths $paths -Operation save -RemotePath $save.path -ExpectedVersion $save.version -Bytes ([byte[]]@()) -Backup $false
if ($empty.size -ne 0 -or [IO.File]::ReadAllBytes($read.path).Length -ne 0) { throw 'Empty save failed.' }
$large=New-Object byte[] 2097152
for ($i=0;$i -lt $large.Length;$i++) { $large[$i]=120 }
$savedLarge=Invoke-SSHManagerRemoteTextFile -HostEntry $node -Paths $paths -Operation save -RemotePath $empty.path -ExpectedVersion $empty.version -Bytes $large -Backup $false -TimeoutSeconds 15 -OnProgress $callback
$readLarge=Invoke-SSHManagerRemoteTextFile -HostEntry $node -Paths $paths -Operation read -RemotePath $savedLarge.path -TimeoutSeconds 15
if ([Convert]::ToBase64String($large) -cne $readLarge.content) { throw '2 MiB pipe roundtrip corrupted.' }
$directory=Invoke-SSHManagerRemoteDirectoryList -HostEntry $node -Paths $paths -RemotePath $fixture.directory -TimeoutSeconds 10
if (@($directory.Items | Where-Object { $_.FullPath -ceq $fixture.file }).Count -ne 1) { throw 'Remote browser regression after SSH helper refactor.' }
Write-Host 'PASS native pipe: read/save, Unicode/quotes, backup, stale conflict, empty file, 2 MiB, progress, browser listing'
foreach ($failure in @('missing-python','bad-response','timeout','inherited-pipes')) {
    $env:EDITOR_TEST_MODE=$failure
    $caught=$false
    $clock=[Diagnostics.Stopwatch]::StartNew()
    try { Invoke-SSHManagerRemoteTextFile -HostEntry $node -Paths $paths -Operation read -RemotePath $fixture.file -TimeoutSeconds 3 | Out-Null }
    catch {
        $failureMessage=$_.Exception.Message
        $caught = switch ($failure) { 'missing-python' { $failureMessage -match 'membutuhkan python3' } 'bad-response' { $failureMessage -match 'Balasan editor remote tidak valid' } default { $failureMessage -match 'Timeout editor' } }
    }
    if (-not $caught) { throw ('Failure not surfaced: '+$failure) }
    if ($failure -in @('timeout','inherited-pipes') -and $clock.Elapsed.TotalSeconds -gt 6) { throw 'SSH timeout did not terminate promptly.' }
}
Write-Host 'PASS native pipe: missing Python, invalid protocol, timeout and inherited output handles'
''', encoding='utf-8-sig')
        child_pid_file = root / 'child.pid'
        env = dict(os.environ, PATH=str(binary)+os.pathsep+os.environ['PATH'], EDITOR_TEST_CHILD=str(child_pid_file),
                   EDITOR_TEST_CAPTURE=str(capture), PROPER_SSH_MANAGER_DATA=str(root / 'data'))
        try:
            run = subprocess.run([options.pwsh, '-NoProfile', '-File', str(harness), str(app), str(fixture)],
                                 env=env, text=True, capture_output=True, timeout=45)
        finally:
            if child_pid_file.exists():
                try:
                    os.kill(int(child_pid_file.read_text()), 15)
                except ProcessLookupError:
                    pass
        assert run.returncode == 0, run.stdout + run.stderr
        print(run.stdout.strip())
        calls = [json.loads(line) for line in capture.read_text().splitlines()]
        assert len(calls) == 11, len(calls)
        for arguments in calls:
            assert arguments[:3] == ['-T', '-p', '2223'], arguments
            assert 'StrictHostKeyChecking=yes' in arguments
            assert arguments[arguments.index('-J')+1] == 'jumpuser@gateway:2200'
            assert arguments[arguments.index('-i')+1] == str(key)
            assert arguments[-2] == 'user-a@node-a'
        for arguments in calls[:6]:
            assert str(file) not in arguments[-1] and 'saved=ok' not in arguments[-1], 'File path/content leaked to remote command line.'
        print('PASS SSH options: port, key with spaces, jump host, host key policy; file payload stays on stdin')


if __name__ == '__main__':
    main()
