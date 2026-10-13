#!/usr/bin/env python3
"""Exercise the optional compiled resize adapter's input boundary."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import unittest

BINARY = None

class AdapterTests(unittest.TestCase):
    def run_adapter(self, *arguments):
        return subprocess.run([str(BINARY), *arguments], capture_output=True,
                              text=True, timeout=30)

    def test_invalid_inputs_fail_before_snapshot(self):
        for arguments in [[], ['0', '3'], ['4097', '3'], ['6', '-1'],
                          ['6x', '3'], ['6', '3', 'feed', '0'],
                          ['6', '3', 'feed', 'gg'], ['6', '3', 'feed'],
                          ['6', '3', 'resize', '4'],
                          ['6', '3', 'resize', '4', '0'],
                          ['6', '3', 'unknown']]:
            with self.subTest(arguments=arguments):
                result = self.run_adapter(*arguments)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(result.stdout, '')
                self.assertIn('resize oracle:', result.stderr)

    def test_empty_feed_and_resize_emit_complete_snapshots(self):
        result = self.run_adapter('1', '1', 'feed', '', 'snapshot',
                                  'resize', '2', '2', 'snapshot')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        snapshots = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([(s['cols'], s['rows']) for s in snapshots], [(1, 1), (2, 2)])
        for snapshot in snapshots:
            self.assertEqual((snapshot['x'], snapshot['y']), (0, 0))
            self.assertFalse(snapshot['pending_wrap'])
            self.assertFalse(snapshot['alternate'])
            self.assertEqual(snapshot['scrollback'], [])
            self.assertEqual(len(snapshot['screen']), snapshot['rows'])
            for row in snapshot['screen']:
                self.assertFalse(row['wrapped'])
                self.assertEqual(len(row['cells']), snapshot['cols'])
                for cell in row['cells']:
                    self.assertEqual(cell, {'cps': [], 'width': 1, 'head': False,
                                            'protected': False, 'style': [0, 0, 0, 0], 'uri': []})

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    args, remaining = parser.parse_known_args()
    BINARY = args.binary.resolve()
    unittest.main(argv=[sys.argv[0], *remaining])
