#!/usr/bin/env python3
"""Offline guards for immutable resize fixtures and oracle provenance."""
from __future__ import annotations
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools/ghostty'))
import build_oracle
import capture_resize
from resize_cases import CASES

class OracleTests(unittest.TestCase):
    def test_fixture_inputs_and_hashes(self):
        data = json.loads((ROOT / 'tests/fixtures/ghostty-resize.json').read_text())
        pin = json.loads((ROOT / 'tools/ghostty/oracle-pin.json').read_text())
        port = json.loads((ROOT / 'THIRD_PARTY/ghostty-port.json').read_text())
        self.assertEqual(data['upstream_revision'], pin['revision'])
        self.assertEqual(pin['revision'], port['revision'])
        self.assertEqual(data['source_archive_sha256'], pin['archive_sha256'])
        self.assertEqual(data['adapter_sha256'], capture_resize.sha(ROOT / 'tools/ghostty/resize_oracle.c'))
        self.assertEqual(data['cases_sha256'], capture_resize.sha(ROOT / 'tools/ghostty/resize_cases.py'))
        self.assertTrue(data['grapheme_mode'])
        self.assertEqual(data['history_limit'], 2000)
        self.assertEqual(len({c['name'] for c in CASES}), len(CASES))
        self.assertEqual(len(data['cases']), len(CASES))
        for actual, expected in zip(data['cases'], CASES):
            self.assertEqual({k: actual[k] for k in expected}, expected)
            self.assertEqual(len(actual['snapshots']), len(expected['operations']) + 1)

    def test_snapshot_geometry_and_wide_pairs(self):
        data = json.loads((ROOT / 'tests/fixtures/ghostty-resize.json').read_text())
        for case in data['cases']:
            columns, height = case['columns'], case['rows']
            for index, snap in enumerate(case['snapshots']):
                if index and 'resize' in case['operations'][index - 1]:
                    columns, height = case['operations'][index - 1]['resize']
                self.assertEqual((snap['cols'], snap['rows']), (columns, height))
                self.assertTrue(0 <= snap['x'] < columns and 0 <= snap['y'] < height)
                if snap['pending_wrap']:
                    self.assertEqual(snap['x'], columns - 1)
                self.assertEqual(len(snap['screen']), height)
                for row in snap['screen'] + snap['scrollback']:
                    self.assertEqual(len(row['cells']), columns)
                    for x, cell in enumerate(row['cells']):
                        self.assertIn(cell['width'], (0, 1, 2))
                        self.assertLessEqual(len(cell['cps']), 65)
                        self.assertTrue(all(0 < cp <= 0x10ffff and not 0xd800 <= cp <= 0xdfff for cp in cell['cps']))
                        self.assertEqual(len(cell['style']), 4)
                        self.assertTrue(all(isinstance(n, int) and n >= 0 for n in cell['style']))
                        self.assertTrue(all(0 <= b <= 255 for b in cell['uri']))
                        if cell['width'] == 2:
                            self.assertLess(x + 1, columns)
                            self.assertEqual(row['cells'][x + 1]['width'], 0)
                        elif cell['width'] == 0:
                            self.assertGreater(x, 0)
                            self.assertEqual(row['cells'][x - 1]['width'], 2)
                            self.assertEqual(cell['cps'], [])
                        if cell['head']:
                            self.assertEqual(x, columns - 1)
                            self.assertTrue(row['wrapped'])
                            self.assertEqual(cell['cps'], [])

    def test_source_materialization_rejects_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); archive = root / 'source.tar.gz'
            with tarfile.open(archive, 'w:gz') as out:
                member = tarfile.TarInfo('pinned/src/terminal.zig'); body = b'const x = 1;\n'
                member.size = len(body); out.addfile(member, io.BytesIO(body))
            source = root / 'source'
            self.assertEqual(build_oracle.materialize(archive, source), 1)
            self.assertEqual(build_oracle.materialize(archive, source), 1)
            (source / 'src/terminal.zig').write_text('changed')
            with self.assertRaisesRegex(ValueError, 'pinned source differs'):
                build_oracle.materialize(archive, source)

    def test_source_archive_rejects_traversal_and_links(self):
        for name, kind in [('pinned/../../escape', tarfile.REGTYPE), ('pinned/link', tarfile.SYMTYPE)]:
            with tempfile.TemporaryDirectory() as directory:
                archive_path = Path(directory) / 'bad.tar.gz'
                with tarfile.open(archive_path, 'w:gz') as out:
                    member = tarfile.TarInfo(name); member.type = kind; member.linkname = '/tmp/escape'
                    out.addfile(member)
                with self.assertRaises(ValueError):
                    build_oracle.materialize(archive_path, Path(directory) / 'source')

    def test_native_abi_verification_requires_platform_library(self):
        with tempfile.TemporaryDirectory() as directory:
            prefix = Path(directory)
            (prefix / 'lib').mkdir()
            for platform, name in [('darwin', 'libghostty-vt.dylib'), ('linux', 'libghostty-vt.so')]:
                with self.assertRaisesRegex(ValueError, 'missing native VT library'):
                    build_oracle.native_library(prefix, platform)
                library = prefix / 'lib' / name
                library.write_bytes(b'test library')
                self.assertEqual(build_oracle.native_library(prefix, platform), library)
            with self.assertRaisesRegex(ValueError, 'supports macOS and Linux'):
                build_oracle.native_library(prefix, 'win32')

    def test_provenance_rejects_stale_binary_pin_and_adapter(self):
        pin = json.loads((ROOT / 'tools/ghostty/oracle-pin.json').read_text())
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'oracle'; binary.write_bytes(b'test binary')
            manifest = Path(directory) / 'oracle.json'
            data = {'schema': 1, 'revision': pin['revision'], 'archive_sha256': pin['archive_sha256'],
                    'zig_version': pin['zig_version'], 'adapter_sha256': capture_resize.sha(ROOT / 'tools/ghostty/resize_oracle.c'),
                    'binary_sha256': capture_resize.sha(binary)}
            manifest.write_text(json.dumps(data))
            self.assertEqual(capture_resize.validate_metadata(binary, manifest), data)
            for field in data:
                corrupted = {**data, field: 'stale'}; manifest.write_text(json.dumps(corrupted))
                with self.assertRaisesRegex(ValueError, 'oracle provenance mismatch'):
                    capture_resize.validate_metadata(binary, manifest)
            manifest.write_text(json.dumps(data)); binary.write_bytes(b'changed binary')
            with self.assertRaisesRegex(ValueError, 'binary_sha256'):
                capture_resize.validate_metadata(binary, manifest)

if __name__ == '__main__':
    unittest.main()
