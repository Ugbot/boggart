#!/usr/bin/env python3
"""Offline guards for the optional, instrumented SDK topology diagnostic."""
from copy import deepcopy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools/ghostty'))
from probe_page_topology import generated_cases, literal, validate_frames, validate_abi_snapshot

class TopologyTests(unittest.TestCase):
    def setUp(self):
        self.cases = [{'name': 'two-pages', 'columns': 4, 'rows': 2,
                       'operations': [{'resize': [6, 2]}]}]
        def frame(step, columns):
            return {'name': 'two-pages', 'step': step, 'screen': 'primary',
                    'columns': columns, 'rows': 2, 'pages': [
                        {'serial': serial, 'columns': columns,
                         'capacity': {'cols': 6, 'rows': 1},
                         'rows': [{'wrapped': False, 'head': False}]}
                        for serial in (1, 2)]}
        self.frames = [frame(0, 4), frame(1, 6)]

    def test_distinct_pages_cover_viewport(self):
        validate_frames(self.frames, self.cases)

    def test_incomplete_or_out_of_order_run_rejected(self):
        for frames in (self.frames[:1], self.frames[::-1], self.frames * 2):
            with self.assertRaisesRegex(ValueError, 'incomplete or out-of-order'):
                validate_frames(frames, self.cases)

    def test_wrong_resize_result_rejected(self):
        self.frames[1]['columns'] = 4
        with self.assertRaisesRegex(ValueError, 'dimensions do not match'):
            validate_frames(self.frames, self.cases)

    def test_invalid_membership_and_capacity_rejected(self):
        mutations = [lambda f: f['pages'].pop(),
                     lambda f: f['pages'][1].update(serial=1),
                     lambda f: f['pages'][0]['capacity'].update(rows=0),
                     lambda f: f['pages'][0]['capacity'].update(cols=3),
                     lambda f: f['pages'][0]['rows'][0].update(head=True)]
        for mutate in mutations:
            frames = deepcopy(self.frames); mutate(frames[0])
            with self.assertRaises(ValueError):
                validate_frames(frames, self.cases)

    def test_input_cannot_inject_generated_code(self):
        self.assertEqual(literal(b'"\\\x00\xff'), '"\\x22\\x5c\\x00\\xff"')
        for bad in ('4; @compileError("injected")', True, 0, 4097, 65536):
            cases = deepcopy(self.cases); cases[0]['columns'] = bad
            with self.assertRaisesRegex(ValueError, 'dimensions'):
                generated_cases(cases)

    def test_ambiguous_and_unknown_operations_rejected(self):
        for op in ({'feed_hex': '00', 'resize': [4, 2]}, {'execute': 'code'}, {'feed_hex': 'not hex'}):
            cases = deepcopy(self.cases); cases[0]['operations'] = [op]
            with self.assertRaises(ValueError):
                generated_cases(cases)

    def test_independent_abi_membership_and_flags(self):
        frame = self.frames[0]
        row = {'wrapped': False, 'cells': [{'head': False}]}
        snap = {'cols': 4, 'rows': 2, 'alternate': False, 'scrollback': [], 'screen': [row, row]}
        validate_abi_snapshot(frame, snap)
        for mutate in (lambda s: s.update(alternate=True),
                       lambda s: s['screen'].pop(),
                       lambda s: s['screen'][0].update(wrapped=True),
                       lambda s: s['screen'][0]['cells'][-1].update(head=True)):
            bad = deepcopy(snap); mutate(bad)
            with self.assertRaises(ValueError):
                validate_abi_snapshot(frame, bad)

if __name__ == '__main__':
    unittest.main()
