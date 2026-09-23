#!/usr/bin/env python3
"""No GUI, real app, normal DB, or real host data. Synthetic filesystem tests only."""
import importlib.util
import os
import pathlib
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('smoke', pathlib.Path(__file__).with_name('gui-smoke.py'))
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class SmokeTests(unittest.TestCase):
    def test_runs_unique_private_and_cleanup_owned_only(self):
        a, ta = smoke.create_run(); b, tb = smoke.create_run()
        try:
            self.assertNotEqual(a, b)
            self.assertEqual(a.stat().st_mode & 0o777, 0o700)
            with self.assertRaises(RuntimeError): smoke.cleanup_owned_run(a, tb)
            self.assertTrue(a.exists()); self.assertTrue(b.exists())
            env = smoke.clean_environment(a)
            self.assertEqual(env['SKILL_STUDIO_DATA_DIR'], str(a / 'data'))
            self.assertEqual(env['ITERUNE_RUNTIME_MODE'], 'isolatedDevelopment')
            self.assertEqual(env['STUDIO_DEVELOPMENT'], '1')
            self.assertNotIn('SKILL_STUDIO_LIVE_TRANSLATION_TEST', env)
        finally:
            smoke.cleanup_owned_run(a, ta); smoke.cleanup_owned_run(b, tb)

    def test_fingerprint_covers_wal_shm_and_detects_change_without_sqlite(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            (root / 'studio.sqlite').write_bytes(b'fake database bytes')
            (root / 'studio.sqlite-wal').write_bytes(b'fake WAL bytes')
            (root / 'studio.sqlite-shm').write_bytes(b'fake SHM bytes')
            before = smoke.fingerprint(root)
            self.assertEqual(before, smoke.fingerprint(root))
            (root / 'studio.sqlite-wal').write_bytes(b'changed WAL bytes')
            self.assertNotEqual(before, smoke.fingerprint(root))
            self.assertTrue(before['studio.sqlite-shm']['exists'])

    def test_fingerprint_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder); target = root / 'target'
            target.write_bytes(b'fixture'); (root / 'studio.sqlite').symlink_to(target)
            with self.assertRaises(OSError): smoke.fingerprint(root)
            self.assertEqual(target.read_bytes(), b'fixture')

    def test_wrong_or_production_bundle_rejected_before_execution(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder); app = root / 'Iterune.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            exe = app / 'Contents/MacOS/Iterune'; exe.write_text('synthetic-not-executable-code'); exe.chmod(0o700)
            info = {'CFBundleName': 'Iterune', 'CFBundleDisplayName': 'Iterune', 'CFBundleExecutable': 'Iterune',
                    'CFBundleIdentifier': 'dev.agentskillstudio.mac.development', 'IteruneRuntimeDataMode': 'isolatedDevelopment'}
            path = app / 'Contents/Info.plist'; path.write_bytes(plistlib.dumps(info))
            self.assertEqual(smoke.validate_bundle(app, root), exe)
            with self.assertRaises(RuntimeError): smoke.validate_bundle(app, root / 'other')
            for field, value in [('CFBundleIdentifier', 'dev.agentskillstudio.mac'),
                                 ('IteruneRuntimeDataMode', 'production'), ('CFBundleExecutable', 'UnexpectedExecutable')]:
                wrong = dict(info); wrong[field] = value; path.write_bytes(plistlib.dumps(wrong))
                with self.assertRaises(RuntimeError): smoke.validate_bundle(app, root)


if __name__ == '__main__': unittest.main()
