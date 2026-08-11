#!/usr/bin/env python3
"""Generate src/utf8width.h's range tables from the Unicode Character Database.

Run from the repo root, with the four UCD files in one directory:

    curl -O https://www.unicode.org/Public/16.0.0/ucd/EastAsianWidth.txt
    curl -O https://www.unicode.org/Public/16.0.0/ucd/DerivedCoreProperties.txt
    curl -O https://www.unicode.org/Public/16.0.0/ucd/UnicodeData.txt
    curl -O https://www.unicode.org/Public/16.0.0/ucd/emoji/emoji-data.txt
    python3 tools/genwidth.py <dir-with-those-files> > /tmp/tables.h

...and paste the two tables into src/utf8width.h. Kept as a script rather than
a build step because the UCD is a network fetch and a version decision, and
neither belongs in a build that has to work from a bare checkout offline.

The classification is Markus Kuhn's wcwidth() rules brought up to date:
zero-width is combining-and-invisible, double-width is East Asian Wide or
Fullwidth plus anything with default emoji presentation, everything else is
one. See the comment in src/utf8width.h for what that does and does not buy.
"""
import sys, os, collections


def ranges(path, pred):
    """Codepoints in a UCD file whose (start, end, fields) satisfy pred."""
    out = set()
    with open(path, encoding="utf-8") as fp:
        for line in fp:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            fields = [f.strip() for f in line.split(";")]
            cps = fields[0]
            if ".." in cps:
                a, b = cps.split("..")
            else:
                a = b = cps
            a, b = int(a, 16), int(b, 16)
            if pred(fields):
                out.update(range(a, b + 1))
    return out


def unicodedata_categories(path):
    """cp -> general category, expanding UnicodeData.txt's First/Last pairs."""
    cat = {}
    pending = None
    with open(path, encoding="utf-8") as fp:
        for line in fp:
            f = line.split(";")
            if len(f) < 3:
                continue
            cp, name, gc = int(f[0], 16), f[1], f[2]
            if name.endswith(", First>"):
                pending = (cp, gc)
                continue
            if name.endswith(", Last>") and pending:
                for c in range(pending[0], cp + 1):
                    cat[c] = pending[1]
                pending = None
                continue
            cat[cp] = gc
    return cat


def compress(cps):
    """A sorted set of codepoints as a list of inclusive (lo, hi) ranges."""
    out = []
    for cp in sorted(cps):
        if out and cp == out[-1][1] + 1:
            out[-1][1] = cp
        else:
            out.append([cp, cp])
    return [tuple(r) for r in out]


def emit(name, rs):
    print("static const struct { uint32_t lo, hi; } %s[] = {" % name)
    for i in range(0, len(rs), 4):
        row = "  " + " ".join("{0x%05X,0x%05X}," % r for r in rs[i:i + 4])
        print(row)
    print("};")
    print("/* %d ranges */" % len(rs))


def main(d):
    eaw = os.path.join(d, "EastAsianWidth.txt")
    dcp = os.path.join(d, "DerivedCoreProperties.txt")
    ud = os.path.join(d, "UnicodeData.txt")
    emo = os.path.join(d, "emoji-data.txt")

    cat = unicodedata_categories(ud)

    # ---- zero width --------------------------------------------------------
    # Nonspacing and enclosing marks stack on the character before them, so they
    # take no column of their own. Format characters (ZWJ, the bidi controls,
    # the variation selectors' cousins) are invisible. U+00AD is the exception
    # every wcwidth makes: a soft hyphen is Cf but prints as a hyphen when a
    # line breaks there, and terminals show it.
    zero = {cp for cp, gc in cat.items() if gc in ("Mn", "Me", "Cf")}
    zero.discard(0x00AD)
    # Hangul Jamo medial vowels and final consonants compose onto the leading
    # consonant before them. Category Lo, so the rule above misses them.
    zero.update(range(0x1160, 0x1200))
    # C0/C1. A control has no printed width; callers that care about \t and \n
    # handle them before asking.
    zero.update(range(0x0000, 0x0020))
    zero.update(range(0x007F, 0x00A0))

    # ---- double width ------------------------------------------------------
    wide = ranges(eaw, lambda f: f[1] in ("W", "F"))
    # Emoji whose default presentation is the colour one are drawn two cells
    # wide by every terminal, and a few of them are still EAW=Neutral because
    # East Asian Width predates them.
    wide |= ranges(emo, lambda f: f[1] == "Emoji_Presentation")
    wide -= zero

    emit("UTF8W_ZERO", compress(zero))
    print()
    emit("UTF8W_WIDE", compress(wide))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
