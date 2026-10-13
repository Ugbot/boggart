#!/usr/bin/env python3
"""Offline provenance, completeness and safe-generation checks for SDK Unicode."""
import copy
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools/ghostty'))
from unicode_fixture import FIXTURE, HEADER, generate, tables


class ProfileTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.report = json.loads(FIXTURE.read_text())

    def test_compiled_table_matches_complete_sdk_capture(self):
        self.assertEqual(HEADER.read_text(), generate(self.report))

    def test_unicode18_combining_properties(self):
        values, transitions = tables(self.report)
        self.assertEqual(len(values), 0x110000)
        self.assertEqual(len(transitions), 8192)
        for cp in (0x5c8, 0x5c9):
            self.assertEqual(values[cp] & 3, 0)
            self.assertTrue(values[cp] & 4)

    def test_changed_pin_probe_or_class_encoding_rejected(self):
        for field in ('revision', 'archive_sha256', 'probe_sha256', 'driver_sha256'):
            report = copy.deepcopy(self.report); report[field] = '0' * 64
            with self.assertRaises(ValueError): tables(report)
        report = copy.deepcopy(self.report); report['samples'][0]['class'][1] = 'changed'
        with self.assertRaises(ValueError): tables(report)

    def test_incomplete_duplicate_and_unsafe_records_rejected(self):
        for kind in ('range', 'transition'):
            for change in ('missing', 'duplicate', 'code', 'boolean', 'overflow'):
                report = copy.deepcopy(self.report)
                i = next(i for i, sample in enumerate(report['samples']) if kind in sample)
                if change == 'missing': del report['samples'][i]
                elif change == 'duplicate': report['samples'].append(copy.deepcopy(report['samples'][i]))
                else:
                    report['samples'][i][kind][-1] = {'code': '0}; system("injected");',
                        'boolean': False, 'overflow': 0x1000000}[change]
                with self.assertRaises(ValueError): tables(report)


if __name__ == '__main__':
    unittest.main()
