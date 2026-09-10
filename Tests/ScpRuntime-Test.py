"""Linux/WSL integration harness. Run with Python 3 and --pwsh /path/to/pwsh.

Exercises the actual batch launcher/runtime/worker boundary using a fake native
scp executable, without opening Windows Terminal or making SSH connections.
"""
import argparse
import base64
import json
import os
import pty
import select
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--pwsh', default='pwsh')
    args = parser.parse_args()
    app = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='proper-scp-test-') as temp:
        root = Path(temp)
        binary = root / 'bin'
        binary.mkdir()
        fake = binary / 'scp.exe'
        fake.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['SCP_TEST_ARGS'], 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\\n')
if os.environ.get('SCP_TEST_TTY'):
    with open(os.environ['SCP_TEST_TTY'], 'a') as f:
        f.write(json.dumps(sys.stdout.isatty()) + '\\n')
print('native stdout must stay visible, not become a worker result')
sys.exit(23 if os.environ.get('SCP_TEST_FAIL') and any('user-b@node-b:' in a for a in sys.argv[1:]) else 0)
''')
        fake.chmod(0o755)
        source = root / 'a b;file.txt'
        source.write_text('fixture')
        source2 = root / '日本.txt'
        source2.write_text('fixture 2')
        private_key = root / 'test key'
        private_key.write_text('fixture key; never used by a real SSH client')
        data = root / 'data'
        data.mkdir()
        nodes = [
            dict(Id='a', Name='node A', HostName='node-a', Username='user-a', Port=2222, AuthType='Agent'),
            dict(Id='b', Name='node B', HostName='node-b', Username='user-b', Port=2223, AuthType='Agent'),
            dict(Id='c', Name='node C', HostName='2001:db8::1', Username='user-c', Port=3333,
                 AuthType='PrivateKey', KeyPath=str(private_key), JumpHost='jumpuser@gateway:2200', HostKeyPolicy='Strict'),
        ]
        (data / 'config.json').write_text(json.dumps(dict(Version=1, App=dict(TestConnectionBeforeOpen=False, ConnectTimeoutSeconds=7), Hosts=nodes, VpnProfiles=[])))
        capture = root / 'args.jsonl'
        env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                   PROPER_SSH_MANAGER_DATA=str(data), SCP_TEST_ARGS=str(capture), SCP_TEST_FAIL='1')
        for direction in ('Upload', 'Download'):
            jobs = []
            for node in nodes:
                remote = ['~/incoming files/'] if direction == 'Upload' else (
                    ["/home/mme/it's 日本.txt", '/home/mme/a /slash child.txt'] if node['Id'] == 'a' else ['~/log'])
                jobs.append(dict(HostId=node['Id'], HostName=node['Name'], Direction=direction,
                                 LocalPaths=[str(source), str(source2)] if direction == 'Upload' else [str(root / ('downloads-' + node['Id']))],
                                 RemotePaths=remote, VpnProfileId='', Recursive=direction == 'Download',
                                 PreserveTimes=True, Compression=True, SourceFileCount=2 if node['Id'] == 'a' else 0,
                                 SourceFolderCount=0, SourceItemCount=len(remote) if direction == 'Download' else 2))
            plan = root / ('plan-' + direction + '.json')
            status = root / ('status-' + direction + '.json')
            plan.write_text(json.dumps(dict(Version=1, BatchId=direction, Direction=direction, Jobs=jobs)))
            capture.write_text('')
            run = subprocess.run([args.pwsh, '-NoProfile', '-File', str(app / 'Runtime/Connect-SCP.ps1'),
                                  '-ApplicationRoot', str(app), '-BatchFile', str(plan), '-StatusFile', str(status)],
                                 env=env, text=True, capture_output=True, timeout=30)
            assert status.exists(), run.stdout + run.stderr
            result = json.loads(status.read_text(encoding='utf-8-sig'))
            assert result['IsComplete'] and result['SuccessCount'] == 2 and result['FailedCount'] == 1, (result, run.stdout, run.stderr)
            assert 'exit code 23' in result['Results'][1]['Message'], result
            assert not plan.exists(), 'Plan file must be consumed.'
            assert (data / 'logs' / ('scp-batch-' + direction + '.json')).exists(), 'Final report must be retained.'
            calls = [json.loads(line) for line in capture.read_text().splitlines()]
            assert len(calls) == 3, (calls, run.stdout, run.stderr)
            assert calls[0][:2] == ['-P', '2222'] and calls[1][:2] == ['-P', '2223'] and calls[2][:2] == ['-P', '3333'], calls
            assert 'ConnectTimeout=7' in calls[0] and 'StrictHostKeyChecking=yes' in calls[2], calls
            assert calls[2][calls[2].index('-J')+1] == 'jumpuser@gateway:2200', calls[2]
            assert calls[2][calls[2].index('-i')+1] == str(private_key), calls[2]
            assert all('-p' in c and '-C' in c for c in calls), calls
            if direction == 'Upload':
                for i, call in enumerate(calls):
                    assert call[-3:-1] == [str(source), str(source2)], call
                assert calls[0][-1] == 'user-a@node-a:~/incoming files/', calls[0]
                assert calls[2][-1] == 'user-c@[2001:db8::1]:~/incoming files/', calls[2]
                assert result['Results'][0]['FileCount'] == 2, result
            else:
                assert calls[0][-3:-1] == ["user-a@node-a:/home/mme/it's 日本.txt", 'user-a@node-a:/home/mme/a /slash child.txt'], calls[0]
                assert len({c[-1] for c in calls}) == 3, calls
                assert result['Results'][2]['ItemCount'] == 1 and result['Results'][2]['FileCount'] == result['Results'][2]['FolderCount'] == 0, result
            print('PASS runtime:', direction, '3 nodes; paths, credentials/options, partial failure, final status and log')

        # Keep the uploaded v1.7.5 fix: an older batch can contain a joined source string.
        legacy_jobs = [dict(jobs[0], RemotePaths=['/home/itch/OLTS_ITCH/libs/libFIX5.a /home/itch/OLTS_ITCH/libs/libmisc.a'])]
        plan.write_text(json.dumps(dict(Version=1, BatchId='legacy-joined', Direction='Download', Jobs=legacy_jobs)))
        capture.write_text('')
        run = subprocess.run([args.pwsh, '-NoProfile', '-File', str(app / 'Runtime/Connect-SCP.ps1'),
                              '-ApplicationRoot', str(app), '-BatchFile', str(plan), '-StatusFile', str(status)],
                             env=env, text=True, capture_output=True, timeout=30)
        legacy_status = json.loads(status.read_text(encoding='utf-8-sig'))
        legacy_calls = [json.loads(line) for line in capture.read_text().splitlines()]
        assert legacy_status['SuccessCount'] == 1 and len(legacy_calls) == 1, (legacy_status, run.stdout, run.stderr)
        assert legacy_calls[0][-3:-1] == ['user-a@node-a:/home/itch/OLTS_ITCH/libs/libFIX5.a', 'user-a@node-a:/home/itch/OLTS_ITCH/libs/libmisc.a'], legacy_calls
        print('PASS v1.7.5 compatibility: joined batch download sources become separate native SCP arguments')

        # A worker's native SCP must retain stdout TTY for its progress meter,
        # even while PowerShell captures the worker's structured result.
        plan.write_text(json.dumps(dict(Version=1, BatchId='tty', Direction=direction, Jobs=jobs)))
        tty_capture = root / 'tty.jsonl'
        env['SCP_TEST_TTY'] = str(tty_capture)
        master, slave = pty.openpty()
        process = subprocess.Popen([args.pwsh, '-NoProfile', '-File', str(app / 'Runtime/Connect-SCP.ps1'),
                                    '-ApplicationRoot', str(app), '-BatchFile', str(plan), '-StatusFile', str(status)],
                                   env=env, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            while process.poll() is None:
                ready, _, _ = select.select([master], [], [], 1)
                if ready:
                    try:
                        if not os.read(master, 65536):
                            break
                    except OSError:
                        break
            process.wait(timeout=30)
        finally:
            os.close(master)
            if process.poll() is None:
                process.kill()
        assert [json.loads(line) for line in tty_capture.read_text().splitlines()] == [True, True, True], 'SCP lost its terminal progress meter.'
        print('PASS runtime: native progress retains TTY for every batch worker')

        fake_wt = binary / 'wt.exe'
        fake_wt.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['SCP_TEST_WT'], 'w') as f:
    json.dump(sys.argv[1:], f)
''')
        fake_wt.chmod(0o755)
        wt_capture = root / 'wt.json'
        env['SCP_TEST_WT'] = str(wt_capture)
        plan.write_text(json.dumps(dict(Version=1, BatchId='launch', Direction='Download', Jobs=jobs)))
        launcher_test = root / 'launch.ps1'
        launcher_test.write_text('''param($AppRoot,$PlanPath,$StatusRoot)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $AppRoot 'Modules/SSHManager.Core.psm1') -Force -DisableNameChecking
$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
$paths = Get-SSHManagerPaths -ApplicationRoot $AppRoot
$paths.ScpStatusRoot = $StatusRoot
$result = Start-SSHManagerScpBatch -Plan $plan -Paths $paths -ReturnToManager $true -ManagerProcessId 444 -ManagerWindowHandle 123 -TerminalProfile 'Proper SSH Manager'
if (-not (Test-Path -LiteralPath $result)) { throw 'Initial batch status missing' }
''')
        run = subprocess.run([args.pwsh, '-NoProfile', '-File', str(launcher_test), str(app), str(plan), str(root / "plans ; it's")],
                             env=env, text=True, capture_output=True, timeout=30)
        assert run.returncode == 0, run.stdout + run.stderr
        wt_args = json.loads(wt_capture.read_text())
        assert wt_args[:2] == ['--window', '0'] and '-NoExit' not in wt_args, wt_args
        assert wt_args[wt_args.index('--profile')+1] == 'Proper SSH Manager', wt_args
        command = base64.b64decode(wt_args[wt_args.index('-EncodedCommand')+1]).decode('utf-16-le')
        assert '-ReturnToManager' in command and '-ManagerProcessId 444' in command and '-ManagerWindowHandle 123' in command, command
        assert "plans ; it''s" in command and all(';' not in arg for arg in wt_args), wt_args
        print('PASS launcher: one tab, encoded paths, return-to-manager arguments, initial status')


if __name__ == '__main__':
    main()
