#!/usr/bin/env python3
"""Offline identity guards for the active SDK-derived C layout fixture."""
import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools/ghostty'))
from build_oracle import sha
from layout_fixture import render
from page_layout_cases import CASES
from probe_page_layout import generated_cases

class LayoutFixtureTests(unittest.TestCase):
    def setUp(self):
        self.path = ROOT / 'docs/benchmarks/2026-10-13-sdk-page-layout.json'
        self.report = json.loads(self.path.read_text())

    def test_reference_identity_and_inputs(self):
        pin = json.loads((ROOT / 'tools/ghostty/oracle-pin.json').read_text())
        r = self.report
        self.assertEqual(r['kind'], 'instrumented-sdk-page-layout')
        self.assertEqual(r['revision'], pin['revision'])
        self.assertEqual(r['archive_sha256'], pin['archive_sha256'])
        self.assertEqual(r['zig_version'], pin['zig_version'])
        self.assertEqual(r['driver_sha256'], sha(ROOT / 'tools/ghostty/probe_page_layout.py'))
        self.assertEqual(r['probe_sha256'], sha(ROOT / 'tools/ghostty/page_layout.zig'))
        self.assertEqual(r['generated_cases_sha256'], hashlib.sha256(generated_cases().encode()).hexdigest())
        self.assertEqual([(s['name'], s['cap'], s['adjust']) for s in r['samples']],
                         [(c['name'], c['cap'], c['adjust']) for c in CASES])

    def test_compiled_fixture_matches_sdk_capture(self):
        prefix = '/* SDK report SHA256: ' + sha(self.path) + ' */\n'
        self.assertEqual((ROOT / 'tests/fixtures/ghostty-page-layout.h').read_text(), prefix + render(self.report))

    def test_renderer_rejects_mixed_shapes_and_origins(self):
        for change in ('shape', 'origin', 'capacity'):
            report = json.loads(self.path.read_text())
            if change == 'shape': report['samples'][1]['shape']['word_bytes'] = 4
            elif change == 'origin': report['samples'][0]['layout']['rows_start'] = 1
            else: report['samples'][0]['layout']['capacity']['rows'] += 1
            with self.assertRaises(ValueError): render(report)

    def test_renderer_rejects_code_in_numeric_fields_and_names(self):
        for change in ('number', 'name', 'negative', 'overflow'):
            report = json.loads(self.path.read_text()); s = report['samples'][0]
            if change == 'number': s['adjust'] = '1}; system("injected");'
            elif change == 'name': s['name'] = 'name */ #include "injected"'
            elif change == 'negative': s['layout']['total_size'] = -1
            else: s['layout']['total_size'] = 18446744073709551616
            with self.assertRaises(ValueError): render(report)

if __name__ == '__main__':
    unittest.main()
