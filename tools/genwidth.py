#!/usr/bin/env python3
"""Generate the shared C Unicode table from hash-pinned official UCD inputs.

python3 tools/genwidth.py          # regenerate src/bunicode_data.h offline
python3 tools/genwidth.py --check  # fail on data/license drift or stale output

Builds compile the checked-in result and never run Python or fetch data.
Data copyright Unicode, Inc.; see THIRD_PARTY/unicode-LICENSE (License V3).
"""
import argparse
from array import array
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = "16.0.0"
LIMIT = 0x110000
FILES = {
    "EastAsianWidth.txt", "DerivedCoreProperties.txt", "UnicodeData.txt",
    "emoji/emoji-data.txt", "emoji/emoji-variation-sequences.txt",
    "auxiliary/GraphemeBreakProperty.txt", "auxiliary/GraphemeBreakTest.txt",
}
# Public bit layout and enum order in src/bunicode.h.
GCB = {name: i for i, name in enumerate((
    "Other", "CR", "LF", "Control", "Extend", "ZWJ", "Regional_Indicator",
    "Prepend", "SpacingMark", "L", "V", "T", "LV", "LVT"))}
INCB = {"None": 0, "Consonant": 1, "Extend": 2, "Linker": 3}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(data_root=ROOT / "THIRD_PARTY/unicode"):
    manifest = json.loads((data_root / "manifest.json").read_text())
    if manifest["version"] != VERSION:
        raise ValueError("Unicode version must be " + VERSION)
    expected = {VERSION + "/" + name for name in FILES}
    paths = [item["path"] for item in manifest["files"]]
    if set(paths) != expected or len(paths) != len(expected):
        raise ValueError("manifest must list each required Unicode input exactly once")
    for item in manifest["files"]:
        if item["source"] != "https://www.unicode.org/Public/" + item["path"].replace(VERSION + "/", VERSION + "/ucd/", 1):
            raise ValueError("unexpected Unicode source: " + item["path"])
        if sha256(data_root / item["path"]) != item["sha256"]:
            raise ValueError("Unicode input hash mismatch: " + item["path"])
    license_path = data_root.parent / "unicode-LICENSE"
    if manifest["license_file"] != "THIRD_PARTY/unicode-LICENSE" or sha256(license_path) != manifest["license_sha256"]:
        raise ValueError("Unicode license hash mismatch")
    return manifest


def records(path):
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if line:
            yield number, [field.strip() for field in line.split(";")]


def span(field):
    ends = field.split("..")
    lo, hi = int(ends[0], 16), int(ends[-1], 16)
    if len(ends) > 2 or not 0 <= lo <= hi < LIMIT:
        raise ValueError("invalid Unicode range: " + field)
    return range(lo, hi + 1)


def categories(path):
    result = bytearray(LIMIT)
    # Only categories affecting width need to be retained.
    codes = {"Mn": 1, "Me": 1, "Cf": 1, "Mc": 2}
    pending = None
    for number, fields in records(path):
        cp = int(fields[0], 16)
        if not 0 <= cp < LIMIT:
            raise ValueError("UnicodeData scalar out of range")
        name, category = fields[1:3]
        value = codes.get(category, 0)
        if name.endswith(", First>"):
            if pending is not None:
                raise ValueError("nested UnicodeData First")
            pending = (cp, category, name[:-8])
        elif name.endswith(", Last>"):
            if pending is None or pending[1:] != (category, name[:-7]) or pending[0] > cp:
                raise ValueError("unmatched UnicodeData Last on line " + str(number))
            result[pending[0]:cp + 1] = bytes([value]) * (cp - pending[0] + 1)
            pending = None
        else:
            if pending is not None:
                raise ValueError("missing UnicodeData Last")
            result[cp] = value
    if pending is not None:
        raise ValueError("missing UnicodeData Last")
    return result


