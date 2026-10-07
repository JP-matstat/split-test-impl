#!/usr/bin/env python3
"""Count the test functions in a materialized frozen suite.

Used by sti.sh to know how many tests a slice is supposed to contribute, so
`check` can tell "the slice's tests ran" apart from "the slice was hidden by a
conftest or a module-level skip". Prints a single integer.
"""

from __future__ import annotations

import ast
import sys
from pathlib import Path


def count(path: Path) -> int:
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"))
    except (SyntaxError, UnicodeDecodeError):
        return 0
    return sum(
        1
        for n in ast.walk(tree)
        if isinstance(n, ast.FunctionDef | ast.AsyncFunctionDef) and n.name.startswith("test")
    )


def main(argv: list[str]) -> int:
    root = Path(argv[1])
    files = argv[2:]
    if not files:
        print("usage: count.py <materialized-root> <file> ...", file=sys.stderr)
        return 2
    total = 0
    for name in files:
        p = root / name
        if p.is_file():
            total += count(p)
    print(total)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
