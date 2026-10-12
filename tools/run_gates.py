#!/usr/bin/env python3
"""run_gates.py -- run ctest and fail on the ways a green run can lie (BOG-10).

After Venus's tools/run_gates.py: a bare `ctest -L label` (or -R) that matches
NOTHING exits 0, so a CI step can "pass" with zero tests run. This treats three
things as distinct failures:
  * no tests ran at all (a filter that matched nothing, a broken build tree),
  * tests that were "Not Run" (missing executable),
  * real failures.

usage: tools/run_gates.py <build-dir> [ctest args...]   e.g. -j8 -R 'story|auth'
"""
import re, subprocess, sys

def main():
    if len(sys.argv) < 2:
        print(__doc__); return 2
    build, extra = sys.argv[1], sys.argv[2:]
    p = subprocess.run(["ctest", "--output-on-failure", *extra], cwd=build,
                       capture_output=True, text=True)
    out = p.stdout + p.stderr
    sys.stdout.write(out)
    # "100% tests passed out of 3" or "66% tests passed, 1 tests failed out of 3"
    m = re.search(r"(\d+)% tests passed(?:, (\d+) tests? failed)? out of (\d+)", out)
    total = int(m.group(3)) if m else 0
    failed = int(m.group(2)) if (m and m.group(2)) else 0
    if "No tests were found" in out or total == 0:
        print("GATE FAILED: no tests ran (filter matched nothing, or the build tree is broken)")
        return 1
    not_run = re.findall(r"\*\*\*Not Run.*", out)
    if not_run:
        print(f"GATE FAILED: {len(not_run)} test(s) were not run (missing executable?)")
        return 1
    if p.returncode != 0 or failed > 0:
        print(f"GATE FAILED: {failed} of {total} test(s) failed")
        return 1
    print(f"GATE PASSED: {total} test(s)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
