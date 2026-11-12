#!/usr/bin/env python3
"""Capture pinned SDK layout formulas without allocating terminal pages."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from build_oracle import ROOT, PIN_PATH, materialize, sha
from probe_page_topology import BUILD_ANCHOR, BUILD_EXTENSION, literal
from page_layout_cases import CASES

def generated_cases():
    lines = ['const vt = @import("ghostty-vt");',
             'const Case = struct { name: []const u8, cap: vt.page.Capacity, adjust: u16, initial: bool };',
             'pub const cases = [_]Case{']
    for c in CASES:
        fields = ', '.join(f'.{key}={value}' for key, value in c['cap'].items())
        lines.append(f'.{{ .name={literal(c["name"])}, .cap=.{{ {fields} }}, .adjust={c["adjust"]}, .initial={str(c["initial"]).lower()} }},')
    return '\n'.join(lines + ['};', ''])

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-root', type=Path, required=True)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--global-cache-dir', type=Path)
    args = parser.parse_args()
    pin = json.loads(PIN_PATH.read_text()); driver_hash = sha(__file__)
    if pin['revision'] != json.loads((ROOT / 'THIRD_PARTY/ghostty-port.json').read_text())['revision'] or sha(args.archive) != pin['archive_sha256']:
        raise ValueError('SDK source pin mismatch')
    zig = shutil.which('zig')
    if not zig or subprocess.check_output([zig, 'version'], text=True).strip() != pin['zig_version']:
        raise ValueError('pinned Zig required for optional layout capture')
    work = args.work_root.resolve(); work.mkdir(parents=True, exist_ok=True)
    source = work / 'pinned-source'; probe = work / 'probe-source'
    if source.is_symlink() or probe.is_symlink():
        raise ValueError('source roots must not be symlinks')
    count = materialize(args.archive, source)
    shutil.copytree(source, probe, dirs_exist_ok=True)
    build = probe / 'build.zig'; text = build.read_text()
    if text.count(BUILD_ANCHOR) != 1:
        raise ValueError('SDK build anchor changed')
    build.write_text(text.replace(BUILD_ANCHOR, BUILD_EXTENSION + BUILD_ANCHOR))
    template = Path(__file__).with_name('page_layout.zig'); template_hash = sha(template)
    shutil.copyfile(template, probe / 'src/bmux_page_probe.zig')
    generated = generated_cases(); inputs = probe / 'src/bmux_page_cases.zig'; inputs.write_text(generated)
    command = [zig, 'build', 'bmux-page-probe', '-Demit-lib-vt=true', '-Demit-xcframework=false',
               '-Doptimize=' + pin['optimize'], '-Dsimd=' + str(pin['simd']).lower(),
               '--cache-dir', str(work / 'cache'), '--global-cache-dir',
               str(args.global_cache_dir.resolve() if args.global_cache_dir else work / 'global-cache')]
    result = subprocess.run(command, cwd=probe, capture_output=True, text=True, timeout=600)
    (work / 'build.log').write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f'layout capture failed; see {work / "build.log"}')
    samples = [json.loads(line) for line in result.stderr.splitlines() if line.startswith('{')]
    if [(s['name'], s['cap'], s['adjust']) for s in samples] != [(c['name'], c['cap'], c['adjust']) for c in CASES]:
        raise ValueError('incomplete or mismatched SDK samples')
    materialize(args.archive, source)
    if sha(__file__) != driver_hash or sha(template) != template_hash or generated_cases() != generated:
        raise ValueError('capture sources changed during build')
    report = dict(schema=1, kind='instrumented-sdk-page-layout', revision=pin['revision'],
                  archive_sha256=pin['archive_sha256'], source_files_verified=count,
                  zig_version=pin['zig_version'], command=command, driver_sha256=driver_hash,
                  probe_sha256=template_hash, generated_cases_sha256=hashlib.sha256(generated.encode()).hexdigest(),
                  original_build_sha256=sha(source / 'build.zig'), instrumented_build_sha256=sha(build), samples=samples)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, separators=(',', ':')) + '\n')
    print(f'SDK page layouts: {len(samples)} samples; {args.output}')

if __name__ == '__main__':
    main()
