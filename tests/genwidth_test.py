"""Generator validation; no downloads and no third-party Python packages."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("genwidth", ROOT / "tools/genwidth.py")
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)


class GeneratorTests(unittest.TestCase):
    def test_pinned_output(self):
        self.assertEqual(gen.generate(), (ROOT / "src/bunicode_data.h").read_text())

    def test_ranges_reject_invalid_data(self):
        self.assertEqual(list(gen.span("0010..0012")), [16, 17, 18])
        self.assertEqual(list(gen.span("10FFFF")), [0x10FFFF])
        for value in ("110000", "FFFF..0000", "-1", "0..1..2"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                gen.span(value)

    def test_unmatched_category_ranges(self):
        def row(cp, name, category):
            return f"{cp};{name};{category};0;L;;;;;N;;;;;\n"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "UnicodeData.txt"
            path.write_text(row("3400", "<Ideograph, First>", "Mn") + row("3402", "<Ideograph, Last>", "Mn"))
            self.assertEqual(gen.categories(path)[0x3400:0x3404], bytearray([1, 1, 1, 0]))
            for text in (row("3400", "<Ideograph, First>", "Mn"),
                         row("3402", "<Ideograph, Last>", "Mn"),
                         row("3400", "<Ideograph, First>", "Mn") + row("3402", "<Other, Last>", "Mn")):
                path.write_text(text)
                with self.assertRaises(ValueError):
                    gen.categories(path)

    def test_manifest_rejects_omissions_duplicates_and_wrong_sources(self):
        original = json.loads((ROOT / "THIRD_PARTY/unicode/manifest.json").read_text())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for mutation in ("missing", "duplicate", "source", "version"):
                manifest = json.loads(json.dumps(original))
                if mutation == "missing": manifest["files"].pop()
                if mutation == "duplicate": manifest["files"].append(manifest["files"][0])
                if mutation == "source": manifest["files"][0]["source"] = "https://example.com/other.txt"
                if mutation == "version": manifest["version"] = "17.0.0"
                (root / "manifest.json").write_text(json.dumps(manifest))
                with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                    gen.verify(root)
            # Keep valid sources but corrupt the first file. The generator
            # must detect drift before trying to classify any input.
            (root / "manifest.json").write_text(json.dumps(original))
            first = root / original["files"][0]["path"]
            first.parent.mkdir(parents=True); first.write_text("modified data\n")
            with self.assertRaisesRegex(ValueError, "input hash mismatch"):
                gen.verify(root)


if __name__ == "__main__":
    unittest.main()
