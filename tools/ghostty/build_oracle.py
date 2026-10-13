#!/usr/bin/env python3
"""Build the pinned VT test oracle in a caller-owned scratch directory."""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
PIN_PATH = Path(__file__).with_name('oracle-pin.json')

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def run(command, cwd=None):
    print('+ ' + ' '.join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), cwd=cwd, check=True, timeout=600)

def source_files(archive):
    for member in archive.getmembers():
        path = PurePosixPath(member.name)
        if path.is_absolute() or '..' in path.parts or len(path.parts) < 1:
            raise ValueError('unsafe source archive path')
        if member.isdir():
            continue
        if not member.isfile():
            raise ValueError('source archive contains unsupported link or special file')
        relative = Path(*path.parts[1:])
        if not relative.parts:
            raise ValueError('missing source archive root')
        yield relative, member

def materialize(archive_path, source):
    exists = source.exists()
    with tarfile.open(archive_path, 'r:gz') as archive:
        count = 0
        for relative, member in source_files(archive):
            data = archive.extractfile(member).read()
            target = source / relative
            if exists:
                if target.is_symlink() or not target.is_file() or target.read_bytes() != data:
                    raise ValueError('pinned source differs: ' + str(relative))
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                target.chmod(member.mode & 0o777)
            count += 1
    return count

def native_library(prefix, platform):
    names = {'darwin': 'lib/libghostty-vt.dylib',
             'linux': 'lib/libghostty-vt.so'}
    if platform not in names:
        raise ValueError('this optional oracle builder supports macOS and Linux')
    library = prefix / names[platform]
    if not library.is_file():
        raise ValueError('missing native VT library for ABI schema verification')
    return library

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-root', type=Path, required=True)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--prefix', type=Path)
    parser.add_argument('--cache-dir', type=Path)
    parser.add_argument('--global-cache-dir', type=Path)
    args = parser.parse_args()
    work = args.work_root.resolve(); work.mkdir(parents=True, exist_ok=True)
    pin = json.loads(PIN_PATH.read_text())
    if json.loads((ROOT / 'THIRD_PARTY/ghostty-port.json').read_text())['revision'] != pin['revision']:
        raise ValueError('oracle pin and port ledger disagree')
    archive_path = args.archive.resolve() if args.archive else work / 'ghostty.tar.gz'
    if not archive_path.exists():
        if args.archive:
            raise ValueError('specified source archive is missing')
        with urllib.request.urlopen(pin['archive_url'], timeout=60) as response:
            archive_path.write_bytes(response.read())
    if sha(archive_path) != pin['archive_sha256']:
        raise ValueError('pinned source archive hash mismatch')
    source = args.source.resolve() if args.source else work / 'source'
    count = materialize(archive_path, source)
    run([sys.executable, ROOT / 'tools/check_ghostty_port.py', '--upstream', source])
    zig = shutil.which('zig')
    if not zig:
        raise ValueError('Zig is required only to build this optional oracle')
    zig_version = subprocess.check_output([zig, 'version'], text=True).strip()
    if zig_version != pin['zig_version']:
        raise ValueError(f"oracle requires Zig {pin['zig_version']}, got {zig_version}")
    if sys.platform not in ('darwin', 'linux'):
        raise ValueError('this optional oracle builder supports macOS and Linux')
    if importlib.util.find_spec('jsonschema') is None:
        raise ValueError('the upstream ABI verifier requires the Python jsonschema package')
    prefix = args.prefix.resolve() if args.prefix else work / 'install'
    run([zig, 'build', '-Demit-lib-vt=true', '-Demit-xcframework=false',
         '-Doptimize=' + pin['optimize'], '-Dsimd=' + str(pin['simd']).lower(), '--prefix', prefix,
         '--cache-dir', args.cache_dir.resolve() if args.cache_dir else work / 'cache',
         '--global-cache-dir', args.global_cache_dir.resolve() if args.global_cache_dir else work / 'global-cache'], source)
    library = prefix / 'lib/libghostty-vt.a'
    if not library.is_file():
        raise ValueError('missing native static VT library')
    dynamic = native_library(prefix, sys.platform)
    run([sys.executable, source / 'src/terminal/c/types-schema-verify.py',
         source / 'src/terminal/c/types.schema.json', dynamic])
    # Recheck source after build before recording provenance.
    materialize(archive_path, source)
    compiler = shutil.which('clang') or shutil.which('cc')
    if not compiler:
        raise ValueError('C compiler missing')
    binary = work / 'resize-oracle'
    adapter = ROOT / 'tools/ghostty/resize_oracle.c'
    run([compiler, '-std=c99', '-Wall', '-Wextra', '-Werror', '-I' + str(source / 'include'),
         adapter, library, '-o', binary])
    metadata = {'schema':1, 'revision':pin['revision'], 'archive_sha256':pin['archive_sha256'],
                'source_files_verified':count, 'zig_version':zig_version,
                'library_sha256':sha(library), 'binary_sha256':sha(binary),
                'adapter_sha256':sha(adapter), 'compiler':subprocess.check_output([compiler, '--version'], text=True).splitlines()[0]}
    manifest = work / 'oracle.json'; manifest.write_text(json.dumps(metadata, indent=2) + '\n')
    print('Oracle binary: ' + str(binary)); print('Oracle manifest: ' + str(manifest))

if __name__ == '__main__':
    main()
