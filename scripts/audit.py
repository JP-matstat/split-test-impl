#!/usr/bin/env python3
"""Audit the frozen test suite against the spec.

Gate for the split-test-impl workflow. Checks, in both directions:

  * every test function cites the spec requirement it verifies (`# spec: R3`)
  * every cited requirement exists in the spec
  * every requirement in the spec is covered by at least one test
  * no test reaches into private names (black-box only)

Exits 0 when the mapping is complete, 1 otherwise.
"""

from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

REQ_HEADING = re.compile(r"^#+\s*R(\d+)\b", re.M)
MARKER = re.compile(r"#\s*spec:\s*(.*)$")
ID = re.compile(r"R(\d+)")
TEST_PATH = re.compile(
    r"(^|/)(tests?/.*|test_[^/]*\.py|[^/]*_test\.py|conftest\.py)$"
)


def is_test_path(name: str) -> bool:
    return bool(TEST_PATH.match(name))


def requirement_headings_missing(spec: Path) -> list[str]:
    """`## Requirements` is where R-numbered headings live; without it the
    audit silently checks nothing and the spec reads as unversioned prose."""
    return [] if re.search(r"^#+\s*Requirements\b", spec.read_text(encoding="utf-8"), re.M) else [
        "has no '## Requirements' section — R-numbered headings live there"
    ]


def spec_requirements(spec: Path) -> set[str]:
    return {f"R{n}" for n in REQ_HEADING.findall(spec.read_text(encoding="utf-8"))}


def marker_text(node: ast.FunctionDef | ast.AsyncFunctionDef, source: str) -> str:
    """The `# spec:` marker may live in the docstring or in the comment block above."""
    parts: list[str] = []
    if ast.get_docstring(node):
        parts.append(ast.get_docstring(node) or "")
    start = node.decorator_list[0].lineno - 1 if node.decorator_list else node.lineno - 1
    line = start - 1
    while line >= 0 and source.splitlines()[line].lstrip().startswith("#"):
        parts.append(source.splitlines()[line])
        line -= 1
    return "\n".join(parts)


def test_functions(
    path: Path, source: str | None = None
) -> list[ast.FunctionDef | ast.AsyncFunctionDef]:
    try:
        tree = ast.parse(source if source is not None else path.read_text(encoding="utf-8"))
    except SyntaxError as exc:
        print(f"  ERROR {path}: syntax error: {exc}")
        return []
    return [
        n
        for n in ast.walk(tree)
        if isinstance(n, ast.FunctionDef | ast.AsyncFunctionDef) and n.name.startswith("test")
    ]


def private_imports(path: Path, source: str | None = None) -> list[str]:
    try:
        tree = ast.parse(source if source is not None else path.read_text(encoding="utf-8"))
    except SyntaxError:
        return []  # already reported by test_functions()
    hits: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and (node.level or 0) > 0:
            hits.append(f"{path}:{node.lineno} relative import {node.module or ''}")
            continue
        if not isinstance(node, ast.ImportFrom):
            continue
        for alias in node.names:
            if alias.name.startswith("_"):
                hits.append(f"{path}:{node.lineno} imports private name {alias.name}")
    return hits


def skips_whole_module(path: Path) -> bool:
    """True if the module never executes: `pytest.skip(allow_module_level=True)`
    or a module-level `pytestmark` skip. Such a file contributes tests to the
    frozen commit that can never fail, so it verifies nothing."""
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"))
    except SyntaxError:
        return False
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            func = node.func
            name = getattr(func, "attr", getattr(func, "id", ""))
            if name == "skip" and any(
                kw.arg == "allow_module_level" and ast.literal_eval(kw.value) is True
                for kw in node.keywords
                if isinstance(kw.value, ast.Constant)
            ):
                return True
        if isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            value = node.value
            for t in targets:
                if isinstance(t, ast.Name) and t.id == "pytestmark" and isinstance(value, ast.Call):
                    if "skip" in ast.dump(value.func):
                        return True
    return False


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("usage: audit.py <spec> <materialized-root> [changed-file ...]")
        return 2
    spec_path, root = Path(argv[1]), Path(argv[2])
    changed = [a for a in argv[3:] if a]
    test_files = [Path(f) for f in changed if f.endswith(".py") and is_test_path(f)]

    errors: list[str] = []
    warnings: list[str] = []

    requirements = spec_requirements(spec_path)
    if not requirements:
        errors.append(
            f"{spec_path}: no requirement headings found. "
            "Each one must look like '### R1 - <behavior>'"
        )
    for problem in requirement_headings_missing(spec_path):
        errors.append(f"{spec_path}: {problem}")

    if not test_files:
        errors.append("the frozen commit adds no test files")
        return report(errors, warnings)

    covered: set[str] = set()
    for test_file in test_files:
        source = (root / test_file).read_text(encoding="utf-8", errors="replace")
        functions = test_functions(root / test_file, source)
        if not functions:
            warnings.append(f"{test_file}: contains no test functions")
        if functions and skips_whole_module(root / test_file):
            errors.append(
                f"{test_file}: skips at module level, so none of its {len(functions)} "
                "test(s) can ever fail — it verifies nothing"
            )
        for fn in functions:
            text = marker_text(fn, source)
            matches = MARKER.findall(text)
            if not matches:
                errors.append(
                    f"{test_file}:{fn.lineno} {fn.name} has no '# spec:' marker "
                    "- say which requirement it verifies"
                )
                continue
            for payload in matches:
                payload = payload.strip()
                if payload.upper().startswith("SKIP"):
                    if len(payload) <= 4:
                        errors.append(
                            f"{test_file}:{fn.lineno} {fn.name} skips the spec mapping "
                            "without a reason"
                        )
                    continue
                ids = {f"R{n}" for n in ID.findall(payload)}
                if not ids:
                    errors.append(
                        f"{test_file}:{fn.lineno} {fn.name} marker '{payload}' names no requirement"
                    )
                    continue
                unknown = sorted(ids - requirements)
                if unknown:
                    errors.append(
                        f"{test_file}:{fn.lineno} {fn.name} cites unknown requirement(s) "
                        f"{', '.join(unknown)}"
                    )
                covered |= ids & requirements
        errors.extend(private_imports(root / test_file, source))

    for requirement in sorted(requirements - covered, key=lambda r: int(r[1:])):
        errors.append(f"{spec_path}: requirement {requirement} has no test")

    return report(errors, warnings)


def report(errors: list[str], warnings: list[str]) -> int:
    for warning in warnings:
        print(f"  WARN  {warning}")
    for error in errors:
        print(f"  ERROR {error}")
    print(f"audit: {len(errors)} error(s), {len(warnings)} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
