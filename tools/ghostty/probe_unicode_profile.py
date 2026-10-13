#!/usr/bin/env python3
"""Export the terminal Unicode profile from a separately built, pinned SDK."""
import argparse
import json
import re
from pathlib import Path
import shutil
import subprocess

from build_oracle import ROOT, PIN_PATH, materialize, sha
from probe_page_topology import BUILD_ANCHOR, BUILD_EXTENSION


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-root', type=Path, required=True)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--global-cache-dir', type=Path, required=True)
    args = parser.parse_args()
    pin = json.loads(PIN_PATH.read_text())
    if sha(args.archive) != pin['archive_sha256']:
        raise ValueError('SDK archive mismatch')
    zig = shutil.which('zig')
    if not zig or subprocess.check_output([zig, 'version'], text=True).strip() != pin['zig_version']:
        raise ValueError('pinned Zig required')
    work = args.work_root.resolve(); work.mkdir(parents=True, exist_ok=True)
    source, probe = work / 'pinned-source', work / 'probe-source'
    if source.is_symlink() or probe.is_symlink():
        raise ValueError('source roots must not be symlinks')
    count = materialize(args.archive, source)
    shutil.copytree(source, probe, dirs_exist_ok=True)
    build = probe / 'build.zig'; text = build.read_text()
    if text.count(BUILD_ANCHOR) != 1:
        raise ValueError('SDK build anchor changed')
    extension = BUILD_EXTENSION.replace('topology_mod.addImport("ghostty-vt", mod.vt);',
        'topology_mod.addImport("uucode", mod.vt.import_table.get("uucode").?);\n'
        '    topology_mod.addImport("unicode_tables", mod.vt.import_table.get("unicode_tables").?);')
    build.write_text(text.replace(BUILD_ANCHOR, extension + BUILD_ANCHOR))
    template = Path(__file__).with_name('unicode_profile.zig')
    driver_hash, template_hash = sha(__file__), sha(template)
    shutil.copyfile(template, probe / 'src/bmux_page_probe.zig')
    lock = (source / 'build.zig.zon').read_text()
    package = re.search(r'\.uucode = \.\{.*?\.hash = "([^"]+)"', lock, re.S).group(1)
    command = [zig, 'build', 'bmux-page-probe', '-Demit-lib-vt=true', '-Demit-xcframework=false',
        '-Doptimize=' + pin['optimize'], '-Dsimd=' + str(pin['simd']).lower(),
        '--cache-dir', str(work / 'cache'), '--global-cache-dir', str(args.global_cache_dir.resolve())]
    result = subprocess.run(command, cwd=probe, capture_output=True, text=True, timeout=600)
    (work / 'build.log').write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f'Unicode export failed; see {work / "build.log"}')
    samples = [json.loads(line) for line in result.stderr.splitlines() if line.startswith('{')]
    dependency = probe / 'zig-pkg' / package
    actual = subprocess.check_output([zig, 'fetch', '--global-cache-dir', str(work / 'verify-cache'),
        str(dependency)], cwd=probe, text=True).strip()
    if actual != package:
        raise ValueError('uucode dependency package hash mismatch')
    dependencies = []
    for path in sorted(dependency.rglob('*')):
        if path.is_file():
            dependencies.append(dict(path=str(path.relative_to(probe)), sha256=sha(path)))
    materialize(args.archive, source)
    if sha(__file__) != driver_hash or sha(template) != template_hash:
        raise ValueError('capture sources changed')
    report = dict(schema=1, kind='pinned-sdk-terminal-unicode', revision=pin['revision'],
        archive_sha256=pin['archive_sha256'], source_files_verified=count, zig_version=pin['zig_version'],
        driver_sha256=driver_hash, probe_sha256=template_hash, dependencies=dependencies, samples=samples)
    report['uucode_package_hash'] = package
    report['dependency_lock_sha256'] = sha(source / 'build.zig.zon')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, separators=(',', ':')) + '\n')
    print(f'SDK terminal Unicode: {len(samples)} records; {args.output}')


if __name__ == '__main__':
    main()
