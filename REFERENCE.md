# Reference: split-test-impl

## Prompt templates

### Test worker (step 2)

> You are writing tests for a slice of this system. You have **not** implemented
> it and you will not. Your job is to find out whether the spec is precise
> enough to implement.
>
> Spec: `specs/<slice>.md` — read it fully before writing anything.
> Vault: `<test vault>` — a private git repo at the base commit. Commit your
> tests there.
>
> Rules:
> - Test through the public contract only. No private imports, no mocking of
>   internal collaborators, no asserting on call order or internal structure.
> - One requirement per test. Put `# spec: Rn` directly above each test.
>   `# spec: SKIP <reason>` only for a regression guard on existing behaviour.
> - Every requirement `Rn` in the spec needs at least one test. If a requirement
>   is untestable as written, say so — do not invent a weaker version.
> - A test that is always skipped proves nothing. Do not use `pytest.mark.skip`
>   to make a suite pass; if a requirement genuinely cannot run here, report it.
> - If the spec is ambiguous, stop and report the ambiguity instead of guessing.
>   Ambiguity you paper over here becomes a failing test the implementer cannot
>   fix without seeing it.
> - Commit when done, then stop.

### Implementation worker (step 4)

> Implement the slice described in `specs/<slice>.md` in this worktree:
> `<impl worktree>`.
>
> There is **no test suite** for this slice. None exists, none is expected, and
> looking for one is a waste of your time. Do not write tests.
>
> Rules:
> - The spec is the contract. Implement what it says, including names,
>   signatures and error behaviour. If it is ambiguous or self-contradictory,
>   stop and report it — do not pick an interpretation silently.
> - Follow the repo conventions in the project's agent instructions file
>   (`AGENTS.md` / `CLAUDE.md`): layout, naming, lint, typecheck and where tests
>   live.
> - Run the existing suite and `ruff`/`mypy` yourself to check you broke nothing.
>   Do not add a `conftest.py` that ignores test directories.
> - When done, report what you implemented and anything in the spec you could
>   not satisfy.

### Orchestrator's check loop (step 5)

Run `sti.sh check <slice>`, then give the worker **only** the counts line from
stdout, plus your own reading of it:

> `passed=14 failed=2 errors=0 skipped=0 total=16`
> Two behaviours are wrong. Keep implementing from the spec.

Never paste names, tracebacks, assertion diffs or your guess at what a test
does. If you catch yourself wanting to, that's the `reveal` decision. Ignore
the progress lines on stderr — they exist for you, not for the worker.

## Why two repositories

The obvious design — tests on a branch, implementation on a worktree of the same
repository — is not blind. Both branches live in one object store, so from the
implementation worktree a single command reads the whole suite:

```
git show tests/<slice>:tests/<slice>/test_x.py
```

`sti.sh` therefore gives each worker its own repository:

| | Test vault | Implementation worktree |
| --- | --- | --- |
| Location | `.git/sti/<slice>/tests` | `${TMPDIR:-/tmp}/sti/impl/<slice>` |
| Seeded from | `refs/sti/base/<slice>` in the main repo | the same ref |
| Owns | `tests/<slice>` and the frozen commit | `impl/<slice>` |
| Shared objects with the other | none | none |

`assert_blind` runs before every `check` and `finish`: if the frozen commit is
present as an object in the implementation repository, or a `tests/*` ref exists
there, the command refuses.

## Leak channels

Tests get through even when the files are hidden. Close all of these:

- **Filesystem** — enforced structurally: the frozen commit is not an object in
  the implementation repository, and `check` re-verifies it. The suite is
  executed in a throwaway copy under `/tmp`, never in the implementation
  worktree. `assert_tests_absent_from_impl` also compares blob hashes, so a
  frozen test copied in under a different name is still a leak.
- **Test output** — the biggest one. `check` parses pytest's junit XML and
  prints numbers, so no name or traceback reaches stdout.
- **Collection and skips** — enforced: `check` refuses when the frozen tests
  were not collected, or when every one of them skipped or xfailed. A green run
  that verified nothing is not a signal.
- **Agent memory** — use a fresh session for each worker. Do not summarise the
  test worker's reasoning when briefing the implementation worker.
- **The spec** — don't name test cases in it. Requirements are behaviours, not
  assertions. `freeze` pins the spec text, so it cannot be quietly rewritten
  after the tests were written against it.
- **Issues and PRs** — don't file the test worker's findings where the
  implementation worker will read them.
- **Commit messages and code comments** — the implementation branch must not
  mention specific tests, even "fixed the rounding case".
- **Stale slices** — `sti.sh reset <slice>` removes the vault, the worktree, the
  state file and `refs/sti/base/<slice>`. Run it on abandoned slices; a leftover
  `refs/sti/*` is a leftover frozen suite.

## Escalation policy

`reveal` is counted, and the third attempt is refused by the script. Two reveals
and you stop iterating. At that point one of these is true:

1. The spec is wrong → fix the spec, reset and re-open the slice with a new name.
2. The tests over-specify → they encode an implementation choice the spec never
   made. Re-open and delete those tests.
3. The implementation is wrong in a way that needs a specific hint → write the
   hint into the **spec** as a requirement, then re-open. Never paste the hint
   into the session.

Re-opening means a new slice name: `sti.sh reset <slice>` then
`sti.sh open <slice>-2 <spec>`.

## Cost

This is roughly 2x the tokens of writing tests and implementation in one
session, plus a review pass on the spec and one extra suite run per `check` (the
collection probe). It pays off when the slice is large enough that "looks right"
is a real risk — new domain packages, pricing and forecasting logic, anything
with a public API others will depend on. It is overkill for a bug fix with an
obvious fix.

## State and environment

`sti.sh` records state in `.git/sti/<slice>.env` and the test suite in
`.git/sti/<slice>/tests` — both inside `.git`, never tracked. Inspect with
`sti.sh status <slice>`; tear down with `sti.sh reset <slice>`.

| Variable | Default | Purpose |
| --- | --- | --- |
| `STI_WORKTREE_ROOT` | `$TMPDIR/sti` | Where implementation worktrees are created |
| `STI_TEST_TIMEOUT` | `600` | Seconds before a hung suite is killed |
| `STI_TEST_TMPDIR` | `$TMPDIR/sti-selftest` | Where `sti_test.sh` builds its repos |

Run the script as the user that owns the repository. It writes branches,
repositories and refs; files created by another user would lock the owner out
of their next commit.

## Verifying the harness itself

`scripts/sti_test.sh` runs whole slices in throwaway repositories and asserts on
what each command accepts and refuses, including the leak channels above:

```bash
bash scripts/sti_test.sh
```

It builds its own miniature repositories under `$TMPDIR` and touches nothing
outside them. Treat a red run as a broken promise in the skill, not as a flaky
test.
