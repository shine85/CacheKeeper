"""The compiler version argument must come from one control field and remain a literal."""
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from package_version import package_version


class PackageVersionTests(unittest.TestCase):
    def test_compiler_literal_boundary(self):
        (ROOT / "tmp").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="package-version-", dir=ROOT / "tmp") as temporary:
            control = Path(temporary) / "control"
            for version in ("0.7.2", "0.7.2-154.1"):
                with self.subTest(version=version):
                    control.write_bytes(f"Package: dev.local.cachekeeper\r\nVersion: {version}\r\n".encode())
                    self.assertEqual(package_version(control), version)
            invalid = ("", "Version: 0.7.2\nVersion: 0.7.3\n", "Version: 0.7.2 ",
                       'Version: 0.7.2\" -DOTHER=1', "Version: $(exit 1)",
                       "Version: `exit 1`", "Version: 0.7.2;exit 1", "Version: ０.７.２",
                       "Version: 0.7.2-", "Version: " + "1" * 49 + ".1.1")
            for value in invalid:
                with self.subTest(control=value):
                    control.write_text(value, encoding="utf-8")
                    with self.assertRaises(ValueError):
                        package_version(control)


if __name__ == "__main__":
    unittest.main()
