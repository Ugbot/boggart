#!/usr/bin/env python3
"""Offline guards for full observable resize snapshot digests."""
from copy import deepcopy
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools/ghostty'))
from build_oracle import sha
from resize_digest import digest
from resize_large_cases import CASES

class DigestTests(unittest.TestCase):
    def test_fixture_identity_and_complete_inputs(self):
        r = json.loads((ROOT / 'tests/fixtures/ghostty-resize-large.json').read_text())
        pin = json.loads((ROOT / 'tools/ghostty/oracle-pin.json').read_text())
        self.assertEqual(r['oracle']['revision'], pin['revision'])
        self.assertEqual(r['oracle']['archive_sha256'], pin['archive_sha256'])
        self.assertEqual(set(r['profile']), {'system', 'machine', 'pointer_bytes'})
        self.assertEqual(r['driver_sha256'], sha(ROOT / 'tools/ghostty/resize_digest.py'))
        self.assertEqual(r['cases_sha256'], sha(ROOT / 'tools/ghostty/resize_large_cases.py'))
        self.assertEqual([{k: c[k] for k in ('name', 'columns', 'rows', 'operations')} for c in r['cases']], CASES)
        for c in r['cases']:
            self.assertEqual(len(c['digests']), len(c['operations']) + 1)
            self.assertTrue(all(len(d) == 64 and all(ch in '0123456789abcdef' for ch in d) for d in c['digests']))

    def test_protocol_includes_every_observable_field(self):
        cell = dict(cps=[65], width=1, head=False, protected=False, style=[0,0,0,0], uri=[97])
        s = dict(cols=1, rows=1, x=0, y=0, pending_wrap=False, alternate=False,
                 scrollback=[], screen=[dict(wrapped=False, cells=[cell])])
        base = digest(s)
        for field in ('cols', 'rows', 'x', 'y', 'pending_wrap', 'alternate'):
            changed = deepcopy(s); changed[field] = 1 if isinstance(s[field], bool) else s[field] + 1
            self.assertNotEqual(digest(changed), base, field)
        changed = deepcopy(s); changed['screen'][0]['wrapped'] = True
        self.assertNotEqual(digest(changed), base)
        for field in ('cps', 'width', 'head', 'protected', 'style', 'uri'):
            changed = deepcopy(s); c = changed['screen'][0]['cells'][0]
            c[field] = ([66] if field == 'cps' else [98] if field == 'uri' else [0,1,0,0]
                        if field == 'style' else 2 if field == 'width' else True)
            self.assertNotEqual(digest(changed), base, field)
        changed = deepcopy(s); changed['scrollback'] = changed['screen']; changed['screen'] = []
        self.assertNotEqual(digest(changed), base)

if __name__ == '__main__': unittest.main()
