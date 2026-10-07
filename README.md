# split-test-impl

Develop a slice from a spec with two isolated agents: one writes the tests, a
second implements the spec without ever seeing them.

A spec written, implemented and checked by one mind is self-confirming. This
skill splits the work so the two halves cannot flatter each other. The test
worker turns the spec into a suite and freezes it. The implementation worker gets
a fresh session, the spec, and an empty worktree — no test names, no assertions,
no hint of how many tests exist or what they check.

If the two disagree, something is wrong: the spec is vague, or a test over-specifies
it. Either way you find out before the code is written, which is the cheapest
moment to find out.

## What it enforces

The blindness is mechanical, not a matter of good intentions.

- **Two private repositories.** The tests live in a vault that the main repo
  never holds a ref to; the implementation gets its own worktree seeded from the
  pre-test base commit. They share no object store, so neither can read the
  other with a single `git` command.
- **Counts-only feedback.** `check` parses the JUnit XML and prints
  `passed=14 failed=2 errors=0 skipped=0 total=16`. Test names and tracebacks
  require an explicit, counted `reveal` — and only two are allowed.
- **Content-based leak detection.** A frozen test copied into the implementation
  worktree is caught by blob hash, not by filename.
- **The suite must actually run.** A `conftest.py` that ignores the slice's
  directory, or a suite that skips itself, is refused rather than reported green.
- **The spec is pinned at freeze.** Rewriting the spec after the tests were
  written against it makes every later command refuse until the slice is
  re-opened under a new name.

## What you don't get

Proof of correctness. You get proof that *some* implementation satisfies the spec
as written — which is a statement about the spec's implementability, not its
rightness. Worth saying out loud to the implementation worker, so it doesn't
optimise for a test suite it cannot see.

## Install

Copy the skill directory into your agent's skills folder:

```
.agents/skills/split-test-impl/     # or wherever your agent looks
```

The harness is plain bash plus two small Python helpers. It needs `git`, `rsync`,
and `pytest` on the target project's interpreter.

## Use

Requires `git`, `rsync`, `pytest`, and Python 3.11+. Run `sti.sh` as the user who
owns the repository — it creates repositories, worktrees and refs, and files
created by the wrong user lock the owner out.

Write a spec first, with a public contract and numbered requirements:

```markdown
# Basket

## Public contract

`demo/basket.py`

- `line_total(unit_price: int, qty: int) -> int`
- `basket_total(lines: list[tuple[int, int]]) -> int`

## Requirements

### R1 - line_total multiplies unit price by quantity
### R2 - basket_total sums the line totals
### R3 - basket_total of an empty list is 0
```

Then:

```bash
STI=.agents/skills/split-test-impl/scripts/sti.sh

$STI open basket specs/basket.md   # private test vault at HEAD
                                    # -> hand the spec + vault to the test worker
$STI freeze basket                 # tests immutable, spec text pinned
$STI audit basket                  # every test cites a requirement, and vice versa
$STI impl basket                   # private worktree at the pre-test base commit
                                    # -> hand the spec + worktree to the impl worker
$STI check basket                  # counts only
$STI finish basket                 # audit + green + committed gates, prints the merge
```

Each step is a separate agent session. `[SKILL.md](SKILL.md)` has the workflow and
the prompt templates for both workers; `[REFERENCE.md](REFERENCE.md)` covers the
leak channels and the escalation policy.

## Developing the harness

`scripts/sti_test.sh` is the harness's own test suite: 71 assertions over whole
slices run end to end in throwaway repositories under `$TMPDIR`, including
attempts to defeat the blindness.

```bash
bash scripts/sti_test.sh
```

If it goes red, the skill's promises are broken — that is the signal to act on,
not a flaky test to re-run.

## When it pays off

Roughly twice the tokens of writing tests and implementation in one session,
plus a review pass on the spec. Worth it when the slice is big enough that
"looks right" is a real risk: a new domain package, pricing or forecasting logic,
anything with a public API others will depend on. Overkill for a bug fix with an
obvious fix.
