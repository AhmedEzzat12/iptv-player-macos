"""Android parity backlog: Apple commits since android/PARITY_BASE that still need something on Android.

Run through scripts/android-backlog.sh. Spec: docs/superpowers/specs/google-tv/E-parity-tooling.md.
Reads only git history, scripts/parity-paths.txt and android/parity-tags.txt. Standard library only.
"""

from __future__ import annotations  # macOS's /usr/bin/python3 is 3.9

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

TRAILER = re.compile(r"^Android: (ported|todo|deferred|n/a)(?: (.+))?$")
PORTS = re.compile(r"^Ports: (.+)$")
PORTS_SKIPPED = re.compile(r"^Ports-skipped: ([0-9a-fA-F]{7,40})(?: .*)?$")


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def resolve(sha: str) -> str | None:
    result = subprocess.run(["git", "rev-parse", "-q", "--verify", sha + "^{commit}"], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [l.strip() for l in path.read_text().splitlines() if l.strip() and not l.lstrip().startswith("#")]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--all", action="store_true", help="also list deferred and Apple-only commits")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--since", help="start after this commit instead of android/PARITY_BASE")
    ap.add_argument("--check", action="store_true", help="exit 1 when anything is untagged or still to port")
    args = ap.parse_args()

    root = Path(git("rev-parse", "--show-toplevel").strip())
    base_file = root / "android" / "PARITY_BASE"
    base = args.since or (base_file.read_text().strip() if base_file.exists() else "")
    if not base:
        print("android/PARITY_BASE is missing (pass --since <sha>).", file=sys.stderr)
        return 2
    prefixes = read_lines(root / "scripts" / "parity-paths.txt")
    tags: dict[str, tuple[str, str]] = {}
    for line in read_lines(root / "android" / "parity-tags.txt"):
        parts = line.split(maxsplit=2)
        if len(parts) >= 2 and parts[1] in ("todo", "deferred", "n/a"):
            full = resolve(parts[0])
            if full:
                tags[full] = (parts[1], parts[2] if len(parts) > 2 else "")

    shas = git("rev-list", "--reverse", "--no-merges", f"{base}..HEAD").split()
    now = time.time()
    commits = []
    done: set[str] = set()
    for sha in shas:
        subject, timestamp, body = git("log", "-1", "--format=%s%x00%ct%x00%B", sha).split("\x00", 2)
        files = git("diff-tree", "--no-commit-id", "--name-only", "-r", sha).split("\n")
        trailer = None
        for line in body.splitlines():
            if m := TRAILER.match(line.strip()):
                trailer = (m.group(1), m.group(2) or "")
            elif m := PORTS.match(line.strip()):
                for part in m.group(1).replace(",", " ").split():
                    if full := resolve(part):
                        done.add(full)
            elif m := PORTS_SKIPPED.match(line.strip()):
                if full := resolve(m.group(1)):
                    done.add(full)
        tagged_path = any(f.startswith(p) for f in files if f for p in prefixes)
        commits.append({"sha": sha, "subject": subject, "time": int(timestamp), "trailer": trailer,
                        "tagged": tagged_path})

    groups: dict[str, list[dict]] = {"untagged": [], "toPort": [], "deferred": [], "na": []}
    for c in commits:
        if not c["tagged"]:
            continue
        kind, text = c["trailer"] or tags.get(c["sha"]) or (None, "")
        if c["trailer"] and c["sha"] in tags:
            print(f"warning: {c['sha'][:7]} has a trailer and a parity-tags.txt line; using the trailer",
                  file=sys.stderr)
        entry = {"sha": c["sha"], "shortSha": c["sha"][:7], "ageDays": int((now - c["time"]) // 86400),
                 "subject": c["subject"], "trailer": kind, "text": text}
        if kind is None:
            groups["untagged"].append(entry)
        elif kind == "todo" and c["sha"] not in done:
            groups["toPort"].append(entry)
        elif kind == "deferred":
            groups["deferred"].append(entry)
        elif kind == "n/a":
            groups["na"].append(entry)

    open_items = groups["untagged"] + groups["toPort"]
    summary = {"toPort": len(groups["toPort"]), "untagged": len(groups["untagged"]),
               "oldestDays": max((e["ageDays"] for e in open_items), default=0)}

    if args.json:
        print(json.dumps({**groups, "summary": summary}, indent=2, ensure_ascii=False))
    else:
        def section(title: str, items: list[dict]) -> None:
            if not items:
                return
            print(f"{title} ({len(items)}):")
            for e in items:
                note = f"{e['trailer']}: {e['text']} — " if e["trailer"] else ""
                print(f"  {e['shortSha']}  {e['ageDays']:>3}d  {note}{e['subject']}")
        section("Untagged", groups["untagged"])
        section("To port", groups["toPort"])
        if args.all:
            section("Deferred", sorted(groups["deferred"], key=lambda e: e["text"]))
            section("Apple-only", groups["na"])
        print(f"Summary: {summary['toPort']} to port, {summary['untagged']} untagged, "
              f"oldest {summary['oldestDays']} days.")

    return 1 if args.check and open_items else 0


if __name__ == "__main__":
    sys.exit(main())
