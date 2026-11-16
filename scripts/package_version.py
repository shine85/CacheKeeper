"""Read the sole package version source; only a safe literal may reach compiler flags."""
from pathlib import Path
import re
import sys


def package_version(control: Path) -> str:
    versions = re.findall(r"^Version: ([^\r\n]+)$", control.read_text(encoding="utf-8"), re.M)
    if len(versions) != 1 or len(versions[0]) > 48 or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9]+\.[0-9]+)?", versions[0]):
        raise ValueError("control must contain one valid CacheKeeper package version")
    return versions[0]


if __name__ == "__main__":
    try:
        print(package_version(Path(__file__).resolve().parents[1] / "control"))
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
