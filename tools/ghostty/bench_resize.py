#!/usr/bin/env python3
"""Measure paired native/SDK C-API resize calls with verified inputs and libraries."""
from __future__ import annotations
import argparse
import datetime
import json
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
from build_oracle import materialize, sha
from capture_resize import validate_metadata

ROOT = Path(__file__).resolve().parents[2]
HARNESS = Path(__file__).with_name('resize_bench.c')
ESC = '\x1b'


def scenarios():
    plain = ''.join(f'{i:04d} ' + 'abcdefghij'*7 + '\r\n' for i in range(256))
    rich = ESC+'[31;1m'+ESC+']8;id=bench;https://example.com/resize\a'+('é日👩‍💻🇬🇧❤️|'*8+'\r\n')*64+ESC+']8;;\a'+ESC+'[0m'
    widths = [[40,24],[120,32],[80,24]]
    return [
        ('empty', '', widths),
        ('plain_history', plain, widths),
        ('styled_linked_unicode_history', rich, widths),
        ('nowrap_cached_history', plain+ESC+'[?7l', [[40,24],[80,24],[120,32],[80,24]]),
        ('alternate_crop', 'primary'+ESC+'[?1049h'+plain, widths),
        ('height_only_history', plain, [[80,12],[80,48],[80,24]]),
        ('same_size_history', plain, [[80,24],[80,24],[80,24]]),
    ]


def run(command):
    return subprocess.run(list(map(str, command)), cwd=ROOT, check=True,
                          capture_output=True, text=True, timeout=300).stdout


def percentile(values, fraction):
    values = sorted(values)
    return values[max(0, min(len(values)-1, int(len(values)*fraction+.999999)-1))]


