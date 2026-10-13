#!/usr/bin/env python3
"""Capture/recheck immutable resize vectors through the compiled VT adapter."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from resize_cases import CASES

ROOT = Path(__file__).resolve().parents[2]
DEFAULT = ROOT / 'tests/fixtures/ghostty-resize.json'

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def validate_metadata(binary, manifest):
    metadata = json.loads(Path(manifest).read_text())
    pin = json.loads((ROOT / 'tools/ghostty/oracle-pin.json').read_text())
    ledger = json.loads((ROOT / 'THIRD_PARTY/ghostty-port.json').read_text())
    if pin['revision'] != ledger['revision']:
        raise ValueError('oracle pin and port ledger disagree')
    checks = {'schema': 1, 'revision': pin['revision'], 'archive_sha256': pin['archive_sha256'],
              'zig_version': pin['zig_version'], 'adapter_sha256': sha(ROOT / 'tools/ghostty/resize_oracle.c'),
              'binary_sha256': sha(binary)}
    for key, expected in checks.items():
        if metadata.get(key) != expected:
            raise ValueError('oracle provenance mismatch: ' + key)
    return metadata

def capture(binary):
    results = []
    for case in CASES:
        command = [str(binary), str(case['columns']), str(case['rows']), 'snapshot']
        for op in case['operations']:
            if 'feed_hex' in op:
                command += ['feed', op['feed_hex']]
            else:
                command += ['resize', *map(str, op['resize'])]
            command += ['snapshot']
        process = subprocess.run(command, check=True, capture_output=True, text=True, timeout=30)
        snapshots = [json.loads(line) for line in process.stdout.splitlines()]
        if len(snapshots) != len(case['operations']) + 1:
            raise ValueError(case['name'] + ': incomplete snapshots')
        results.append({**case, 'snapshots': snapshots})
    return results

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=DEFAULT)
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    binary = args.binary.resolve()
    metadata = validate_metadata(binary, args.manifest or binary.parent / 'oracle.json')
    revision = json.loads((ROOT / 'THIRD_PARTY/ghostty-port.json').read_text())['revision']
    data = {'schema': 1, 'upstream_revision': revision, 'grapheme_mode': True,
            'history_limit': 2000, 'source_archive_sha256': metadata['archive_sha256'], 'adapter_sha256': sha(ROOT / 'tools/ghostty/resize_oracle.c'),
            'cases_sha256': sha(ROOT / 'tools/ghostty/resize_cases.py'), 'cases': capture(args.binary.resolve())}
    if args.check:
        if json.loads(args.output.read_text()) != data:
            raise SystemExit('resize fixtures differ from oracle capture')
    else:
        args.output.write_text(json.dumps(data, ensure_ascii=False, separators=(',', ':')) + '\n')
    print(f"Ghostty resize fixtures: {len(data['cases'])} cases, "
          f"{sum(len(c['snapshots']) for c in data['cases'])} snapshots")

if __name__ == '__main__':
    main()
