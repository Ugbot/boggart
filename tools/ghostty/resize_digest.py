#!/usr/bin/env python3
"""Capture complete observable snapshots as compact SHA256 expectations."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import struct
import subprocess

from build_oracle import ROOT, sha
from capture_resize import validate_metadata
from resize_large_cases import CASES

def digest(snapshot):
    parts = [b'BMUX-RESIZE-1\0', struct.pack('<IIIIBB', snapshot['cols'], snapshot['rows'],
             snapshot['x'], snapshot['y'], snapshot['pending_wrap'], snapshot['alternate'])]
    for name in ('scrollback', 'screen'):
        rows = snapshot[name]; parts.append(struct.pack('<I', len(rows)))
        for row in rows:
            parts.append(struct.pack('<BI', row['wrapped'], len(row['cells'])))
            for cell in row['cells']:
                cps = cell['cps']; uri = bytes(cell['uri'])
                parts.append(struct.pack('<BBBI', cell['width'], cell['head'], cell['protected'], len(cps)))
                parts.append(struct.pack('<' + 'I' * len(cps), *cps))
                parts.append(struct.pack('<IIII', *cell['style']))
                parts.append(struct.pack('<I', len(uri))); parts.append(uri)
    return hashlib.sha256(b''.join(parts)).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args(); binary = args.binary.resolve()
    metadata = validate_metadata(binary, binary.parent / 'oracle.json')
    driver_hash = sha(__file__); cases_hash = sha(Path(__file__).with_name('resize_large_cases.py'))
    results = []
    for c in CASES:
        command = [str(binary), str(c['columns']), str(c['rows']), 'snapshot']
        for op in c['operations']:
            command += ['feed', op['feed_hex']] if 'feed_hex' in op else ['resize', *map(str, op['resize'])]
            command += ['snapshot']
        result = subprocess.run(command, capture_output=True, text=True, check=True, timeout=60)
        snapshots = [json.loads(line) for line in result.stdout.splitlines()]
        if len(snapshots) != len(c['operations']) + 1:
            raise ValueError('incomplete SDK snapshots: ' + c['name'])
        results.append(dict(c, digests=[digest(s) for s in snapshots]))
    if validate_metadata(binary, binary.parent / 'oracle.json') != metadata or sha(__file__) != driver_hash:
        raise ValueError('capture identity changed')
    if sha(Path(__file__).with_name('resize_large_cases.py')) != cases_hash:
        raise ValueError('cases changed during capture')
    report = dict(schema=1, protocol='BMUX-RESIZE-1', history_limit=2000, oracle=metadata,
                  profile=dict(system=platform.system(), machine=platform.machine(), pointer_bytes=struct.calcsize('P')),
                  driver_sha256=driver_hash, cases_sha256=cases_hash, cases=results)
    body = json.dumps(report, separators=(',', ':')) + '\n'
    if args.check:
        if json.loads(args.output.read_text()) != report: raise ValueError('SDK digest capture differs')
    else: args.output.write_text(body)
    print(f'SDK full-state digests: {len(results)} cases, {sum(len(c["digests"]) for c in results)} snapshots')

if __name__ == '__main__': main()
