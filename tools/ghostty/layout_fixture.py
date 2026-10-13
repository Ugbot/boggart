"""Render SDK-captured expectations as a dependency-free C99 test fixture."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re

FIELDS = ('total_size', 'rows_size', 'cells_start', 'cells_size', 'meta_start', 'meta_size',
          'styles_start', 'grapheme_alloc_start', 'grapheme_map_start', 'string_alloc_start',
          'hyperlink_set_start', 'hyperlink_map_start')
CAP_FIELDS = ('cols', 'rows', 'styles', 'hyperlink_bytes', 'grapheme_bytes', 'string_bytes')

def render(report):
    samples = report['samples']
    if not samples or len({s['name'] for s in samples}) != len(samples):
        raise ValueError('layout samples must be nonempty and uniquely named')
    shape = samples[0]['shape']
    if any(s['shape'] != shape for s in samples):
        raise ValueError('mixed SDK layout shapes')
    def number(value, maximum):
        if type(value) is not int or not 0 <= value <= maximum:
            raise ValueError('invalid SDK numeric field')
        return value
    for key in ('page_align', 'cell_align', 'word_bytes'):
        number(shape[key], 4294967295)
    def cap(value):
        if value is not None:
            for k in CAP_FIELDS:
                number(value[k], 4294967295 if k in ('grapheme_bytes', 'string_bytes') else 65535)
        return '{' + ','.join(str(value[k]) for k in CAP_FIELDS) + '}' if value else '{0}'
    lines = ['/* Generated from pinned SDK page_layout.zig; do not edit. */',
             'static const lp_layout_shape sdk_layout_shape = {' + ','.join(str(shape[k]) for k in ('page_align', 'cell_align', 'word_bytes')) + '};',
             'static const struct { lp_capacity cap; lp_layout layout; uint16_t columns;',
             '  bool has_adjust, has_initial; lp_capacity adjusted, initial; } sdk_layout_cases[] = {']
    for s in samples:
        if not re.fullmatch(r'[a-zA-Z0-9_]+', s['name']):
            raise ValueError('invalid SDK sample name')
        number(s['adjust'], 65535)
        l, m = s['layout'], s['meta']
        if l['rows_start'] != 0 or l['capacity'] != s['cap']:
            raise ValueError('SDK grid origin/capacity mismatch')
        values = dict(l, meta_start=l['styles_start'], meta_size=m['total_size'])
        for k in FIELDS:
            number(values[k], 18446744073709551615)
        layout = '{' + ','.join(f'UINT64_C({values[k]})' for k in FIELDS) + '}'
        lines.append('  {' + cap(s['cap']) + ',' + layout + f',{s["adjust"]},'
                     + str(s['adjusted'] is not None).lower() + ',' + str(s['initial'] is not None).lower()
                     + ',' + cap(s['adjusted']) + ',' + cap(s['initial']) + '}, /* ' + s['name'] + ' */')
    return '\n'.join(lines + ['};', ''])

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    report = json.loads(args.report.read_text())
    pin = json.loads(Path(__file__).with_name('oracle-pin.json').read_text())
    if report['revision'] != pin['revision'] or report['archive_sha256'] != pin['archive_sha256']:
        raise ValueError('layout fixture source pin mismatch')
    body = '/* SDK report SHA256: ' + hashlib.sha256(args.report.read_bytes()).hexdigest() + ' */\n' + render(report)
    if args.check:
        if args.output.read_text() != body:
            raise ValueError('layout fixture differs from captured SDK report')
    else:
        args.output.write_text(body)
    print(f'SDK layout fixture: {len(report["samples"])} cases')

if __name__ == '__main__':
    main()
