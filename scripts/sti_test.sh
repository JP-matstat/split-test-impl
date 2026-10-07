#!/usr/bin/env bash
# End-to-end test of sti.sh. Runs a whole slice in throwaway repos and asserts
# on what each command accepts and refuses.
#
#   scripts/sti_test.sh
#
# Deliberately repo-agnostic: it builds miniature git repos under $TMPDIR and
# touches nothing outside them. Run it as the user who owns the repo you are
# testing against, so file ownership stays consistent.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STI="$HERE/sti.sh"
AUDIT="$HERE/audit.py"
ROOT="${STI_TEST_TMPDIR:-${TMPDIR:-/tmp}/sti-selftest}"
PASS=0
FAIL=0

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ok() { PASS=$((PASS + 1)); grn "  ok   $*"; }
no() { FAIL=$((FAIL + 1)); red "  FAIL $*"; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3', got '$2')"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (missing '$3' in: $2)" ;; esac; }
hasnt() { case "$2" in *"$3"*) no "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }

# Builds a miniature repo: $1 = dir. Sets BASE_SHA.
mkrepo() {
  local d="$1"
  rm -rf "$d"
  mkdir -p "$d/specs" "$d/demo" "$d/tests"
  # Deliberately NOT a copy of this skill: the fixture must not contain the test
  # names and markers it later asserts are absent from the implementation repo.
  : >"$d/demo/__init__.py"
  cat >"$d/pyproject.toml" <<'EOF'
[tool.pytest.ini_options]
testpaths = ["tests"]
python_files = ["test_*.py"]
EOF
  cat >"$d/demo/money.py" <<'PY'
def total(prices: list[int]) -> int:
    return sum(prices)
PY
  cat >"$d/tests/test_seed.py" <<'PY'
def test_seed():
    assert True
PY
  specs_standard "$d"
  git -C "$d" init -q -b main .
  git -C "$d" config user.email t@t
  git -C "$d" config user.name t
  git -C "$d" add -A
  git -C "$d" commit -qm base
  BASE_SHA="$(git -C "$d" rev-parse HEAD)"
}

specs_standard() {
  cat >"$1/specs/basket.md" <<'MD'
# Basket

## Public contract

`demo/basket.py`

- `line_total(unit_price: int, qty: int) -> int`
- `basket_total(lines: list[tuple[int, int]]) -> int`

## Requirements

### R1 - line_total multiplies unit price by quantity
### R2 - basket_total sums the line totals
### R3 - basket_total of an empty list is 0
MD
}

# Writes a good suite into a slice's vault and commits it.
good_suite() {
  local slice="$1" dir="$2"
  mkdir -p "$dir/tests/basket"
  cat >"$dir/tests/basket/test_basket.py" <<'PY'
from demo.basket import basket_total, line_total


# spec: R1
def test_line_total_multiplies_price_by_qty():
    assert line_total(10, 3) == 30


# spec: R2
def test_basket_total_sums_lines():
    assert basket_total([(10, 3), (5, 2)]) == 40


# spec: R3
def test_empty_basket_is_zero():
    assert basket_total([]) == 0
PY
  git -C "$dir" add -A
  git -C "$dir" -c user.email=t@t -c user.name=t commit -qm "test: basket suite"
}

# Writes the reference implementation into the impl worktree.
good_impl() {
  local dir="$1"
  cat >"$dir/demo/basket.py" <<'PY'
def line_total(unit_price: int, qty: int) -> int:
    return unit_price * qty


def basket_total(lines: list[tuple[int, int]]) -> int:
    return sum(line_total(p, q) for p, q in lines)
PY
}

# sti <repo> <worktree-root> <args...>
# Sets $out (combined stdout+stderr) and $RC. Never call these in a command
# substitution: that would run them in a subshell and lose both variables.
out=""
RC=0
sti() {
  local repo="$1" wtr="$2"; shift 2
  out="$(cd "$repo" && STI_WORKTREE_ROOT="$wtr" "$STI" "$@" 2>&1)"
  RC=$?
}
stic() { sti "$@"; }

section() { printf '\n== %s\n' "$*"; }

rm -rf "$ROOT"
mkdir -p "$ROOT"

###############################################################################
section "audit.py: the mapping gate"
###############################################################################

A="$ROOT/audit"
mkdir -p "$A/tests"
printf '# S\n\n## Public contract\n\nx\n\n## Requirements\n\n### R1 - a\n### R2 - b\n' >"$A/spec.md"
cat >"$A/tests/test_good.py" <<'PY'
# spec: R1
def test_a():
    assert True


# spec: R2
def test_b():
    assert True
PY
out="$(python3 "$AUDIT" "$A/spec.md" "$A" tests/test_good.py 2>&1)"
has "clean suite passes" "$out" "0 error(s)"

cat >"$A/tests/test_nomarker.py" <<'PY'
def test_c():
    assert True
PY
out="$(python3 "$AUDIT" "$A/spec.md" "$A" tests/test_nomarker.py 2>&1)"
has "test without a marker is an error" "$out" "has no '# spec:' marker"

cat >"$A/tests/test_unknown.py" <<'PY'
# spec: R9
def test_d():
    assert True
PY
out="$(python3 "$AUDIT" "$A/spec.md" "$A" tests/test_unknown.py 2>&1)"
has "cites a requirement that does not exist" "$out" "cites unknown requirement(s) R9"
has "uncovered requirement is an error" "$out" "requirement R1 has no test"

cat >"$A/tests/test_private.py" <<'PY'
from demo.basket import _secret


# spec: R1
def test_p():
    assert True


# spec: R2
def test_q():
    assert True
PY
out="$(python3 "$AUDIT" "$A/spec.md" "$A" tests/test_private.py 2>&1)"
has "private import is an error" "$out" "imports private name _secret"

cat >"$A/tests/test_skipped.py" <<'PY'
import pytest


# spec: R1
@pytest.mark.skip(reason="later")
def test_s():
    assert True


# spec: R2
@pytest.mark.skip(reason="later")
def test_t():
    assert True
PY
out="$(python3 "$AUDIT" "$A/spec.md" "$A" tests/test_skipped.py 2>&1)"
hasnt "decorated skip is NOT rejected (real skips exist in this repo)" "$out" "verifies nothing"

cat >"$A/tests/test_modskip.py" <<'PY'
import pytest

pytest.skip("nothing to test yet", allow_module_level=True)


# spec: R1
def test_u():
    assert True


# spec: R2
def test_v():
    assert True
PY
out="$(python3 "$AUDIT" "$A/spec.md" "$A" tests/test_modskip.py 2>&1)"
has "module-level skip is rejected" "$out" "verifies nothing"

cat >"$A/tests/test_docstring.py" <<'PY'
def test_w():
    """# spec: R1"""
    assert True


# spec: R2
def test_x():
    assert True
PY
out="$(python3 "$AUDIT" "$A/spec.md" "$A" tests/test_docstring.py 2>&1)"
has "marker in a docstring counts" "$out" "0 error(s)"

printf '# S\n\n## Public contract\n\nx\n\n### R1 - a\n### R2 - b\n' >"$A/nohdr.md"
out="$(python3 "$AUDIT" "$A/nohdr.md" "$A" tests/test_good.py 2>&1)"
has "spec without a Requirements section is an error" "$out" "no '## Requirements' section"

printf 'def test_broken(:\n' >"$A/tests/test_broken.py"
out="$(python3 "$AUDIT" "$A/spec.md" "$A" tests/test_broken.py 2>&1)"
hasnt "syntax error does not crash the audit" "$out" "Traceback"

cat >"$A/tests/sub_test_alt.py" <<'PY'
# spec: R1
def test_y():
    assert True


# spec: R2
def test_z():
    assert True
PY
out="$(python3 "$AUDIT" "$A/spec.md" "$A" tests/sub_test_alt.py 2>&1)"
has "*_test.py naming is audited too" "$out" "0 error(s)"

###############################################################################
section "happy path: open -> freeze -> audit -> impl -> check -> finish"
###############################################################################

REPO="$ROOT/happy"
WT="$ROOT/wt-happy"
mkrepo "$REPO" >/dev/null

stic "$REPO" "$WT" open basket specs/basket.md; rc=$RC
is "open succeeds" "$rc" 0
has "open names the vault" "$out" "test vault"
[ -d "$WT/impl" ] && ok "open creates the impl parent" || no "open creates the impl parent"
hasnt "main repo has no tests branch" "$(git -C "$REPO" branch --list 'tests/*')" "tests/basket"

stic "$REPO" "$WT" check basket; rc=$RC
has "check before freeze is refused" "$out" "is not frozen yet"
stic "$REPO" "$WT" check nosuchslice
has "check on an unknown slice is refused" "$out" "unknown slice"
stic "$REPO" "$WT" freeze basket; rc=$RC
has "freeze before tests exist is refused" "$out" "nothing to freeze"

good_suite basket "$(printf '%s/%s/tests' "$REPO/.git/sti" basket)"
stic "$REPO" "$WT" freeze basket; rc=$RC
is "freeze succeeds" "$rc" 0
has "freeze reports the test count" "$out" "3 test function(s)"
has "freeze pins the spec" "$out" "spec pinned"

stic "$REPO" "$WT" audit basket; rc=$RC
is "audit passes" "$rc" 0

stic "$REPO" "$WT" impl basket; rc=$RC
is "impl succeeds" "$rc" 0
has "impl explains the briefing" "$out" "no test suite exists"

# The blindness assertions, checked directly against the impl worktree.
IMPL="$WT/impl/basket"
FROZEN="$(grep tests_commit= "$REPO/.git/sti/basket.env" | cut -d= -f2-)"
if git -C "$IMPL" cat-file -e "$FROZEN^{commit}" 2>/dev/null; then
  no "frozen commit is absent from the impl repo"
else
  ok "frozen commit is absent from the impl repo"
fi
# The spec is in the base commit and both workers are meant to see it, so its
# identifiers prove nothing. What must not appear is test content: the marker
# comments and assertions exist only in the frozen suite. grep -c, not grep -q:
# under `set -o pipefail` a -q that exits early can SIGPIPE the git process and
# flip the pipeline's status depending on scheduling.
IMPL_LOG="$(git -C "$IMPL" log --all -p 2>/dev/null || true)"
if printf '%s' "$IMPL_LOG" | grep -c "# spec: R" | grep -qv '^0$'; then
  no "impl history contains no test markers"
else
  ok "impl history contains no test markers"
fi
if printf '%s' "$IMPL_LOG" | grep -c "test_line_total_multiplies" | grep -qv '^0$'; then
  no "impl history contains no test names"
else
  ok "impl history contains no test names"
fi
hasnt "impl repo lists no tests branch" "$(git -C "$IMPL" branch -a)" "tests/basket"
hasnt "main repo lists no tests branch" "$(git -C "$REPO" branch -a)" "tests/basket"
[ -e "$IMPL/tests/basket/test_basket.py" ] && no "test file not in impl worktree" || ok "test file not in impl worktree"

stic "$REPO" "$WT" check basket; rc=$RC
has "check without the implementation errors, not counts" "$out" "pytest exited 2"

good_impl "$IMPL"
stic "$REPO" "$WT" check basket; rc=$RC
is "check is green" "$rc" 0
has "check prints counts only" "$out" "passed=4 failed=0 errors=0 skipped=0 total=4"
hasnt "check leaks no test name" "$out" "test_line_total"
hasnt "check leaks no path" "$out" "test_basket.py"

stic "$REPO" "$WT" status basket; rc=$RC
has "status shows the vault" "$out" "vault"
has "status survives a half-open slice" "$out" "slice"

stic "$REPO" "$WT" finish basket; rc=$RC
has "finish refuses uncommitted work" "$out" "uncommitted changes"

git -C "$IMPL" add -A
git -C "$IMPL" -c user.email=t@t -c user.name=t commit -qm "feat: basket"
stic "$REPO" "$WT" finish basket; rc=$RC
is "finish succeeds" "$rc" 0
has "finish prints the fetch" "$out" "fetch '"
has "finish prints the merge" "$out" "merge --no-ff tests/basket"
has "finish restates the epistemics" "$out" "It did not prove the spec is right."

stic "$REPO" "$WT" reveal basket; rc=$RC
is "first reveal runs" "$rc" 0
has "reveal is labelled" "$out" "REVEAL #1"

###############################################################################
section "the counts-only channel"
###############################################################################

REPO="$ROOT/counts"
WT="$ROOT/wt-counts"
mkrepo "$REPO" >/dev/null
sti "$REPO" "$WT" open basket specs/basket.md
good_suite basket "$REPO/.git/sti/basket/tests"
sti "$REPO" "$WT" freeze basket
sti "$REPO" "$WT" audit basket
sti "$REPO" "$WT" impl basket
cat >"$WT/impl/basket/demo/basket.py" <<'PY'
def line_total(unit_price: int, qty: int) -> int:
    return 0


def basket_total(lines: list[tuple[int, int]]) -> int:
    return 0
PY
stic "$REPO" "$WT" check basket; rc=$RC
has "failing suite reports failed count" "$out" "failed=2"
hasnt "and no test names" "$out" "test_line_total_multiplies_price_by_qty"
hasnt "and no assertion text" "$out" "assert"
hasnt "and no file names" "$out" "test_basket"

###############################################################################
section "hide the slice: the frozen suite must actually run"
###############################################################################

REPO="$ROOT/hidden"
WT="$ROOT/wt-hidden"
mkrepo "$REPO" >/dev/null
sti "$REPO" "$WT" open basket specs/basket.md
good_suite basket "$REPO/.git/sti/basket/tests"
sti "$REPO" "$WT" freeze basket
sti "$REPO" "$WT" audit basket
sti "$REPO" "$WT" impl basket
good_impl "$WT/impl/basket"
# A conftest in the impl worktree that ignores the slice's directory.
cat >"$WT/impl/basket/conftest.py" <<'PY'
collect_ignore = ["tests/basket"]
PY
stic "$REPO" "$WT" check basket
has "collect_ignore cannot fake green" "$out" "collected"

REPO="$ROOT/skipped"
WT="$ROOT/wt-skipped"
mkrepo "$REPO" >/dev/null
cat >"$REPO/specs/basket.md" <<'MD'
# Basket

## Public contract

`demo/basket.py` - `line_total(p: int, q: int) -> int`

## Requirements

### R1 - line_total multiplies price by qty
### R2 - basket_total sums the line totals
### R3 - basket_total of an empty list is 0
MD
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm spec
sti "$REPO" "$WT" open basket specs/basket.md
mkdir -p "$REPO/.git/sti/basket/tests/tests/basket"
cat >"$REPO/.git/sti/basket/tests/tests/basket/test_basket.py" <<'PY'
import pytest

from demo.basket import basket_total, line_total


# spec: R1
@pytest.mark.skip(reason="environment")
def test_line_total():
    assert line_total(10, 3) == 30


# spec: R2
@pytest.mark.skip(reason="environment")
def test_basket_total():
    assert basket_total([(10, 3), (5, 2)]) == 40


# spec: R3
@pytest.mark.skip(reason="environment")
def test_empty_basket():
    assert basket_total([]) == 0
PY
git -C "$REPO/.git/sti/basket/tests" add -A
git -C "$REPO/.git/sti/basket/tests" -c user.email=t@t -c user.name=t commit -qm t
sti "$REPO" "$WT" freeze basket
sti "$REPO" "$WT" impl basket
cat >"$WT/impl/basket/demo/basket.py" <<'PY'
def line_total(unit_price: int, qty: int) -> int:
    return 0


def basket_total(lines: list[tuple[int, int]]) -> int:
    return 0
PY
stic "$REPO" "$WT" check basket; rc=$RC
has "an all-skipped slice suite is caught" "$out" "the suite verifies nothing"
stic "$REPO" "$WT" finish basket; rc=$RC
is "finish refuses it too" "$rc" 1

###############################################################################
section "spec drift after freeze"
###############################################################################

REPO="$ROOT/drift"
WT="$ROOT/wt-drift"
mkrepo "$REPO" >/dev/null
sti "$REPO" "$WT" open basket specs/basket.md
good_suite basket "$REPO/.git/sti/basket/tests"
sti "$REPO" "$WT" freeze basket
stic "$REPO" "$WT" audit basket; rc=$RC
is "audit passes before the edit" "$rc" 0
cat >"$REPO/specs/basket.md" <<'MD'
# Basket (v2)

## Public contract

`demo/basket.py` - `line_total(p: int, q: int) -> int`

## Requirements

### R1 - COMPLETELY DIFFERENT BEHAVIOUR: always returns 0
### R2 - basket_total sums the line totals
### R3 - basket_total of an empty list is 0
MD
stic "$REPO" "$WT" audit basket; rc=$RC
has "audit refuses a rewritten spec" "$out" "spec changed after the tests were frozen"
sti "$REPO" "$WT" impl basket
stic "$REPO" "$WT" check basket
has "check refuses a rewritten spec" "$out" "spec changed"
stic "$REPO" "$WT" finish basket; rc=$RC
has "finish refuses a rewritten spec" "$out" "spec changed"
git -C "$REPO" checkout -q -- specs/basket.md
stic "$REPO" "$WT" audit basket; rc=$RC
is "restoring the spec unblocks it" "$rc" 0

###############################################################################
section "tampering with the frozen tests"
###############################################################################

REPO="$ROOT/tamper"
WT="$ROOT/wt-tamper"
mkrepo "$REPO" >/dev/null
sti "$REPO" "$WT" open basket specs/basket.md
good_suite basket "$REPO/.git/sti/basket/tests"
sti "$REPO" "$WT" freeze basket
# Someone weakens a frozen test after the freeze.
python3 - "$REPO/.git/sti/basket/tests/tests/basket/test_basket.py" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("assert line_total(10, 3) == 30", "assert True"))
PY
git -C "$REPO/.git/sti/basket/tests" add -A
git -C "$REPO/.git/sti/basket/tests" -c user.email=t@t -c user.name=t commit -qm "test: weaken"
stic "$REPO" "$WT" check basket
has "a post-freeze edit is refused" "$out" "changed after freeze"

