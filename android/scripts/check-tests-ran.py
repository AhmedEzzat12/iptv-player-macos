"""Fails when a Kotlin @Test method didn't run. JUnit silently skips test methods that return a value (for example a
`= runBlocking { … }` body ending in assertNotNull), so every @Test written must appear in the results.
Usage: python3 -I android/scripts/check-tests-ran.py <module dir>…"""

import glob
import re
import sys
from pathlib import Path

missing_total = 0
for module in sys.argv[1:]:
    written: dict[str, set[str]] = {}
    for f in glob.glob(f"{module}/src/test/**/*.kt", recursive=True):
        cls = None
        for line in Path(f).read_text().splitlines():
            if m := re.match(r"\s*(?:internal |private )?class (\w+)", line):
                cls = m.group(1)
            if (m := re.search(r"@Test fun (\w+)", line)) and cls:
                written.setdefault(cls, set()).add(m.group(1))
    ran: dict[str, set[str]] = {}
    for f in glob.glob(f"{module}/build/test-results/**/*.xml", recursive=True):
        s = Path(f).read_text()
        if m := re.search(r'testsuite name="[\w.$]*?\.?(\w+)"', s):
            ran.setdefault(m.group(1), set()).update(n.split("(")[0] for n in re.findall(r'testcase name="([^"]+)"', s))
    for cls, names in sorted(written.items()):
        for name in sorted(names - ran.get(cls, set())):
            print(f"{module}: {cls}.{name} did not run (does it return a value? end the body with Unit)", file=sys.stderr)
            missing_total += 1
sys.exit(1 if missing_total else 0)
