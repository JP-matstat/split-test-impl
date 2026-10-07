# Split Test / Implementation

A spec written, implemented and checked by one mind is self-confirming. This
workflow splits the work: a **test worker** turns the spec into a frozen suite,
then a **second agent with no memory of that session** implements the spec from
the spec alone. It cannot see the tests, so it cannot satisfy them by pattern
matching.

The blindness is enforced by `scripts/sti.sh` — two private repositories, not one
shared object store — not by good intentions. Run the script; do not reimplement
its checks by hand.

## What you get, and what you don't

You get an independent signal that the spec is implementable (the test worker's
friction = spec gaps) and resistance to specification-gaming. You do **not** get
proof of correctness — only proof that *some* implementation satisfies the spec
as written. Say this to the implementation worker so it doesn't optimise for an
imagined test suite.

## The spec comes first, and it must contain a contract

The whole scheme rests on both agents working from the same text. Before any
worker starts, the spec needs:

- `## Public contract` — exact module paths, function signatures, types, return
  shapes, error types, and what is public vs internal
- `## Requirements` — one heading per behaviour: `### R1 - <one line>`

`freeze` records a hash of the spec text. Editing the spec afterwards makes every
later command refuse until the slice is re-opened under a new name — otherwise
you would be auditing tests written against one spec against a different one.

If the contract is vague, tests and implementation will disagree on names and
`sti.sh audit` will pass while the merge fails on trivia. Fix the spec first.

## Workflow

One slice at a time. Each step is a separate agent session. Run `sti.sh` as the
user that owns the repo — it creates repositories, worktrees and refs, and
files created by the wrong user lock the owner out.

```bash
STI=<this skill's directory>/scripts/sti.sh
```

The spec path is yours to choose; the examples below use `specs/<slice>.md`.
Keep it committed: `open` pins a hash of the spec text.

### 1. Open the slice

```bash
$STI open <slice> specs/<slice>.md
```

Records the base commit, warns if the contract section is missing, and creates
the **test vault**: a private git repository under `.git/sti/<slice>/tests`,
seeded from the base commit by ref. The tests branch is created inside the vault,
so the main repository never holds it.

### 2. Test worker

Fresh session. Give it the spec path and the vault, nothing else. It writes
black-box tests — public API only, no private imports, no mocking of internal
collaborators — and commits them. Each test cites the requirement it verifies:

```python
# spec: R3
async def test_rejects_unknown_article_code():
    ...
```

### 3. Freeze

```bash
$STI freeze <slice>      # tests are now immutable; the spec text is pinned
$STI audit <slice>       # mandatory gate, see below
```

`audit` is bidirectional: every test must cite a real requirement, and every
requirement must have a test. A test that no requirement justifies is either a
missing spec requirement (write it into the spec, re-open the slice) or an
implementation detail (delete it). It also rejects suites that cannot fail — a
module-level `pytest.skip` — and private imports. Fix audit failures now; after
the freeze the suite is untouchable, by design.

### 4. Implementation worker

Fresh session, no history from step 2.

```bash
$STI impl <slice>
```

Creates a **second private repository** at the pre-test base commit under
`${TMPDIR:-/tmp}/sti/impl/<slice>`. It shares no object store with the vault, so
the frozen commit is not present in it at all — `check` asserts that before every
run. Hand the worker the spec path and that worktree. Tell it: no test suite
exists, do not write or search for one, and report ambiguity instead of guessing.
Prompt template in [REFERENCE.md](REFERENCE.md).

### 5. Check loop

```bash
$STI check <slice>     # prints: passed=14 failed=2 errors=0 skipped=0 total=16
```

Counts only, on stdout. No test names, no tracebacks — the first failure would
otherwise reveal the shape of the whole suite. Progress lines go to stderr;
relay the stdout counts to the worker verbatim and nothing else.

Two things are checked before the counts mean anything: that the frozen tests
were **collected** (a `conftest.py` in the implementation worktree could
otherwise `collect_ignore` the whole slice), and that they were not all
**skipped** (a green run that verified nothing). Both are refused, not counted.

Expect ~25s: the worktree is copied to a throwaway directory (frozen tests are
overlaid there, never in the worktree) and the whole suite runs against the copy.

Iterate: implement → `check` → read counts → implement. Don't ask for names.

```bash
$STI reveal <slice>    # test names + tracebacks, counted, at most twice
```

An escalation, not a channel. Two reveals means the problem is the spec or the
over-specified tests, not the implementation. The third is refused; `reset` and
re-open instead.

### 6. Finish

```bash
$STI finish <slice>    # audit + green + committed gates, prints the merge command
```

`check` grades the *working tree*, so `finish` refuses while the implementation
has uncommitted changes — otherwise it would pass the gate and then merge a
branch without the implementation on it. Only then do the frozen tests enter the
implementation branch.

## Rules

- [ ] Spec has `## Public contract`, `## Requirements` and `### Rn` headings
- [ ] Test worker session is discarded before the implementation session
- [ ] `audit` passes before `impl` worktree is created
- [ ] Spec text is not edited after `freeze` — re-open under a new name instead
- [ ] Tests touched only test files (`freeze` enforces this)
- [ ] Implementation worker never receives test names, output, or the vault path
- [ ] Spec gaps go back into the spec and re-open the slice — never patched by
      editing frozen tests
- [ ] Merge only after `finish`

## Common failure modes

| Symptom | Cause |
| --- | --- |
| Merge conflict on names only | Spec lacked a contract section |
| Suite green but impl is weird | Tests over-specified; ran `reveal` too early |
| `audit` flags unknown requirement | Test worker invented behaviour — back to the spec |
| `check` says "collected 0 of N" | A conftest in the impl worktree ignores the slice |
| `check` says "verifies nothing" | Every frozen test skipped or xfailed |
| Every command refuses on the spec | Spec edited after freeze — `reset`, re-open as `<slice>-2` |
| `LEAK: same content as …` | A frozen test was copied into the implementation worktree |
| Worker writes its own tests | Blindness was not stated; re-read the prompt template |
| Worker asks "what does test X expect?" | Leak channel; use `check`, not `reveal` |

## Maintaining the harness

`scripts/sti_test.sh` is the harness's own test suite: miniature repos under
`$TMPDIR`, whole slices run end to end, assertions on what each command accepts
and refuses. Run it as the repo owner after any change to `sti.sh`, `audit.py` or
`count.py` — it is the only evidence that the blindness still holds.

```bash
bash <this skill's directory>/scripts/sti_test.sh
```

See [REFERENCE.md](REFERENCE.md) for prompt templates, leak channels, and the
escalation policy.