REPO="$ROOT/leak"
WT="$ROOT/wt-leak"
mkrepo "$REPO" >/dev/null
sti "$REPO" "$WT" open basket specs/basket.md
good_suite basket "$REPO/.git/sti/basket/tests"
sti "$REPO" "$WT" freeze basket
sti "$REPO" "$WT" impl basket
mkdir -p "$WT/impl/basket/tests/basket"
cp "$REPO/.git/sti/basket/tests/tests/basket/test_basket.py" "$WT/impl/basket/tests/basket/test_basket.py"
stic "$REPO" "$WT" check basket
has "a copied-in test file is a leak" "$out" "LEAK"
rm -rf "$WT/impl/basket/tests/basket"
# Renaming it does not help: the harness compares content, not paths.
mkdir -p "$WT/impl/basket/tests/other"
cp "$REPO/.git/sti/basket/tests/tests/basket/test_basket.py" "$WT/impl/basket/tests/other/helper.py"
stic "$REPO" "$WT" check basket
has "a renamed copy is still a leak" "$out" "same content as"
rm -rf "$WT/impl/basket/tests/other"

###############################################################################
section "freeze refuses non-test files"
###############################################################################

REPO="$ROOT/scope"
WT="$ROOT/wt-scope"
mkrepo "$REPO" >/dev/null
sti "$REPO" "$WT" open basket specs/basket.md
mkdir -p "$REPO/.git/sti/basket/tests/basket"
good_suite basket "$REPO/.git/sti/basket/tests"
cat >"$REPO/.git/sti/basket/tests/demo/basket.py" <<'PY'
def line_total(unit_price: int, qty: int) -> int:
    return unit_price * qty
