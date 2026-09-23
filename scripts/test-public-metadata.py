#!/usr/bin/env python3
"""Offline regression checks; synthetic inputs only, no GitHub requests."""
import pathlib
import plistlib
import os
import re
import subprocess
import sys
import tempfile
import unittest
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent


class PublicMetadataTests(unittest.TestCase):
    def check_fixture(self, content):
        with tempfile.TemporaryDirectory(prefix='studio-privacy-fixture-') as directory:
            pathlib.Path(directory, 'sample.txt').write_text(content)
            return subprocess.run([sys.executable, str(ROOT / 'scripts/check-privacy.py'),
                                   '--directory', directory], capture_output=True, text=True)

    def test_scanner_detects_without_echoing_values(self):
        samples = ['sk-' + 'SyntheticOnly1234567890' * 2,
                   '/' + 'Users/' + 'synthetic-person/secret.txt',
                   'synthetic-person' + '@' + 'example.invalid',
                   '-----BEGIN ' + 'PRIVATE KEY-----']
        for sample in samples:
            with self.subTest(kind=samples.index(sample)):
                result = self.check_fixture(sample)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(sample, result.stdout + result.stderr)
                self.assertIn('sample.txt:', result.stderr)

    def test_explicit_fixture_identifiers_are_allowed(self):
        result = self.check_fixture('fixture@example.com localhost '
                                    '00000000-0000-0000-0000-000000000000')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_public_document_links_resolve(self):
        for document in ROOT.glob('*.md'):
            for target in re.findall(r'\]\(([^)]+)\)', document.read_text()):
                parsed = urllib.parse.urlsplit(target)
                if parsed.scheme or parsed.netloc or not parsed.path:
                    continue
                path = document.parent / urllib.parse.unquote(parsed.path)
                self.assertTrue(path.exists(), f'{document.name}: broken relative link')

    def test_guidance_uses_current_entry_points(self):
        guidance = (ROOT / 'AGENTS.md').read_text()
        self.assertFalse((ROOT / 'HANDOFF.md').exists())
        for document in ROOT.glob('*.md'):
            self.assertNotIn('HANDOFF.md', document.read_text(), document.name)
        self.assertIn('README.md', guidance)
        self.assertIn('AI改善・翻訳は実装済み', guidance)
        self.assertNotIn('LLMを実装するまでは', guidance)

    def test_product_identity_and_app_bundle(self):
        self.assertTrue((ROOT / 'README.md').read_text().startswith('# Attune\n'))
        self.assertIn('.executable(name: "Attune",', (ROOT / 'Package.swift').read_text())
        if os.environ.get('STUDIO_TEST_BUNDLE'):
            app = pathlib.Path(os.environ['STUDIO_TEST_BUNDLE'])
            with (app / 'Contents/Info.plist').open('rb') as file:
                info = plistlib.load(file)
            self.assertEqual(info['CFBundleName'], 'Attune')
            self.assertEqual(info['CFBundleDisplayName'], 'Attune')
            self.assertEqual(info['CFBundleExecutable'], 'Attune')
            self.assertTrue((app / 'Contents/MacOS' / info['CFBundleExecutable']).is_file())
            # Storage identity is independent from public product branding.
            self.assertEqual(info['CFBundleIdentifier'], 'dev.agentskillstudio.mac')
            self.assertTrue((app / 'Contents/Resources/Attune_SkillStudioCore.bundle').is_dir())

    def test_no_vendor_artwork_in_resources_or_local_app(self):
        forbidden = {'claude.icns', 'codex.icns', 'gemini.png'}
        roots = [ROOT / 'Sources/SkillStudioCore/Resources']
        # Optional generated app, checked after build without launching it.
        if os.environ.get('STUDIO_TEST_BUNDLE'):
            roots.append(pathlib.Path(os.environ['STUDIO_TEST_BUNDLE']))
        for root in roots:
            self.assertTrue(root.is_dir())
            self.assertFalse(any(p.name in forbidden for p in root.rglob('*')))


if __name__ == '__main__':
    unittest.main()
