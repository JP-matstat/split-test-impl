#!/usr/bin/env bash
# sti.sh — enforcement harness for the split-test-impl workflow.
#
# The point of this script is that the implementation worker must not be able
# to see the tests, even by accident. It enforces that mechanically:
#
#   * the test suite is written in its OWN repository (the "vault"), created by
#     fetching the base commit by ref — the tests branch and its objects never
#     enter the main repo, so `git branch`, `git log --all` and `git show` in
#     either worker's checkout cannot reveal them
#   * the implementation worktree is a second private repository at the
#     pre-test base commit; `check` asserts the frozen commit is not even
#     present as an object in it
#   * the suite is executed in a throwaway copy, so no frozen test file ever
#     lands in the implementation worktree
#   * `check` reports that the frozen tests were actually collected, so a
#     conftest that hides them (or skips them) cannot pass as green
#   * the default feedback is pass/fail COUNTS ONLY; full output requires an
#     explicit, counted `reveal`
#
# State lives in $GIT_COMMON/sti/<slice>.env (inside .git — never tracked) and
# the test vault at $GIT_COMMON/sti/<slice>/tests (also inside .git).

set -euo pipefail

PROG=sti.sh
WT_ROOT="${STI_WORKTREE_ROOT:-${TMPDIR:-/tmp}/sti}"
TEST_TIMEOUT="${STI_TEST_TIMEOUT:-600}"

die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }
say() { printf '%s\n' "$*" >&2; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
GIT_COMMON="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
STATE_DIR="$GIT_COMMON/sti"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Throwaway copies live here and are removed when we exit. An EXIT trap is used
# rather than a RETURN trap on purpose: a RETURN trap would fire after every
# nested helper returned and delete the copy mid-run.
SCRATCH_DIRS=()
SCRATCH=""
cleanup() {
  local d
  for d in ${SCRATCH_DIRS[@]+"${SCRATCH_DIRS[@]}"}; do rm -rf "$d"; done
}
trap cleanup EXIT

# Sets $SCRATCH. Not a command substitution: a subshell would swallow the
# bookkeeping and leave the copy behind.
new_scratch() {
  SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/sti-XXXXXX")"
  SCRATCH_DIRS+=("$SCRATCH")
}

# ---------------------------------------------------------------- state ----

sf() { printf '%s/%s.env\n' "$STATE_DIR" "$1"; }

need_slice() {
  [ -f "$(sf "$1")" ] || die "unknown slice '$1' — run: $PROG open $1"
}

getk() {
  local f; f="$(sf "$1")"
  local v; v="$(grep -E "^$2=" "$f" | tail -1 | cut -d= -f2- || true)"
  [ -n "$v" ] || die "slice '$1' has no '$2' recorded"
  printf '%s\n' "$v"
}

# For display only: never fails, never calls die.
getk_opt() {
  local f; f="$(sf "$1")"
  grep -E "^$2=" "$f" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

setk() {
  local f; f="$(sf "$1")"
  local tmp; tmp="$(mktemp)"
  if [ -f "$f" ] && grep -q "^$2=" "$f"; then
    awk -v k="$2" -v v="$3" 'BEGIN{FS=OFS="="} $1==k{$0=k"="v} {print}' "$f" >"$tmp"
  else
    cat "$f" 2>/dev/null >"$tmp" || true
    printf '%s=%s\n' "$2" "$3" >>"$tmp"
  fi
  mv "$tmp" "$f"
}

# -------------------------------------------------------------- layout ----

vault() { printf '%s/%s/tests\n' "$STATE_DIR" "$1"; }
impl_dir() { printf '%s/impl/%s\n' "$WT_ROOT" "$1"; }
tests_branch() { printf 'tests/%s' "$1"; }
impl_branch() { printf 'impl/%s' "$1"; }
base_ref() { printf 'refs/sti/base/%s' "$1"; }

# ---------------------------------------------------------------- frozen ----

is_test_path() {
  case "$1" in
    tests/*|*/tests/*|test_*.py|*_test.py|conftest.py|*/conftest.py) return 0 ;;
    *) return 1 ;;
  esac
}