PY
git -C "$REPO/.git/sti/basket/tests" add -A
git -C "$REPO/.git/sti/basket/tests" -c user.email=t@t -c user.name=t commit -qm t
stic "$REPO" "$WT" freeze basket
has "the test branch may not touch implementation" "$out" "non-test file"

###############################################################################
section "dirty tree, missing spec, reset"
###############################################################################

REPO="$ROOT/dirty"
WT="$ROOT/wt-dirty"
mkrepo "$REPO" >/dev/null
echo "scratch" >"$REPO/untracked.txt"
stic "$REPO" "$WT" open basket specs/basket.md
has "open refuses a dirty tree" "$out" "working tree is dirty"
rm "$REPO/untracked.txt"
stic "$REPO" "$WT" open basket nosuch.md
has "open refuses a missing spec" "$out" "spec not found"
stic "$REPO" "$WT" open basket specs/basket.md; rc=$RC
is "open succeeds on a clean tree" "$rc" 0
stic "$REPO" "$WT" open basket specs/basket.md
has "open refuses a second open" "$out" "already exists"
sti "$REPO" "$WT" reset basket
stic "$REPO" "$WT" status basket; rc=$RC
has "reset removes the slice" "$out" "unknown slice"
stic "$REPO" "$WT" open basket specs/basket.md; rc=$RC
is "the slice name is reusable after reset" "$rc" 0

