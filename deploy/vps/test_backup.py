import datetime
import importlib.machinery
import importlib.util
import sqlite3
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.modules.setdefault('boto3', types.ModuleType('boto3'))
loader = importlib.machinery.SourceFileLoader('lykta_backup', str(Path(__file__).with_name('backup')))
spec = importlib.util.spec_from_loader(loader.name, loader)
backup = importlib.util.module_from_spec(spec)
loader.exec_module(backup)


class BackupTests(unittest.TestCase):
    def test_snapshot_matches_source_and_preserves_rows(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'source.sqlite'
            destination = Path(temporary) / 'copy.sqlite'
            with sqlite3.connect(source) as database:
                database.execute('CREATE TABLE things (id INTEGER PRIMARY KEY)')
                database.executemany('INSERT INTO things VALUES (?)', [(1,), (2,)])
            with patch.object(backup, 'DATABASE', source):
                manifest = backup.snapshot(destination)
            self.assertEqual(manifest['row_counts'], {'things': 2})
            with sqlite3.connect(destination) as copied:
                self.assertEqual(copied.execute('PRAGMA integrity_check').fetchone(), ('ok',))
                self.assertEqual(copied.execute('SELECT id FROM things ORDER BY id').fetchall(), [(1,), (2,)])

    def test_retention_deletes_after_twelve_days_and_reports_overdue(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        client = Mock()
        client.get_paginator.return_value.paginate.return_value = [{'Contents': [
            {'Key': 'backups/new', 'LastModified': now - datetime.timedelta(days=11)},
            {'Key': 'backups/old', 'LastModified': now - datetime.timedelta(days=12, hours=1)},
            {'Key': 'backups/overdue', 'LastModified': now - datetime.timedelta(days=13, hours=1)},
        ]}]
        with self.assertRaisesRegex(RuntimeError, 'exceeded 13 days'):
            backup.prune(client, 'bucket')
        self.assertEqual([call.kwargs['Key'] for call in client.delete_object.call_args_list],
                         ['backups/old', 'backups/overdue'])


if __name__ == '__main__':
    unittest.main()
