#!/usr/bin/env python3
"""Trace SDK page membership in an isolated, explicitly instrumented build."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from build_oracle import PIN_PATH, ROOT, materialize, sha
from page_topology_cases import CASES
from capture_resize import validate_metadata

BUILD_ANCHOR = '    // All our steps which'
BUILD_EXTENSION = '''    const topology_mod = b.createModule(.{
        .root_source_file = b.path("src/bmux_page_probe.zig"),
        .target = config.target, .optimize = config.optimize, .link_libc = true,
    });
    topology_mod.addImport("ghostty-vt", mod.vt);
    const topology_exe = b.addExecutable(.{ .name = "bmux-page-probe", .root_module = topology_mod });
    const topology_run = b.addRunArtifact(topology_exe);
    b.step("bmux-page-probe", "Trace terminal page topology").dependOn(&topology_run.step);

'''

def literal(value):
    """Encode bytes without allowing case text to become generated Zig syntax."""
    if isinstance(value, str):
        value = value.encode('utf-8')
    return '"' + ''.join(f'\\x{b:02x}' for b in value) + '"'

def generated_cases(cases):
    validate_cases(cases)
    lines = ['const Resize = struct { columns: u16, rows: u16 };',
             'const Operation = union(enum) { feed: []const u8, resize: Resize };',
             'const Case = struct { name: []const u8, columns: u16, rows: u16, operations: []const Operation };',
             'pub const cases = [_]Case{']
    for c in cases:
        lines.append(f'.{{ .name={literal(c["name"])}, .columns={c["columns"]}, .rows={c["rows"]}, .operations=&.{{')
        for op in c['operations']:
            if 'feed_hex' in op:
                lines.append(f'.{{ .feed={literal(bytes.fromhex(op["feed_hex"]))} }},')
            else:
                cols, rows = op['resize']
                lines.append(f'.{{ .resize=.{{ .columns={cols}, .rows={rows} }} }},')
        lines.append('} },')
    return '\n'.join(lines + ['};', ''])

def validate_cases(cases):
    if not isinstance(cases, list) or not cases:
        raise ValueError('cases must be a nonempty JSON array')
    names = set()
    def dimension(value):
        return type(value) is int and 1 <= value <= 4096
    for c in cases:
        if not isinstance(c, dict) or not isinstance(c.get('name'), str) or not c['name'] or c['name'] in names:
            raise ValueError('case names must be unique nonempty strings')
        names.add(c['name'])
        if not dimension(c.get('columns')) or not dimension(c.get('rows')):
            raise ValueError('invalid case dimensions')
        if not isinstance(c.get('operations'), list):
            raise ValueError('case operations must be an array')
        for op in c['operations']:
            if not isinstance(op, dict) or len(op) != 1:
                raise ValueError('operation must contain exactly one feed or resize')
            if 'feed_hex' in op:
                if not isinstance(op['feed_hex'], str):
                    raise ValueError('feed_hex must be a string')
                bytes.fromhex(op['feed_hex'])
            elif 'resize' in op:
                if not isinstance(op['resize'], list) or len(op['resize']) != 2 or not all(dimension(v) for v in op['resize']):
                    raise ValueError('invalid resize dimensions')
            else:
                raise ValueError('unknown operation')

def validate_frames(frames, cases):
    validate_cases(cases)
    expected = [(c['name'], step) for c in cases for step in range(len(c['operations']) + 1)]
    if [(f['name'], f['step']) for f in frames] != expected:
        raise ValueError('incomplete or out-of-order topology frames')
    dimensions = {}
    for c in cases:
        cols, rows = c['columns'], c['rows']
        dimensions[(c['name'], 0)] = (cols, rows)
        for step, op in enumerate(c['operations'], 1):
            cols, rows = op.get('resize', (cols, rows))
            dimensions[(c['name'], step)] = (cols, rows)
    for f in frames:
        if (f['columns'], f['rows']) != dimensions[(f['name'], f['step'])]:
            raise ValueError('frame dimensions do not match inputs')
        if sum(len(p['rows']) for p in f['pages']) < f['rows']:
            raise ValueError('page rows do not cover the viewport')
        if len({p['serial'] for p in f['pages']}) != len(f['pages']):
            raise ValueError('duplicate page serial')
        for p in f['pages']:
            if p['columns'] != f['columns'] or p['capacity']['cols'] < p['columns'] or p['capacity']['rows'] < len(p['rows']):
                raise ValueError('invalid page geometry')
            if any(r['head'] and not r['wrapped'] for r in p['rows']):
                raise ValueError('wide head without wrap')

def validate_abi_snapshot(frame, snap):
    if (frame['columns'], frame['rows'], frame['screen'] == 'alternate') != (snap['cols'], snap['rows'], snap['alternate']):
        raise ValueError('diagnostic geometry/screen differs from verified C ABI')
    expected = [{'wrapped': r['wrapped'], 'head': r['cells'][-1]['head']}
                for r in snap['scrollback'] + snap['screen']]
    actual = [r for p in frame['pages'] for r in p['rows']]
    if actual != expected:
        raise ValueError('diagnostic row count/order/wrap/head differs from verified C ABI')

def check_abi(binary, cases, frames):
    metadata = validate_metadata(binary, binary.parent / 'oracle.json')
    checks = []
    offset = 0
    for c in cases:
        command = [str(binary), str(c['columns']), str(c['rows']), 'snapshot']
        for op in c['operations']:
            command += ['feed', op['feed_hex']] if 'feed_hex' in op else ['resize', *map(str, op['resize'])]
            command += ['snapshot']
        result = subprocess.run(command, capture_output=True, text=True, check=True, timeout=30)
        snaps = [json.loads(line) for line in result.stdout.splitlines()]
        count = len(c['operations']) + 1
        if len(snaps) != count:
            raise ValueError('incomplete C ABI snapshots')
        for f, s in zip(frames[offset:offset + count], snaps):
            validate_abi_snapshot(f, s)
        checks.append({'name': c['name'], 'snapshots': count,
                       'snapshot_output_sha256': hashlib.sha256(result.stdout.encode()).hexdigest()})
        offset += count
    return {'manifest': metadata, 'wrap_head_row_checks': checks}

def main():
    driver_hash = sha(__file__)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-root', type=Path, required=True)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--cases', type=Path, help='JSON array of resize-case inputs; defaults to curated cases')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--oracle-binary', type=Path, required=True, help='independent verified C ABI oracle')
    parser.add_argument('--global-cache-dir', type=Path)
    args = parser.parse_args()
    pin = json.loads(PIN_PATH.read_text())
    if pin['revision'] != json.loads((ROOT / 'THIRD_PARTY/ghostty-port.json').read_text())['revision']:
        raise ValueError('oracle pin and port ledger disagree')
    if sha(args.archive) != pin['archive_sha256']:
        raise ValueError('pinned source archive hash mismatch')
    zig = shutil.which('zig')
    if not zig or subprocess.check_output([zig, 'version'], text=True).strip() != pin['zig_version']:
        raise ValueError('the pinned Zig version is required for this optional diagnostic')
    cases = json.loads(args.cases.read_text()) if args.cases else CASES
    generated = generated_cases(cases)
    work = args.work_root.resolve(); work.mkdir(parents=True, exist_ok=True)
    source = work / 'pinned-source'; probe = work / 'probe-source'
    if probe.is_symlink() or source.is_symlink():
        raise ValueError('diagnostic source roots must not be symlinks')
    verified = materialize(args.archive, source)
    shutil.copytree(source, probe, dirs_exist_ok=True)
    build = probe / 'build.zig'; original = build.read_text()
    if original.count(BUILD_ANCHOR) != 1:
        raise ValueError('SDK build integration anchor changed')
    build.write_text(original.replace(BUILD_ANCHOR, BUILD_EXTENSION + BUILD_ANCHOR))
    template = Path(__file__).with_name('page_topology.zig')
    template_hash = sha(template)
    shutil.copyfile(template, probe / 'src/bmux_page_probe.zig')
    inputs = probe / 'src/bmux_page_cases.zig'; inputs.write_text(generated)
    command = [zig, 'build', 'bmux-page-probe', '-Demit-lib-vt=true', '-Demit-xcframework=false',
               '-Doptimize=' + pin['optimize'], '-Dsimd=' + str(pin['simd']).lower(),
               '--cache-dir', str(work / 'cache'), '--global-cache-dir',
               str(args.global_cache_dir.resolve() if args.global_cache_dir else work / 'global-cache')]
    result = subprocess.run(command, cwd=probe, capture_output=True, text=True, timeout=600)
    (work / 'build.log').write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f'SDK diagnostic build/run failed; see {work / "build.log"}')
    frames = [json.loads(line) for line in result.stderr.splitlines() if line.startswith('{')]
    validate_frames(frames, cases)
    abi = check_abi(args.oracle_binary.resolve(), cases, frames)
    # Verify the reference tree remains pristine. This probe is not an oracle ABI artifact.
    materialize(args.archive, source)
    if sha(__file__) != driver_hash or sha(template) != template_hash or sha(probe / 'src/bmux_page_probe.zig') != template_hash:
        raise ValueError('diagnostic sources changed during build/run')
    report = {'schema': 1, 'kind': 'instrumented-sdk-page-topology', 'revision': pin['revision'],
              'archive_sha256': pin['archive_sha256'], 'source_files_verified': verified,
              'zig_version': pin['zig_version'], 'command': command,
              'probe_sha256': template_hash, 'driver_sha256': driver_hash,
              'original_build_sha256': sha(source / 'build.zig'), 'instrumented_build_sha256': sha(build),
              'generated_cases_sha256': sha(inputs), 'c_abi_verification': abi, 'inputs': cases, 'frames': frames}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, separators=(',', ':')) + '\n')
    print(f'SDK page topology: {len(cases)} cases, {len(frames)} frames; {args.output}')

if __name__ == '__main__':
    main()
