import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

HELPER = Path(__file__).resolve().parents[1] / 'Runtime' / 'RemoteTextFile.py'


class RemoteTextTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(HELPER.is_file(), 'Remote text read/save helper is missing')
        self.temp = tempfile.TemporaryDirectory(prefix='proper-editor-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.file = self.root / "config ; it's 日本.cfg"
        self.file.write_bytes(b'port=22\n')
        self.file.chmod(0o754)

    def call(self, operation='read', **kwargs):
        request = dict(operation=operation, path=str(self.file))
        request.update(kwargs)
        completed = subprocess.run([sys.executable, str(HELPER)], input=json.dumps(request),
                                   text=True, capture_output=True, timeout=5)
        marker = '__PSM_TEXT__'
        lines = [line[len(marker):] for line in completed.stdout.splitlines() if line.startswith(marker)]
        self.assertEqual(len(lines), 1, completed.stdout + completed.stderr)
        return json.loads(lines[0])

    def test_read_save_preserves_mode_and_makes_backup(self):
        before = self.call()
        self.assertTrue(before['ok'], before)
        new = b'port=3333\n'
        saved = self.call('save', expected=before['version'], content=base64.b64encode(new).decode(), backup=True)
        self.assertTrue(saved['ok'], saved)
        self.assertEqual(self.file.read_bytes(), new)
        self.assertEqual(self.file.stat().st_mode & 0o7777, 0o754)
        self.assertEqual(Path(saved['backup']).read_bytes(), b'port=22\n')
        self.assertNotEqual(before['version'], saved['version'])

    def test_conflict_keeps_other_writers_content(self):
        before = self.call()
        self.file.write_bytes(b'changed elsewhere\n')
        saved = self.call('save', expected=before['version'], content='eA==', backup=True)
        self.assertFalse(saved['ok'])
        self.assertEqual(saved['code'], 'CONFLICT')
        self.assertEqual(self.file.read_bytes(), b'changed elsewhere\n')

    def test_symlink_is_preserved_and_hardlink_is_not_broken(self):
        link = self.root / 'link.cfg'
        link.symlink_to(self.file)
        before = self.call(path=str(link))
        self.assertEqual(before['path'], str(self.file.resolve()))
        saved = self.call('save', path=before['path'], expected=before['version'], content='', backup=False)
        self.assertTrue(saved['ok'], saved)
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.read_bytes(), b'')
        os.link(self.file, self.root / 'hard.cfg')
        before = self.call()
        saved = self.call('save', expected=before['version'], content='eA==', backup=False)
        self.assertFalse(saved['ok'])
        self.assertEqual(saved['code'], 'HARDLINK')
        self.assertEqual(self.file.read_bytes(), b'')

    def test_limit_missing_and_special_file(self):
        self.file.write_bytes(b'x' * (2097152 + 1))
        self.assertEqual(self.call()['code'], 'TOO_LARGE')
        self.assertFalse(self.call(path=str(self.root / 'missing'))['ok'])
        fifo = self.root / 'pipe'
        os.mkfifo(fifo)
        self.assertEqual(self.call(path=str(fifo))['code'], 'NOT_FILE')

    def test_empty_unicode_and_metadata(self):
        if hasattr(os, 'setxattr'):
            os.setxattr(self.file, 'user.proper-editor-test', b'fixture')
        before = self.call()
        content = 'name=日本\r\n'.encode('utf-16')
        saved = self.call('save', expected=before['version'], content=base64.b64encode(content).decode(), backup=False)
        self.assertTrue(saved['ok'], saved)
        self.assertEqual(self.file.read_bytes(), content)
        if hasattr(os, 'getxattr'):
            self.assertEqual(os.getxattr(self.file, 'user.proper-editor-test'), b'fixture')

    def test_overlapping_saves_allow_only_one_version(self):
        before = self.call()
        ready = self.root / 'writer-staged'
        # Pause writer one after its final check, where two unlocked writers could both pass.
        wrapper = '''import importlib.util, os, sys, time
spec=importlib.util.spec_from_file_location('editor',sys.argv[1])
editor=importlib.util.module_from_spec(spec);spec.loader.exec_module(editor)
replace=editor.os.replace
def pause_replace(source,target):
    with open(sys.argv[2],'w') as signal: signal.write('ready')
    time.sleep(0.5)
    return replace(source,target)
editor.os.replace=pause_replace
editor.main()
'''
        request = dict(operation='save', path=str(self.file), expected=before['version'],
                       content=base64.b64encode(b'writer one\n').decode(), backup=True)
        first = subprocess.Popen([sys.executable, '-c', wrapper, str(HELPER), str(ready)],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            first.stdin.write(json.dumps(request))
            first.stdin.close()
            deadline = time.monotonic() + 3
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(ready.exists(), 'first writer never reached replacement')
            second = self.call('save', expected=before['version'], content=base64.b64encode(b'writer two\n').decode(), backup=True)
            first.wait(timeout=3)
            first_result = json.loads(first.stdout.read().split('__PSM_TEXT__', 1)[1])
            self.assertTrue(first_result['ok'], first_result)
            self.assertFalse(second['ok'], second)
            self.assertEqual(second['code'], 'CONFLICT')
            self.assertEqual(self.file.read_bytes(), b'writer one\n')
        finally:
            if first.poll() is None:
                first.kill(); first.wait(timeout=3)
            first.stdout.close(); first.stderr.close()


if __name__ == '__main__':
    unittest.main()
