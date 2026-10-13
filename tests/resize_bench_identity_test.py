#!/usr/bin/env python3
"""Exercise the resize benchmark's provenance guards against a real build."""
import argparse
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools/ghostty'))
import bench_resize

class IdentityTests(unittest.TestCase):
    def test_current_source_and_compilation_contract(self):
        report = bench_resize.identity(BUILD)
        self.assertIn('src/lpage_layout.c', {s['path'] for s in report['source_files']})
        self.assertTrue(any('lpage_layout.c' in c for c in report['compile_commands']))

    def test_missing_and_duplicate_fingerprints_rejected(self):
        header = (BUILD / 'terminal-source.h').read_text()
        lines = header.splitlines(keepends=True)
        layout = next(line for line in lines if '"src/lpage_layout.c"' in line)
        for changed in (header.replace(layout, ''), header.replace(layout, layout * 2)):
            with tempfile.TemporaryDirectory() as directory:
                temp = Path(directory); (temp / 'terminal-source.h').write_text(changed)
                with self.assertRaisesRegex(ValueError, 'unexpected native source fingerprint'):
                    bench_resize.identity(temp)

    def test_stale_source_digest_rejected(self):
        header = (BUILD / 'terminal-source.h').read_text()
        current = bench_resize.identity(BUILD)['source_files'][0]
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory); (temp / 'terminal-source.h').write_text(header.replace(current['sha256'], '0' * 64))
            with self.assertRaisesRegex(ValueError, 'stale native source identity'):
                bench_resize.identity(temp)

    def test_missing_and_duplicate_compilation_rejected(self):
        actual = bench_resize.run(['ninja', '-C', BUILD, '-t', 'commands', 'libboggart_vt.a'])
        lines = actual.splitlines(keepends=True)
        layout = next(line for line in lines if ' -c ' in line and 'lpage_layout.c' in line)
        for changed in (actual.replace(layout, ''), actual.replace(layout, layout * 2)):
            with patch.object(bench_resize, 'run', return_value=changed):
                with self.assertRaisesRegex(ValueError, 'native core compilation list changed'):
                    bench_resize.identity(BUILD)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=ROOT / 'build')
    args, rest = parser.parse_known_args(); BUILD = args.build_dir.resolve()
    unittest.main(argv=[sys.argv[0], *rest])