# A spec without a contract section warns but does not block.
REPO="$ROOT/nocontract"
WT="$ROOT/wt-nocontract"
mkrepo "$REPO" >/dev/null
printf '# S\n\n## Requirements\n\n### R1 - a\n' >"$REPO/specs/basket.md"
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm spec
stic "$REPO" "$WT" open basket specs/basket.md
has "a missing contract section warns" "$out" "no '## Public contract' section"

###############################################################################
section "reveal budget"
###############################################################################

REPO="$ROOT/reveal"
WT="$ROOT/wt-reveal"
mkrepo "$REPO" >/dev/null
sti "$REPO" "$WT" open basket specs/basket.md
good_suite basket "$REPO/.git/sti/basket/tests"
sti "$REPO" "$WT" freeze basket
sti "$REPO" "$WT" audit basket
sti "$REPO" "$WT" impl basket
good_impl "$WT/impl/basket"
stic "$REPO" "$WT" reveal basket; rc=$RC
is "reveal 1 runs" "$rc" 0
stic "$REPO" "$WT" reveal basket; rc=$RC
is "reveal 2 runs" "$rc" 0
stic "$REPO" "$WT" reveal basket; rc=$RC
is "reveal 3 is refused" "$rc" 1
has "and says what to do instead" "$out" "Re-open the slice"

###############################################################################
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || red "some self-tests failed"
exit $(( FAIL > 0 ? 1 : 0 ))
