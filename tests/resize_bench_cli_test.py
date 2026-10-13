#!/usr/bin/env python3
"""Check optional benchmark binaries against complete pinned SDK snapshots."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARIES = {}


def fingerprint(snapshot):
    result = 14695981039346656037
    def value(number):
        nonlocal result
        for shift in range(0,64,8):
            result = ((result ^ ((int(number) >> shift)&255))*1099511628211)&((1<<64)-1)
    for field in ['cols','rows','x','y','pending_wrap','alternate']:
        value(snapshot[field])
    value(len(snapshot['scrollback']))
    for row in snapshot['scrollback']+snapshot['screen']:
        value(row['wrapped'])
        for cell in row['cells']:
            for field in ['width','head','protected']:
                value(cell[field])
            for color in cell['style']:
                value(color)
            for field in ['cps','uri']:
                value(len(cell[field]))
                for scalar in cell[field]:
                    value(scalar)
    return f'{result:016x}'


class BenchmarkCLI(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='bmux-resize-bench-test-')
        self.addCleanup(self.scratch.cleanup)
        self.feed = Path(self.scratch.name)/'feed.bin'
        self.feed.write_bytes(b'')

    def invoke(self, binary, *args):
        return subprocess.run([str(binary),*map(str,args)], capture_output=True, text=True, timeout=30)

    def fixture(self, name):
        cases = json.loads((ROOT/'tests/fixtures/ghostty-resize.json').read_text())['cases']
        case = next(c for c in cases if c['name']==name)
        self.feed.write_bytes(bytes.fromhex(case['operations'][0]['feed_hex']))
        steps = [op['resize'] for op in case['operations'][1:]]
        expected = list(map(fingerprint,case['snapshots'][1:]))
        for backend,binary in BINARIES.items():
            with self.subTest(backend=backend):
                result = self.invoke(binary,3,1,case['columns'],case['rows'],self.feed,*[v for step in steps for v in step])
                self.assertEqual(result.returncode,0,result.stderr)
                report = json.loads(result.stdout)
                self.assertEqual(report['states']+report['resized_states'],expected)
                self.assertEqual(len(report['timings_ns']),3)
                self.assertTrue(all(len(t)==len(steps) and all(isinstance(n,int) and n>=0 for n in t) for t in report['timings_ns']))
                self.assertEqual(len(report['memory']),len(steps)+1)
                self.assertTrue(all(m['pages']>0 for m in report['memory']))
                self.assertGreaterEqual(report['peak_rss_bytes'],report['initial_peak_rss_bytes'])
                self.assertEqual(len(report['clock_probe_ns']),128)

    def test_cached_regrowth(self):
        self.fixture('nowrap_cached_width')

    def test_background_only_rgb(self):
        self.fixture('rgb_background_blanks')

    def test_styles_and_uri(self):
        self.fixture('styles_and_links')

    def test_complete_unicode_clusters(self):
        self.fixture('owned_clusters')

    def test_invalid_inputs(self):
        good = ['1','0','6','3',str(self.feed),'4','3']
        invalid = [[],good[:-1],['0',*good[1:]],['10001',*good[1:]],
            [good[0],'-1',*good[2:]],good[:2]+['0']+good[3:],
            good[:2]+['4097']+good[3:],good[:5]+['+4','3'],good[:5]+['4x','3'],
            good[:5]+['4','3']*17,good[:4]+[str(self.feed)+'-missing']+good[5:]]
        for backend,binary in BINARIES.items():
            for args in invalid:
                with self.subTest(backend=backend,args=args):
                    result = self.invoke(binary,*args)
                    self.assertEqual(result.returncode,2)
                    self.assertEqual(result.stdout,'')

    def test_empty_feed_no_warmup(self):
        for backend,binary in BINARIES.items():
            with self.subTest(backend=backend):
                result = self.invoke(binary,1,0,6,3,self.feed,4,3)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(len(json.loads(result.stdout)['timings_ns']),1)

    def test_feed_limit(self):
        self.feed.write_bytes(b'x'*(1024*1024+1))
        for backend,binary in BINARIES.items():
            with self.subTest(backend=backend):
                result = self.invoke(binary,1,0,6,3,self.feed,4,3)
                self.assertEqual(result.returncode,2)
                self.assertIn('feed size',result.stderr)


if __name__=='__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native-binary',type=Path,required=True)
    parser.add_argument('--oracle-binary',type=Path,required=True)
    args,other = parser.parse_known_args()
    BINARIES.update(native=args.native_binary.resolve(),ghostty=args.oracle_binary.resolve())
    unittest.main(argv=[__file__,*other])