# Every path the test author changed, base -> frozen commit.
frozen_files() {
  git -C "$(vault "$1")" diff --name-only "$(getk "$1" base)" "$(getk "$1" tests_commit)" --
}

frozen_commit() { getk "$1" tests_commit; }

# The frozen tests as pytest paths, for the collection probe.
frozen_test_paths() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      tests/*|*/tests/*) case "$f" in *test_*.py|*/test_*.py|*_test.py) printf '%s\n' "$f" ;; esac ;;
      test_*.py|*_test.py) printf '%s\n' "$f" ;;
    esac
  done < <(frozen_files "$1")
}

spec_file() {
  local s; s="$(getk "$1" spec)"
  if [ -f "$REPO_ROOT/$s" ]; then printf '%s\n' "$REPO_ROOT/$s"
  elif [ -f "$s" ]; then printf '%s\n' "$s"
  else die "spec not found: $s"; fi
}

assert_tests_untouched() {
  local slice="$1" head
  [ -n "$(getk_opt "$slice" tests_commit)" ] ||
    die "slice '$slice' is not frozen yet — run: $PROG freeze $slice"
  head="$(git -C "$(vault "$slice")" rev-parse "$(tests_branch "$slice")")"
  [ "$head" = "$(frozen_commit "$slice")" ] ||
    die "the test suite changed after freeze ($head != $(frozen_commit "$slice")).
The tests are no longer independent. Re-open the slice with a new name."
}

assert_tests_absent_from_impl() {
  local slice="$1" wt f hash
  local -a want=() have=()
  wt="$(impl_dir "$slice")"
  [ -d "$wt" ] || die "implementation worktree is gone: $wt — run: $PROG impl $slice"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -e "$wt/$f" ]; then
      die "LEAK: frozen test file exists in the implementation worktree: $wt/$f
