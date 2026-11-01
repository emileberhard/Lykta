import hashlib
import importlib.machinery
import importlib.util
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader('updater', str(Path(__file__).with_name('update')))
updater = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(updater)


class UpdateTests(unittest.TestCase):
    def test_failed_attestation_keeps_running_binary_and_alerts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            previous = root / 'releases/0.17.0'
            previous.mkdir(parents=True)
            (root / 'current').symlink_to(previous)
            state = root / 'state'
            digest = 'sha256:' + hashlib.sha256(b'binary').hexdigest()
            candidate = ((0, 18, 0), '0.18.0', {updater.ASSET: {'digest': digest}})
            commands = []

            def fetch(url, destination, limit):
                destination.write_bytes(b'bundle' if url.endswith('.json') else b'binary')

            def execute(arguments, **_):
                commands.append(arguments)
                if arguments[0].endswith('/verify'):
                    raise subprocess.CalledProcessError(1, arguments)
                return SimpleNamespace(returncode=0)

            with patch.object(updater, 'ROOT', root), patch.object(updater, 'STATE', state), \
                 patch.object(updater, 'latest', return_value=candidate), patch.object(updater, 'fetch', side_effect=fetch), \
                 patch.object(updater.subprocess, 'run', side_effect=execute):
                self.assertEqual(updater.run(), 1)
            self.assertEqual((root / 'current').resolve(), previous.resolve())
            self.assertFalse(any(command[0] == 'systemctl' for command in commands))
            self.assertEqual(len([command for command in commands if command[0].endswith('/notify')]), 1)

    def test_failed_health_rolls_back_without_restoring_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            previous = root / 'releases/0.17.0'
            previous.mkdir(parents=True)
            (root / 'current').symlink_to(previous)
            state = root / 'state'
            digest = 'sha256:' + hashlib.sha256(b'binary').hexdigest()
            candidate = ((0, 18, 0), '0.18.0', {updater.ASSET: {'digest': digest}})
            commands = []

            def fetch(url, destination, limit):
                destination.write_bytes(b'bundle' if url.endswith('.json') else b'binary')

            def execute(arguments, **_):
                commands.append(arguments)
                if len(arguments) > 1 and arguments[1] == 'backup':
                    with sqlite3.connect(arguments[2]) as connection:
                        connection.execute('CREATE TABLE preserved (id INTEGER)')
                return SimpleNamespace(returncode=0)

            with patch.object(updater, 'ROOT', root), patch.object(updater, 'STATE', state), \
                 patch.object(updater, 'latest', return_value=candidate), patch.object(updater, 'fetch', side_effect=fetch), \
                 patch.object(updater, 'schema', return_value=1), patch.object(updater, 'preflight'), \
                 patch.object(updater, 'wait_for', side_effect=[False, True]), \
                 patch.object(updater.subprocess, 'run', side_effect=execute):
                self.assertEqual(updater.run(), 1)
            self.assertEqual((root / 'current').resolve(), previous.resolve())
            self.assertTrue((state / 'failed-0.18.0').exists())
            self.assertFalse((state / 'pending.json').exists())
            self.assertEqual([command[1] for command in commands if command[0] == 'systemctl'], ['restart', 'stop', 'start'])


if __name__ == '__main__':
    unittest.main()
