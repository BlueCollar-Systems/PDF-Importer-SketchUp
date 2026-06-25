#!/usr/bin/env python3
"""Fail on Ruby features that SketchUp 2017's Ruby 2.2 cannot support.

Modern Ruby can parse or execute code that SketchUp Make 2017 cannot. This
guard intentionally scans the shipped extension payload before packaging so a
release cannot include Ruby 2.3+ convenience APIs or Ruby 2.6+ syntax.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


INCOMPATIBLE_PATTERNS = [
    (re.compile(r"&\."), "safe navigation operator (&.) requires Ruby 2.3+"),
    (
        re.compile(
            r"(?<!\.)\.\s*(?:"
            r"positive\?|negative\?|dig|match\?|casecmp\?|"
            r"delete_prefix|delete_suffix|fetch_values|"
            r"sum|filter|filter_map|tally|transform_values|"
            r"then|yield_self|chunk_while"
            r")\s*(?:\(|\b)"
        ),
        "method is not available in Ruby 2.2",
    ),
    (re.compile(r"<<~"), "squiggly heredoc requires Ruby 2.3+"),
    (re.compile(r"\[[^\]\n]*\.\.\s*\]"), "endless range requires Ruby 2.6+"),
    (re.compile(r"\[\s*\.\.[^\]\n]*\]"), "beginless range requires Ruby 2.7+"),
    (re.compile(r"\bdef\b[^\n]*\.\.\."), "argument forwarding requires Ruby 2.7+"),
]


def _strip_strings_and_comments(line: str) -> str:
    """Remove quoted text and comments enough for source guardrails.

    This is intentionally conservative rather than a full Ruby lexer. It avoids
    flagging examples inside strings while keeping actual method calls visible.
    """
    output = []
    quote = None
    escape = False
    index = 0
    while index < len(line):
        char = line[index]
        if quote:
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == quote:
                quote = None
            index += 1
            continue

        if char in ("'", '"'):
            quote = char
            index += 1
            continue
        if char == "#":
            break
        output.append(char)
        index += 1
    return "".join(output)


def _iter_ruby_files(paths: list[Path]) -> list[Path]:
    files: list[Path] = []
    for path in paths:
        if path.is_file() and path.suffix == ".rb":
            files.append(path)
        elif path.is_dir():
            files.extend(sorted(path.rglob("*.rb")))
    return sorted(set(files))


def check(paths: list[Path]) -> list[str]:
    findings: list[str] = []
    for ruby_file in _iter_ruby_files(paths):
        try:
            text = ruby_file.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            findings.append(f"{ruby_file}:0: cannot read file: {exc}")
            continue

        for line_number, raw_line in enumerate(text.splitlines(), start=1):
            if "su2017-compat: ignore" in raw_line:
                continue
            scan_line = _strip_strings_and_comments(raw_line)
            if not scan_line.strip():
                continue
            for pattern, reason in INCOMPATIBLE_PATTERNS:
                if pattern.search(scan_line):
                    findings.append(
                        f"{ruby_file}:{line_number}: {reason}: {raw_line.strip()}"
                    )
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check SketchUp 2017 Ruby 2.2 compatibility."
    )
    parser.add_argument(
        "paths",
        nargs="+",
        type=Path,
        help="Ruby file or directory paths to scan.",
    )
    args = parser.parse_args()

    findings = check(args.paths)
    if not findings:
        print("SketchUp 2017 Ruby compatibility: PASS")
        return 0

    print("SketchUp 2017 Ruby compatibility: FAIL", file=sys.stderr)
    for finding in findings:
        print(f"  {finding}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