Delete it. The implementation worker must never see a test."
    fi
    if git -C "$(vault "$slice")" cat-file -e "$(frozen_commit "$slice"):$f" 2>/dev/null; then
      hash="$(git -C "$(vault "$slice")" rev-parse "$(frozen_commit "$slice"):$f")"
      want+=("$hash:$f")
    fi
  done < <(frozen_files "$slice")

  # Same content under a different name is the same leak: the worker just has to
  # know where to look. Compare blob hashes, tracked and untracked.
  [ "${#want[@]}" -gt 0 ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    hash="$(git -C "$wt" hash-object "$f" 2>/dev/null || true)"
    [ -n "$hash" ] && have+=("$hash:$f")
  done < <(cd "$wt" && { git ls-files; git ls-files --others --exclude-standard; } | sort -u)
  for hash in "${want[@]}"; do
    for other in "${have[@]}"; do
      [ "${hash%%:*}" = "${other%%:*}" ] || continue
      die "LEAK: the implementation worktree contains a file identical to a frozen test:
$wt/${other#*:} (same content as ${hash#*:})
The implementation worker must never see a test, renamed or not."
    done
  done
  return 0
}

# Blindness, verified rather than assumed: the frozen commit must not exist as
# an object in the implementation repository, and no tests/* ref may live there.
assert_blind() {
  local slice="$1" wt ref
  wt="$(impl_dir "$slice")"
  if git -C "$wt" cat-file -e "$(frozen_commit "$slice")^{commit}" 2>/dev/null; then
    die "LEAK: the frozen test commit $(frozen_commit "$slice") is present in
$wt. The implementation worker could read it with a single git command.
Reset the slice and re-open it."
  fi
  for ref in $(git -C "$wt" for-each-ref --format='%(refname)' 'refs/heads/tests/*' 2>/dev/null); do
    die "LEAK: $ref exists in $wt. The implementation worker must not have a tests branch."
  done
  return 0
}

py_bin() {
  if [ -x "$REPO_ROOT/.venv/bin/python" ]; then
    printf '%s\n' "$REPO_ROOT/.venv/bin/python"
  elif command -v python3 >/dev/null 2>&1; then
    command -v python3
  else
    die "no python interpreter found (run: uv sync --extra dev)"
  fi
}

# Materialise the frozen suite into $2 without touching the implementation worktree.
materialize() {
  local slice="$1" dest="$2" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    git -C "$(vault "$slice")" cat-file -e "$(frozen_commit "$slice"):$f" 2>/dev/null || continue
    mkdir -p "$dest/$(dirname "$f")"
    git -C "$(vault "$slice")" show "$(frozen_commit "$slice"):$f" >"$dest/$f"
  done < <(frozen_files "$slice")
  return 0
}

# The frozen tests must be collected by the very run that grades the work.
# Without this, a conftest that ignores the directory — or a suite that skips
# itself — reports a green run that verified nothing.
#
# The probe mirrors the real run (no path arguments, so rootdir config and
# conftest collection rules apply) and then asks whether the frozen files were
# among the collected node ids.
assert_collected() {
  local slice="$1" scratch="$2" py log n rc expected f
  local -a paths=()
  mapfile -t paths < <(frozen_test_paths "$slice")
  [ "${#paths[@]}" -gt 0 ] || die "the frozen commit contains no test files — run: $PROG audit $slice"
  expected="$(getk "$slice" frozen_tests)"
  py="$(py_bin)"
  log="$scratch/.sti-collect.log"
  set +e
  (cd "$scratch" && PYTHONPATH="$scratch" timeout --foreground -k 5 "$TEST_TIMEOUT" \
    "$py" -m pytest --collect-only -q --no-header -p no:cacheprovider >"$log" 2>&1)
  rc=$?
  set -e
  # rc > 1 means the collection itself broke (the implementation does not exist
  # yet, or does not import). The real run reports that with a better message.
  if [ "$rc" -gt 1 ]; then return 0; fi
  n=0
  for f in "${paths[@]}"; do
    n=$((n + "$(grep -c "^${f}::" "$log" || true)"))
  done
  if [ "$n" -lt "$expected" ]; then
    say "the frozen suite collected $n of $expected test(s) — fix that before trusting counts"
    say "(a conftest that ignores the directory, or a module-level skip, hides the slice)"
    exit 1
  fi
  return 0
}

# Run the whole suite against the implementation worktree.
# $1 slice, $2 mode (counts|full). Counts mode leaks nothing but numbers.
run_suite() {
  local slice="$1" mode="$2" wt scratch report raw rc tb py
  wt="$(impl_dir "$slice")"
  py="$(py_bin)"
  new_scratch
  scratch="$SCRATCH"

  # Only the code under test: skip venvs, caches and vendored assets. The suite
  # runs with the repo's own interpreter, so .venv does not need copying.
  rsync -a --delete \
    --exclude '.git/' --exclude '.venv/' --exclude 'node_modules/' \
    --exclude '__pycache__/' --exclude '.pytest_cache/' --exclude '.mypy_cache/' \
    --exclude '.ruff_cache/' --exclude '*.egg-info/' --exclude 'data/' \
    --exclude '.env' \
    "$wt/" "$scratch/"
  materialize "$slice" "$scratch"

  # The repo is installed editable, so a stale path could shadow the copy under
  # test and quietly grade the wrong code. Verify what actually gets imported —
  # for every top-level package in the copy, not a hardcoded list.
  cat >"$scratch/.sti-guard.py" <<'PY'
import importlib.util, os, sys

scratch = os.path.abspath(os.environ["STI_SCRATCH"])
skip = {"tests", "scripts", "alembic", "docs", "plans", "data", "node_modules"}
bad = []
for entry in sorted(os.listdir(scratch)):
    if entry.startswith((".", "_")) or entry in skip:
        continue
    if not os.path.isdir(os.path.join(scratch, entry)):
        continue
    if not os.path.exists(os.path.join(scratch, entry, "__init__.py")):
        continue
    try:
        spec = importlib.util.find_spec(entry)
    except Exception:
        continue
    origin = (spec.origin if spec else None) or ""
    if origin and not os.path.abspath(origin).startswith(scratch + os.sep):
        bad.append(f"{entry} -> {origin}")
if bad:
    print("imported from outside the scratch copy: " + ", ".join(bad))
    sys.exit(3)
PY
  if ! (cd "$scratch" && PYTHONPATH="$scratch" STI_SCRATCH="$scratch" "$py" .sti-guard.py); then
    die "editable install shadows the scratch copy — cannot verify the suite honestly"
  fi

  assert_collected "$slice" "$scratch"

  report="$scratch/.sti-report.xml"
  raw="$scratch/.sti-pytest.log"
  tb=no
  if [ "$mode" = full ]; then tb=long; fi
  say "running suite in a throwaway copy (timeout ${TEST_TIMEOUT}s)"
  set +e
  if [ "$mode" = full ]; then
    (cd "$scratch" && PYTHONPATH="$scratch" timeout --foreground -k 5 "$TEST_TIMEOUT" \
      "$py" -m pytest -q --no-header -p no:cacheprovider --tb="$tb" --junitxml="$report") \
      2>&1 | tee "$raw"
    rc="${PIPESTATUS[0]}"
  else
    # pytest's own output names tests in its warnings summary, so in counts mode
    # it goes to a file that dies with the scratch copy.
    (cd "$scratch" && PYTHONPATH="$scratch" timeout --foreground -k 5 "$TEST_TIMEOUT" \
      "$py" -m pytest -q --no-header -p no:cacheprovider --tb="$tb" \
      --junitxml="$report" >"$raw" 2>&1)
    rc=$?
  fi
  set -e
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    die "the suite hung for more than ${TEST_TIMEOUT}s (STI_TEST_TIMEOUT to change).
An implementation that never returns will stall the whole loop — fix it in the
worktree, or re-open the slice if the frozen tests are the ones hanging."
  fi
  if [ "$rc" -gt 1 ] && [ "$rc" -ne 5 ]; then
    die "pytest exited $rc (collection error or crash) — fix that before trusting counts"
  fi

  if [ "$mode" = full ]; then
    printf '\n== counts ==\n'
  fi
  "$py" - "$report" "$rc" "$slice" "$(frozen_test_paths "$slice" | tr '\n' ' ')" <<'PY'
import sys, xml.etree.ElementTree as ET

report, rc = sys.argv[1], int(sys.argv[2])
slice_name = sys.argv[3]
frozen = [p.strip() for p in sys.argv[4:] if p.strip()]
modules = [".".join(p.split("/")[:-1] + [p.rsplit("/", 1)[-1][:-3]]) for p in frozen]

tot = {"tests": 0, "failures": 0, "errors": 0, "skipped": 0}
try:
    root = ET.parse(report).getroot()
except Exception as exc:  # no junit file at all
    print(f"no report produced ({exc})")
    sys.exit(2)
nodes = [root] if root.tag == "testsuite" else root.iter("testsuite")
for node in nodes:
    for key in tot:
        tot[key] += int(node.get(key, 0))

# A frozen test that skipped or xfailed verified nothing. If every one of them
# did, the counts below would read as a pass for the wrong reason.
frozen_skipped = frozen_total = 0
for node in root.iter("testsuite"):
    for case in node.iter("testcase"):
        cls = case.get("classname") or ""
        if modules and not any(cls == m or cls.endswith("." + m) for m in modules):
            continue
        frozen_total += 1
        if case.find("skipped") is not None:
            frozen_skipped += 1

if frozen_total and frozen_skipped == frozen_total:
    print(
        f"all {frozen_total} test(s) of slice '{slice_name}' skipped or xfailed — "
        "the suite verifies nothing",
        file=sys.stderr,
    )
    sys.exit(3)

passed = tot["tests"] - tot["failures"] - tot["errors"] - tot["skipped"]
print(
    f"passed={passed} failed={tot['failures']} errors={tot['errors']} "
    f"skipped={tot['skipped']} total={tot['tests']}"
)
sys.exit(0 if tot["failures"] == 0 and tot["errors"] == 0 and rc == 0 else 1)
PY
}

# -------------------------------------------------------------- commands ----

cmd_open() {
  local slice="${1:-}" spec="${2:-}" vault_dir
  [ -n "$slice" ] || die "usage: $PROG open <slice> <spec-path>"
  [ -n "$spec" ] || die "usage: $PROG open <slice> <spec-path>"
  [ -f "$spec" ] || die "spec not found: $spec"
  [ -z "$(git status --porcelain)" ] || die "working tree is dirty — commit or stash first"
  if git show-ref --verify --quiet "$(base_ref "$slice")" || [ -e "$(sf "$slice")" ]; then
    die "slice '$slice' already exists — reset it first: $PROG reset $slice"
  fi
  vault_dir="$(vault "$slice")"
  mkdir -p "$STATE_DIR" "$WT_ROOT/impl"
  rm -rf "$vault_dir"
  {
    printf 'slice=%s\n' "$slice"
    printf 'base=%s\n' "$(git rev-parse HEAD)"
    printf 'spec=%s\n' "$spec"
    printf 'reveals=0\n'
  } >"$(sf "$slice")"

  if ! grep -qE '^#+\s*Public contract' "$spec"; then
    say "WARNING: $spec has no '## Public contract' section."
    say "         Without it the two agents will disagree on names and signatures."
  fi

  # The test vault: an independent repository seeded from the base commit by ref.
  # The tests branch is created HERE, so the main repo never holds it and neither
  # worker can reach it from their own checkout.
  git update-ref "$(base_ref "$slice")" "$(git rev-parse HEAD)"
  git init -q --initial-branch=sti-bootstrap "$vault_dir"
  git -C "$vault_dir" fetch -q --no-tags "$REPO_ROOT" \
    "+$(base_ref "$slice"):refs/heads/$(tests_branch "$slice")"
  git -C "$vault_dir" checkout -q "$(tests_branch "$slice")"
  local k
  for k in user.name user.email; do
    local v; v="$(git config --local --get "$k" || true)"
    [ -n "$v" ] && git -C "$vault_dir" config "$k" "$v"
  done

  say "test vault (private repo, tests live only here): $vault_dir"
  say "tests branch: $(tests_branch "$slice") (at the base commit)"
  say ""
  say "1. Hand the TEST worker $spec and $vault_dir. It writes tests there and commits."
  say "2. Then: $PROG freeze $slice"
}

cmd_freeze() {
  local slice="${1:-}" vt head count=0 f spec
  need_slice "$slice"
  vt="$(vault "$slice")"
  [ -d "$vt" ] || die "test vault missing: $vt"
  [ -z "$(git -C "$vt" status --porcelain)" ] || die "uncommitted work in the vault — commit the tests first"
  head="$(git -C "$vt" rev-parse HEAD)"
  [ "$head" != "$(getk "$slice" base)" ] || die "no test files were committed — nothing to freeze"

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    count=$((count + 1))
    if ! is_test_path "$f"; then
      die "the test branch touched a non-test file: $f
Tests may only add or change test files. Implementation belongs to the other worker."
    fi
  done < <(git -C "$vt" diff --name-only "$(getk "$slice" base)" "$head" --)

  spec="$(spec_file "$slice")"
  setk "$slice" tests_commit "$head"
  # Pin the spec text the tests were written against. Editing it afterwards makes
  # the audit meaningless, so every later command refuses until the slice is re-opened.
  setk "$slice" spec_sha "$(sha256sum "$spec" | cut -d' ' -f1)"
  setk "$slice" frozen_tests "$(count_frozen "$slice")"
  say "frozen at $head ($count file(s) changed, $(getk "$slice" frozen_tests) test function(s))"
  say "spec pinned: $(basename "$spec")"
  say ""
  say "next: $PROG audit $slice   (mandatory gate)"
}

cmd_audit() {
  local slice="${1:-}" spec scratch py f want have
  local -a files=()
  need_slice "$slice"
  assert_tests_untouched "$slice"
  spec="$(spec_file "$slice")"
  assert_spec_unchanged "$slice" "$spec"
  py="$(py_bin)"
  new_scratch
  scratch="$SCRATCH"
  materialize "$slice" "$scratch"
  while IFS= read -r f; do
    [ -n "$f" ] && files+=("$f")
  done < <(frozen_files "$slice")
  "$py" "$SKILL_DIR/audit.py" "$spec" "$scratch" "${files[@]}"
  want="$(count_frozen "$slice")"
  have="$(getk "$slice" frozen_tests)"
  [ "$want" = "$have" ] || die "frozen test count changed ($have -> $want); re-open the slice"
  return 0
}

cmd_impl() {
  local slice="${1:-}" wt origin
  need_slice "$slice"
  frozen_commit "$slice" >/dev/null
  wt="$(impl_dir "$slice")"
  [ ! -e "$wt" ] || die "$wt already exists — reset the slice first"
  mkdir -p "$(dirname "$wt")"
  # A second private repository at the base commit. The tests branch and its
  # objects are not reachable from here, and `check` keeps proving it.
  git init -q --initial-branch=sti-bootstrap "$wt"
  git -C "$wt" fetch -q --no-tags "$REPO_ROOT" \
    "+$(base_ref "$slice"):refs/heads/$(impl_branch "$slice")"
  git -C "$wt" checkout -q "$(impl_branch "$slice")"
  # Carry over the identity and remotes the worker needs to commit and push. A
  # fresh `git init` has neither, and this repo configures them locally.
  local k v
  for k in user.name user.email; do
    v="$(git config --local --get "$k" || true)"
    [ -n "$v" ] && git -C "$wt" config "$k" "$v"
  done
  origin="$(git remote get-url origin 2>/dev/null || true)"
  [ -n "$origin" ] && git -C "$wt" remote add origin "$origin"
  setk "$slice" impl_branch "$(impl_branch "$slice")"
  assert_tests_absent_from_impl "$slice"
  assert_blind "$slice"
  say "implementation worktree: $wt (branch $(impl_branch "$slice"), based on $(getk "$slice" base))"
  say ""
  say "Hand the IMPLEMENTATION worker: $(getk "$slice" spec), and this worktree. Nothing else."
  say "Tell it explicitly: no test suite exists; do not write or search for one;"
  say "if the spec is ambiguous, say so instead of guessing."
}

cmd_check() {
  local slice="${1:-}"
  need_slice "$slice"
  assert_tests_untouched "$slice"
  assert_tests_absent_from_impl "$slice"
  assert_blind "$slice"
  assert_spec_unchanged "$slice" "$(spec_file "$slice")"
  run_suite "$slice" counts
}

cmd_reveal() {
  local slice="${1:-}" n
  need_slice "$slice"
  assert_tests_untouched "$slice"
  assert_tests_absent_from_impl "$slice"
  assert_blind "$slice"
  assert_spec_unchanged "$slice" "$(spec_file "$slice")"
  n="$(getk "$slice" reveals)"
  if [ "$n" -ge 2 ]; then
    say "== REVEAL #$((n + 1)) REFUSED — two reveals already =="
    say "Stop treating this as an implementation problem: either the spec is wrong, or the"
    say "frozen tests over-specify it. Re-open the slice ($PROG reset $slice, then open ${slice}-2)."
    exit 1
  fi
  setk "$slice" reveals "$((n + 1))"
  say "== REVEAL #$((n + 1)) — test names and tracebacks are now visible to the implementation worker =="
  run_suite "$slice" full
}

cmd_finish() {
  local slice="${1:-}" wt ib
  need_slice "$slice"
  assert_tests_untouched "$slice"
  wt="$(impl_dir "$slice")"
  [ -d "$wt" ] || die "implementation worktree is gone: $wt"
  # Spec-side gates first: if the spec moved, nothing below says anything useful.
  cmd_audit "$slice" || die "audit failed — fix the mapping before merging"
  [ -z "$(git -C "$wt" status --porcelain)" ] ||
    die "the implementation worktree has uncommitted changes — commit them first.
check grades the working tree, so an uncommitted implementation would pass the gate
and then be left out of the merge."
  ib="$(impl_branch "$slice")"
  [ "$(git -C "$wt" rev-parse HEAD)" != "$(getk "$slice" base)" ] ||
    die "the implementation branch has no commits — there is nothing to merge the suite into."
  cmd_check "$slice" >/dev/null || die "suite is not green — do not merge"
  say "green and audited. Merge the frozen suite in:"
  say ""
  say "  git -C $wt fetch '$(vault "$slice")' '+refs/heads/$(tests_branch "$slice"):refs/heads/$(tests_branch "$slice")'"
  say "  git -C $wt merge --no-ff $(tests_branch "$slice") -m 'test: freeze suite for $slice'"
  if git -C "$wt" remote get-url origin >/dev/null 2>&1; then
    say "  git -C $wt push -u origin $ib"
  fi
  say ""
  say "Remember what this proved: some implementation satisfies the spec as written."
  say "It did not prove the spec is right."
}

cmd_status() {
  local slice="${1:-}"
  need_slice "$slice"
  printf 'slice        %s\n' "$slice"
  printf 'spec         %s\n' "$(getk "$slice" spec)"
  printf 'spec sha     %s\n' "$(getk_opt "$slice" spec_sha)"
  printf 'base         %s\n' "$(getk "$slice" base)"
  printf 'vault        %s (%s)\n' "$(vault "$slice")" "$(tests_branch "$slice")"
  printf 'tests        @ %s\n' "$(getk_opt "$slice" tests_commit)"
  printf 'impl         %s (%s)\n' "$(getk_opt "$slice" impl_branch)" "$(impl_dir "$slice")"
  printf 'reveals      %s\n' "$(getk "$slice" reveals)"
}

cmd_reset() {
  local slice="${1:-}" wt
  need_slice "$slice"
  wt="$(impl_dir "$slice")"
  if [ -d "$wt/.git" ] && [ -n "$(git -C "$wt" status --porcelain)" ]; then
    die "$wt has uncommitted work — commit it or delete it by hand before resetting"
  fi
  rm -rf "$wt" "$(vault "$slice")" "$(sf "$slice")"
  git update-ref -d "$(base_ref "$slice")" 2>/dev/null || true
  say "slice '$slice' removed (vault, worktree, state, refs/sti/base/$slice)"
}

# ----------------------------------------------------------- shared bits ----

assert_spec_unchanged() {
  local slice="$1" spec="$2" pinned now
  pinned="$(getk_opt "$slice" spec_sha)"
  [ -n "$pinned" ] || die "slice '$slice' is not frozen yet — run: $PROG freeze $slice"
  now="$(sha256sum "$spec" | cut -d' ' -f1)"
  [ "$pinned" = "$now" ] ||
    die "the spec changed after the tests were frozen.
The tests were written against the pinned text; auditing them against different
text proves nothing. Re-open the slice: $PROG reset $slice && $PROG open ${slice}-2 <spec>"
  return 0
}

# Number of test functions in the frozen suite, straight from the AST. Recorded
# at freeze so `check` can tell "the slice tests ran" from "the slice was hidden".
count_frozen() {
  local slice="$1" scratch py n
  new_scratch
  scratch="$SCRATCH"
  materialize "$slice" "$scratch"
  py="$(py_bin)"
  n="$("$py" "$SKILL_DIR/count.py" "$scratch" $(frozen_files "$slice" | tr '\n' ' '))"
  [ "$n" -gt 0 ] || die "no test functions found in the frozen suite"
  printf '%s\n' "$n"
}

usage() {
  cat <<EOF
usage: $PROG <command> <slice>

  open   <slice> <spec>   private test vault at HEAD + state
  freeze <slice>          record the test commit (tests are now immutable) and
                          pin the spec text they were written against
  audit  <slice>           mandatory gate: every test cites a spec requirement,
                          every requirement is covered, no test is a no-op
  impl   <slice>           private implementation worktree at the pre-test base commit
  check  <slice>           run the suite, print COUNTS ONLY
  reveal <slice>          print test names + tracebacks (at most twice)
  finish <slice>           audit + green + committed gates, then print the merge
  status <slice>          show recorded state
  reset  <slice>          remove the vault, worktree, state and refs for a slice
EOF
}

main() {
  local cmd="${1:-}" slice="${2:-}"
  case "$cmd" in
    open) cmd_open "$slice" "${3:-}" ;;
    freeze) cmd_freeze "$slice" ;;
    audit) cmd_audit "$slice" ;;
    impl) cmd_impl "$slice" ;;
    check) cmd_check "$slice" ;;
    reveal) cmd_reveal "$slice" ;;
    finish) cmd_finish "$slice" ;;
    status) cmd_status "$slice" ;;
    reset) cmd_reset "$slice" ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown command '$cmd' (try: $PROG help)" ;;
  esac
}

main "$@"