def properties(data_root):
    root = data_root / VERSION
    cat = categories(root / "UnicodeData.txt")
    gcb, incb, emoji = bytearray(LIMIT), bytearray(LIMIT), bytearray(LIMIT)
    wide, vs_base = bytearray(LIMIT), bytearray(LIMIT)
    for _, fields in records(root / "EastAsianWidth.txt"):
        if fields[1] in ("W", "F"):
            for cp in span(fields[0]):
                wide[cp] = 1
    for _, fields in records(root / "auxiliary/GraphemeBreakProperty.txt"):
        value = GCB[fields[1]]
        for cp in span(fields[0]):
            gcb[cp] = value
    for _, fields in records(root / "DerivedCoreProperties.txt"):
        if fields[1] == "InCB":
            value = INCB[fields[2]]
            for cp in span(fields[0]):
                incb[cp] = value
    for _, fields in records(root / "emoji/emoji-data.txt"):
        bit = {"Extended_Pictographic": 1, "Emoji_Presentation": 2}.get(fields[1], 0)
        if bit:
            for cp in span(fields[0]):
                emoji[cp] |= bit
    for _, fields in records(root / "emoji/emoji-variation-sequences.txt"):
        cps = [int(v, 16) for v in fields[0].split()]
        if len(cps) != 2 or cps[1] not in (0xFE0E, 0xFE0F) or not 0 <= cps[0] < LIMIT:
            raise ValueError("invalid emoji variation sequence")
        vs_base[cps[0]] = 1
    result = array("H")
    cluster_zero_classes = {GCB[name] for name in ("Extend", "ZWJ", "SpacingMark", "V", "T")}
    for cp in range(LIMIT):
        zero = (cat[cp] == 1 and cp != 0xAD) or 0x1160 <= cp < 0x1200 or cp < 0x20 or 0x7F <= cp < 0xA0
        width = 0 if zero else 2 if wide[cp] or emoji[cp] & 2 else 1
        # Invalid scalars are printable replacement cells, not table lookups.
        if 0xD800 <= cp <= 0xDFFF:
            width = 1
        zero_in_cluster = zero or cat[cp] == 2 or gcb[cp] in cluster_zero_classes
        value = width | gcb[cp] << 2 | incb[cp] << 6 | emoji[cp] << 8 | vs_base[cp] << 10 | int(zero_in_cluster) << 11
        result.append(value)
    return result


def generate(data_root=ROOT / "THIRD_PARTY/unicode"):
    verify(data_root)
    values = properties(data_root)
    page_map, pages, index = {}, [], []
    for start in range(0, LIMIT, 256):
        page = tuple(values[start:start + 256])
        if page not in page_map:
            page_map[page] = len(pages)
            pages.append(page)
        index.append(page_map[page])
    if len(pages) > 65536:
        raise ValueError("page index exceeds uint16_t")
    # Verify the compressed lookup exhaustively before writing any output.
    for cp, expected in enumerate(values):
        if pages[index[cp >> 8]][cp & 255] != expected:
            raise ValueError("table reconstruction mismatch")
    out = ["/* Generated by tools/genwidth.py; do not edit.",
           " * Unicode " + VERSION + "; Copyright Unicode, Inc.",
           " * SPDX-License-Identifier: Unicode-3.0; see THIRD_PARTY/unicode-LICENSE.",
           " * Inputs and SHA-256 hashes: THIRD_PARTY/unicode/manifest.json.",
           " * " + str(len(pages)) + " unique 256-scalar pages; " + str(2 * (len(index) + 256 * len(pages))) + " table bytes.",
           " */", "#ifndef BOGGART_BUNICODE_DATA_H", "#define BOGGART_BUNICODE_DATA_H", "#include <stdint.h>",
           "/* Manifest SHA-256: " + sha256(data_root / "manifest.json") + " */",
           "static const uint16_t bunicode_page_index[] = {"]
    for start in range(0, len(index), 16):
        out.append("  " + ", ".join(str(v) for v in index[start:start + 16]) + ",")
    out += ["};", "static const uint16_t bunicode_pages[][256] = {"]
    for page in pages:
        out.append("  {")
        for start in range(0, 256, 16):
            out.append("    " + ", ".join("0x%03x" % v for v in page[start:start + 16]) + ",")
        out.append("  },")
    out += ["};", "#endif", ""]
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "src/bunicode_data.h")
    parser.add_argument("--data-dir", type=Path, default=ROOT / "THIRD_PARTY/unicode")
    args = parser.parse_args()
    try:
        output = generate(args.data_dir)
        if args.check:
            if not args.output.exists() or args.output.read_text() != output:
                raise ValueError("stale generated Unicode table: " + str(args.output))
            print("Unicode " + VERSION + " inputs, license, and generated table verified")
        else:
            args.output.write_text(output)
            print("Generated " + str(args.output))
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
