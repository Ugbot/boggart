#!/usr/bin/env python3
"""Verify BMUX's pinned source ledger and attribution without fetching anything."""
import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def check(upstream=None):
    manifest = json.loads((ROOT / "THIRD_PARTY/ghostty-port.json").read_text())
    revision = manifest["revision"]
    assert re.fullmatch(r"[0-9a-f]{40}", revision), "invalid upstream revision"
    assert manifest["repository"] == "https://github.com/ghostty-org/ghostty"
    license_path = ROOT / manifest["license_file"]
    notice = license_path.read_bytes()
    assert hashlib.sha256(notice).hexdigest() == manifest["license_sha256"], "licence notice changed"
    assert b"MIT License" in notice and b"Ghostty contributors" in notice, "missing attribution"
    sources, ports = set(), {}
    for module in manifest["modules"]:
        source = module["upstream_path"]
        assert source not in sources, "duplicate source: " + source
        sources.add(source)
        assert module["status"] in {"ported", "studied", "skipped"}, "invalid status: " + source
        files = module["ported_files"]
        assert bool(files) == (module["status"] == "ported"), "status/files disagree: " + source
        if "sha256" in module:
            assert re.fullmatch(r"[0-9a-f]{64}", module["sha256"]), "invalid source hash: " + source
            if upstream:
                content = (upstream / source).read_bytes()
                assert hashlib.sha256(content).hexdigest() == module["sha256"], "source changed: " + source
        for filename in files:
            path = (ROOT / filename).resolve()
            assert path.is_relative_to(ROOT), "port escapes repository: " + filename
            assert path.suffix in {".c", ".h"}, "expected a C port: " + filename
            header = path.read_text()[:4096]
            marker = "ported from ghostty@" + revision + " " + source
            assert marker in header, "missing pinned header: " + filename
            ports.setdefault(filename, set()).add(source)
    # A derivative cannot escape attribution just by being left out of the
    # ledger: check the inverse mapping as well as the listed ports.
    for base in (ROOT / "src", ROOT / "studio/src"):
        for path in base.rglob("*"):
            if path.suffix not in {".c", ".h"} or "vendor" in path.parts:
                continue
            for sha, source in re.findall(r"ported from ghostty@([0-9a-f]+) ([\w./-]+)",
                                          path.read_text(errors="replace")[:4096]):
                relative = path.relative_to(ROOT).as_posix()
                assert sha == revision and source in ports.get(relative, set()), "unlisted port: " + relative
    print(f"Ghostty attribution: {revision}, {len(sources)} modules, {len(ports)} ported files")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", type=Path, help="also verify source hashes in a pinned checkout")
    args = parser.parse_args()
    check(args.upstream)