def identity(build):
    source = []
    for path, digest in re.findall(r'\{"([^"]+)", "([0-9a-f]{64})"\}', (build/'terminal-source.h').read_text()):
        if sha(ROOT/path) != digest:
            raise ValueError('stale native source identity: '+path)
        source.append({'path':path,'sha256':digest})
    if len(source) != 31:
        raise ValueError('unexpected native source fingerprint; review the harness identity contract')
    cache = (build/'CMakeCache.txt').read_text()
    if 'BOGGART_SANITIZER:STRING=none' not in cache:
        raise ValueError('benchmark needs an unsanitized native build')
    # Ask the active generator: an old compile_commands.json can cover only
    # vendored targets when export was disabled for the native core.
    commands = run(['ninja','-C',build,'-t','commands','libboggart_vt.a']).splitlines()
    selected = [c for c in commands if ' -c ' in c and ('CMakeFiles/boggart_vt.dir/' in c or 'CMakeFiles/boggart_unicode.dir/' in c)]
    if len(selected) != 15:
        raise ValueError('native core compilation list changed; review benchmark provenance')
    return {'source_files':source,'compile_commands':selected,
            'libraries':{name:sha(build/name) for name in ['libboggart_vt.a','libboggart_unicode.a']}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir',type=Path,default=ROOT/'build')
    parser.add_argument('--oracle-work-root',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--samples',type=int,default=31)
    parser.add_argument('--warmups',type=int,default=3)
    parser.add_argument('--rounds',type=int,default=4)
    args = parser.parse_args()
    if not 1 <= args.samples <= 10000 or not 0 <= args.warmups <= 1000 or not 1 <= args.rounds <= 100:
        parser.error('sample, warmup or round count out of range')
    if sys.platform not in ('darwin','linux'):
        parser.error('the optional benchmark requires native macOS or Linux')
    build, work = args.build_dir.resolve(), args.oracle_work_root.resolve()
    metadata = validate_metadata(work/'resize-oracle', work/'oracle.json')
    library = work/'install/lib/libghostty-vt.a'
    if sha(library) != metadata['library_sha256']:
        raise ValueError('SDK static library differs from verified manifest')
    if sha(work/'ghostty.tar.gz') != metadata['archive_sha256']:
        raise ValueError('SDK source archive differs from verified manifest')
    materialize(work/'ghostty.tar.gz',work/'source')
    run(['cmake','--build',build,'--target','boggart_vt'])
    native_identity = identity(build)
    compiler = shutil.which('clang') or shutil.which('cc')
    if not compiler:
        raise ValueError('C compiler missing')
    report = {'schema':1,'ticket':'BMUX-20','created_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'host':{'system':platform.system(),'release':platform.release(),'machine':platform.machine()},
        'compiler':run([compiler,'--version']).splitlines()[0],
        'harness_sha256':sha(HARNESS),'driver_sha256':sha(__file__),'validation_test_sha256':sha(ROOT/'tests/resize_bench_cli_test.py'),'validation_fixture_sha256':sha(ROOT/'tests/fixtures/ghostty-resize.json'),'oracle':metadata,'native':native_identity,
        'samples_per_round':args.samples,'warmups_per_round':args.warmups,'rounds':args.rounds,
        'timer':'mach_absolute_time' if sys.platform=='darwin' else 'clock_gettime(CLOCK_MONOTONIC)',
        'method':'Fresh terminal and identical feed per sample; only each C resize call is timed. Complete resolved-value FNV-1a digests and memory queries run in a separate verification terminal before warmup. Backend order alternates across rounds. Digests cover geometry, cursor, wrap, visible/history cells, full scalars, widths/flags, resolved styles and URIs; they do not cover parser, queues or pool ownership.',
        'memory_scope':{'native':'Screen allocated storage, pointer rings and shared style/link/grapheme pools; excludes terminal/parser, tabs, callbacks and allocator overhead.',
                        'ghostty':'SDK-reported primary+alternate page resident and virtual bytes; includes page metadata/spares as defined by the SDK, excludes non-page bookkeeping.',
                        'rss':'Per-process peak RSS including harness, libraries, feed buffer, verification and timing; fresh process per backend/round/case. No RSS measurement inside the resize transaction.'},
        'cases':[]}
    valid = True
    with tempfile.TemporaryDirectory(prefix='bmux-resize-bench-') as scratch_name:
        scratch = Path(scratch_name)
        binaries = {name:scratch/name for name in ['native','ghostty']}
        flags = ['-std=c99','-O2','-Wall','-Wextra','-Werror']
        commands = {
            'native':[compiler,*flags,'-I'+str(ROOT/'src'),HARNESS,build/'libboggart_vt.a',build/'libboggart_unicode.a','-o',binaries['native']],
            'ghostty':[compiler,*flags,'-DBMUX_GHOSTTY','-I'+str(work/'source/include'),HARNESS,library,'-o',binaries['ghostty']]}
        for command in commands.values():
            run(command)
        run([sys.executable,ROOT/'tests/resize_bench_cli_test.py',
             '--native-binary',binaries['native'],'--oracle-binary',binaries['ghostty']])
        report['harness_validation']='Seven compiled CLI tests pass for both backends, including complete SDK fixture fingerprints for cached growth, RGB-only blanks, styled links and Unicode clusters.'
        report['harness_compile_commands']={k:list(map(str,v)) for k,v in commands.items()}
        report['harness_binary_sha256']={k:sha(v) for k,v in binaries.items()}
        for name, text, steps in scenarios():
            feed = text.encode('utf-8'); path = scratch/'feed.bin'; path.write_bytes(feed)
            case = {'name':name,'columns':80,'rows':24,'history_limit':2000,'feed_hex':feed.hex(),
                'feed_sha256':sha(path),'resize_steps':steps,'runs':[]}
            for round_index in range(args.rounds):
                order = ['native','ghostty'] if round_index%2==0 else ['ghostty','native']
                outputs = {}
                for backend in order:
                    command = [binaries[backend],args.samples,args.warmups,80,24,path,*[v for step in steps for v in step]]
                    outputs[backend] = json.loads(run(command))
                    output = outputs[backend]
                    if len(output['states']) != 1 or len(output['resized_states']) != len(steps) or len(output['memory']) != len(steps)+1:
                        raise ValueError('incomplete verification states or memory observations')
                    if len(output['timings_ns']) != args.samples or any(len(t)!=len(steps) or any(not isinstance(n,int) or n<0 for n in t) for t in output['timings_ns']):
                        raise ValueError('incomplete timing samples')
                parity = outputs['native']['states'] == outputs['ghostty']['states'] and outputs['native']['resized_states'] == outputs['ghostty']['resized_states']
                valid &= parity
                for output in outputs.values():
                    positive = [n for n in output['clock_probe_ns'] if n>0]
                    output['clock_min_positive_ns'] = min(positive) if positive else None
                case['runs'].append({'round':round_index,'order':order,'resolved_state_digest_parity':parity,**outputs})
            case['summary'] = {}
            for backend in binaries:
                case['summary'][backend] = [
                    {'median_ns':statistics.median([sample[i] for r in case['runs'] for sample in r[backend]['timings_ns']]),
                     'p95_ns':percentile([sample[i] for r in case['runs'] for sample in r[backend]['timings_ns']],.95)}
                    for i in range(len(steps))]
            report['cases'].append(case)
            print(name+': digest parity '+('pass' if all(r['resolved_state_digest_parity'] for r in case['runs']) else 'FAIL'),flush=True)
    materialize(work/'ghostty.tar.gz',work/'source')
    if native_identity != identity(build) or metadata['library_sha256'] != sha(library) or report['harness_sha256'] != sha(HARNESS):
        raise ValueError('measured source or library changed during benchmark')
    report['all_resolved_state_digests_match'] = valid
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,ensure_ascii=False,separators=(',',':'))+'\n')
    if not valid:
        raise SystemExit('Benchmark states differ: evidence saved; do not claim a matched performance comparison')


if __name__ == '__main__':
    main()
